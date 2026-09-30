import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// The approval commit owns both authority and the promised execution intent.
@MainActor
enum PermissionApprovalResolutionService {
    enum Scope { case once, task }
    enum Outcome {
        case queued(ExecutionRequestSubmissionService.Submission)
        case live, saved, ignored, failed
    }

    static func approve(
        task: AgentTask,
        scope: Scope,
        modelContext: ModelContext,
        heldGrants: [PermissionGrant] = [],
        persist: (() throws -> Void)? = nil
    ) -> Outcome {
        guard let payload = TaskRuntimePermissionOpenRequestStore.latestRequestPayload(for: task),
              TaskRuntimePermissionOpenRequestStore.hasOpenRequest(for: task) else { return .ignored }
        let snapshot = ExecutionMutationSnapshot(task)
        let approval = PermissionApprovalEventPayload.decoded(from: payload)
        let binding = TaskPermissionContinuation.binding(payload: payload, task: task, modelContext: modelContext)
        let grants = TaskRuntimePermissionOpenRequestStore.latestApprovalGrants(for: task)
        let runtime = approval?.providerID ?? task.resolvedRuntimeID
        let requestID = approval?.requestID
        let asks = InFlightPermissionCenter.shared.pendingAsks(taskID: task.id)
        let liveID = asks.first(where: { $0.requestID == requestID })?.requestID
            ?? (requestID == nil && asks.count == 1 ? asks.first?.requestID : nil)
        let stale: Bool
        do {
            let current = try binding.map { try TaskPermissionContinuation.isCurrent($0, task: task, modelContext: modelContext) } ?? true
            stale = task.isDone || task.status == .cancelled || runtime != task.resolvedRuntimeID
                || !current
        } catch {
            reportFailure(task: task, modelContext: modelContext)
            return .failed
        }
        if stale {
            TaskRuntimePermissionOpenRequestStore.resolveRequest(payload: payload, task: task)
            modelContext.insert(TaskEvent(task: task, eventType: TaskEventTypes.System.info,
                payload: "This permission request is no longer current. No continuation was started."))
            return save(task: task, modelContext: modelContext, persist: persist, snapshot: snapshot) ? .ignored : .failed
        }
        let shouldContinue = approval?.behavior != .futureUse
            && (binding != nil || liveID != nil || task.status == .pendingUser)
        let taskScope = scope == .task && !PermissionBroker.taskScopedApprovalGrants(for: grants).isEmpty
        guard shouldContinue || taskScope else { return .ignored }
        let apply = {
            if taskScope {
                _ = TaskRuntimePermissionGrants.record(grants: grants, providerID: runtime, task: task,
                    modelContext: modelContext, source: "approve_similar")
            }
            TaskRuntimePermissionOpenRequestStore.resolveRequest(payload: payload, task: task)
            task.updatedAt = Date()
            task.markRead()
            let detail = taskScope ? " for this task" : ""
            let effect = !shouldContinue ? " Permission saved for future use."
                : (liveID != nil ? " Approved for the live provider session." : " Continuation queued.")
            modelContext.insert(TaskEvent(task: task, eventType: TaskEventTypes.Task.approved,
                payload: "Runtime permission approved by user\(detail).\(effect)"))
        }
        if !shouldContinue {
            apply()
            return save(task: task, modelContext: modelContext, persist: persist, snapshot: snapshot) ? .saved : .failed
        }
        if let liveID {
            apply()
            if let binding {
                LivePermissionApprovalRecovery.record(binding: binding, requestID: liveID, runtime: runtime,
                    grants: heldGrants + (taskScope ? [] : grants), taskScope: taskScope,
                    task: task, modelContext: modelContext)
            }
            guard save(task: task, modelContext: modelContext, persist: persist, snapshot: snapshot) else { return .failed }
            if InFlightPermissionCenter.shared.resolve(taskID: task.id, requestID: liveID, approved: true) { return .live }
            // The process can die while persistence is in progress. Preserve
            // the already committed grant and submit a durable replacement run.
            TaskRuntimePermissionOpenRequestStore.recordOpenRequest(payload: payload, task: task)
            return approve(task: task, scope: scope, modelContext: modelContext, heldGrants: heldGrants, persist: persist)
        }
        let message = PermissionBroker.resumeMessage(
            providerID: runtime,
            grants: taskScope ? PermissionBroker.taskScopedApprovalGrants(for: grants) : grants,
            fallback: TaskRuntimePermissionOpenRequestStore.latestRequestedToolName(for: task)
                .flatMap { PermissionBroker.permissionGrant(fromProviderString: $0)?.displayName },
            scopeDescription: taskScope ? "task-scoped runtime permission for similar requests in this task" : "one-time runtime permission"
        )
        let policy: AgentRuntimeExecutionPolicy = taskScope && heldGrants.isEmpty
            ? .default : PermissionBroker.executionPolicy(forRuntime: runtime, grants: heldGrants + (taskScope ? [] : grants))
        let approvalID = binding.map { "\($0.runID.uuidString):\(requestID ?? payload)" }
            ?? requestID
        let result = ExecutionRequestSubmissionService.submitPermissionResume(
            message: binding.map { TaskPermissionContinuation.resumeMessage(message, binding: $0) } ?? TaskPermissionContinuation.legacyResumeMessage(message, task: task, payload: payload),
            executionPolicy: policy,
            for: task, into: modelContext,
            continuation: binding, approvalID: approvalID,
            persist: persist, prepare: apply,
            rollback: { snapshot.restore(task, in: modelContext) }
        )
        guard case .success(let submission) = result else {
            reportFailure(task: task, modelContext: modelContext)
            return .failed
        }
        return .queued(submission)
    }

    private static func save(task: AgentTask, modelContext: ModelContext, persist: (() throws -> Void)?, snapshot: ExecutionMutationSnapshot) -> Bool {
        do {
            if let persist { try persist() }
            else {
                try WorkspacePersistenceCoordinator.saveAndAutoExportOrThrow(workspace: task.workspace,
                    modelContext: modelContext, taskID: task.id, auditFields: ["operation": "permission_approval"])
            }
            return true
        } catch {
            snapshot.restore(task, in: modelContext)
            reportFailure(task: task, modelContext: modelContext)
            return false
        }
    }

    private static func reportFailure(task: AgentTask, modelContext: ModelContext) {
        AppLogger.audit(.taskFailed, category: "Persistence", taskID: task.id,
            fields: ["operation": "permission_approval", "result": "not_submitted"], level: .error)
        modelContext.insert(TaskEvent(task: task, eventType: TaskEventTypes.System.info,
            payload: "Permission approval could not be saved. The request remains open; please try again."))
        TaskThreadChangeNotifier.post(taskID: task.id, source: "permission_approval_failed")
    }
}

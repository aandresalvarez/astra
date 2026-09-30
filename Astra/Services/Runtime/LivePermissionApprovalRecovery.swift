import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// A live approval is committed before the process-local control channel is
/// answered. Only a receipt recorded after a successful stdin write closes
/// the delivery crash window; a local decision event is not such a receipt.
@MainActor
enum LivePermissionApprovalRecovery {
    struct Commit: Codable {
        let requestID: String
        let runtime: AgentRuntimeID
        let binding: PermissionApprovalContinuation
        let grants: [PermissionGrant]
        let taskScope: Bool
        var approvalID: String { "\(binding.runID.uuidString):\(requestID)" }
    }

    static func record(binding: PermissionApprovalContinuation, requestID: String, runtime: AgentRuntimeID,
                       grants: [PermissionGrant], taskScope: Bool, task: AgentTask, modelContext: ModelContext) {
        let commit = Commit(requestID: requestID, runtime: runtime, binding: binding, grants: grants, taskScope: taskScope)
        modelContext.insert(TaskEvent.structuredPayloadEvent(task: task,
            type: TaskEventTypes.Tool.permissionLiveApprovalCommitted.rawValue,
            payload: commit, run: task.runs.first { $0.id == binding.runID }))
    }

    @discardableResult
    static func recordDelivery(requestID: String, toolName: String, task: AgentTask,
                               run: TaskRun, modelContext: ModelContext,
                               persist: (() throws -> Void)? = nil) -> Bool {
        let event = TaskEvent(task: task, eventType: TaskEventTypes.Tool.permissionApprovalDelivered,
            payload: PermissionRequestResolution(requestID: requestID, approved: true, toolName: toolName).payloadString,
            run: run)
        modelContext.insert(event)
        do {
            if let persist { try persist() }
            else {
                try WorkspacePersistenceCoordinator.saveWithoutAutoExportOrThrow(workspace: task.workspace,
                    modelContext: modelContext, taskID: task.id, auditFields: ["operation": "live_approval_delivery"])
            }
            return true
        } catch {
            modelContext.delete(event)
            AppLogger.audit(.taskFailed, category: "Persistence", taskID: task.id,
                fields: ["operation": "live_approval_delivery", "result": "receipt_not_saved"], level: .error)
            return false
        }
    }

    /// Startup calls this after orphaned runs and their original requests have
    /// been settled, before normal queue replay. Recovery never starts a provider.
    @discardableResult
    static func recover(modelContext: ModelContext, autoExportWorkspaces: Bool = true) -> Int {
        let type = TaskEventTypes.Tool.permissionLiveApprovalCommitted.rawValue
        let events: [TaskEvent]
        do { events = try modelContext.fetch(FetchDescriptor<TaskEvent>(predicate: #Predicate { $0.type == type })) }
        catch {
            AppLogger.audit(.taskFailed, category: "Persistence", fields: ["operation": "live_approval_recovery_fetch"], level: .error)
            return 0
        }
        var submitted = 0
        for event in events {
            guard let task = event.task,
                  let data = event.payload.data(using: .utf8),
                  let commit = try? JSONDecoder().decode(Commit.self, from: data),
                  task.resolvedRuntimeID == commit.runtime,
                  (try? TaskPermissionContinuation.isCurrent(commit.binding, task: task, modelContext: modelContext,
                      recoveringRestart: true)) == true else { continue }
            let delivered = task.events.contains {
                !$0.isDeleted && $0.type == TaskEventTypes.Tool.permissionApprovalDelivered.rawValue && $0.run?.id == commit.binding.runID
                    && $0.timestamp >= event.timestamp
                    && PermissionRequestResolution.decode(from: $0.payload)?.requestID == commit.requestID
                    && PermissionRequestResolution.decode(from: $0.payload)?.approved == true
            }
            guard !delivered else { continue }
            var binding = commit.binding
            binding.mode = .relaunch
            let snapshot = ExecutionMutationSnapshot(task)
            let policy: AgentRuntimeExecutionPolicy = commit.taskScope && commit.grants.isEmpty
                ? .default : PermissionBroker.executionPolicy(forRuntime: commit.runtime, grants: commit.grants)
            let message = TaskPermissionContinuation.resumeMessage(
                PermissionBroker.resumeMessage(providerID: commit.runtime, grants: commit.grants), binding: commit.binding
            )
            let result = ExecutionRequestSubmissionService.submitPermissionResume(message: message, executionPolicy: policy,
                for: task, into: modelContext, continuation: binding, approvalID: commit.approvalID,
                persist: autoExportWorkspaces ? nil : {
                    try WorkspacePersistenceCoordinator.saveWithoutAutoExportOrThrow(workspace: task.workspace,
                        modelContext: modelContext, taskID: task.id, auditFields: ["operation": "live_approval_recovery"])
                },
                prepare: {
                    modelContext.insert(TaskEvent(task: task, eventType: TaskEventTypes.Task.approved,
                        payload: "Runtime permission approval recovered after restart. Continuation queued."))
                }, rollback: { snapshot.restore(task, in: modelContext) })
            if case .success = result { submitted += 1 }
        }
        return submitted
    }
}

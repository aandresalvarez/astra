import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// A live approval is committed before the process-local control channel is
/// answered. Only observed provider turn completion closes the delivery crash
/// window; local decisions and successful pipe writes are not acknowledgements.
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

    private struct DeliveryReceipt: Codable {
        let version: Int
        let evidence: String
        let requestID: String
        let approved: Bool
        let toolName: String

        init(requestID: String, toolName: String) {
            version = 1
            evidence = "provider_turn_completed"
            self.requestID = requestID
            approved = true
            self.toolName = toolName
        }
    }

    private struct BindingKey: Hashable {
        let taskID: UUID
        let runID: UUID
        let sourceEventID: UUID?
        let originalUserRequest: String
        let runtime: String
    }

    private struct PendingApproval {
        let task: AgentTask
        let commit: Commit
        let delivered: Bool
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
        guard !task.isDeleted, !run.isDeleted else { return false }
        let event = TaskEvent(task: task, eventType: TaskEventTypes.Tool.permissionApprovalDelivered,
            payload: TaskEvent.payloadString(DeliveryReceipt(requestID: requestID, toolName: toolName)),
            run: run)
        modelContext.insert(event)
        do {
            if let persist { try persist() }
            else {
                try WorkspacePersistenceCoordinator.saveAndAutoExportOrThrow(workspace: task.workspace,
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

    /// Restore receipt evidence into the durable transaction at settlement.
    /// Leave staged receipts in the context if saving fails, so a later save
    /// cannot persist the approval commit while losing its acknowledgement.
    @discardableResult
    static func stageAcknowledgements(task: AgentTask, run: TaskRun, requestIDs: Set<String>,
                                      modelContext: ModelContext) -> Bool {
        var staged = false
        for id in requestIDs {
            guard let commitEvent = task.events.filter({
                !$0.isDeleted && $0.run?.id == run.id
                    && $0.type == TaskEventTypes.Tool.permissionLiveApprovalCommitted.rawValue
                    && (try? JSONDecoder().decode(Commit.self, from: Data($0.payload.utf8)))?.requestID == id
            }).max(by: { $0.timestamp < $1.timestamp }),
                !hasDeliveryReceipt(requestID: id, task: task, run: run, after: commitEvent.timestamp) else { continue }
            modelContext.insert(TaskEvent(task: task, eventType: TaskEventTypes.Tool.permissionApprovalDelivered,
                payload: TaskEvent.payloadString(DeliveryReceipt(requestID: id, toolName: "Approved tool")), run: run))
            staged = true
        }
        return staged
    }

    static func hasDeliveryReceipt(requestID: String, task: AgentTask, run: TaskRun, after: Date = .distantPast) -> Bool {
        task.events.contains {
            guard !$0.isDeleted, $0.run?.id == run.id, $0.timestamp >= after,
                  $0.type == TaskEventTypes.Tool.permissionApprovalDelivered.rawValue,
                  case .success(let receipt) = $0.decodePayload(as: DeliveryReceipt.self) else { return false }
            return receipt.version == 1 && receipt.evidence == "provider_turn_completed"
                && receipt.approved && receipt.requestID == requestID
        }
    }

    static func unacknowledgedCommits(task: AgentTask, run: TaskRun, acknowledgedRequestIDs: Set<String>,
                                      modelContext: ModelContext) throws -> [Commit] {
        try task.events.compactMap { event in
            guard !event.isDeleted, event.run?.id == run.id,
                  event.type == TaskEventTypes.Tool.permissionLiveApprovalCommitted.rawValue else { return nil }
            let commit = try JSONDecoder().decode(Commit.self, from: Data(event.payload.utf8))
            guard TaskPermissionContinuation.runtime(forRunID: commit.binding.runID, task: task) == commit.runtime,
                  try TaskPermissionContinuation.isCurrent(commit.binding, task: task, modelContext: modelContext),
                  !acknowledgedRequestIDs.contains(commit.requestID),
                  !hasDeliveryReceipt(requestID: commit.requestID, task: task, run: run, after: event.timestamp) else { return nil }
            return commit
        }
    }

    /// Stages recovery in the caller's settlement transaction and propagates
    /// submission failures. No later save may mark this turn settled while
    /// silently losing its required continuation.
    static func recoverForSettlement(task: AgentTask, run: TaskRun, modelContext: ModelContext,
                                      acknowledgedRequestIDs: Set<String>, persist: @escaping () throws -> Void) throws -> Int {
        let events = task.events.filter {
            $0.type == TaskEventTypes.Tool.permissionLiveApprovalCommitted.rawValue && $0.run?.id == run.id
        }
        return try recover(events: events, modelContext: modelContext, autoExportWorkspaces: true,
            recoveringRestart: false, acknowledgedPermissionRequestIDs: acknowledgedRequestIDs, persist: persist)
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
        return (try? recover(events: events, modelContext: modelContext,
            autoExportWorkspaces: autoExportWorkspaces, recoveringRestart: true)) ?? 0
    }

    /// Runtime settlement also closes the failed-delivery window in the current
    /// session. Submission is durable; the existing queue dispatches it after
    /// the current worker and its resource lease have been released.
    @discardableResult
    static func recoverSettledRun(task: AgentTask, run: TaskRun, modelContext: ModelContext,
                                  acknowledgedPermissionRequestIDs: Set<String> = [],
                                  autoExportWorkspaces: Bool = true) -> Int {
        guard !task.isDeleted, !run.isDeleted, run.status != .running else { return 0 }
        let events = task.events.filter {
            $0.type == TaskEventTypes.Tool.permissionLiveApprovalCommitted.rawValue && $0.run?.id == run.id
        }
        return (try? recover(events: events, modelContext: modelContext,
            autoExportWorkspaces: autoExportWorkspaces, recoveringRestart: false,
            acknowledgedPermissionRequestIDs: acknowledgedPermissionRequestIDs)) ?? 0
    }

    private static func recover(events: [TaskEvent], modelContext: ModelContext,
                                autoExportWorkspaces: Bool, recoveringRestart: Bool,
                                acknowledgedPermissionRequestIDs: Set<String> = [],
                                persist: (() throws -> Void)? = nil) throws -> Int {
        // Validate every commit before creating any newer turn request. Recovery
        // itself must not make another approval of the same binding look stale.
        var groups: [BindingKey: [PendingApproval]] = [:]
        for event in events.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard !event.isDeleted, let task = event.task,
                  !task.events.contains(where: { $0.run?.id == event.run?.id
                      && $0.type == TaskEventTypes.System.runtimeReconciliationRequired.rawValue }),
                  !(recoveringRestart && event.run.map { RuntimeTurnSettlementService.hasUnsettledResult(task: task, run: $0) } == true),
                  let data = event.payload.data(using: .utf8),
                  let commit = try? JSONDecoder().decode(Commit.self, from: data),
                  TaskPermissionContinuation.runtime(forRunID: commit.binding.runID, task: task) == commit.runtime,
                  (try? TaskPermissionContinuation.isCurrent(commit.binding, task: task, modelContext: modelContext,
                      recoveringRestart: recoveringRestart)) == true else { continue }
            let delivered = acknowledgedPermissionRequestIDs.contains(commit.requestID)
                || event.run.map { hasDeliveryReceipt(requestID: commit.requestID, task: task, run: $0, after: event.timestamp) } == true
            let key = BindingKey(taskID: task.id, runID: commit.binding.runID,
                sourceEventID: commit.binding.sourceEventID, originalUserRequest: commit.binding.originalUserRequest,
                runtime: commit.runtime.rawValue)
            groups[key, default: []].append(PendingApproval(task: task, commit: commit, delivered: delivered))
        }
        var submitted = 0
        for group in groups.values {
            // Delivery decides whether recovery is necessary, not which
            // already-approved authority belongs to this originating turn.
            guard group.contains(where: { !$0.delivered }), let first = group.first else { continue }
            let task = first.task
            let commit = first.commit
            var binding = commit.binding
            binding.mode = .relaunch
            let snapshot = ExecutionMutationSnapshot(task)
            var seenGrants: Set<PermissionGrant> = []
            let grants = group.flatMap { $0.commit.grants }.filter { seenGrants.insert($0).inserted }
            let policy: AgentRuntimeExecutionPolicy = grants.isEmpty
                ? .default : PermissionBroker.executionPolicy(forRuntime: commit.runtime, grants: grants)
            let message = TaskPermissionContinuation.resumeMessage(
                PermissionBroker.resumeMessage(providerID: commit.runtime, grants: grants), binding: binding
            )
            let approvalID = "live:\(binding.runID.uuidString):\(binding.sourceEventID?.uuidString ?? "legacy")"
            let result = ExecutionRequestSubmissionService.submitPermissionResume(message: message, executionPolicy: policy,
                for: task, into: modelContext, continuation: binding, approvalID: approvalID,
                persist: persist ?? (autoExportWorkspaces ? nil : {
                    try WorkspacePersistenceCoordinator.saveWithoutAutoExportOrThrow(workspace: task.workspace,
                        modelContext: modelContext, taskID: task.id, auditFields: ["operation": "live_approval_recovery"])
                }),
                prepare: {
                    modelContext.insert(TaskEvent(task: task, eventType: TaskEventTypes.Task.approved,
                        payload: recoveringRestart
                            ? "Runtime permission approval recovered after restart. Continuation queued."
                            : "Runtime permission approval recovered after provider exit. Continuation queued."))
                }, rollback: { snapshot.restore(task, in: modelContext) })
            guard case .success = result else { throw RuntimeTurnSettlementService.Failure.recoverySubmissionFailed }
            if case .success = result {
                submitted += 1
                AppLogger.audit(.taskApproved, category: "PermissionApproval", taskID: task.id,
                    fields: ["approval_scope": "recovered", "runtime": commit.runtime.rawValue,
                        "outcome": "queued", "request_count": String(group.count)])
            }
        }
        return submitted
    }
}

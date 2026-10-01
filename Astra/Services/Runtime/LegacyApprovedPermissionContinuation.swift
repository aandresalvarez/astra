import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

/// Explicit recovery for older tasks whose grant was saved without scheduling
/// the promised continuation. Merely rendering this action never changes state.
enum LegacyApprovedPermissionContinuation {
    static func isAvailable(task: AgentTask) -> Bool {
        requestEvent(task: task) != nil
    }

    private static func requestEvent(task: AgentTask) -> TaskEvent? {
        guard task.status == .completed, !task.isDone,
              !TaskRuntimePermissionOpenRequestStore.hasOpenRequest(for: task),
              let run = task.runs.max(by: { $0.startedAt < $1.startedAt }),
              let event = task.events.filter({ $0.type == "permission.approval.requested" && $0.run?.id == run.id })
                .max(by: { $0.timestamp < $1.timestamp }),
              let approval = PermissionApprovalEventPayload.decoded(from: event.payload),
              !TaskPermissionContinuation.isFutureUse(payload: event.payload, task: task),
              approval.requestID?.hasPrefix(BrokeredCredentialApprovalRecord.offerRequestIDPrefix) == true,
              approval.providerID == TaskPermissionContinuation.runtime(forRunID: run.id, task: task),
              !task.events.contains(where: {
                  ($0.type.hasPrefix("execution.request.") && $0.timestamp > event.timestamp)
                      || ($0.type == "user.message" && $0.timestamp > run.startedAt)
              }) else { return nil }
        let latestResolution = task.events.filter {
            !$0.isDeleted && $0.type == TaskEventTypes.Tool.permissionRequestResolved.rawValue
                && $0.timestamp >= event.timestamp
                && PermissionRequestResolution.decode(from: $0.payload)?.requestID == approval.requestID
        }.max { $0.timestamp < $1.timestamp }
        guard latestResolution.flatMap({ PermissionRequestResolution.decode(from: $0.payload) })?.approved != false else { return nil }
        let labels = PermissionBroker.structuredApprovalGrants(from: event.payload).compactMap { grant -> String? in
            if case .credential(let label) = grant { return label }; return nil
        }
        let approved = Set(TaskRuntimePermissionGrants.approvedCredentialLabels(for: task, runtime: approval.providerID))
        // The saved authority is the durable approval evidence, including for
        // older tasks whose human-readable approval notice was compacted.
        guard !labels.isEmpty, labels.allSatisfy(approved.contains) else { return nil }
        return event
    }

    @MainActor
    static func submit(task: AgentTask, modelContext: ModelContext) -> ExecutionRequestSubmissionService.Submission? {
        guard let event = requestEvent(task: task), let run = event.run else { return nil }
        let binding = TaskPermissionContinuation.capture(task: task, run: run, modelContext: modelContext)
        guard (try? TaskPermissionContinuation.isCurrent(binding, task: task, modelContext: modelContext)) == true else { return nil }
        let snapshot = ExecutionMutationSnapshot(task)
        let approvalID = "\(run.id.uuidString):\(PermissionApprovalEventPayload.decoded(from: event.payload)?.requestID ?? event.id.uuidString)"
        let message = TaskPermissionContinuation.resumeMessage("Continue using the connector permission already approved for this task.", binding: binding)
        let result = ExecutionRequestSubmissionService.submitPermissionResume(message: message, executionPolicy: .default,
            for: task, into: modelContext, continuation: binding, approvalID: approvalID,
            prepare: {
                modelContext.insert(TaskEvent(task: task, eventType: TaskEventTypes.Task.approved,
                    payload: "Runtime permission already approved. Continuation queued."))
            }, rollback: { snapshot.restore(task, in: modelContext) })
        if case .success(let submission) = result { return submission }
        return nil
    }
}

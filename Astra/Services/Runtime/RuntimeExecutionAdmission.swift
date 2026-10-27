import Foundation
import SwiftData
import ASTRAModels

/// A continuation-shaped prompt does not grant permission to bypass recovery
/// proof. Only its durable source distinguishes new work from replaying work.
enum RuntimeExecutionAdmission {
    case recovery, userInstruction, approvedContinuation
    var isNewUserTurn: Bool { self != .recovery }

    @MainActor
    static func resolve(request: TaskTurnRequest?, task: AgentTask) -> Self {
        guard let request, request.taskID == task.id,
              let source = TaskHistoryRead.event(id: request.sourceEventID, in: task) else { return .recovery }
        if source.type == TaskEventTypes.Conversation.userMessage.rawValue, request.kind == .followUp {
            // The source-to-run link survives requeue/restart even when the
            // request's current-attempt fields are cleared. Replaying that
            // durable instruction must not mint another request allowance.
            return source.run == nil && request.runID == nil && request.startedAt == nil
                ? .userInstruction : .recovery
        }
        guard let payload = ExecutionRequestSubmissionService.decodeSourcePayload(source) else { return .recovery }
        if source.type == TaskEventTypes.ExecutionRequest.planStep.rawValue, request.kind == .planStep,
           payload.launchMode == .approvedPlan, payload.planSnapshot != nil, payload.planExecutionMode != nil {
            return .approvedContinuation
        }
        if source.type == TaskEventTypes.ExecutionRequest.permissionResume.rawValue,
           payload.permissionContinuation != nil, payload.permissionApprovalID?.isEmpty == false {
            return .approvedContinuation
        }
        return .recovery
    }
}

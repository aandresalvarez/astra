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
              let source = task.events.first(where: { $0.id == request.sourceEventID }) else { return .recovery }
        if source.type == TaskEventTypes.Conversation.userMessage.rawValue, request.kind == .followUp {
            return .userInstruction
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

import Foundation
import SwiftData
import ASTRAModels
import ASTRAPersistence

/// A continuation-shaped prompt does not grant permission to bypass recovery
/// proof. Only its durable source distinguishes new work from replaying work.
enum RuntimeExecutionAdmission {
    case recovery, userInstruction, approvedContinuation
    var isNewUserTurn: Bool { self != .recovery }

    typealias RequestReader = @MainActor (UUID, ModelContext) throws -> TaskTurnRequest?

    enum RequestReadFailure: String, Error {
        case missing = "execution_request_missing"
        case invalidOwner = "execution_request_invalid_owner"
        case unreadable = "execution_request_unreadable"
        case invalidResourceClaims = "execution_request_invalid_resource_claims"
    }

    /// Only an omitted ID denotes a direct launch. A supplied ID must retain
    /// its durable local owner; an unavailable row cannot inherit live settings.
    @MainActor
    static func readSubmittedRequest(
        id: UUID?, task: AgentTask, context: ModelContext,
        read: RequestReader = { try TaskTurnRequestRepository.request(id: $0, in: $1) }
    ) throws -> TaskTurnRequest? {
        guard let id else { return nil }
        do {
            guard task.isLive, task.modelContext === context else { throw RequestReadFailure.invalidOwner }
            guard let request = try read(id, context) else { throw RequestReadFailure.missing }
            guard request.id == id, !request.isDeleted, request.modelContext === context,
                  request.taskID == task.id,
                  try TaskTurnRequestOwnership.resolve(request, in: context)?.persistentModelID == task.persistentModelID
            else { throw RequestReadFailure.invalidOwner }
            guard request.decodedResourceClaims != nil else { throw RequestReadFailure.invalidResourceClaims }
            return request
        } catch let failure as RequestReadFailure {
            throw failure
        } catch {
            throw RequestReadFailure.unreadable
        }
    }

    @MainActor
    static func rejectRequest(_ error: Error, task: AgentTask, context: ModelContext) {
        let reason = (error as? RequestReadFailure ?? .unreadable).rawValue
        AppLogger.audit(.workerBlocked, category: "Worker", taskID: task.id,
            fields: ["reason": reason], level: .warning)
        guard task.isLive, task.modelContext === context else { return }
        TaskStateMachine.failFromRuntime(task, modelContext: context)
        context.insert(TaskEvent(task: task, eventType: TaskEventTypes.System.error,
            payload: "The saved execution request could not be verified. Further execution was blocked."))
        WorkspacePersistenceCoordinator.saveWithoutAutoExport(modelContext: context)
    }

    @MainActor
    static func resolve(request: TaskTurnRequest?, task: AgentTask) -> Self {
        guard let request, request.taskID == task.id,
              let source = TaskHistoryRead.event(id: request.sourceEventID, in: task) else { return .recovery }
        if let context = task.modelContext,
           (try? TaskTurnRequestOwnership.resolve(request, in: context))?.persistentModelID != task.persistentModelID { return .recovery }
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

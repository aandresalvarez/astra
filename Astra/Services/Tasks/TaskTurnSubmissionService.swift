import Foundation
import SwiftData
import ASTRAModels
import ASTRAPersistence

/// Atomic Send-boundary persistence for task conversations.
///
/// The returned request is now the durable source of truth for queue
/// admission. Callers must clear their composer only after this API returns
/// success. It intentionally does not start provider work.
@MainActor
enum TaskTurnSubmissionService {
    struct Submission: Equatable {
        let requestID: UUID
        let eventID: UUID
        let sequence: Int
    }

    enum SubmissionError: Error, Equatable {
        case emptyMessage
        case persistenceFailed(String)
    }

    static func submit(
        message: String,
        for task: AgentTask,
        into modelContext: ModelContext,
        at date: Date = Date()
    ) -> Result<Submission, SubmissionError> {
        switch ExecutionRequestSubmissionService.submitFollowUp(
            message: message,
            for: task,
            into: modelContext,
            at: date
        ) {
        case .success(let submission):
            return .success(Submission(
                requestID: submission.requestID,
                eventID: submission.eventID,
                sequence: submission.sequence
            ))
        case .failure(.emptySource):
            return .failure(.emptyMessage)
        case .failure(.persistenceFailed(let reason)):
            return .failure(.persistenceFailed(reason))
        }
    }
}

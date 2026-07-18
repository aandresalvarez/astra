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
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else { return .failure(.emptyMessage) }

        let nextSequence: Int
        do {
            nextSequence = try TaskTurnRequestRepository.nextSequence(for: task, in: modelContext)
        } catch {
            return .failure(.persistenceFailed(String(describing: type(of: error))))
        }
        let event = TaskEvent(
            task: task,
            eventType: TaskEventTypes.Conversation.userMessage,
            payload: trimmedMessage
        )
        event.timestamp = date
        let request = TaskTurnRequest(
            task: task,
            messageEventID: event.id,
            sequence: nextSequence,
            submittedAt: date
        )

        modelContext.insert(event)
        modelContext.insert(request)
        do {
            try WorkspacePersistenceCoordinator.saveAndAutoExportOrThrow(
                workspace: task.workspace,
                modelContext: modelContext,
                taskID: task.id,
                auditFields: [
                    "operation": "turn_submission",
                    "request_id": request.id.uuidString,
                    "message_length": String(trimmedMessage.count)
                ]
            )
        } catch {
            // Ensure a retry cannot accidentally save an earlier failed
            // submission along with its fresh replacement.
            modelContext.delete(request)
            modelContext.delete(event)
            return .failure(.persistenceFailed(String(describing: type(of: error))))
        }

        TaskEventInsertionService.publishInsertion(for: event)
        TaskThreadChangeNotifier.post(taskID: task.id, source: "turn_submitted")
        return .success(Submission(requestID: request.id, eventID: event.id, sequence: nextSequence))
    }
}

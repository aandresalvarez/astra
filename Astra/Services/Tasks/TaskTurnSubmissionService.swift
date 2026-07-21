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
        // While the task is running, an auto-export here races runtime
        // finalization's own terminal-state export: `WorkspaceConfigManager
        // .autoExport` snapshots synchronously but writes via a *detached*
        // Task onto `WorkspaceAutoExportWriter`, so submission order does not
        // guarantee write order. If this still-running snapshot's write lands
        // after the finalizer's terminal one, the recovery JSON is left
        // showing a running status with no final output. The SwiftData save
        // below is durable regardless (recovery reads the store, not the
        // JSON mirror); defer the export to the terminal save that is
        // guaranteed to follow.
        let auditFields = [
            "operation": "turn_submission",
            "request_id": request.id.uuidString,
            "message_length": String(trimmedMessage.count)
        ]
        do {
            if task.status == .running {
                try WorkspacePersistenceCoordinator.saveWithoutAutoExportOrThrow(
                    workspace: task.workspace,
                    modelContext: modelContext,
                    taskID: task.id,
                    auditFields: auditFields
                )
            } else {
                try WorkspacePersistenceCoordinator.saveAndAutoExportOrThrow(
                    workspace: task.workspace,
                    modelContext: modelContext,
                    taskID: task.id,
                    auditFields: auditFields
                )
            }
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

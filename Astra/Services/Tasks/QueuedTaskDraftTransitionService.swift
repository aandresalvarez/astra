import Foundation
import SwiftData
import ASTRAModels
import ASTRAPersistence

/// Owns the atomic durable transition from queued execution back to an
/// editable draft. The queue remains responsible only for waking completion
/// handles after this service commits the request cancellation.
@MainActor
enum QueuedTaskDraftTransitionService {
    private struct RequestSnapshot {
        let request: TaskTurnRequest
        let state: TaskTurnRequestState
        let blockingTaskID: UUID?
        let blockerSummary: String?

        init(_ request: TaskTurnRequest) {
            self.request = request
            state = request.state
            blockingTaskID = request.blockingTaskID
            blockerSummary = request.blockerSummary
        }

        @MainActor
        func restore() {
            request.state = state
            request.blockingTaskID = blockingTaskID
            request.blockerSummary = blockerSummary
            request.terminalAt = nil
            request.terminalReason = nil
            TaskThreadChangeNotifier.post(
                taskID: request.taskID,
                source: "turn_request_\(state.rawValue)"
            )
        }
    }

    static func transition(_ task: AgentTask, modelContext: ModelContext) -> [UUID]? {
        guard task.status == .queued,
              let requests = try? TaskTurnRequestRepository.activeRequests(for: task, in: modelContext),
              requests.allSatisfy({ $0.state == .waitingForWorker || $0.state == .waitingForResource }) else {
            return nil
        }
        let taskSnapshot = TaskStateMachine.snapshot(task)
        let requestSnapshots = requests.map(RequestSnapshot.init)
        for request in requests {
            _ = TaskTurnRequestStateMachine.transition(
                request,
                to: .cancelled,
                terminalReason: "moved_to_draft_for_editing"
            )
        }
        TaskStateMachine.restoreDraftForEditing(task, modelContext: modelContext)
        do {
            try WorkspacePersistenceCoordinator.saveAndAutoExportOrThrow(
                workspace: task.workspace,
                modelContext: modelContext,
                taskID: task.id,
                auditFields: ["operation": "move_queued_task_to_draft"]
            )
            return requests.map(\.id)
        } catch {
            TaskStateMachine.restoreExecutionSubmissionFailure(
                task,
                snapshot: taskSnapshot,
                modelContext: modelContext,
                at: task.updatedAt
            )
            requestSnapshots.forEach { $0.restore() }
            AppLogger.audit(.taskFailed, category: "Persistence", taskID: task.id, fields: [
                "operation": "move_queued_task_to_draft",
                "error_type": String(describing: type(of: error))
            ], level: .error)
            return nil
        }
    }
}

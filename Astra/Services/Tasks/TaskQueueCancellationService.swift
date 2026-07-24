import Foundation
import SwiftData
import ASTRAModels
import ASTRAPersistence

/// Commits cancellation of durable queue authority before process-local
/// workers or completion handles are released. A failed save restores every
/// request exactly, allowing shutdown to be rejected without replaying work
/// that appeared cancelled only in memory.
@MainActor
enum TaskQueueCancellationService {
    private struct Snapshot {
        let request: TaskTurnRequest
        let state: TaskTurnRequestState
        let blockingTaskID: UUID?
        let blockerSummary: String?
        let terminalAt: Date?
        let terminalReason: String?

        init(_ request: TaskTurnRequest) {
            self.request = request
            state = request.state
            blockingTaskID = request.blockingTaskID
            blockerSummary = request.blockerSummary
            terminalAt = request.terminalAt
            terminalReason = request.terminalReason
        }

        @MainActor
        func restore() {
            request.state = state
            request.blockingTaskID = blockingTaskID
            request.blockerSummary = blockerSummary
            request.terminalAt = terminalAt
            request.terminalReason = terminalReason
            TaskThreadChangeNotifier.post(
                taskID: request.taskID,
                source: "turn_request_\(state.rawValue)"
            )
        }
    }

    static func cancelActiveRequests(
        in modelContext: ModelContext,
        persist: () -> Bool
    ) -> [UUID]? {
        let requests: [TaskTurnRequest]
        do {
            requests = try TaskTurnRequestRepository.allActiveRequests(in: modelContext)
        } catch {
            AppLogger.audit(.taskFailed, category: "Persistence", fields: [
                "operation": "fetch_cancel_all_execution_requests",
                "error_type": String(describing: type(of: error))
            ], level: .error)
            return nil
        }
        guard !requests.isEmpty else { return [] }

        let snapshots = requests.map(Snapshot.init)
        for request in requests {
            _ = TaskTurnRequestStateMachine.transition(
                request,
                to: .cancelled,
                terminalReason: "queue_cancelled"
            )
        }
        guard persist() else {
            snapshots.forEach { $0.restore() }
            AppLogger.audit(.taskFailed, category: "Persistence", fields: [
                "operation": "cancel_all_execution_requests",
                "result": "persist_failed"
            ], level: .error)
            return nil
        }
        return requests.map(\.id)
    }

    static func persist(_ modelContext: ModelContext) -> Bool {
        WorkspacePersistenceCoordinator.saveWithoutAutoExport(
            modelContext: modelContext,
            auditFields: ["operation": "cancel_all_execution_requests"]
        )
    }
}

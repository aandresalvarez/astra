import Foundation
import SwiftData
import ASTRAModels
import ASTRAPersistence

/// Reconciles durable turn admissions after an app restart. Worker and
/// resource-lock ownership are process-local, so no request may remain
/// admitted or running once a new process owns the store.
@MainActor
enum TaskTurnRequestRecoveryService {
    struct Summary: Equatable {
        var returnedToWaiting = 0
        var terminalized = 0

        var hasChanges: Bool { returnedToWaiting > 0 || terminalized > 0 }
    }

    @discardableResult
    static func recoverInterruptedRequests(
        modelContext: ModelContext,
        at recoveredAt: Date = Date()
    ) -> Summary {
        let requests: [TaskTurnRequest]
        do {
            requests = try modelContext.fetch(FetchDescriptor<TaskTurnRequest>())
        } catch {
            AppLogger.audit(.taskFailed, category: "Persistence", fields: [
                "operation": "recover_turn_requests_fetch",
                "error_type": String(describing: type(of: error))
            ], level: .error)
            return Summary()
        }

        var summary = Summary()
        var affectedWorkspaces: [UUID: Workspace] = [:]
        for request in requests where request.state.isActive {
            guard let task = request.task else {
                _ = TaskTurnRequestStateMachine.transition(
                    request,
                    to: .failed,
                    terminalReason: "missing_task",
                    at: recoveredAt
                )
                summary.terminalized += 1
                continue
            }

            if request.state == .running {
                let transition = TaskTurnRequestStateMachine.transition(
                    request,
                    to: .failed,
                    terminalReason: "app_restarted",
                    at: recoveredAt
                )
                if transition.changed { summary.terminalized += 1 }
            } else if let runID = request.runID,
               let run = task.runs.first(where: { $0.id == runID }),
               run.status != .running {
                let terminalState: TaskTurnRequestState = switch run.status {
                case .completed: .completed
                case .cancelled: .cancelled
                case .failed, .timeout, .budgetExceeded, .running: .failed
                }
                let transition = TaskTurnRequestStateMachine.transition(
                    request,
                    to: terminalState,
                    runID: run.id,
                    terminalReason: run.stopReason.isEmpty ? run.status.rawValue : run.stopReason,
                    at: recoveredAt
                )
                if transition.changed { summary.terminalized += 1 }
            } else {
                let transition = TaskTurnRequestStateMachine.transition(
                    request,
                    to: .waitingForWorker,
                    blockerSummary: "Recovered after ASTRA restarted; waiting for admission.",
                    at: recoveredAt
                )
                if transition.changed { summary.returnedToWaiting += 1 }
            }
            if let workspace = task.workspace {
                affectedWorkspaces[workspace.id] = workspace
            }
        }

        guard summary.hasChanges else { return summary }
        for workspace in affectedWorkspaces.values {
            WorkspacePersistenceCoordinator.saveAndAutoExport(
                workspace: workspace,
                modelContext: modelContext,
                auditFields: ["operation": "recover_turn_requests"]
            )
        }
        if affectedWorkspaces.isEmpty {
            WorkspacePersistenceCoordinator.saveWithoutAutoExport(
                modelContext: modelContext,
                auditFields: ["operation": "recover_turn_requests"]
            )
        }
        AppLogger.audit(.taskInterrupted, category: "App", fields: [
            "source": "startup_turn_request_recovery",
            "returned_to_waiting": String(summary.returnedToWaiting),
            "terminalized": String(summary.terminalized)
        ], level: .warning)
        return summary
    }
}

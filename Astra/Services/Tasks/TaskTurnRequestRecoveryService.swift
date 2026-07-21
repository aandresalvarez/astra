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
        at recoveredAt: Date = Date(),
        autoExportWorkspaces: Bool = true
    ) -> Summary {
        let requests: [TaskTurnRequest]
        do {
            // The table is append-only; recovery only ever acts on active
            // (non-terminal) rows, so bound the fetch at the store rather
            // than pulling the full history into memory to filter it.
            requests = try TaskTurnRequestRepository.allActiveRequests(in: modelContext)
        } catch {
            AppLogger.audit(.taskFailed, category: "Persistence", fields: [
                "operation": "recover_turn_requests_fetch",
                "error_type": String(describing: type(of: error))
            ], level: .error)
            return Summary()
        }
        guard !requests.isEmpty else { return Summary() }

        var summary = Summary()
        var affectedWorkspaces: [UUID: Workspace] = [:]
        // Resolve the owning task via the scalar `taskID` (there is no
        // relationship). Fetch once into a map, bounded to the distinct
        // task ids the active requests actually reference — not every
        // `AgentTask` row in the store.
        let taskIDs = Array(Set(requests.map(\.taskID)))
        let tasksByID = Dictionary(
            ((try? modelContext.fetch(
                FetchDescriptor<AgentTask>(predicate: #Predicate { taskIDs.contains($0.id) })
            )) ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for request in requests {
            guard let task = tasksByID[request.taskID] else {
                _ = TaskTurnRequestStateMachine.transition(
                    request,
                    to: .failed,
                    terminalReason: "missing_task",
                    at: recoveredAt
                )
                summary.terminalized += 1
                continue
            }

            // Prefer the linked run's outcome for BOTH running and admitted
            // requests. A run persists its terminal status
            // (AgentRuntimeRunPersistence.finalizeAndPersist) before the
            // request's own finalizer defer runs, so a crash in that window must
            // not mismark a genuinely completed turn as failed.
            if let runID = request.runID,
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
            } else if request.state == .running {
                // No terminal run to mirror — the run (if any) never finished.
                // Worker ownership is process-local, so a running turn cannot
                // survive the restart; fail it.
                let transition = TaskTurnRequestStateMachine.transition(
                    request,
                    to: .failed,
                    terminalReason: "app_restarted",
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
        // `autoExportWorkspaces: false` mirrors recoverOrphanedRunningRuns:
        // a launch that explicitly disabled workspace recovery (e.g.
        // ASTRA_SKIP_WORKSPACE_RECOVERY=true) must still persist the state
        // reconciliation but must not rewrite workspace export JSON.
        if autoExportWorkspaces {
            for workspace in affectedWorkspaces.values {
                WorkspacePersistenceCoordinator.saveAndAutoExport(
                    workspace: workspace,
                    modelContext: modelContext,
                    auditFields: ["operation": "recover_turn_requests"]
                )
            }
        }
        if affectedWorkspaces.isEmpty || !autoExportWorkspaces {
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

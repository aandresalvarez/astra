import Foundation
import SwiftData
import ASTRAModels
import ASTRAPersistence

/// Reconciles durable turn admissions after an app restart. Worker and
/// resource-lock ownership are process-local. An execution with a durable
/// unresolved owner is preserved until its termination can be established.
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
            // Repair a proved tool-free host completion before deciding whether
            // its saved follow-up lost an unresolved connection on restart.
            try RuntimeHostNoToolReceiptReconciliation.reconcile(
                in: RuntimeExecutionOwner.store(in: modelContext), context: modelContext)
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

        let ownership = RuntimeStartupRecoveryOwnership(context: modelContext)
        defer { withExtendedLifetime(ownership) {} }
        var summary = Summary()
        var affectedWorkspaces: [UUID: Workspace] = [:]
        // Resolve the owning task via the scalar `taskID` (there is no
        // relationship). Fetch once into a map, bounded to the distinct
        // task ids the active requests actually reference — not every
        // `AgentTask` row in the store.
        let taskIDs = Array(Set(requests.map(\.taskID)))
        let tasksByID = Dictionary(grouping: ((try? modelContext.fetch(
            FetchDescriptor<AgentTask>(predicate: #Predicate { taskIDs.contains($0.id) })
        )) ?? []), by: \.id)
        var resolver = TaskTurnRequestOwnership.Resolver(candidates: tasksByID.values.flatMap { $0 })
        for request in requests {
            guard ownership.claim(request.taskID) else { continue }
            guard let task = resolver.resolve(request) else {
                _ = TaskTurnRequestStateMachine.transition(
                    request,
                    to: .failed,
                    terminalReason: tasksByID[request.taskID]?.isEmpty == false ? "task_owner_unresolved" : "missing_task",
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
            if let runID = request.runID, let run = task.runs.first(where: { $0.id == runID }),
               RuntimeTurnSettlementService.hasUnsettledResult(task: task, run: run) { continue }
            if let runID = request.runID,
               let run = task.runs.first(where: { $0.id == runID }),
               run.status != .running {
                let terminalState: TaskTurnRequestState = switch run.status {
                case .completed: .completed
                case .cancelled: .cancelled
                case .failed, .timeout, .budgetExceeded, .running: .failed
                }
                let terminalReason = run.stopReason.isEmpty ? run.status.rawValue : run.stopReason
                var transition = TaskTurnRequestStateMachine.transition(
                    request,
                    to: terminalState,
                    runID: run.id,
                    terminalReason: terminalReason,
                    at: recoveredAt
                )
                // `.admitted` has no direct edge to `.completed` — a request
                // must run to complete. Left unhandled the transition is
                // rejected, `changed` stays false, the branches below are
                // skipped because they belong to this same chain, and the
                // request stays `.admitted` and active across every later
                // restart. The linked run did execute, so passing through
                // `.running` records what happened rather than inventing it.
                // (`.admitted -> .cancelled` and `-> .failed` are already
                // legal, so only the completed case needs this.)
                if transition.rejection != nil {
                    _ = TaskTurnRequestStateMachine.transition(
                        request,
                        to: .running,
                        runID: run.id,
                        at: recoveredAt
                    )
                    transition = TaskTurnRequestStateMachine.transition(
                        request,
                        to: terminalState,
                        runID: run.id,
                        terminalReason: terminalReason,
                        at: recoveredAt
                    )
                }
                if transition.changed {
                    summary.terminalized += 1
                } else if transition.rejection != nil {
                    // Never leave a recovered request stuck in a non-terminal
                    // state: return it to the admission queue instead, which is
                    // legal from every active state.
                    let requeued = TaskTurnRequestStateMachine.transition(
                        request,
                        to: .waitingForWorker,
                        blockerSummary: "Recovered after ASTRA restarted; waiting for admission.",
                        at: recoveredAt
                    )
                    if requeued.changed { summary.returnedToWaiting += 1 }
                }
            } else if !RuntimeCompletedUserTurnContinuation.permits(task: task, request: request, context: modelContext),
                      RuntimeExecutionOwner.preserveUnresolvedSession(task: task, context: modelContext, reportStatus: false) {
                // The app's connection ended; the execution itself is still unverified.
                // Keeping this admission "running" would show a false spinner and
                // consume a queue slot forever. The protected execution owner still
                // blocks every replacement, independently of this request outcome.
                let transition = TaskTurnRequestStateMachine.transition(
                    request, to: .failed, terminalReason: "runtime_connection_lost",
                    at: recoveredAt)
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

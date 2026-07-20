import Foundation
import SwiftData
import ASTRAModels
import ASTRAPersistence

/// Links a send-boundary event to its admitted run without creating a second
/// user message. Kept outside the runtime worker so the ownership rule stays
/// explicit and independently testable.
@MainActor
enum PersistedTurnRuntimeEventLinker {
    struct RuntimeBegin {
        let request: TaskTurnRequest?
        /// False only when the running-state save failed. The running state
        /// (with its run link) must be durable BEFORE provider work, exactly
        /// like the admitted save in `TaskQueue`: if the app exits after the
        /// provider mutates the workspace but before a later successful save,
        /// startup recovery still sees an admitted request without a run,
        /// returns it to waiting, and replays the whole turn — duplicating
        /// whatever the runtime already did. `beginRuntime` has already failed
        /// the run in this case; the worker must return before provider work.
        let persisted: Bool
    }

    /// Starts the persisted turn lifecycle as soon as its runtime attempt has
    /// a durable `TaskRun`. Kept outside the worker to avoid making provider
    /// execution own SwiftData turn-state policy.
    static func beginRuntime(
        requestID: UUID?,
        run: TaskRun,
        task: AgentTask,
        in modelContext: ModelContext
    ) -> RuntimeBegin {
        guard let requestID,
              let request = try? TaskTurnRequestRepository.request(id: requestID, in: modelContext) else {
            return RuntimeBegin(request: nil, persisted: true)
        }
        let transition = TaskTurnRequestStateMachine.transition(
            request,
            to: .running,
            runID: run.id
        )
        guard transition.changed else {
            return RuntimeBegin(request: request, persisted: true)
        }
        let persisted = WorkspacePersistenceCoordinator.saveWithoutAutoExport(
            modelContext: modelContext,
            taskID: task.id,
            auditFields: ["operation": "turn_request_running"]
        )
        if !persisted {
            AgentRuntimeLaunchPreflight.failLaunchForUnpersistedTurnState(
                run: run,
                task: task,
                modelContext: modelContext
            )
        }
        return RuntimeBegin(request: request, persisted: persisted)
    }

    /// Terminalizes the request after every runtime exit path, including
    /// preflight failures before a provider process starts.
    static func finishRuntime(
        request: TaskTurnRequest?,
        run: TaskRun,
        task: AgentTask,
        in modelContext: ModelContext
    ) {
        guard let request else { return }
        let terminalState: TaskTurnRequestState = switch run.status {
        case .completed: .completed
        case .cancelled: .cancelled
        case .running, .failed, .timeout, .budgetExceeded: .failed
        }
        let reason = run.stopReason.trimmingCharacters(in: .whitespacesAndNewlines)
        let transition = TaskTurnRequestStateMachine.transition(
            request,
            to: terminalState,
            runID: run.id,
            terminalReason: reason.isEmpty ? run.status.rawValue : reason
        )
        if transition.changed {
            WorkspacePersistenceCoordinator.saveAndAutoExport(
                workspace: task.workspace,
                modelContext: modelContext,
                taskID: task.id,
                auditFields: ["operation": "turn_request_\(terminalState.rawValue)"]
            )
        }
    }

    @discardableResult
    static func link(
        eventID: UUID?,
        to run: TaskRun,
        for task: AgentTask,
        fallbackType: String,
        fallbackPayload: String,
        in modelContext: ModelContext
    ) -> Bool {
        if let eventID,
           let event = task.events.first(where: { $0.id == eventID }) {
            event.run = run
            TaskThreadChangeNotifier.post(taskID: task.id, source: "turn_request_admitted")
            return true
        }
        let event = TaskEvent(task: task, type: fallbackType, payload: fallbackPayload, run: run)
        TaskEventInsertionService.insert(event, into: modelContext)
        return false
    }
}

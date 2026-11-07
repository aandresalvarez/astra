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
        in modelContext: ModelContext,
        persist: (() -> Bool)? = nil
    ) -> RuntimeBegin {
        // `requestID == nil` legitimately means a legacy (non-durable)
        // continuation — proceed with no request to track. `requestID` set
        // but its row unreadable (throws or genuinely missing) is different:
        // this IS a durable launch, just one that lost its bookkeeping row.
        // Silently proceeding would let the request stay `.admitted` while
        // provider work runs unowned; a crash before any later save then
        // lets startup recovery replay the same turn. Fail closed instead.
        guard let requestID else {
            return RuntimeBegin(request: nil, persisted: true)
        }
        guard let request = try? TaskTurnRequestRepository.request(id: requestID, in: modelContext) else {
            AgentRuntimeLaunchPreflight.failLaunchForUnpersistedTurnState(run: run, task: task, modelContext: modelContext)
            return RuntimeBegin(request: nil, persisted: false)
        }
        guard (try? TaskTurnRequestOwnership.resolve(request, in: modelContext))?.persistentModelID == task.persistentModelID,
              run.task?.persistentModelID == task.persistentModelID, request.state != .running || request.runID == run.id else {
            AgentRuntimeLaunchPreflight.failLaunchForUnpersistedTurnState(run: run, task: task, modelContext: modelContext)
            return RuntimeBegin(request: nil, persisted: false)
        }
        let transition = TaskTurnRequestStateMachine.transition(
            request,
            to: .running,
            runID: run.id
        )
        guard transition.rejection == nil else {
            AgentRuntimeLaunchPreflight.failLaunchForUnpersistedTurnState(run: run, task: task, modelContext: modelContext)
            return RuntimeBegin(request: request, persisted: false)
        }
        do {
            try recordAssociation(request, run: run, task: task, in: modelContext)
        } catch {
            AgentRuntimeLaunchPreflight.failLaunchForUnpersistedTurnState(run: run, task: task, modelContext: modelContext)
            return RuntimeBegin(request: request, persisted: false)
        }
        // Even an idempotent running transition may follow a source link or
        // historical association staged by `link`; save the whole boundary.
        let persisted = persist?() ?? WorkspacePersistenceCoordinator.saveWithoutAutoExport(
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
    ///
    /// `forcedOutcome` exists for launches whose real outcome is only decided
    /// after the run has settled — an approved plan's post-run checkpoint and
    /// contract validation can reject a run the provider reported as
    /// successful. Terminal request state is irreversible, so those callers
    /// must terminalize with the validated outcome rather than let the run's
    /// raw status report a success the task never got.
    static func finishRuntime(
        request: TaskTurnRequest?,
        run: TaskRun,
        task: AgentTask,
        acknowledgedPermissionRequestIDs: Set<String> = [],
        forcedOutcome: (state: TaskTurnRequestState, reason: String)? = nil,
        in modelContext: ModelContext
    ) {
        guard run.task?.persistentModelID == task.persistentModelID else { return }
        if let request, (try? TaskTurnRequestOwnership.resolve(request, in: modelContext))?.persistentModelID != task.persistentModelID { return }
        let stagedAcknowledgements = LivePermissionApprovalRecovery.stageAcknowledgements(
            task: task, run: run, requestIDs: acknowledgedPermissionRequestIDs, modelContext: modelContext)
        guard let request else {
            if stagedAcknowledgements { WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: modelContext) }
            return
        }
        let runState: TaskTurnRequestState = switch run.status {
        case .completed: .completed
        case .cancelled: .cancelled
        case .running, .failed, .timeout, .budgetExceeded: .failed
        }
        let terminalState = forcedOutcome?.state ?? runState
        let reason = run.stopReason.trimmingCharacters(in: .whitespacesAndNewlines)
        let transition = TaskTurnRequestStateMachine.transition(
            request,
            to: terminalState,
            runID: run.id,
            terminalReason: forcedOutcome?.reason ?? (reason.isEmpty ? run.status.rawValue : reason)
        )
        if transition.changed || stagedAcknowledgements {
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
    ) throws -> Bool {
        guard run.task?.persistentModelID == task.persistentModelID,
              run.modelContext === modelContext, task.modelContext === modelContext else {
            throw TaskRunRequestAssociation.Failure.invalidReference
        }
        if let eventID,
           let event = sourceEvent(eventID, of: task, in: modelContext) {
            if let previousRun = event.run, previousRun.persistentModelID != run.persistentModelID {
                try preservePreviousAssociation(event: event, run: previousRun, task: task, in: modelContext)
            }
            event.run = run
            TaskThreadChangeNotifier.post(taskID: task.id, source: "turn_request_admitted")
            return true
        }
        let event = TaskEvent(task: task, type: fallbackType, payload: fallbackPayload, run: run)
        TaskEventInsertionService.insert(event, into: modelContext)
        return false
    }

    /// Upgrade an older attempt while its source still identifies it. These
    /// pending rows and the source move share beginRuntime's atomic save: a
    /// failed save leaves the old durable source link intact, while in-memory
    /// readers can already use the preserved association.
    private static func preservePreviousAssociation(
        event: TaskEvent, run: TaskRun, task: AgentTask, in context: ModelContext
    ) throws {
        guard run.task?.persistentModelID == task.persistentModelID else {
            throw TaskRunRequestAssociation.Failure.invalidReference
        }
        if let recorded = try TaskRunRequestAssociation.request(for: run, in: context) {
            guard recorded.sourceEventID == event.id else { throw TaskRunRequestAssociation.Failure.conflictingReference }
            return
        }
        let taskID = task.id
        let eventID = event.id
        let rows = try context.fetch(FetchDescriptor<TaskTurnRequest>(predicate: #Predicate {
            $0.taskID == taskID && $0.messageEventID == eventID
        })).filter { !$0.isDeleted }
        var owners = TaskTurnRequestOwnership.Resolver(candidates: try TaskTurnRequestOwnership.candidates(taskID: taskID, in: context))
        var owned: [TaskTurnRequest] = []
        for request in rows {
            guard let owner = owners.resolve(request) else { throw TaskRunRequestAssociation.Failure.invalidReference }
            if owner.persistentModelID == task.persistentModelID { owned.append(request) }
        }
        guard owned.count <= 1 else { throw TaskRunRequestAssociation.Failure.conflictingReference }
        if let request = owned.first {
            try recordAssociation(request, run: run, task: task, in: context)
        } else if event.type.hasPrefix("execution.request.") {
            throw TaskRunRequestAssociation.Failure.invalidReference
        }
    }

    private static func recordAssociation(
        _ request: TaskTurnRequest, run: TaskRun, task: AgentTask, in context: ModelContext
    ) throws {
        try TaskRunRequestAssociation.validate(request, for: run, in: context)
        if let recorded = try TaskRunRequestAssociation.request(for: run, in: context) {
            guard recorded.persistentModelID == request.persistentModelID else {
                throw TaskRunRequestAssociation.Failure.conflictingReference
            }
            return
        }
        let reference = TaskRunRequestAssociationPayload(taskID: task.id, runID: run.id,
            requestID: request.id, sourceEventID: request.sourceEventID)
        TaskEventInsertionService.insert(TaskEvent.structuredPayloadEvent(task: task,
            eventType: TaskEventTypes.ExecutionRequest.runAssociated, payload: reference, run: run), into: context)
    }

    /// One row by id, matched in the store rather than by faulting the task's
    /// whole event relationship in to compare ids.
    private static func sourceEvent(_ eventID: UUID, of task: AgentTask, in modelContext: ModelContext) -> TaskEvent? {
        TaskHistoryRead.event(id: eventID, in: task)
    }
}

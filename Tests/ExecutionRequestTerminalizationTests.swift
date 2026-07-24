import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// Terminalization totality: every execution request that gets admitted must
/// eventually reach EXACTLY ONE terminal state. A request that never
/// terminalizes stays `isActive`, so the admission scheduler keeps selecting
/// it and redispatches the same turn forever.
///
/// Three separate bugs of this class shipped into this PR before it landed:
///
/// 1. A claimless (no-workspace) request was admitted by policy, but the
///    lease wait returned `nil` for an empty claim set, so no worker ever
///    started and nothing terminalized it.
/// 2. Approved-plan requests were marked `.completed` on raw provider success,
///    before contract validation could reject the run — an irreversibly wrong
///    terminal state (`.completed` is absorbing).
/// 3. `TaskQueue`'s post-worker net for approved plans terminalized a
///    still-`.admitted` request straight to `.completed`. That edge does not
///    exist, so `TaskTurnRequestStateMachine` REJECTED the transition — and
///    the call site discards the result (`_ = transitionPersistedTurn(...)`),
///    so the rejection was invisible and the request stayed active forever.
///
/// Bug 3 was never flagged by a reviewer; it was found only by auditing
/// exactly-once coverage. These tests pin the structural invariants that make
/// that class of bug fail loudly instead of silently.
@Suite("Execution request terminalization totality", .serialized)
@MainActor
struct ExecutionRequestTerminalizationTests {

    // MARK: - Harness

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    private func makeTask(in context: ModelContext) -> AgentTask {
        let task = AgentTask(title: "Terminalization", goal: "Reach a terminal state.")
        context.insert(task)
        return task
    }

    /// `TaskTurnRequest.init` writes `stateRawValue` directly, which is the
    /// only way to seed a probe in an arbitrary starting state without going
    /// through the very transition table under test.
    private func makeRequest(
        _ state: TaskTurnRequestState,
        task: AgentTask,
        sequence: Int,
        in context: ModelContext
    ) -> TaskTurnRequest {
        let request = TaskTurnRequest(
            task: task,
            messageEventID: UUID(),
            sequence: sequence,
            state: state
        )
        context.insert(request)
        return request
    }

    /// Reconstructs `TaskTurnRequestStateMachine.allowedTransitions` by
    /// probing every ordered pair of distinct states, because the table itself
    /// is `private` (and `@testable import` does not reach `private`).
    ///
    /// `transition` returns `rejection == nil` for a pair exactly when the
    /// table contains that edge, with one documented exception: a same-state
    /// call short-circuits into the idempotent "re-assert" branch before the
    /// table is consulted. Self-pairs are therefore skipped — the real table
    /// declares no self-edges either, so the reconstruction is exact.
    private func probedTransitionTable(
        task: AgentTask,
        in context: ModelContext
    ) -> [TaskTurnRequestState: Set<TaskTurnRequestState>] {
        var table: [TaskTurnRequestState: Set<TaskTurnRequestState>] = [:]
        var sequence = 0
        for from in TaskTurnRequestState.allCases {
            var edges: Set<TaskTurnRequestState> = []
            for to in TaskTurnRequestState.allCases where to != from {
                sequence += 1
                let probe = makeRequest(from, task: task, sequence: sequence, in: context)
                let result = TaskTurnRequestStateMachine.transition(probe, to: to)
                if result.rejection == nil {
                    edges.insert(to)
                    #expect(probe.state == to)
                } else {
                    #expect(probe.state == from)
                    #expect(!result.changed)
                }
            }
            table[from] = edges
        }
        return table
    }

    /// Breadth-first closure, inclusive of `start` (a terminal state trivially
    /// "reaches" a terminal state in zero steps).
    private func reachableStates(
        from start: TaskTurnRequestState,
        in table: [TaskTurnRequestState: Set<TaskTurnRequestState>]
    ) -> Set<TaskTurnRequestState> {
        var seen: Set<TaskTurnRequestState> = [start]
        var frontier: [TaskTurnRequestState] = [start]
        while let current = frontier.popLast() {
            for next in table[current, default: []] where !seen.contains(next) {
                seen.insert(next)
                frontier.append(next)
            }
        }
        return seen
    }

    /// Number of transitions on the shortest path, or nil when unreachable.
    private func shortestPathLength(
        from start: TaskTurnRequestState,
        to goal: TaskTurnRequestState,
        in table: [TaskTurnRequestState: Set<TaskTurnRequestState>]
    ) -> Int? {
        if start == goal { return 0 }
        var seen: Set<TaskTurnRequestState> = [start]
        var frontier: [TaskTurnRequestState] = [start]
        var distance = 0
        while !frontier.isEmpty {
            distance += 1
            var nextFrontier: [TaskTurnRequestState] = []
            for state in frontier {
                for neighbour in table[state, default: []] where !seen.contains(neighbour) {
                    if neighbour == goal { return distance }
                    seen.insert(neighbour)
                    nextFrontier.append(neighbour)
                }
            }
            frontier = nextFrontier
        }
        return nil
    }

    // MARK: - Transition-table invariants

    @Test("Every active state can be terminalized, and terminal states stay closed")
    func transitionTableKeepsEveryRequestAbleToTerminalize() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let task = makeTask(in: context)
        let table = probedTransitionTable(task: task, in: context)

        // Adding a case to `TaskTurnRequestState` must force an explicit
        // decision here rather than silently inheriting an empty (and
        // therefore stuck-forever) edge set from `allowedTransitions`'
        // `default: []` lookup.
        #expect(Set(TaskTurnRequestState.allCases) == Set<TaskTurnRequestState>([
            .waitingForWorker,
            .waitingForResource,
            .admitted,
            .running,
            .completed,
            .failed,
            .cancelled
        ]))

        let terminals = Set(TaskTurnRequestState.allCases.filter(\.isTerminal))
        #expect(terminals == Set<TaskTurnRequestState>([.completed, .failed, .cancelled]))
        // `isActive` is the predicate the scheduler and every `activeRequests`
        // store fetch use; it must stay the exact complement of `isTerminal`.
        let actives = Set(TaskTurnRequestState.allCases.filter(\.isActive))
        #expect(actives == Set(TaskTurnRequestState.allCases).subtracting(terminals))

        // Whoever holds an ACTIVE request must always be able to end it in a
        // single step — otherwise an abort path (queue stopped, worker never
        // started, task deleted) has no legal way to close the request out.
        let activeWithoutDirectExit = TaskTurnRequestState.allCases
            .filter { $0.isActive && table[$0, default: []].isDisjoint(with: terminals) }
            .map(\.rawValue)
            .sorted()
        #expect(
            activeWithoutDirectExit.isEmpty,
            "Active states with no direct edge to any terminal state strand their requests: \(activeWithoutDirectExit)"
        )

        // `.completed` is absorbing: a successfully finished turn must never
        // be reopened or downgraded (bug 2's irreversibility is the whole
        // reason terminalization has to wait for the finalization decision).
        #expect(table[.completed] == Set<TaskTurnRequestState>())

        // `.failed`/`.cancelled` reopen for a retry, and ONLY back to the head
        // of the queue — never straight to `.admitted` or `.running`, which
        // would skip the admission and resource-lease gates.
        #expect(table[.failed] == Set<TaskTurnRequestState>([.waitingForWorker]))
        #expect(table[.cancelled] == Set<TaskTurnRequestState>([.waitingForWorker]))

        // Totality, stated as a graph property: no state is a dead end.
        let stranded = TaskTurnRequestState.allCases
            .filter { reachableStates(from: $0, in: table).isDisjoint(with: terminals) }
            .map(\.rawValue)
            .sorted()
        #expect(
            stranded.isEmpty,
            "Every state must have SOME path to a terminal state; these do not: \(stranded)"
        )

        // And the whole lifecycle stays live from the submission state.
        #expect(
            reachableStates(from: .waitingForWorker, in: table) == Set(TaskTurnRequestState.allCases)
        )
    }

    @Test("`.completed` is reachable only through `.running`, never straight from `.admitted`")
    func completedIsReachableOnlyThroughRunning() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let task = makeTask(in: context)
        let table = probedTransitionTable(task: task, in: context)

        // THE bug-3 invariant. `.admitted -> .completed` is deliberately NOT
        // an edge: a request must actually run before it can be reported as
        // completed. Any code that terminalizes an `.admitted` request as
        // completed MUST step through `.running` first — the state machine
        // rejects the shortcut, and every production call site discards the
        // rejection (`_ = transitionPersistedTurn(...)`), so the request would
        // silently stay active and be redispatched forever.
        //
        // If a future change adds a direct `.admitted -> .completed` edge,
        // this test fails on purpose: that edge lets a turn report success
        // without a run ever having been created for it.
        #expect(!table[.admitted, default: []].contains(.completed))

        let predecessorsOfCompleted = TaskTurnRequestState.allCases
            .filter { table[$0, default: []].contains(.completed) }
        #expect(
            predecessorsOfCompleted == [.running],
            "`.running` must remain the only state with an edge into `.completed`, found: \(predecessorsOfCompleted.map(\.rawValue))"
        )

        // Spelled out as distances, so the cost of the missing edge is
        // explicit: completing an admitted request takes TWO transitions.
        #expect(shortestPathLength(from: .running, to: .completed, in: table) == 1)
        #expect(shortestPathLength(from: .admitted, to: .completed, in: table) == 2)
        #expect(shortestPathLength(from: .waitingForWorker, to: .completed, in: table) == 3)
        #expect(shortestPathLength(from: .waitingForResource, to: .completed, in: table) == 3)
        // Absorbing in the strongest sense: nothing at all leaves `.completed`.
        #expect(shortestPathLength(from: .completed, to: .failed, in: table) == nil)
        #expect(shortestPathLength(from: .completed, to: .waitingForWorker, in: table) == nil)
    }

    // MARK: - Silent-rejection guard

    @Test("A direct `.admitted` -> `.completed` is rejected and leaves the request ACTIVE")
    func directAdmittedToCompletedIsRejectedAndLeavesTheRequestActive() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let task = makeTask(in: context)

        // The pre-fix shape of TaskQueue's post-worker net for approved plans:
        //     let terminal = task.status == .completed ? .completed : .failed
        //     _ = transitionPersistedTurn(request, to: terminal, ...)
        // on a request that is still `.admitted`.
        let shortcut = makeRequest(.admitted, task: task, sequence: 1, in: context)
        let rejected = TaskTurnRequestStateMachine.transition(shortcut, to: .completed)

        #expect(
            rejected.rejection == TaskTurnRequestStateMachine.Rejection.illegalTransition(
                from: .admitted,
                to: .completed
            )
        )
        #expect(!rejected.changed)
        #expect(rejected.from == .admitted)
        #expect(rejected.to == .completed)
        // The failure mode, precisely: the caller believes it terminalized the
        // request (it threw the result away), but the request is untouched and
        // still ACTIVE, so the scheduler keeps picking it up.
        #expect(shortcut.state == .admitted)
        #expect(shortcut.state.isActive)
        #expect(shortcut.terminalAt == nil)
        #expect(shortcut.terminalReason == nil)

        // The fixed shape: step through `.running` first, then terminalize.
        let stepped = makeRequest(.admitted, task: task, sequence: 2, in: context)
        let toRunning = TaskTurnRequestStateMachine.transition(stepped, to: .running)
        let toCompleted = TaskTurnRequestStateMachine.transition(stepped, to: .completed)
        #expect(toRunning.rejection == nil)
        #expect(toCompleted.rejection == nil)
        #expect(stepped.state == .completed)
        #expect(stepped.state.isTerminal)
        #expect(stepped.terminalAt != nil)
        #expect(stepped.startedAt != nil)
    }

    @Test("Every terminalization sequence the queue performs actually reaches a terminal state")
    func productionTerminalizationSequencesAllEndTerminal() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let task = makeTask(in: context)

        // One production net, transcribed from its call site.
        struct TerminalizationPath {
            let name: String
            let start: TaskTurnRequestState
            let steps: [TaskTurnRequestState]
            let expected: TaskTurnRequestState
        }

        let paths: [TerminalizationPath] = [
            // TaskQueue.continuePersistedTurn -> AgentRuntimeWorker:
            // waiting -> resource wait -> admitted, then the worker's
            // PersistedTurnRuntimeEventLinker.beginRuntime/.finishRuntime.
            TerminalizationPath(
                name: "continue path, run finished successfully",
                start: .waitingForWorker,
                steps: [.waitingForResource, .admitted, .running, .completed],
                expected: .completed
            ),
            // TaskQueue.executeApprovedPlan's post-worker net when the worker
            // returned before creating a run and the task did complete. This
            // is bug 3: without the `.running` step the `.completed` hop is
            // rejected and the request never terminalizes.
            TerminalizationPath(
                name: "approved-plan post-worker net, task completed",
                start: .admitted,
                steps: [.running, .completed],
                expected: .completed
            ),
            // Same net, unsuccessful branch (terminalReason runtime_not_started).
            TerminalizationPath(
                name: "approved-plan post-worker net, task not completed",
                start: .admitted,
                steps: [.failed],
                expected: .failed
            ),
            // TaskQueue.executeTask: worker exited without creating a run.
            TerminalizationPath(
                name: "worker never started",
                start: .admitted,
                steps: [.failed],
                expected: .failed
            ),
            // TaskQueue.continuePersistedTurn tail / cancelAll: the queue was
            // stopped while the admission loop was parked on a lease.
            TerminalizationPath(
                name: "admission cancelled while parked on a resource lease",
                start: .waitingForResource,
                steps: [.cancelled],
                expected: .cancelled
            ),
            // TaskTurnRequestRecoveryService: a run interrupted by app exit.
            TerminalizationPath(
                name: "startup recovery of an interrupted run",
                start: .running,
                steps: [.failed],
                expected: .failed
            ),
            // TaskTurnRequestRecoveryService: an admitted-but-not-started
            // request goes back to the head of the queue, then runs to
            // completion on the next pass.
            TerminalizationPath(
                name: "startup recovery returns an admitted request to waiting, then it completes",
                start: .admitted,
                steps: [.waitingForWorker, .admitted, .running, .completed],
                expected: .completed
            ),
            // TaskLifecycleCoordinator retry: a terminal request is reopened
            // and must be able to reach a terminal state again.
            TerminalizationPath(
                name: "retry after a failure",
                start: .failed,
                steps: [.waitingForWorker, .admitted, .running, .completed],
                expected: .completed
            )
        ]

        for (index, path) in paths.enumerated() {
            let request = makeRequest(path.start, task: task, sequence: index + 1, in: context)
            for step in path.steps {
                let result = TaskTurnRequestStateMachine.transition(request, to: step)
                #expect(
                    result.rejection == nil,
                    "\(path.name): \(result.from.rawValue) -> \(result.to.rawValue) was rejected, so this net never terminalizes its request"
                )
            }
            #expect(
                request.state == path.expected,
                "\(path.name): expected \(path.expected.rawValue), got \(request.state.rawValue)"
            )
            #expect(
                request.state.isTerminal,
                "\(path.name): request stayed active (\(request.state.rawValue)) — the queue would redispatch it forever"
            )
            #expect(!request.state.isActive)
            #expect(request.terminalAt != nil)
        }
    }

    // MARK: - Queue-level behaviour

    /// The approved-plan entry point is where bug 3 lived. This drives the
    /// real `TaskQueue` far enough to prove the entry point never leaves an
    /// admitted request active: it admits the request (claimless lease path,
    /// bug 1), then runtime admission rejects the non-queued task and the
    /// request must come out terminal rather than stuck at `.admitted`.
    ///
    /// It deliberately stops short of `worker.executeApprovedPlan`, which
    /// would need a real provider process.
    @Test("The approved-plan entry point never leaves an admitted request active")
    func approvedPlanEntryPointTerminalizesAnAdmittedRequest() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        // No workspace: the request resolves to zero resource claims, so the
        // lease path must hand back an empty lease instead of nil.
        let task = AgentTask(title: "No workspace", goal: "Execute the approved plan.")
        // Runtime admission only accepts `.queued`, which terminalizes the
        // request before any provider work starts.
        task.status = .completed
        context.insert(task)
        let request = TaskTurnRequest(
            task: task,
            messageEventID: UUID(),
            sequence: 1,
            kind: .planStep
        )
        context.insert(request)
        try context.save()
        #expect(request.state == .waitingForWorker)
        #expect(TaskExecutionResourceClaimResolver.claims(for: task).isEmpty)

        let plan = TaskPlanPayload(
            title: "Plan",
            goal: "Execute the approved plan.",
            steps: [TaskPlanPayloadStep(id: "step-1", title: "Do the thing")]
        )
        let queue = TaskQueue(poolSize: 1)
        await queue.executeApprovedPlan(
            task: task,
            plan: plan,
            modelContext: context,
            executionRequestID: request.id
        )

        #expect(!request.state.isActive)
        #expect(request.state == .failed)
        #expect(request.terminalReason == "task_not_queued")
        #expect(request.terminalAt != nil)
        #expect(queue.activeTasks.isEmpty)
        #expect(queue.activeResourceLocks.isEmpty)
    }

    /// Startup recovery mirrors a linked run's terminal status onto its
    /// request, and its comment says that covers "BOTH running and admitted
    /// requests". But `.admitted -> .completed` is not an edge, so for an
    /// admitted request whose run completed, the transition was rejected,
    /// `changed` stayed false, the `else if` / `else` recovery branches were
    /// skipped (they belong to the same chain), and the request was left
    /// `.admitted` and ACTIVE — re-fetched and re-skipped on every subsequent
    /// restart, forever.
    @Test("Recovery terminalizes an admitted request whose linked run completed")
    func recoveryTerminalizesAdmittedRequestWithCompletedRun() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let task = makeTask(in: context)

        let run = TaskRun(task: task)
        run.status = .completed
        run.stopReason = "completed"
        context.insert(run)

        // The state this branch claims to handle: admitted, with a linked run
        // that already reached a terminal status.
        let request = makeRequest(.admitted, task: task, sequence: 1, in: context)
        request.runID = run.id

        let summary = TaskTurnRequestRecoveryService.recoverInterruptedRequests(
            modelContext: context,
            at: Date(timeIntervalSince1970: 4_242),
            autoExportWorkspaces: false
        )

        // Before the fix this was `.admitted` / `isActive` / terminalized == 0.
        #expect(request.state == .completed)
        #expect(!request.state.isActive)
        #expect(request.terminalAt != nil)
        #expect(summary.terminalized == 1)
        #expect(summary.returnedToWaiting == 0)
    }

    /// The cancelled/failed mirrors were always legal from `.admitted`, so
    /// they must keep terminalizing in one step rather than being routed
    /// through the new `.running` recovery step.
    @Test("Recovery still mirrors non-completed run outcomes straight from admitted")
    func recoveryMirrorsNonCompletedOutcomesDirectly() throws {
        for (runStatus, expected) in [
            (RunStatus.cancelled, TaskTurnRequestState.cancelled),
            (RunStatus.failed, TaskTurnRequestState.failed)
        ] {
            let container = try makeContainer()
            let context = container.mainContext
            let task = makeTask(in: context)

            let run = TaskRun(task: task)
            run.status = runStatus
            run.stopReason = runStatus.rawValue
            context.insert(run)

            let request = makeRequest(.admitted, task: task, sequence: 1, in: context)
            request.runID = run.id

            let summary = TaskTurnRequestRecoveryService.recoverInterruptedRequests(
                modelContext: context,
                at: Date(timeIntervalSince1970: 4_242),
                autoExportWorkspaces: false
            )

            #expect(request.state == expected)
            #expect(request.runID == run.id)
            #expect(summary.terminalized == 1)
        }
    }
}

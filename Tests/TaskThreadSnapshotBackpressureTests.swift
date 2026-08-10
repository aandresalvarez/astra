import Foundation
import Testing
import ASTRAModels
@testable import ASTRA

/// Explicit rendezvous for the injected snapshot builder. Replaces a sleep so
/// the test controls exactly when a build finishes and can inspect the pipeline
/// while one is genuinely in flight.
private actor BuildGate {
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    /// Once opened the gate stays open. Releasing only the currently parked
    /// builds would deadlock the test the moment the worker picks the pending
    /// request up and parks again -- which, now that a supersession no longer
    /// cancels, is exactly what it is supposed to do.
    private var isOpen = false
    private(set) var enteredCount = 0
    private(set) var cancelledCount = 0

    func enter() async {
        enteredCount += 1
        let waiters = entryWaiters
        entryWaiters = []
        waiters.forEach { $0.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation { parked.append($0) }
    }

    func noteCancelled() { cancelledCount += 1 }

    func open() {
        isOpen = true
        let continuations = parked
        parked = []
        continuations.forEach { $0.resume() }
    }

    func waitForEntry(count: Int) async {
        while enteredCount < count {
            await withCheckedContinuation { entryWaiters.append($0) }
        }
    }
}

@MainActor
private final class ManualClock {
    private(set) var now = ContinuousClock().now

    func advance(milliseconds: Int) {
        now = now.advanced(by: .milliseconds(milliseconds))
    }
}

/// End-to-end back-pressure behaviour of the live snapshot pipeline.
///
/// The incident these cover: a streaming thread whose snapshot build cost
/// 369-390 ms received a fresh request roughly every 180 ms, and every request
/// cancelled the in-flight build. No build ever completed, no snapshot was ever
/// applied, and because `thread_snapshot_build` and
/// `chat_stream_snapshot_cadence` are only emitted on completion, the log went
/// silent at the same instant the transcript froze.
@MainActor
@Suite("Task thread snapshot back-pressure")
struct TaskThreadSnapshotBackpressureTests {
    /// The 30 s budget matches the rest of the thread suites. Every wait here is
    /// on a condition the pipeline reaches in milliseconds when the machine is
    /// idle; the budget exists because the full suite runs main-actor tests
    /// concurrently and can starve a single hop for seconds. A tight bound would
    /// measure host load, not back-pressure.
    private func waitUntil(
        timeout: Duration = .seconds(30),
        _ condition: () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private func makeRunningTask(goal: String) -> AgentTask {
        let task = makeTask(goal: goal, status: .running)
        let run = TaskRun(task: task)
        run.startedAt = Date(timeIntervalSince1970: 1)
        run.status = .running
        task.runs.append(run)
        return task
    }

    /// One streamed chunk, invalidating the way production does.
    ///
    /// `TaskThreadSnapshotTrigger.==` deliberately ignores raw `eventCount` on
    /// the reactive path: `agent.response` is a high-frequency type, so a live
    /// thread is only re-projected when `visibleEventCount` changes or the
    /// latest run's output crosses a 1 KiB bucket. Appending an event alone
    /// leaves the trigger equal and `refreshSnapshot` returns before it ever
    /// reaches the pipeline -- which would make every assertion below pass
    /// vacuously.
    private func streamChunk(_ index: Int, into task: AgentTask) {
        task.events.append(makeEvent(
            task: task,
            type: "agent.response",
            payload: "chunk \(index)",
            timestamp: Date(timeIntervalSince1970: Double(200 + index)),
            run: task.runs.last
        ))
        task.runs.last?.appendOutput(String(repeating: "x", count: 1_100))
        task.updatedAt = Date()
    }

    @Test("A measured render holds the next live refresh instead of stacking rebuilds")
    func aMeasuredRenderHoldsTheNextLiveRefresh() async {
        let clock = ManualClock()
        let task = makeRunningTask(goal: "Paced")
        let viewModel = TaskThreadViewModel(
            snapshotBuilder: { input, _, _ in TaskThreadSnapshot(input: input) },
            // A 1 ms base debounce so the test never waits on the production
            // coalescing floor; the pacing itself is driven entirely by the
            // manual clock, so the assertions are about the control law.
            livePacer: TaskThreadLiveSnapshotPacer(
                baseDebounceNanoseconds: 1_000_000,
                monotonicNow: { clock.now }
            )
        )
        viewModel.reset(for: task)
        _ = await waitUntil { viewModel.appliedSnapshotRevision > 0 }
        let baseline = viewModel.snapshotBuildCountForTesting

        // Stand in for the layout pass the apply just triggered: one 700 ms
        // main-actor block, exactly the shape `main_actor_max_stall_ms=703.63`
        // recorded, fed through the sampler's synthetic seam.
        viewModel.mainActorStallSamplerForTesting.record(wakeGapNanoseconds: 750_000_000)
        clock.advance(milliseconds: 700)

        for index in 0..<40 {
            streamChunk(index, into: task)
            viewModel.requestSnapshotRefresh(for: task)
        }

        // The duty-cycle deadline is 1400 ms from the apply and the clock has
        // only advanced 700 ms, so no amount of stream pressure may produce a
        // build. Before this change every one of the 40 requests reached the
        // pipeline.
        try? await Task.sleep(for: .milliseconds(120))
        #expect(
            viewModel.snapshotBuildCountForTesting == baseline,
            "a paced interval must suppress the build, not just the apply"
        )

        // Past the hard ceiling rather than exactly to the 1400 ms deadline. The
        // task is running, so the real 20 Hz probe is live and folds genuine
        // host contention into every reconcile; with a frozen manual clock that
        // pushes the duty-cycle deadline out indefinitely, which is exactly what
        // `maximumPeriodNanoseconds` exists to bound. Admission past the ceiling
        // is the no-lost-update contract and is measurement-independent -- the
        // duty-cycle arithmetic itself is pinned hermetically in
        // `TaskThreadLiveSnapshotPacerTests`.
        clock.advance(milliseconds: 2_500)
        let admitted = await waitUntil {
            viewModel.snapshot?.sortedEvents.contains { $0.payload == "chunk 39" } ?? false
        }
        #expect(admitted, "the held update must be admitted once the deadline passes")
        #expect(
            viewModel.snapshotBuildCountForTesting - baseline <= 2,
            "40 streamed events inside one paced interval must collapse to one build"
        )
    }

    @Test("A terminal transition drains the pace interval instead of waiting it out")
    func aTerminalTransitionDrainsThePaceInterval() async {
        let clock = ManualClock()
        let task = makeRunningTask(goal: "Draining")
        let viewModel = TaskThreadViewModel(
            snapshotBuilder: { input, _, _ in TaskThreadSnapshot(input: input) },
            livePacer: TaskThreadLiveSnapshotPacer(
                baseDebounceNanoseconds: 1_000_000,
                monotonicNow: { clock.now }
            )
        )
        viewModel.reset(for: task)
        _ = await waitUntil { viewModel.appliedSnapshotRevision > 0 }

        viewModel.mainActorStallSamplerForTesting.record(wakeGapNanoseconds: 1_050_000_000)
        clock.advance(milliseconds: 1_000)
        task.updatedAt = Date()
        viewModel.requestSnapshotRefresh(for: task)
        #expect(viewModel.livePacerForTesting.isPacing)

        // The run ends. The clock never advances again: if the terminal
        // transcript were paced it could never arrive, which is precisely the
        // no-lost-update contract.
        task.runs.last?.status = .completed
        task.status = .completed
        task.events.append(makeEvent(
            task: task,
            type: "agent.response",
            payload: "final answer",
            timestamp: Date(timeIntervalSince1970: 900),
            run: task.runs.last
        ))
        task.updatedAt = Date()
        viewModel.requestSnapshotRefresh(for: task)

        let converged = await waitUntil {
            viewModel.snapshot?.sortedEvents.contains { $0.payload == "final answer" } ?? false
        }
        #expect(converged, "the final snapshot must land without waiting out a pace interval")
        #expect(!viewModel.livePacerForTesting.isPacing)
    }

    @Test("A superseding request no longer cancels the in-flight build")
    func aSupersedingRequestNoLongerCancelsTheInFlightBuild() async {
        let gate = BuildGate()
        let task = makeRunningTask(goal: "Livelock")
        let viewModel = TaskThreadViewModel(
            snapshotBuilder: { input, _, _ in
                await gate.enter()
                if Task.isCancelled {
                    await gate.noteCancelled()
                    throw CancellationError()
                }
                return TaskThreadSnapshot(input: input)
            }
        )
        viewModel.reset(for: task)
        await gate.waitForEntry(count: 1)

        // Three more generations land while the first build is parked. This is
        // the incident's interleaving: a 369 ms build with a request every
        // ~180 ms. Cancelling here meant no build ever completed, the transcript
        // froze and all three snapshot events went silent.
        for index in 0..<3 {
            streamChunk(index, into: task)
            viewModel.refreshSnapshot(for: task)
        }

        // Opening rather than draining once matters: the first build completes,
        // its apply is correctly dropped by the revision guard, and the worker
        // immediately picks the newest pending request up and builds again. A
        // one-shot release would strand that second build forever.
        await gate.open()
        let converged = await waitUntil {
            viewModel.snapshot?.sortedEvents.contains { $0.payload == "chunk 2" } ?? false
        }
        #expect(converged, "forward progress must not depend on a main-actor stall breaking the cycle")
        #expect(await gate.cancelledCount == 0, "an in-flight build must not be cancelled by a supersession")
        #expect(viewModel.snapshotBuildCompletedCountForTesting >= 1)
        #expect(viewModel.snapshotBuildCancelledCountForTesting == 0)
    }

    @Test("Task open is never paced")
    func taskOpenIsNeverPaced() async {
        let clock = ManualClock()
        let task = makeRunningTask(goal: "Open")
        let pacer = TaskThreadLiveSnapshotPacer(monotonicNow: { clock.now })
        let viewModel = TaskThreadViewModel(
            snapshotBuilder: { input, _, _ in TaskThreadSnapshot(input: input) },
            livePacer: pacer
        )
        // A pacer carrying a large interval from a previous task must not be
        // able to delay the next task's first transcript.
        pacer.recordApply(isLive: true, synchronousApplyNanoseconds: 0)
        pacer.observe(
            TaskThreadMainActorStallSampler.Occupancy(
                busyNanoseconds: 1_800_000_000,
                longestBlockNanoseconds: 1_800_000_000
            )
        )

        viewModel.reset(for: task)
        #expect(!pacer.isPacing, "reset must disarm the pacer before the open refresh")
        let opened = await waitUntil { viewModel.appliedSnapshotRevision > 0 }
        #expect(opened)
    }
}

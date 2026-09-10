import Testing
import AppKit
import SwiftUI
import ASTRAModels
@testable import ASTRA
import ASTRACore

private actor SnapshotBuildBarrier {
    private var firstContinuation: CheckedContinuation<Void, Never>?
    private(set) var startedCount = 0

    func build(input: TaskThreadSnapshotInput) async -> TaskThreadSnapshot {
        startedCount += 1
        if startedCount == 1 {
            await withCheckedContinuation { continuation in
                firstContinuation = continuation
            }
        }
        return TaskThreadSnapshot(input: input)
    }

    func releaseFirst() {
        firstContinuation?.resume()
        firstContinuation = nil
    }
}

private final class SnapshotTelemetryCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: [Double]] = [:]
    private var eventOrder: [String] = []

    func record(event: String, duration: Double) {
        lock.withLock {
            values[event, default: []].append(duration)
            eventOrder.append(event)
        }
    }

    func latest(_ event: String) -> Double? {
        lock.withLock { values[event]?.last }
    }

    func lastIndex(of event: String) -> Int? {
        lock.withLock { eventOrder.lastIndex(of: event) }
    }
}

private final class SnapshotExecutorStartSignal: @unchecked Sendable {
    private let executorStarted = DispatchSemaphore(value: 0)
    private let measuredRequestReady = DispatchSemaphore(value: 0)

    func signalExecutorStarted() { executorStarted.signal() }
    func waitForExecutorStart() { executorStarted.wait() }
    func signalMeasuredRequestReady() { measuredRequestReady.signal() }
    func waitForMeasuredRequest() { measuredRequestReady.wait() }
}

// MARK: - TaskThreadViewModel progressive window

@Suite("TaskThreadViewModel", .serialized)
struct TaskThreadViewModelTests {

    /// Was "Live throttle is excluded from executor admission telemetry", which
    /// asserted `queueWait >= 100`: the old 120 ms floor slept *inside* the
    /// snapshot worker, so the wait it caused was charged to
    /// `task_open_snapshot_queue_wait`. Note what it took to observe that at
    /// all -- a direct `refreshSnapshot` call with no `modelContext`. On the
    /// production storage-backed path the floor compared `lastSnapshotApplyAt`
    /// against a moment that always arrived at least a debounce, a save and a
    /// store read later, so it was structurally unreachable and logged
    /// `throttle_delay_ms=0.00` forever. This test was the only coverage it had,
    /// and it exercised a call sequence production never runs.
    ///
    /// Pacing now happens in `requestSnapshotRefresh`, upstream of the save, the
    /// read and the build, so no deliberate delay passes through the worker at
    /// all and a direct refresh -- always a user action -- is never paced.
    @MainActor
    @Test("A direct refresh reaches the executor without a deliberate wait")
    func aDirectRefreshReachesTheExecutorWithoutADeliberateWait() async throws {
        let capture = SnapshotTelemetryCapture()
        let context = TaskThreadResponsivenessContext(
            traceID: "separate-snapshot-waits",
            telemetryObserver: { event, duration in
                capture.record(event: event, duration: duration)
            }
        )
        let vm = TaskThreadViewModel()
        let task = makeTask(goal: "Streaming response", status: .running)
        let run = TaskRun(task: task)
        run.status = .running
        task.runs.append(run)

        vm.reset(for: task, responsivenessContext: context)
        // Poll tightly rather than through the shared readiness helper, whose
        // 100 ms interval is the same order as the wait being measured.
        // Cold/full-suite load can delay the first build substantially, so the
        // budget stays generous.
        let initialDeadline = Date().addingTimeInterval(30)
        while !vm.appliedSnapshotReadiness.isReady(for: task.id), Date() < initialDeadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(vm.appliedSnapshotReadiness.isReady(for: task.id))
        run.setOutput("new streaming output")
        vm.refreshSnapshot(for: task)
        let expectedRevision = vm.appliedSnapshotRevision + 1
        let deadline = Date().addingTimeInterval(30)
        while vm.appliedSnapshotRevision < expectedRevision, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        _ = try #require(capture.latest("task_open_snapshot_queue_wait"))
        let queueIndex = try #require(capture.lastIndex(of: "task_open_snapshot_queue_wait"))
        let admissionStartIndex = try #require(capture.lastIndex(of: "thread_snapshot_executor_admission_started"))
        let admissionEndIndex = try #require(capture.lastIndex(of: "thread_snapshot_executor_admission_wait"))
        // Deliberately not a wall-clock bound on `queueWait`. It now spans a
        // single main-actor hop, but the hop is only as fast as the host: this
        // suite has been observed at 7,896 ms of genuine queueing while the full
        // test run saturates the main actor, so any threshold tight enough to
        // catch a reintroduced 120 ms sleep would fail on load instead. The
        // pacer's own accounting is the load-independent statement of the same
        // contract -- a direct refresh is a user action and is never paced.
        #expect(vm.livePacerForTesting.consumeTelemetryFields()["throttle_delay_ms"] == "0.00",
                "a direct refresh is a user action and must never be paced")
        #expect(queueIndex < admissionStartIndex, "executor admission must start only after queue wait ends")
        #expect(admissionStartIndex < admissionEndIndex, "executor admission telemetry must close after it starts")
    }

    @MainActor
    @Test("Executor admission telemetry retains genuine actor contention")
    func executorAdmissionTelemetryRetainsActorContention() async throws {
        let executor = TaskThreadSnapshotBuildExecutor()
        let started = SnapshotExecutorStartSignal()
        let blocker = Task {
            await executor.occupyForTelemetryTesting(milliseconds: 150) {
                started.signalExecutorStarted()
                started.waitForMeasuredRequest()
            }
        }
        await Task.detached { started.waitForExecutorStart() }.value

        let capture = SnapshotTelemetryCapture()
        let context = TaskThreadResponsivenessContext(
            traceID: "executor-contention",
            telemetryObserver: { event, duration in
                capture.record(event: event, duration: duration)
            }
        )
        let task = makeTask(goal: "Queued executor build")
        let input = TaskThreadSnapshotInput(task: task, maxRuns: 50)
        let admittedAt = DispatchTime.now().uptimeNanoseconds
        // The blocker cannot begin its timed hold until this request has
        // captured its admission timestamp. This makes the measured wait
        // deterministic even if the full suite delays either task.
        started.signalMeasuredRequestReady()
        _ = try await executor.build(
            input: input,
            fields: [:],
            responsivenessContext: context,
            admittedAt: admittedAt
        )
        await blocker.value

        let admission = try #require(capture.latest("thread_snapshot_executor_admission_wait"))
        #expect(admission >= 100, "time queued behind actor work must remain visible")
    }

    @MainActor
    private func awaitSnapshot(
        _ vm: TaskThreadViewModel,
        where predicate: @Sendable (TaskThreadSnapshot) -> Bool,
        timeout: TimeInterval = 30
    ) async -> TaskThreadSnapshot? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let snap = vm.snapshot, predicate(snap) {
                return snap
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return vm.snapshot
    }

    @MainActor
    private func awaitReadiness(
        _ vm: TaskThreadViewModel,
        taskID: UUID,
        timeout: TimeInterval = 30
    ) async -> TaskThreadSnapshotReadiness {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let readiness = vm.appliedSnapshotReadiness
            if readiness.isReady(for: taskID) {
                return readiness
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return vm.appliedSnapshotReadiness
    }

    @MainActor
    @Test("ViewModel starts with default 50-run window")
    func viewModelStartsWithDefaultWindow() async {
        let vm = TaskThreadViewModel()
        let task = makeTask(goal: "test")
        task.createdAt = Date(timeIntervalSince1970: 0)

        for i in 0..<100 {
            let run = TaskRun(task: task)
            run.startedAt = Date(timeIntervalSince1970: Double(i * 100))
            run.completedAt = Date(timeIntervalSince1970: Double(i * 100 + 90))
            run.setOutput("run \(i)")
            task.runs.append(run)
        }

        vm.reset(for: task)

        guard let snapshot = await awaitSnapshot(vm, where: { $0.sortedRuns.count > 0 }) else {
            Issue.record("Snapshot should be built after reset")
            return
        }
        #expect(snapshot.sortedRuns.count == 50)
        #expect(snapshot.omittedRunCount == 50)
        #expect(snapshot.latestRun?.output == "run 99")
        #expect(vm.appliedSnapshotRevision > 0)
        #expect(vm.appliedSnapshotTaskID == task.id)
        #expect(vm.lastSnapshotCacheState == "not_applicable")
    }

    @MainActor
    @Test("Reset clears the previous task readiness before applying the next snapshot")
    func resetClearsPreviousTaskReadiness() async {
        let vm = TaskThreadViewModel()
        let firstTask = makeTask(goal: "First task")
        let secondTask = makeTask(goal: "Second task")
        firstTask.runs.append(TaskRun(task: firstTask))

        vm.reset(for: firstTask)
        _ = await awaitSnapshot(vm, where: { $0.sortedRuns.count == 1 })
        #expect(vm.appliedSnapshotTaskID == firstTask.id)
        #expect(vm.appliedSnapshotRevision > 0)

        vm.reset(for: secondTask)

        #expect(vm.appliedSnapshotTaskID == nil)
        #expect(vm.appliedSnapshotRevision == 0)
        // refreshSnapshot resolves cache eligibility synchronously during
        // reset, before the detached snapshot has been applied.
        #expect(vm.lastSnapshotCacheState == "not_applicable")
    }

    @MainActor
    @Test("Applied empty snapshot advances readiness even when placeholder geometry matches")
    func appliedEmptySnapshotAdvancesReadiness() async {
        let vm = TaskThreadViewModel()
        let task = makeTask(goal: "Only the initial goal")

        vm.reset(for: task)
        let pendingReadiness = vm.appliedSnapshotReadiness
        let appliedReadiness = await awaitReadiness(vm, taskID: task.id)

        #expect(!pendingReadiness.isReady(for: task.id))
        #expect(appliedReadiness.isReady(for: task.id))
        #expect(appliedReadiness != pendingReadiness)
        #expect(vm.snapshot?.sortedRuns.isEmpty == true)
        #expect(vm.snapshot?.sortedEvents.isEmpty == true)
    }

    @MainActor
    @Test("Initial snapshot pipeline retains and clears the task-open trace ID")
    func initialSnapshotPipelineCarriesTraceID() async {
        let vm = TaskThreadViewModel()
        let task = makeTask(goal: "Trace correlation")
        let context = TaskThreadResponsivenessContext(traceID: "task-open-test-trace")

        vm.reset(for: task, responsivenessContext: context)
        _ = await awaitReadiness(vm, taskID: task.id)

        #expect(vm.initialSnapshotResponsivenessTraceID == "task-open-test-trace")
        vm.completeInitialResponsivenessTrace(for: task.id)
        #expect(vm.initialSnapshotResponsivenessTraceID == nil)
    }

    @MainActor
    @Test("Cancelling an unfinished open trace keeps the snapshot build alive")
    func cancellationClearsCorrelationWithoutCancellingSnapshot() async {
        let vm = TaskThreadViewModel()
        let task = makeTask(goal: "Cancelled trace")
        let context = TaskThreadResponsivenessContext(traceID: "cancelled-trace")
        vm.reset(for: task, responsivenessContext: context)

        vm.cancelInitialResponsivenessCorrelation(for: task.id)
        let readiness = await awaitReadiness(vm, taskID: task.id)

        #expect(!context.isActive)
        #expect(vm.initialSnapshotResponsivenessTraceID == nil)
        #expect(readiness.isReady(for: task.id))
        #expect(vm.appliedSnapshotTaskID == task.id)
    }

    @MainActor
    @Test("Rapid live refreshes coalesce to one build of the latest revision")
    func rapidLiveRefreshesCoalesceToLatestRevision() async {
        let vm = TaskThreadViewModel()
        let task = makeTask(goal: "Streaming response", status: .running)
        let run = TaskRun(task: task)
        run.status = .running
        task.runs.append(run)

        vm.reset(for: task)
        for index in 0..<20 {
            run.setOutput(String(repeating: "x", count: (index + 1) * 1_024))
            let event = TaskEvent(
                task: task,
                type: "agent.response",
                payload: "revision \(index)",
                run: run
            )
            event.timestamp = Date(timeIntervalSince1970: Double(index))
            task.events.append(event)
            vm.refreshSnapshot(for: task)
        }

        let snapshot = await awaitSnapshot(vm, where: {
            $0.latestRun?.output.count == 20 * 1_024 && $0.sortedEvents.count == 20
        })

        #expect(snapshot?.latestRun?.output.count == 20 * 1_024)
        #expect(snapshot?.sortedEvents.map(\.payload).last == "revision 19")
        #expect(vm.snapshotBuildCountForTesting == 1)
        #expect(vm.appliedSnapshotRevision == 1)
    }

    /// Was "Refresh during an active build preempts it and applies only the
    /// latest snapshot", which required the replacement to *start* while the
    /// obsolete build was still suspended -- only possible because every new
    /// request cancelled the worker and a fresh one began immediately. That is
    /// the livelock: the build is cancellation-aware, so a 369 ms build under a
    /// request every ~180 ms never completed and the transcript froze.
    ///
    /// The invariant the old test was really protecting is that an obsolete
    /// build never reaches the screen, and that survives without cancellation:
    /// the revision guard in `applySnapshotIfCurrent` drops it, and the worker
    /// then picks the newest request out of the last-wins pending slot. The
    /// build count is the cost of that trade -- one wasted build here, versus
    /// none ever finishing before.
    @MainActor
    @Test("An obsolete build finishes and is dropped rather than cancelled")
    func refreshDuringActiveBuildDropsObsoleteSnapshot() async {
        let barrier = SnapshotBuildBarrier()
        let vm = TaskThreadViewModel(snapshotBuilder: { input, _, _ in
            await barrier.build(input: input)
        })
        let task = makeTask(goal: "Streaming response", status: .running)
        let run = TaskRun(task: task)
        run.status = .running
        run.setOutput("old")
        task.runs.append(run)

        vm.reset(for: task)
        while await barrier.startedCount < 1 { await Task.yield() }

        let latestOutput = String(repeating: "latest", count: 1_024)
        run.setOutput(latestOutput)
        vm.refreshSnapshot(for: task)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(
            await barrier.startedCount == 1,
            "the replacement must queue behind the in-flight build, not race it"
        )
        #expect(vm.appliedSnapshotRevision == 0, "nothing may be applied while the first build is parked")

        await barrier.releaseFirst()
        let latest = await awaitSnapshot(vm, where: { $0.latestRun?.output == latestOutput }, timeout: 30)

        #expect(await barrier.startedCount == 2, "the newest request must be built once the worker is free")
        #expect(latest?.latestRun?.output == latestOutput)
        // Two builds, one apply: the obsolete generation was dropped by the
        // revision guard rather than painted and then replaced.
        #expect(vm.snapshotBuildCountForTesting == 2)
        #expect(vm.appliedSnapshotRevision == 1)
    }

    @MainActor
    @Test("Task reset preempts an active build without applying the previous task")
    func taskResetPreemptsActiveBuild() async {
        let barrier = SnapshotBuildBarrier()
        let vm = TaskThreadViewModel(snapshotBuilder: { input, _, _ in
            await barrier.build(input: input)
        })
        let first = makeTask(goal: "First task")
        let second = makeTask(goal: "Second task")

        vm.reset(for: first)
        while await barrier.startedCount < 1 { await Task.yield() }
        vm.reset(for: second)

        let readiness = await awaitReadiness(vm, taskID: second.id, timeout: 2)
        #expect(readiness.isReady(for: second.id))
        if case .userMessage(_, let text, _)? = vm.snapshot?.conversationItems.first {
            #expect(text == second.goal)
        } else {
            Issue.record("The second task snapshot should own the visible transcript")
        }
        #expect(vm.appliedSnapshotRevision == 1)

        await barrier.releaseFirst()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(vm.appliedSnapshotTaskID == second.id)
        #expect(vm.appliedSnapshotRevision == 1)
    }

    @MainActor
    @Test("Terminal cache hit preempts an active build and cannot be overwritten")
    func terminalCacheHitPreemptsActiveBuild() async {
        TaskThreadViewModel.resetSnapshotCacheForTesting()
        let terminal = makeTask(goal: "Cached terminal task", status: .completed)
        terminal.completedAt = Date(timeIntervalSince1970: 10)
        let primingViewModel = TaskThreadViewModel()
        primingViewModel.reset(for: terminal)
        _ = await awaitReadiness(primingViewModel, taskID: terminal.id)

        let barrier = SnapshotBuildBarrier()
        let vm = TaskThreadViewModel(snapshotBuilder: { input, _, _ in
            await barrier.build(input: input)
        })
        let obsolete = makeTask(goal: "Obsolete active task", status: .running)
        vm.reset(for: obsolete)
        while await barrier.startedCount < 1 { await Task.yield() }

        vm.reset(for: terminal)
        #expect(vm.lastSnapshotCacheState == "hit")
        #expect(vm.appliedSnapshotTaskID == terminal.id)
        #expect(vm.appliedSnapshotRevision == 1)

        await barrier.releaseFirst()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(vm.appliedSnapshotTaskID == terminal.id)
        #expect(vm.appliedSnapshotRevision == 1)
        TaskThreadViewModel.resetSnapshotCacheForTesting()
    }

    @MainActor
    @Test("expandWindow increases the run window and rebuilds snapshot")
    func expandWindowIncreasesRunWindow() async {
        let vm = TaskThreadViewModel()
        let task = makeTask(goal: "test")
        task.createdAt = Date(timeIntervalSince1970: 0)

        for i in 0..<150 {
            let run = TaskRun(task: task)
            run.startedAt = Date(timeIntervalSince1970: Double(i * 100))
            run.completedAt = Date(timeIntervalSince1970: Double(i * 100 + 90))
            run.setOutput("run \(i)")
            task.runs.append(run)
        }

        vm.reset(for: task)
        _ = await awaitSnapshot(vm, where: { $0.sortedRuns.count == 50 })

        #expect(vm.snapshot?.sortedRuns.count == 50)
        #expect(vm.snapshot?.omittedRunCount == 100)

        vm.expandWindow(for: task)
        _ = await awaitSnapshot(vm, where: { $0.sortedRuns.count == 100 })

        #expect(vm.snapshot?.sortedRuns.count == 100)
        #expect(vm.snapshot?.omittedRunCount == 50)
        #expect(vm.snapshot?.latestRun?.output == "run 149")

        vm.expandWindow(for: task)
        _ = await awaitSnapshot(vm, where: { $0.sortedRuns.count == 150 })

        #expect(vm.snapshot?.sortedRuns.count == 150)
        #expect(vm.snapshot?.omittedRunCount == 0)
    }

    @MainActor
    @Test("expandWindow is a no-op when no runs are omitted")
    func expandWindowNoOpWhenNoOmitted() async {
        let vm = TaskThreadViewModel()
        let task = makeTask(goal: "test")
        task.createdAt = Date(timeIntervalSince1970: 0)

        for i in 0..<10 {
            let run = TaskRun(task: task)
            run.startedAt = Date(timeIntervalSince1970: Double(i * 100))
            run.completedAt = Date(timeIntervalSince1970: Double(i * 100 + 90))
            run.setOutput("run \(i)")
            task.runs.append(run)
        }

        vm.reset(for: task)
        _ = await awaitSnapshot(vm, where: { $0.sortedRuns.count == 10 })

        #expect(vm.snapshot?.sortedRuns.count == 10)
        #expect(vm.snapshot?.omittedRunCount == 0)

        vm.expandWindow(for: task)
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(vm.snapshot?.sortedRuns.count == 10)
        #expect(vm.snapshot?.omittedRunCount == 0)
    }

    @MainActor
    @Test("reset restores the default window after expansion")
    func resetRestoresDefaultWindow() async {
        let vm = TaskThreadViewModel()
        let task = makeTask(goal: "test")
        task.createdAt = Date(timeIntervalSince1970: 0)

        for i in 0..<120 {
            let run = TaskRun(task: task)
            run.startedAt = Date(timeIntervalSince1970: Double(i * 100))
            run.completedAt = Date(timeIntervalSince1970: Double(i * 100 + 90))
            run.setOutput("run \(i)")
            task.runs.append(run)
        }

        vm.reset(for: task)
        _ = await awaitSnapshot(vm, where: { $0.sortedRuns.count == 50 })
        #expect(vm.snapshot?.sortedRuns.count == 50)

        vm.expandWindow(for: task)
        _ = await awaitSnapshot(vm, where: { $0.sortedRuns.count == 100 })
        #expect(vm.snapshot?.sortedRuns.count == 100)

        vm.reset(for: task)
        _ = await awaitSnapshot(vm, where: { $0.sortedRuns.count == 50 })
        #expect(vm.snapshot?.sortedRuns.count == 50)
        #expect(vm.snapshot?.omittedRunCount == 70)
    }

    @MainActor
    @Test("Completed large task reset reuses terminal snapshot cache")
    func completedLargeTaskResetReusesTerminalSnapshotCache() async {
        TaskThreadViewModel.resetSnapshotCacheForTesting()

        let vm = TaskThreadViewModel()
        let task = makeTask(goal: "Summarize a large completed task", status: .completed)
        task.createdAt = Date(timeIntervalSince1970: 0)
        task.completedAt = Date(timeIntervalSince1970: 30_000)

        for i in 0..<220 {
            let run = TaskRun(task: task)
            run.status = .completed
            run.startedAt = Date(timeIntervalSince1970: Double(i * 100))
            run.completedAt = Date(timeIntervalSince1970: Double(i * 100 + 90))
            run.setOutput("completed run \(i)")
            task.runs.append(run)

            let event = TaskEvent(task: task, type: "agent.response", payload: "response \(i)", run: run)
            event.timestamp = Date(timeIntervalSince1970: Double(i * 100 + 95))
            task.events.append(event)
        }

        vm.reset(for: task)
        _ = await awaitSnapshot(vm, where: { $0.sortedRuns.count == 50 })

        let firstStats = TaskThreadViewModel.snapshotCacheStatsForTesting
        #expect(firstStats.entryCount == 1)
        #expect(firstStats.missCount == 1)
        #expect(firstStats.hitCount == 0)
        #expect(vm.lastSnapshotCacheState == "miss")

        vm.reset(for: task)

        let secondStats = TaskThreadViewModel.snapshotCacheStatsForTesting
        #expect(vm.snapshot?.sortedRuns.count == 50)
        #expect(vm.snapshot?.omittedRunCount == 170)
        #expect(secondStats.entryCount == 1)
        #expect(secondStats.hitCount == 1)
        #expect(secondStats.missCount == 1)
        #expect(vm.lastSnapshotCacheState == "hit")

        TaskThreadViewModel.resetSnapshotCacheForTesting()
    }

    @MainActor
    @Test("Terminal snapshot cache key uses the durable task revision without event signatures")
    func terminalSnapshotCacheKeyUsesTaskRevisionWithoutEventSignatures() throws {
        let task = makeTask(
            goal: String(repeating: "Long goal with expensive retained text. ", count: 300),
            status: .completed
        )
        task.createdAt = Date(timeIntervalSince1970: 0)
        task.completedAt = Date(timeIntervalSince1970: 100)
        let key = try #require(TaskThreadSnapshotCacheKey(task: task, maxRuns: 50))

        let fieldNames = Set(Mirror(reflecting: key).children.compactMap(\.label))
        #expect(fieldNames.contains("revision"))
        #expect(!fieldNames.contains("eventSignatures"))
        #expect(!fieldNames.contains("runSignatures"))
    }

    @Test("Terminal snapshot cache key invalidates from the task revision")
    func terminalSnapshotCacheKeyInvalidatesFromTaskRevision() throws {
        let task = makeTask(goal: "Completed task", status: .completed)
        task.updatedAt = Date(timeIntervalSince1970: 100)
        let initialKey = try #require(TaskThreadSnapshotCacheKey(task: task, maxRuns: 50))

        task.updatedAt = Date(timeIntervalSince1970: 101)
        let updatedKey = try #require(TaskThreadSnapshotCacheKey(task: task, maxRuns: 50))

        #expect(initialKey != updatedKey)
    }

    @Test("Task thread view model reuses one cache key for terminal snapshot lookup and storage")
    func taskThreadViewModelReusesOneCacheKeyForTerminalSnapshotLookupAndStorage() throws {
        let sourceURL = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Astra/Views/TaskThreadViewModel.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let constructorCount = source.components(separatedBy: "TaskThreadSnapshotCacheKey(task:").count - 1

        #expect(constructorCount == 1)
    }

    @Test("Terminal cache lookup happens before the full snapshot trigger")
    func terminalCacheLookupHappensBeforeSnapshotTrigger() throws {
        let sourceURL = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Astra/Views/TaskThreadViewModel.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let cacheLookup = try #require(source.range(of: "let cacheKey = TaskThreadSnapshotCacheKey"))
        let triggerConstruction = try #require(source.range(of: "let trigger = TaskThreadSnapshotTrigger"))

        #expect(cacheLookup.lowerBound < triggerConstruction.lowerBound)
    }
}

// MARK: - TaskCheckpointPresentation

@Suite("TaskCheckpointPresentation")
struct TaskCheckpointPresentationTests {

    @Test("Checkpoint comparison separates restored branch from later task history")
    func checkpointComparisonSeparatesRestoredBranchFromLaterHistory() throws {
        let task = makeTask(goal: "Try alternative implementation branches")
        let first = makeCheckpointRun(
            task: task,
            index: 0,
            output: "First branch created the model.",
            tokens: 100,
            filePaths: ["/tmp/model.swift"]
        )
        let second = makeCheckpointRun(
            task: task,
            index: 1,
            output: "Second branch wired the checkpoint browser.",
            tokens: 200,
            filePaths: ["/tmp/browser.swift"]
        )
        let third = makeCheckpointRun(
            task: task,
            index: 2,
            output: "Later branch changed the restore path.",
            tokens: 300,
            filePaths: ["/tmp/restore.swift"]
        )

        let summaries = TaskCheckpointPresentation.summaries(from: [third, first, second].map(runSnapshot))
        let comparison = try #require(TaskCheckpointPresentation.comparison(for: second.id, in: summaries))

        #expect(summaries.map(\.run.id) == [first.id, second.id, third.id])
        #expect(comparison.selected.stepNumber == 2)
        #expect(comparison.includedRunCount == 2)
        #expect(comparison.excludedRunCount == 1)
        #expect(comparison.includedTokenCount == 300)
        #expect(comparison.excludedTokenCount == 300)
        #expect(comparison.includedFileCount == 2)
        #expect(comparison.excludedFileCount == 1)
        #expect(comparison.includedFiles == ["/tmp/model.swift", "/tmp/browser.swift"])
        #expect(comparison.excludedFiles == ["/tmp/restore.swift"])
        #expect(comparison.selected.outputPreview.contains("checkpoint browser"))
        #expect(comparison.laterOutputPreview.contains("restore path"))
        #expect(comparison.branchSummary == "1 later step will stay on the current task.")
        #expect(comparison.canRestore)
        #expect(TaskCheckpointPresentation.restoreActionTitle == "Fork Conversation")
    }

    @Test("Checkpoint file counts match deduplicated file lists")
    func checkpointFileCountsMatchDeduplicatedFileLists() throws {
        let task = makeTask(goal: "Compare repeated file changes")
        let first = makeCheckpointRun(
            task: task,
            index: 0,
            output: "First edit.",
            tokens: 100,
            filePaths: ["/tmp/shared.swift"]
        )
        let second = makeCheckpointRun(
            task: task,
            index: 1,
            output: "Second edit repeats shared files.",
            tokens: 200,
            filePaths: ["/tmp/shared.swift", "/tmp/unique.swift", "/tmp/unique.swift"]
        )
        let third = makeCheckpointRun(
            task: task,
            index: 2,
            output: "Later edit repeats another file.",
            tokens: 300,
            filePaths: ["/tmp/later.swift", "/tmp/later.swift"]
        )

        let summaries = TaskCheckpointPresentation.summaries(from: [first, second, third].map(runSnapshot))
        let comparison = try #require(TaskCheckpointPresentation.comparison(for: second.id, in: summaries))

        #expect(summaries.map(\.fileCount) == [1, 2, 1])
        #expect(comparison.includedFiles == ["/tmp/shared.swift", "/tmp/unique.swift"])
        #expect(comparison.excludedFiles == ["/tmp/later.swift"])
        #expect(comparison.includedFileCount == comparison.includedFiles.count)
        #expect(comparison.excludedFileCount == comparison.excludedFiles.count)
    }

    @Test("Checkpoint browser uses deterministic UUID ordering for tied start times")
    func checkpointBrowserUsesDeterministicTieBreak() {
        let task = makeTask()
        let first = makeCheckpointRun(task: task, index: 0, output: "One", tokens: 1, filePaths: [])
        let second = makeCheckpointRun(task: task, index: 0, output: "Two", tokens: 1, filePaths: [])
        let snapshots = [runSnapshot(second), runSnapshot(first)]
        let expected = snapshots.sorted { $0.id.uuidString < $1.id.uuidString }.map(\.id)

        #expect(TaskCheckpointPresentation.summaries(from: snapshots).map(\.id) == expected)
    }

    @Test("Running checkpoint cannot be restored from browser")
    func runningCheckpointCannotBeRestoredFromBrowser() throws {
        let task = makeTask()
        let run = makeCheckpointRun(
            task: task,
            index: 0,
            status: .running,
            completed: nil,
            output: "Still streaming.",
            tokens: 10,
            filePaths: []
        )

        let summaries = TaskCheckpointPresentation.summaries(from: [runSnapshot(run)])
        let comparison = try #require(TaskCheckpointPresentation.comparison(for: run.id, in: summaries))

        #expect(!comparison.canRestore)
        #expect(comparison.restoreDisabledReason == "Wait for this step to finish before restoring from it.")
    }

    private func makeCheckpointRun(
        task: AgentTask,
        index: Int,
        status: RunStatus = .completed,
        completed: Date? = nil,
        output: String,
        tokens: Int,
        filePaths: [String]
    ) -> TaskRun {
        let run = TaskRun(task: task)
        run.status = status
        run.startedAt = Date(timeIntervalSince1970: Double(index * 100))
        run.completedAt = completed ?? (status == .running ? nil : Date(timeIntervalSince1970: Double(index * 100 + 20)))
        run.setOutput(output)
        run.tokensUsed = tokens

        for path in filePaths {
            run.appendFileChange(StoredFileChange(
                from: FileChange(
                    path: path,
                    changeType: .write,
                    content: "content",
                    oldString: nil,
                    newString: nil,
                    timestamp: run.startedAt
                )
            ))
        }

        return run
    }

    private func runSnapshot(_ run: TaskRun) -> TaskRunSnapshot {
        TaskRunSnapshot(input: TaskRunSnapshotInput(run: run))
    }
}

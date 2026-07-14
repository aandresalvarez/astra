import Testing
import Foundation
import ASTRAModels
@testable import ASTRA
import ASTRACore

/// Stress tests for the transcript snapshot pipeline: windowing at scale,
/// same-timestamp floods, tool-result capping, cancellation, executor
/// serialization, trigger bucketing, and terminal-cache LRU behavior. This is
/// the per-tick cost of a streaming chat, so the invariants here are what keep
/// a 30k-event task from freezing the UI.
///
/// Opt-in: runs only with `RUN_UI_STRESS=1` (see `uiStressSuitesEnabled`).
@Suite(
    "UI stress: thread snapshot",
    .enabled(if: uiStressSuitesEnabled, "Set RUN_UI_STRESS=1 to run the UI stress suites")
)
struct UIStressThreadSnapshotTests {
    private static let heavyTierEnabled = ProcessInfo.processInfo.environment["RUN_UI_STRESS"] == "1"

    // MARK: - Fixtures

    /// A task with `runCount` completed runs and `eventsPerRun` mixed events
    /// per run, including enough `tool.result` rows to exceed the per-run cap.
    ///
    /// Events and runs accumulate in plain local arrays and land on the model
    /// in ONE assignment each: every `append` on an observed SwiftData array
    /// property copies the whole array, so per-element appends make a 30k
    /// fixture take minutes instead of milliseconds.
    private static func denseTask(runCount: Int, eventsPerRun: Int, goal: String = "Dense fixture") -> AgentTask {
        let task = makeTask(goal: goal)
        task.createdAt = Date(timeIntervalSince1970: 0)
        var runs: [TaskRun] = []
        var events: [TaskEvent] = []
        runs.reserveCapacity(runCount)
        events.reserveCapacity(runCount * eventsPerRun)
        for runIndex in 0..<runCount {
            let base = Double(runIndex * 10_000)
            let run = TaskRun(task: task)
            run.startedAt = Date(timeIntervalSince1970: base)
            run.completedAt = Date(timeIntervalSince1970: base + 9_000)
            run.status = .completed
            run.output = "Answer for run \(runIndex) with a small body of text."
            runs.append(run)

            for eventIndex in 0..<eventsPerRun {
                let type: String
                switch eventIndex % 5 {
                case 0: type = "tool.result"
                case 1: type = "agent.response"
                case 2: type = "tool.use"
                case 3: type = "agent.thinking"
                default: type = "user.message"
                }
                events.append(makeEvent(
                    task: task,
                    type: type,
                    payload: "event \(runIndex)-\(eventIndex) payload",
                    timestamp: Date(timeIntervalSince1970: base + Double(eventIndex)),
                    run: run
                ))
            }
        }
        task.runs = runs
        task.events = events
        return task
    }

    private static func toolResultCounts(byRun snapshot: TaskThreadSnapshot) -> [UUID?: Int] {
        var counts: [UUID?: Int] = [:]
        for event in snapshot.sortedEvents where event.type == "tool.result" {
            counts[event.runID, default: 0] += 1
        }
        return counts
    }

    // MARK: - Windowing invariants at scale

    @Test("30k-event task windows to bounded input with consistent accounting")
    func largeTaskWindowsWithConsistentAccounting() {
        let task = Self.denseTask(runCount: 150, eventsPerRun: 200)

        var input: TaskThreadSnapshotInput?
        let elapsed = ContinuousClock().measure {
            input = TaskThreadSnapshotInput(task: task)
        }
        guard let input else {
            Issue.record("input construction failed")
            return
        }

        #expect(input.totalEventCount == 30_000)
        #expect(input.totalRunCount == 150)
        #expect(input.runs.count == 50)
        #expect(input.events.count <= 1_200)
        #expect(input.omittedRunCount == 100)
        #expect(input.omittedEventCount == input.totalEventCount - input.events.count)
        // Locally ~120ms for 30k events; this bounds the main-thread capture
        // cost for a very long live task.
        #expect(elapsed < .seconds(5), "windowing took \(elapsed) for \(input.totalEventCount) events")

        let snapshot = TaskThreadSnapshot(input: input)
        #expect(snapshot.sortedRuns.count == 50)
        #expect(snapshot.sortedEvents.count == input.events.count)

        let timestamps = snapshot.sortedEvents.map(\.timestamp)
        #expect(timestamps == timestamps.sorted(), "sortedEvents must be time-ordered")

        for (runID, count) in Self.toolResultCounts(byRun: snapshot) {
            #expect(count <= 12, "run \(String(describing: runID)) kept \(count) tool results, cap is 12")
        }
    }

    @Test("snapshot construction is deterministic for the same task state")
    func snapshotConstructionIsDeterministic() {
        let task = Self.denseTask(runCount: 30, eventsPerRun: 60)
        let first = TaskThreadSnapshot(input: TaskThreadSnapshotInput(task: task))
        let second = TaskThreadSnapshot(input: TaskThreadSnapshotInput(task: task))

        #expect(first.sortedEvents.map(\.id) == second.sortedEvents.map(\.id))
        #expect(first.sortedRuns.map(\.id) == second.sortedRuns.map(\.id))
        #expect(first.conversationItems.count == second.conversationItems.count)
    }

    @Test("a 2k flood of identical timestamps stays deterministic and bounded")
    func identicalTimestampFloodIsDeterministic() {
        let task = makeTask(goal: "Same-instant flood")
        task.createdAt = Date(timeIntervalSince1970: 0)
        let run = TaskRun(task: task)
        run.startedAt = Date(timeIntervalSince1970: 1)
        run.status = .running
        task.runs.append(run)
        let instant = Date(timeIntervalSince1970: 5)
        task.events = (0..<2_000).map { index in
            makeEvent(
                task: task,
                type: index.isMultiple(of: 2) ? "agent.response" : "tool.result",
                payload: "burst \(index)",
                timestamp: instant,
                run: run
            )
        }

        let first = TaskThreadSnapshot(input: TaskThreadSnapshotInput(task: task))
        let second = TaskThreadSnapshot(input: TaskThreadSnapshotInput(task: task))
        #expect(first.sortedEvents.count <= 1_200)
        #expect(first.sortedEvents.map(\.id) == second.sortedEvents.map(\.id),
                "same-instant events must not reorder between rebuilds of the same state")
    }

    @Test("per-run state events survive a 1.3k later-event flood")
    func stateEventsSurviveEventFlood() {
        let task = makeTask(goal: "State survival")
        task.createdAt = Date(timeIntervalSince1970: 0)
        let run = TaskRun(task: task)
        run.startedAt = Date(timeIntervalSince1970: 1)
        run.status = .running
        task.runs.append(run)

        var events: [TaskEvent] = [
            makeEvent(
                task: task,
                type: "astra.todo.replace",
                payload: "[]",
                timestamp: Date(timeIntervalSince1970: 2),
                run: run
            ),
            makeEvent(
                task: task,
                type: "permission.approval.requested",
                payload: "tool: bash",
                timestamp: Date(timeIntervalSince1970: 3),
                run: run
            )
        ]
        for index in 0..<1_300 {
            events.append(makeEvent(
                task: task,
                type: "agent.response",
                payload: "later \(index)",
                timestamp: Date(timeIntervalSince1970: Double(10 + index)),
                run: run
            ))
        }
        task.events = events

        let snapshot = TaskThreadSnapshot(input: TaskThreadSnapshotInput(task: task))
        #expect(snapshot.sortedEvents.contains { $0.type == "astra.todo.replace" })
        #expect(snapshot.sortedEvents.contains { $0.type == "permission.approval.requested" })
    }

    @Test("exact-cap boundaries keep every event and every tool result")
    func exactCapBoundariesKeepEverything() {
        let task = makeTask(goal: "Boundary fixture")
        task.createdAt = Date(timeIntervalSince1970: 0)
        let run = TaskRun(task: task)
        run.startedAt = Date(timeIntervalSince1970: 1)
        run.status = .completed
        run.completedAt = Date(timeIntervalSince1970: 2_000)
        task.runs.append(run)
        var events: [TaskEvent] = []
        for index in 0..<12 {
            events.append(makeEvent(
                task: task,
                type: "tool.result",
                payload: "tool \(index)",
                timestamp: Date(timeIntervalSince1970: Double(10 + index)),
                run: run
            ))
        }
        for index in 0..<1_188 {
            events.append(makeEvent(
                task: task,
                type: "agent.response",
                payload: "filler \(index)",
                timestamp: Date(timeIntervalSince1970: Double(100 + index)),
                run: run
            ))
        }
        task.events = events

        let input = TaskThreadSnapshotInput(task: task)
        #expect(input.totalEventCount == 1_200)
        #expect(input.events.count == 1_200)
        #expect(input.omittedEventCount == 0)
        let snapshot = TaskThreadSnapshot(input: input)
        #expect(Self.toolResultCounts(byRun: snapshot)[run.id] == 12)
    }

    // MARK: - Full build cost at the window ceiling

    @Test("full snapshot build at the window ceiling stays within budget")
    func fullBuildAtWindowCeiling() {
        let task = Self.denseTask(runCount: 50, eventsPerRun: 24)
        task.runs.last?.output = String(repeating: "Streaming answer prose. ", count: 4_000)

        let input = TaskThreadSnapshotInput(task: task)
        #expect(input.events.count <= 1_200)

        var snapshot: TaskThreadSnapshot?
        let elapsed = ContinuousClock().measure {
            snapshot = TaskThreadSnapshot(input: input)
        }
        #expect(snapshot != nil)
        #expect((snapshot?.conversationItems.count ?? 0) > 50)
        // This is the recurring off-main build cost during live streaming
        // (locally ~50ms); a blowup here directly becomes UI latency.
        #expect(elapsed < .seconds(4), "snapshot build took \(elapsed)")
    }

    @Test(
        "heavy tier: 100k-event task input capture",
        .enabled(if: heavyTierEnabled, "Set RUN_UI_STRESS=1 to run heavy UI stress tiers")
    )
    func hundredThousandEventCapture() {
        let task = Self.denseTask(runCount: 500, eventsPerRun: 200)
        var input: TaskThreadSnapshotInput?
        let elapsed = ContinuousClock().measure {
            input = TaskThreadSnapshotInput(task: task)
        }
        #expect(input?.totalEventCount == 100_000)
        #expect((input?.events.count ?? .max) <= 1_200)
        #expect(elapsed < .seconds(20), "100k-event capture took \(elapsed)")
    }

    // MARK: - Cancellation

    @Test("a cancelled executor build acknowledges cancellation promptly")
    func cancellableBuildHonorsCancellation() async {
        let task = Self.denseTask(runCount: 50, eventsPerRun: 24)
        for run in task.runs {
            run.output = String(repeating: "Large body to scan. ", count: 10_000)
        }
        let input = TaskThreadSnapshotInput(task: task)
        let executor = TaskThreadSnapshotBuildExecutor()

        let build = Task.detached(priority: .userInitiated) {
            try await executor.build(
                input: input,
                fields: [:],
                responsivenessContext: nil,
                admittedAt: DispatchTime.now().uptimeNanoseconds
            )
        }
        build.cancel()
        let outcome = await build.result

        switch outcome {
        case .failure(let error):
            #expect(error is CancellationError, "expected CancellationError, got \(error)")
            let stats = await executor.stats
            #expect(stats.cancelled == 1)
        case .success:
            // A race where the build wins is legal; it must still be a
            // complete, well-formed snapshot.
            #expect((try? outcome.get())?.sortedRuns.count == 50)
        }
    }

    // MARK: - Executor serialization

    @Test("executor serializes 24 concurrent builds without deadlock")
    func executorSerializesConcurrentBuilds() async throws {
        let executor = TaskThreadSnapshotBuildExecutor()
        let task = Self.denseTask(runCount: 40, eventsPerRun: 30)
        let input = TaskThreadSnapshotInput(task: task)

        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<24 {
                group.addTask {
                    let snapshot = try await executor.build(
                        input: input,
                        fields: [:],
                        responsivenessContext: nil,
                        admittedAt: DispatchTime.now().uptimeNanoseconds
                    )
                    return snapshot.sortedEvents.count
                }
            }
            var results: [Int] = []
            for try await count in group {
                results.append(count)
            }
            #expect(results.count == 24)
            #expect(Set(results).count == 1, "every build sees the same input")
        }

        let stats = await executor.stats
        #expect(stats.active == 0)
        #expect(stats.maximum == 1, "actor executor must never run builds concurrently")
        #expect(stats.cancelled == 0)
    }

    // MARK: - Trigger bucketing

    @Test("live-output growth only invalidates the trigger across 1KB buckets")
    func triggerBucketsLiveOutputGrowth() {
        let task = makeTask(goal: "Trigger fixture", status: .running)
        let run = TaskRun(task: task)
        run.startedAt = Date(timeIntervalSince1970: 1)
        run.status = .running
        task.runs.append(run)

        run.output = String(repeating: "a", count: 100)
        let base = TaskThreadSnapshotTrigger(task: task)

        run.output += String(repeating: "b", count: 100)
        let sameBucket = TaskThreadSnapshotTrigger(task: task)
        #expect(base == sameBucket, "sub-bucket output growth must coalesce (no rebuild per chunk)")

        run.output += String(repeating: "c", count: 1_024)
        let nextBucket = TaskThreadSnapshotTrigger(task: task)
        #expect(base != nextBucket, "crossing a 1KB bucket must invalidate")

        run.status = .completed
        let statusFlip = TaskThreadSnapshotTrigger(task: task)
        #expect(nextBucket != statusFlip, "run status changes must always invalidate")
    }

    @Test("high-frequency event types do not thrash the trigger")
    func highFrequencyEventsDoNotThrashTrigger() {
        let task = makeTask(goal: "Trigger noise", status: .running)
        let run = TaskRun(task: task)
        run.startedAt = Date(timeIntervalSince1970: 1)
        run.status = .running
        task.runs.append(run)
        let base = TaskThreadSnapshotTrigger(task: task)

        // agent.response / agent.thinking rows are excluded from the visible
        // count precisely so streaming noise coalesces into the output bucket.
        task.events.append(makeEvent(
            task: task,
            type: "agent.thinking",
            payload: "…",
            timestamp: Date(timeIntervalSince1970: 2),
            run: run
        ))
        #expect(TaskThreadSnapshotTrigger(task: task) == base)

        task.events.append(makeEvent(
            task: task,
            type: "tool.result",
            payload: "ls output",
            timestamp: Date(timeIntervalSince1970: 3),
            run: run
        ))
        #expect(TaskThreadSnapshotTrigger(task: task) != base, "visible event types must invalidate")
    }

    // MARK: - Terminal cache

    @Test("terminal snapshot cache evicts LRU at 12 entries and tracks stats")
    func terminalCacheEvictsLeastRecentlyUsed() throws {
        var cache = TaskThreadSnapshotCache()
        var keys: [TaskThreadSnapshotCacheKey] = []
        for index in 0..<13 {
            let task = makeTask(goal: "Cached \(index)", status: .completed)
            task.createdAt = Date(timeIntervalSince1970: Double(index))
            let key = try #require(TaskThreadSnapshotCacheKey(task: task, maxRuns: 50))
            keys.append(key)
            let snapshot = TaskThreadSnapshot(input: TaskThreadSnapshotInput(task: task))
            if index == 12 {
                // Touch the oldest entry right before inserting the 13th so
                // eviction provably follows recency, not insertion order.
                #expect(cache.snapshot(for: keys[0]) != nil)
            }
            cache.store(snapshot, for: key)
        }

        #expect(cache.stats.entryCount == 12)
        #expect(cache.snapshot(for: keys[0]) != nil, "recently-touched oldest key must survive")
        #expect(cache.snapshot(for: keys[1]) == nil, "true LRU key must be evicted")
        #expect(cache.stats.hitCount >= 2)
        #expect(cache.stats.missCount >= 1)
    }

    @Test("running and queued tasks are never cacheable")
    func liveTasksAreNeverCacheable() {
        for status in [TaskStatus.running, .queued] {
            let task = makeTask(goal: "live", status: status)
            #expect(TaskThreadSnapshotCacheKey(task: task, maxRuns: 50) == nil)
        }
        for status in [TaskStatus.completed, .failed, .cancelled, .pendingUser] {
            let task = makeTask(goal: "terminal", status: status)
            #expect(TaskThreadSnapshotCacheKey(task: task, maxRuns: 50) != nil)
        }
    }
}

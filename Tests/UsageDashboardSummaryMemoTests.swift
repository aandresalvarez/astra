import Testing
import AppKit
import SwiftUI
@testable import ASTRA
import ASTRACore

// MARK: - UsageDashboardSummaryMemo

@Suite("UsageDashboardSummaryMemo")
struct UsageDashboardSummaryMemoTests {

    @Test("Summary reflects tasks/runs on first computation, with no follow-up scheduled")
    func summaryReflectsInputsOnFirstComputation() {
        let memo = UsageDashboardSummaryMemo(minimumInterval: 60)
        let task = makeTask(status: .completed, tokensUsed: 100, costUSD: 1.5)
        let run = TaskRun(task: task)
        run.startedAt = Date(timeIntervalSince1970: 0)

        let query = memo.query(tasks: [task], runs: [run], timeFilter: .allTime)

        #expect(query.summary.totalTokens == 100)
        #expect(query.summary.totalCost == 1.5)
        #expect(query.summary.completedCount == 1)
        #expect(query.summary.totalRuns == 1)
        #expect(query.staleRefreshDelay == nil, "a fresh recompute never needs a follow-up refresh")
    }

    @Test("A value-only status change (e.g. approving a pending-user task) reports a stale delay even with no live task anywhere")
    func valueOnlyStatusChangeReportsStaleDelayWithNoLiveTask() {
        // Regression test: TaskLiveness.isLive doesn't cover a
        // .pendingUser -> .completed transition at all (neither status is
        // running/queued), so a design that only scheduled follow-ups while
        // some task looked "live" never caught this — approving a task left
        // the Completed/Failed/token cards stale indefinitely.
        let memo = UsageDashboardSummaryMemo(minimumInterval: 60)
        let task = makeTask(status: .pendingUser, tokensUsed: 100, costUSD: 1.0)
        let run = TaskRun(task: task)

        let first = memo.query(tasks: [task], runs: [run], timeFilter: .allTime)
        #expect(first.summary.completedCount == 0)
        #expect(first.staleRefreshDelay == nil)

        task.status = .completed // e.g. the user approves it; counts/filter unchanged

        let second = memo.query(tasks: [task], runs: [run], timeFilter: .allTime)
        #expect(second.summary.completedCount == 0, "expected the throttled cache to be reused, not recomputed")
        #expect(second.staleRefreshDelay != nil, "a value-only status change was served stale, so a follow-up must be scheduled")
        if let delay = second.staleRefreshDelay {
            #expect(delay > 0 && delay <= 60)
        }
    }

    @Test("Every caller within a stale window gets its own delay, independent of other callers")
    func everyStaleCallerGetsItsOwnDelay() {
        // Regression test: an earlier version deduplicated with a
        // `followUpScheduled` flag so only the first caller in a window got a
        // delay. That's a real bug for multiple open dashboard windows sharing
        // this process-wide memo: if the window that "claimed" the follow-up
        // closes before its delayed re-query fires, every other window's
        // caller also saw the flag set and got nil, so nothing ever refreshed
        // them. Each caller must independently be told to follow up, since the
        // memo has no way to know whether whoever claimed it first is still
        // around to act on it.
        let memo = UsageDashboardSummaryMemo(minimumInterval: 60)
        let task = makeTask(status: .completed, tokensUsed: 100, costUSD: 1.0)
        let run = TaskRun(task: task)

        _ = memo.query(tasks: [task], runs: [run], timeFilter: .allTime)
        task.tokensUsed = 999

        // Simulates two independent dashboard windows observing the same
        // stale cache entry (e.g. window A, then window B, each re-rendering
        // due to the same underlying mutation).
        let windowA = memo.query(tasks: [task], runs: [run], timeFilter: .allTime)
        #expect(windowA.staleRefreshDelay != nil, "window A must be told to schedule its own follow-up")

        let windowB = memo.query(tasks: [task], runs: [run], timeFilter: .allTime)
        #expect(windowB.staleRefreshDelay != nil, "window B must ALSO be told to schedule its own follow-up, even though window A already saw a delay — window A might close before its follow-up fires")
    }

    @Test("A task/run count change always forces a recompute and resets the follow-up flag")
    func countChangeForcesRecomputeAndResetsFollowUp() {
        let memo = UsageDashboardSummaryMemo(minimumInterval: 60)
        let taskA = makeTask(status: .completed, tokensUsed: 100, costUSD: 1.0)
        let runA = TaskRun(task: taskA)

        let first = memo.query(tasks: [taskA], runs: [runA], timeFilter: .allTime)
        #expect(first.summary.totalTokens == 100)

        let taskB = makeTask(status: .completed, tokensUsed: 50, costUSD: 0.5)
        let runB = TaskRun(task: taskB)

        let second = memo.query(tasks: [taskA, taskB], runs: [runA, runB], timeFilter: .allTime)
        #expect(second.summary.totalTokens == 150, "adding a task must always be reflected immediately")
        #expect(second.staleRefreshDelay == nil, "a count change recomputes fresh, no follow-up needed")

        // A subsequent value-only mutation must schedule its own fresh
        // follow-up rather than being silently dropped by a stale flag.
        taskA.tokensUsed = 500
        let third = memo.query(tasks: [taskA, taskB], runs: [runA, runB], timeFilter: .allTime)
        #expect(third.staleRefreshDelay != nil)
    }

    @Test("Changing the time filter always forces a recompute, even inside the throttle window")
    func filterChangeForcesRecomputeInsideThrottleWindow() {
        let memo = UsageDashboardSummaryMemo(minimumInterval: 60)
        let oldTask = makeTask(status: .completed, tokensUsed: 100, costUSD: 1.0)
        oldTask.createdAt = Date(timeIntervalSince1970: 0)
        let run = TaskRun(task: oldTask)
        run.startedAt = Date(timeIntervalSince1970: 0)

        let allTime = memo.query(tasks: [oldTask], runs: [run], timeFilter: .allTime)
        #expect(allTime.summary.totalTokens == 100)

        let today = memo.query(tasks: [oldTask], runs: [run], timeFilter: .today)
        #expect(today.summary.totalTokens == 0, "an old task must be excluded once filtered to Today, not served from the All Time cache")
        #expect(today.staleRefreshDelay == nil)
    }

    @Test("A stale value is picked up once the throttle window elapses")
    func staleValueIsPickedUpAfterThrottleWindowElapses() async {
        let memo = UsageDashboardSummaryMemo(minimumInterval: 0.03)
        let task = makeTask(status: .completed, tokensUsed: 100, costUSD: 1.0)
        let run = TaskRun(task: task)

        let first = memo.query(tasks: [task], runs: [run], timeFilter: .allTime)
        #expect(first.summary.totalTokens == 100)

        task.tokensUsed = 250
        try? await Task.sleep(nanoseconds: 60_000_000)

        let second = memo.query(tasks: [task], runs: [run], timeFilter: .allTime)
        #expect(second.summary.totalTokens == 250)
        #expect(second.staleRefreshDelay == nil, "the window elapsed, so this call recomputed fresh")
    }

    @Test("resetForTesting clears cached state so the next call recomputes unconditionally")
    func resetForTestingClearsCachedState() {
        let memo = UsageDashboardSummaryMemo(minimumInterval: 60)
        let task = makeTask(status: .completed, tokensUsed: 100, costUSD: 1.0)
        let run = TaskRun(task: task)

        _ = memo.query(tasks: [task], runs: [run], timeFilter: .allTime)
        task.tokensUsed = 500
        memo.resetForTesting()

        let after = memo.query(tasks: [task], runs: [run], timeFilter: .allTime)
        #expect(after.summary.totalTokens == 500)
        #expect(after.staleRefreshDelay == nil)
    }
}

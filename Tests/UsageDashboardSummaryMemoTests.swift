import Testing
import AppKit
import SwiftUI
@testable import ASTRA
import ASTRACore

// MARK: - UsageDashboardSummaryMemo

@Suite("UsageDashboardSummaryMemo")
struct UsageDashboardSummaryMemoTests {

    @Test("Summary reflects tasks/runs on first computation")
    func summaryReflectsInputsOnFirstComputation() {
        let memo = UsageDashboardSummaryMemo(minimumInterval: 60)
        let task = makeTask(status: .completed, tokensUsed: 100, costUSD: 1.5)
        let run = TaskRun(task: task)
        run.startedAt = Date(timeIntervalSince1970: 0)

        let summary = memo.summary(tasks: [task], runs: [run], timeFilter: .allTime)

        #expect(summary.totalTokens == 100)
        #expect(summary.totalCost == 1.5)
        #expect(summary.completedCount == 1)
        #expect(summary.totalRuns == 1)
    }

    @Test("Within the throttle window, a token/cost mutation on an existing task is coalesced away")
    func throttleCoalescesUnrelatedPropertyMutations() {
        // A long interval so the test never races the throttle window.
        let memo = UsageDashboardSummaryMemo(minimumInterval: 60)
        let task = makeTask(status: .completed, tokensUsed: 100, costUSD: 1.0)
        let run = TaskRun(task: task)

        let first = memo.summary(tasks: [task], runs: [run], timeFilter: .allTime)
        #expect(first.totalTokens == 100)

        // Simulates a streamed `run.output` update elsewhere mutating this task's
        // tokensUsed without changing the task/run counts @Query would report —
        // the same shape of update that used to force a full O(n) rescan on every
        // streamed chunk. `UsageDashboardView.pollWhileLive()` is what closes
        // this gap now (see TaskLiveness/pollWhileLive), not this memo trying to
        // self-report staleness back to the caller.
        task.tokensUsed = 999

        let second = memo.summary(tasks: [task], runs: [run], timeFilter: .allTime)
        #expect(second.totalTokens == 100, "expected the throttled cache to be reused, not recomputed")
    }

    @Test("A task/run count change always forces a recompute, even inside the throttle window")
    func countChangeForcesRecomputeInsideThrottleWindow() {
        let memo = UsageDashboardSummaryMemo(minimumInterval: 60)
        let taskA = makeTask(status: .completed, tokensUsed: 100, costUSD: 1.0)
        let runA = TaskRun(task: taskA)

        let first = memo.summary(tasks: [taskA], runs: [runA], timeFilter: .allTime)
        #expect(first.totalTokens == 100)

        let taskB = makeTask(status: .completed, tokensUsed: 50, costUSD: 0.5)
        let runB = TaskRun(task: taskB)

        let second = memo.summary(tasks: [taskA, taskB], runs: [runA, runB], timeFilter: .allTime)
        #expect(second.totalTokens == 150, "adding a task must always be reflected immediately")
    }

    @Test("Changing the time filter always forces a recompute, even inside the throttle window")
    func filterChangeForcesRecomputeInsideThrottleWindow() {
        let memo = UsageDashboardSummaryMemo(minimumInterval: 60)
        let oldTask = makeTask(status: .completed, tokensUsed: 100, costUSD: 1.0)
        oldTask.createdAt = Date(timeIntervalSince1970: 0)
        let run = TaskRun(task: oldTask)
        run.startedAt = Date(timeIntervalSince1970: 0)

        let allTime = memo.summary(tasks: [oldTask], runs: [run], timeFilter: .allTime)
        #expect(allTime.totalTokens == 100)

        let today = memo.summary(tasks: [oldTask], runs: [run], timeFilter: .today)
        #expect(today.totalTokens == 0, "an old task must be excluded once filtered to Today, not served from the All Time cache")
    }

    @Test("A stale property mutation is picked up once the throttle window elapses")
    func staleMutationIsPickedUpAfterThrottleWindowElapses() async {
        let memo = UsageDashboardSummaryMemo(minimumInterval: 0.03)
        let task = makeTask(status: .completed, tokensUsed: 100, costUSD: 1.0)
        let run = TaskRun(task: task)

        let first = memo.summary(tasks: [task], runs: [run], timeFilter: .allTime)
        #expect(first.totalTokens == 100)

        task.tokensUsed = 250
        try? await Task.sleep(nanoseconds: 60_000_000)

        let second = memo.summary(tasks: [task], runs: [run], timeFilter: .allTime)
        #expect(second.totalTokens == 250)
    }

    @Test("Repeated queries with nothing changed keep serving the same cached value, not recomputing every call")
    func repeatedIdleQueriesReuseCache() {
        let memo = UsageDashboardSummaryMemo(minimumInterval: 60)
        let task = makeTask(status: .completed, tokensUsed: 100, costUSD: 1.0)
        let run = TaskRun(task: task)

        let first = memo.summary(tasks: [task], runs: [run], timeFilter: .allTime)
        let second = memo.summary(tasks: [task], runs: [run], timeFilter: .allTime)
        let third = memo.summary(tasks: [task], runs: [run], timeFilter: .allTime)

        #expect(first.totalTokens == 100)
        #expect(second.totalTokens == 100)
        #expect(third.totalTokens == 100)
    }

    @Test("resetForTesting clears cached state so the next call recomputes unconditionally")
    func resetForTestingClearsCachedState() {
        let memo = UsageDashboardSummaryMemo(minimumInterval: 60)
        let task = makeTask(status: .completed, tokensUsed: 100, costUSD: 1.0)
        let run = TaskRun(task: task)

        _ = memo.summary(tasks: [task], runs: [run], timeFilter: .allTime)
        task.tokensUsed = 500
        memo.resetForTesting()

        let after = memo.summary(tasks: [task], runs: [run], timeFilter: .allTime)
        #expect(after.totalTokens == 500)
    }
}

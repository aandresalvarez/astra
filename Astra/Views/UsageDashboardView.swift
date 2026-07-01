import SwiftUI
import SwiftData

enum TimeFilter: String, CaseIterable {
    case allTime = "All Time"
    case last7Days = "7 Days"
    case today = "Today"

    var cutoff: Date? {
        switch self {
        case .allTime: return nil
        case .last7Days: return Calendar.current.date(byAdding: .day, value: -7, to: Date())
        case .today: return Calendar.current.startOfDay(for: Date())
        }
    }
}

struct UsageDashboardSummary {
    let tasks: [AgentTask]
    let totalTokens: Int
    let totalCost: Double
    let completedCount: Int
    let failedCount: Int
    let totalRuns: Int

    static func build(tasks: [AgentTask], runs: [TaskRun], timeFilter: TimeFilter) -> UsageDashboardSummary {
        PerformanceTelemetry.measure(
            "usage_summary_build",
            thresholdMilliseconds: 15,
            fields: [
                "task_count": String(tasks.count),
                "run_count": String(runs.count),
                "filter": timeFilter.rawValue.replacingOccurrences(of: " ", with: "_")
            ]
        ) {
            let cutoff = timeFilter.cutoff
            var filteredTasks: [AgentTask] = []
            var totalTokens = 0
            var totalCost = 0.0
            var completedCount = 0
            var failedCount = 0

            for task in tasks where cutoff.map({ task.createdAt >= $0 }) ?? true {
                filteredTasks.append(task)
                totalTokens += task.tokensUsed
                totalCost += task.costUSD
                if task.status == .completed {
                    completedCount += 1
                } else if task.status == .failed || task.status == .budgetExceeded {
                    failedCount += 1
                }
            }

            let totalRuns: Int
            if let cutoff {
                totalRuns = runs.reduce(0) { count, run in
                    count + (run.startedAt >= cutoff ? 1 : 0)
                }
            } else {
                totalRuns = runs.count
            }

            return UsageDashboardSummary(
                tasks: filteredTasks.sorted { $0.createdAt > $1.createdAt },
                totalTokens: totalTokens,
                totalCost: totalCost,
                completedCount: completedCount,
                failedCount: failedCount,
                totalRuns: totalRuns
            )
        }
    }
}

/// Result of `UsageDashboardSummaryMemo.query(...)`: the summary to display, plus
/// (only for the *first* caller to observe an already-cached value still inside
/// the throttle window) how long to wait before re-querying to pick up any
/// value-only change — e.g. `tokensUsed`, `costUSD`, or `status` — that landed
/// since the cache was populated. `nil` when this call recomputed fresh, or when
/// a follow-up for the current cache entry has already been reported to an
/// earlier caller (see `UsageDashboardSummaryMemo.followUpScheduled`).
struct UsageDashboardSummaryQuery {
    let summary: UsageDashboardSummary
    let staleRefreshDelay: TimeInterval?
}

/// Throttled cache for `UsageDashboardSummary`. `@Query`'s invalidation is coarse:
/// it re-runs `body` on ANY mutation to a tracked `AgentTask`/`TaskRun`, including
/// `run.output` appends from every streamed token of any active run anywhere in the
/// workspace — none of which feed this summary (it only reads `tokensUsed`,
/// `costUSD`, `status`, `createdAt`, `startedAt`). Recomputing the full walk over
/// every task/run on each of those invalidations made the dashboard cost scale with
/// streaming activity, not with dashboard-relevant changes. This coalesces repeat
/// recomputation to at most once per `minimumInterval` when the task/run counts and
/// filter haven't changed, so a burst of token updates pays for one full scan
/// instead of one per token. Lock-protected (mirrors `WildcardPatternMatcher`)
/// rather than `@State`-driven since it's read directly from `body`, where mutating
/// `@State` synchronously is unsafe.
///
/// This throttle alone can serve a value-only change (tokensUsed/costUSD/status —
/// e.g. approving a pending-user task, which changes none of the count/filter
/// fields the cache keys on) stale with nothing to force a follow-up. A prior
/// version tried gating a *poll loop* on whether any task looked "live"
/// (`TaskLiveness.isLive`), but that predicate only covers running/queued tasks
/// with a live run — a `.pendingUser → .completed` transition isn't a liveness
/// edge at all, so it was never observed by that loop, leaving the Completed/
/// Failed/token cards stale indefinitely. `query(...)` instead reports the
/// staleness signal directly, guarded by `followUpScheduled` so at most one
/// follow-up gets reported per cache entry: the first caller to see a cached
/// value within the window gets a delay and is responsible for re-querying
/// after it; every other caller within that same window gets `nil` (a
/// follow-up is already on its way). Recomputing always resets the flag, so the
/// next stale read schedules its own follow-up again.
final class UsageDashboardSummaryMemo: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: UsageDashboardSummary?
    private var cachedFilter: TimeFilter?
    private var cachedTaskCount = -1
    private var cachedRunCount = -1
    private var lastComputedAt = Date.distantPast
    private var followUpScheduled = false
    private let minimumInterval: TimeInterval

    init(minimumInterval: TimeInterval) {
        self.minimumInterval = minimumInterval
    }

    func query(tasks: [AgentTask], runs: [TaskRun], timeFilter: TimeFilter) -> UsageDashboardSummaryQuery {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        let inputsUnchanged = cachedFilter == timeFilter
            && cachedTaskCount == tasks.count
            && cachedRunCount == runs.count
        if let cached, inputsUnchanged {
            let remaining = minimumInterval - now.timeIntervalSince(lastComputedAt)
            if remaining > 0 {
                if followUpScheduled {
                    return UsageDashboardSummaryQuery(summary: cached, staleRefreshDelay: nil)
                }
                followUpScheduled = true
                return UsageDashboardSummaryQuery(summary: cached, staleRefreshDelay: remaining)
            }
        }
        let summary = UsageDashboardSummary.build(tasks: tasks, runs: runs, timeFilter: timeFilter)
        cached = summary
        cachedFilter = timeFilter
        cachedTaskCount = tasks.count
        cachedRunCount = runs.count
        lastComputedAt = now
        followUpScheduled = false
        return UsageDashboardSummaryQuery(summary: summary, staleRefreshDelay: nil)
    }

    func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        cached = nil
        cachedFilter = nil
        cachedTaskCount = -1
        cachedRunCount = -1
        lastComputedAt = .distantPast
        followUpScheduled = false
    }
}

struct UsageDashboardView: View {
    private static let summaryMemo = UsageDashboardSummaryMemo(minimumInterval: 1.0)

    @Query private var tasks: [AgentTask]
    @Query private var runs: [TaskRun]
    @State private var timeFilter: TimeFilter = .allTime
    @State private var renderTick = 0

    private var summaryQuery: UsageDashboardSummaryQuery {
        Self.summaryMemo.query(tasks: tasks, runs: runs, timeFilter: timeFilter)
    }

    static func resetSummaryCacheForTesting() {
        summaryMemo.resetForTesting()
    }

    var body: some View {
        // Dependency read: bumping renderTick from scheduleFollowUp() forces this body to re-evaluate.
        let _ = renderTick
        let query = summaryQuery
        let summary = query.summary

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Usage Dashboard")
                        .font(Stanford.heading(22))
                        .foregroundStyle(Stanford.black)
                    Spacer()
                    Picker("Period", selection: $timeFilter) {
                        ForEach(TimeFilter.allCases, id: \.self) { f in
                            Text(f.rawValue).tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                }

                // Summary cards
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 12) {
                    StatCard(title: "Total Tasks", value: "\(summary.tasks.count)", icon: "list.bullet", color: Stanford.lagunita)
                    StatCard(title: "Completed", value: "\(summary.completedCount)", icon: "checkmark.circle", color: Stanford.paloAltoGreen)
                    StatCard(title: "Failed", value: "\(summary.failedCount)", icon: "xmark.circle", color: Stanford.failed)
                    StatCard(title: "Total Runs", value: "\(summary.totalRuns)", icon: "arrow.triangle.2.circlepath", color: Stanford.driftwood)
                }

                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 12) {
                    StatCard(title: "Total Tokens", value: Formatters.formatTokens(summary.totalTokens), icon: "number", color: Stanford.poppy)
                    StatCard(title: "Total Cost", value: String(format: "$%.2f", summary.totalCost), icon: "dollarsign.circle", color: Stanford.sky)
                }

                // Per-task breakdown
                if !summary.tasks.isEmpty {
                    Text("Per-Task Breakdown")
                        .font(Stanford.heading(16))
                        .foregroundStyle(Stanford.black)
                        .padding(.top, 8)

                    ForEach(summary.tasks) { task in
                        let status = breakdownStatusIcon(task.status)
                        HStack {
                            Image(systemName: status.0)
                                .font(Stanford.ui(16, weight: .medium))
                                .foregroundStyle(status.1)
                                .frame(width: 24)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.title)
                                    .font(Stanford.body())
                                    .lineLimit(1)
                                    .help(task.title)
                                Text(task.status.rawValue.replacingOccurrences(of: "_", with: " "))
                                    .font(Stanford.caption())
                                    .foregroundStyle(Stanford.coolGrey)
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 2) {
                                Text(Formatters.formatTokens(task.tokensUsed))
                                    .font(Stanford.body().monospacedDigit())
                                if task.costUSD > 0 {
                                    Text(String(format: "$%.2f", task.costUSD))
                                        .font(Stanford.caption())
                                        .foregroundStyle(Stanford.coolGrey)
                                }
                            }

                            ProgressView(value: min(task.budgetProgress, 1.0))
                                .frame(width: 60)
                                .tint(task.budgetProgress > 0.9 ? Stanford.failed : Stanford.coolGrey)
                        }
                        .padding(.vertical, 4)
                        Divider()
                    }
                }
            }
            .padding()
        }
        // Schedules the follow-up via a plain detached `scheduleFollowUp` Task,
        // not a `.task(id:)`-bound one — `followUpScheduled` inside the memo
        // guarantees only one render per cache entry ever sees a non-nil delay,
        // but every OTHER render in that same window sees nil, and keying a
        // `.task(id:)` on "is a follow-up pending" would flip that id back to
        // false on each of those, cancelling the already-scheduled sleep before
        // it fires. `.task { }` here has no `id:`, so it isn't restarted by
        // those later renders — it runs once per view appearance, catching a
        // delay that's already present on the very first query (e.g. the
        // dashboard reopened while a prior instance's cache entry is still
        // inside its window). `.onChange` catches later transitions (`.task {
        // }` alone wouldn't fire again for those, and `.onChange` alone
        // wouldn't fire for a delay present from the start).
        .task {
            if let delay = query.staleRefreshDelay {
                scheduleFollowUp(after: delay)
            }
        }
        .onChange(of: query.staleRefreshDelay) { _, newDelay in
            guard let newDelay else { return }
            scheduleFollowUp(after: newDelay)
        }
    }

    private func scheduleFollowUp(after delay: TimeInterval) {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            renderTick += 1
        }
    }

    /// Leading status glyph for a per-task breakdown row, so the list has a
    /// scannable status column instead of starting cold with a title.
    private func breakdownStatusIcon(_ status: TaskStatus) -> (String, Color) {
        if let pill = StatusPill.forStatus(status) {
            return (pill.icon, pill.color)
        }
        switch status {
        case .running:
            return ("clock", Stanford.statusInfo)
        default:
            return ("circle", Color.secondary)
        }
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(Stanford.heading(20))
                .foregroundStyle(color)
            Text(value)
                .font(Stanford.heading(18))
                .monospacedDigit()
            Text(title)
                .font(Stanford.caption())
                .foregroundStyle(Stanford.coolGrey)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Stanford.fog)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Stanford.sandstone.opacity(0.3), lineWidth: 1)
        )
    }
}

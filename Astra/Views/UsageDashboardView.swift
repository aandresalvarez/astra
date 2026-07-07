import SwiftUI
import SwiftData
import ASTRAModels
import ASTRAPersistence
import ASTRACore

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
/// how long the *caller* should wait before re-querying to pick up any
/// value-only change — e.g. `tokensUsed`, `costUSD`, or `status` — that landed
/// since the cache was populated. `nil` when this call recomputed fresh (nothing
/// to follow up on yet); a positive interval when serving an already-cached
/// value that's still inside the throttle window.
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
/// fields the cache keys on) stale with nothing to force a follow-up. `query(...)`
/// reports the staleness signal directly so every caller that observes a
/// cache-hit-inside-the-window can schedule its own re-query.
///
/// This memo is a process-wide singleton (`UsageDashboardView.summaryMemo`) shared
/// by every open dashboard instance, but each caller's returned delay is only ever
/// acted on by *that specific caller* — this used to be deduplicated with a
/// `followUpScheduled` flag so only the first caller in a window got a non-nil
/// delay, but that dedup was itself a bug: the flag has no idea whether the
/// caller that "claimed" a follow-up is still around to act on it. If that
/// dashboard window closes before its delayed re-query fires, every other
/// (still-open) window's caller also sees `followUpScheduled == true` and gets
/// `nil`, so nothing ever refreshes them — stale indefinitely. Reporting a delay
/// to every eligible caller instead means multiple open windows each schedule
/// their own follow-up; only the first to fire pays the actual rebuild cost
/// (`inputsUnchanged` + elapsed check below still caps that to once per window),
/// the rest just read the by-then-fresh cache.
final class UsageDashboardSummaryMemo: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: UsageDashboardSummary?
    private var cachedFilter: TimeFilter?
    private var cachedTaskCount = -1
    private var cachedRunCount = -1
    private var lastComputedAt = Date.distantPast
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
                return UsageDashboardSummaryQuery(summary: cached, staleRefreshDelay: remaining)
            }
        }
        let summary = UsageDashboardSummary.build(tasks: tasks, runs: runs, timeFilter: timeFilter)
        cached = summary
        cachedFilter = timeFilter
        cachedTaskCount = tasks.count
        cachedRunCount = runs.count
        lastComputedAt = now
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
        // Keyed on whether a follow-up is pending (not on `staleRefreshDelay`
        // itself, whose exact TimeInterval value differs on every call, which
        // would restart this task on every render instead of only at genuine
        // pending/not-pending transitions). Since the memo no longer dedupes
        // across callers (see `UsageDashboardSummaryMemo`'s doc comment), every
        // render within a stale window reports a non-nil delay, so this id
        // stays `true` continuously for the window's duration — `.task(id:)`
        // only restarts on an actual id *change*, so the sleep scheduled by the
        // first `true` render simply keeps running through the later ones,
        // waking at `lastComputedAt + minimumInterval` regardless of which
        // call's `remaining` estimate it happened to capture (they all target
        // the same instant, since `lastComputedAt` doesn't move until an
        // actual recompute happens). `.task(id:)` also fires for the *initial*
        // id value, so this catches a delay already present on the very first
        // query (e.g. the dashboard reopened while the memo's cache entry is
        // still inside its window) without needing a separate check.
        .task(id: query.staleRefreshDelay != nil) {
            guard let delay = query.staleRefreshDelay else { return }
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

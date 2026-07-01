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
/// This throttle alone can serve a value-only change (tokensUsed/costUSD/status
/// landing inside the window) stale with nothing to force a follow-up — task/run
/// counts and the filter don't capture every field the summary reads. An earlier
/// version tried to have the memo self-report "you got a stale value, wait this
/// long and re-query" back to the caller, but that signal is ambiguous: the memo
/// can't tell "this caller is re-checking a value that was already scheduled for
/// refresh" from "this caller is a genuinely new request that happens to still be
/// within the window" — both look identical (same inputs, recent
/// `lastComputedAt`). Rather than chase that ambiguity, `UsageDashboardView`
/// instead polls at a fixed cadence while anything is live (see
/// `TaskLiveness.isLive`, `TaskThreadChangeObserver` for the same pattern applied
/// to the task thread) so this memo just needs to be a plain, unconditional
/// throttle — eventual consistency comes from the polling cadence, not from this
/// class trying to self-report staleness.
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

    func summary(tasks: [AgentTask], runs: [TaskRun], timeFilter: TimeFilter) -> UsageDashboardSummary {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        let inputsUnchanged = cachedFilter == timeFilter
            && cachedTaskCount == tasks.count
            && cachedRunCount == runs.count
        if let cached, inputsUnchanged, now.timeIntervalSince(lastComputedAt) < minimumInterval {
            return cached
        }
        let summary = UsageDashboardSummary.build(tasks: tasks, runs: runs, timeFilter: timeFilter)
        cached = summary
        cachedFilter = timeFilter
        cachedTaskCount = tasks.count
        cachedRunCount = runs.count
        lastComputedAt = now
        return summary
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
    private static let livePollIntervalNanoseconds: UInt64 = 1_000_000_000

    @Query private var tasks: [AgentTask]
    @Query private var runs: [TaskRun]
    @State private var timeFilter: TimeFilter = .allTime
    @State private var renderTick = 0

    private var usageSummary: UsageDashboardSummary {
        Self.summaryMemo.summary(tasks: tasks, runs: runs, timeFilter: timeFilter)
    }

    /// Cheap (O(task count), no event scanning) check for whether anything in
    /// the workspace could still be producing dashboard-relevant updates.
    private var hasLiveActivity: Bool {
        tasks.contains { TaskLiveness.isLive(task: $0) }
    }

    static func resetSummaryCacheForTesting() {
        summaryMemo.resetForTesting()
    }

    var body: some View {
        // Dependency read: bumping renderTick from pollWhileLive() forces this body to re-evaluate.
        let _ = renderTick
        let summary = usageSummary

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
        .task(id: hasLiveActivity) {
            guard hasLiveActivity else { return }
            await pollWhileLive()
        }
        .onChange(of: hasLiveActivity) { wasLive, isLiveNow in
            guard wasLive, !isLiveNow else { return }
            scheduleFinalCatchUpRefresh()
        }
    }

    /// While anything in the workspace is live, periodically forces a fresh
    /// render so `usageSummary` re-queries the memo — value-only changes
    /// (tokensUsed/costUSD/status) that land inside the throttle window get
    /// picked up on the next tick instead of staying stale indefinitely.
    /// Bounded to zero cost when idle: this loop only runs while
    /// `hasLiveActivity` is true, and `.task(id:)` doesn't restart it otherwise.
    @MainActor
    private func pollWhileLive() async {
        while hasLiveActivity, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: Self.livePollIntervalNanoseconds)
            guard !Task.isCancelled else { return }
            renderTick += 1
        }
    }

    /// `pollWhileLive()` is cancelled the instant `hasLiveActivity` flips false
    /// (SwiftUI restarts `.task(id:)` for the new id), which can land mid-sleep
    /// and swallow the one tick that would have caught a value-only change
    /// landing inside the memo's throttle window right before things went
    /// idle. Scheduled independently of `.task(id:)`'s lifecycle (a plain
    /// detached `Task`, not tied to the modifier that just got cancelled) and
    /// waited out for a full `livePollIntervalNanoseconds` — the same duration
    /// as the memo's throttle window — so by the time it fires, that window has
    /// definitely elapsed and the resulting recompute is guaranteed fresh
    /// rather than served from the same possibly-stale cache entry.
    private func scheduleFinalCatchUpRefresh() {
        Task {
            try? await Task.sleep(nanoseconds: Self.livePollIntervalNanoseconds)
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

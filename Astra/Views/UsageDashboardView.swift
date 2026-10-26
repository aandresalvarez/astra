import SwiftUI
import SwiftData
import ASTRAModels
import ASTRACore

struct UsageDashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var store = UsageDashboardStore()
    @State private var timeFilter: TimeFilter = .allTime

    var body: some View {
        ZStack {
            if let error = store.errorMessage {
                ContentUnavailableView {
                    Label("Usage unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { store.refresh() }
                }
            } else if let summary = store.summary {
                UsageDashboardContent(summary: summary, timeFilter: $timeFilter) { task in
                    UsageDashboardTaskRow(task: task)
                }
            } else {
                ProgressView("Loading usage…")
            }
        }
        .task(id: timeFilter) { store.start(container: modelContext.container, timeFilter: timeFilter) }
        .onChange(of: modelContext) { store.start(container: modelContext.container, timeFilter: timeFilter) }
        .onDisappear { store.stop() }
    }
}

/// Totals remain visible while the native fixed-height table scrolls the
/// archive. Neither managed models nor self-sizing history enter the graph.
struct UsageDashboardContent<Row: View>: View {
    let summary: UsageDashboardSummary
    @Binding var timeFilter: TimeFilter
    let row: (UsageDashboardSummary.TaskRow) -> Row

    var body: some View {
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

                UsageDashboardTaskTable(tasks: summary.tasks, rowHeight: 52 * Stanford.uiScale, row: row)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding()
    }
}

private struct UsageDashboardTaskRow: View {
    let task: UsageDashboardSummary.TaskRow

    var body: some View {
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

            if task.requestUsageReconciliationPending {
                Text("Usage unconfirmed")
                    .font(Stanford.caption())
                    .help("Earlier usage is estimated. These totals remain approximate; the execution allowance stays protected.")
            } else {
                ProgressView(value: min(task.budgetProgress, 1.0))
                    .frame(width: 60)
                    .tint(task.budgetProgress > 0.9 ? Stanford.failed : Stanford.coolGrey)
                    .help("Latest request budget; retries share the same allowance")
            }
        }
        .padding(.vertical, 4)
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
                .stroke(Stanford.borderRest, lineWidth: 1)
        )
    }
}

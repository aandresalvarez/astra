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

struct UsageDashboardView: View {
    @Query private var tasks: [AgentTask]
    @Query private var runs: [TaskRun]
    @State private var timeFilter: TimeFilter = .allTime

    private var filteredTasks: [AgentTask] {
        guard let cutoff = timeFilter.cutoff else { return tasks }
        return tasks.filter { $0.createdAt >= cutoff }
    }

    var totalTokens: Int {
        filteredTasks.reduce(0) { $0 + $1.tokensUsed }
    }

    var totalCost: Double {
        filteredTasks.reduce(0) { $0 + $1.costUSD }
    }

    var completedCount: Int {
        filteredTasks.filter { $0.status == .completed }.count
    }

    var failedCount: Int {
        filteredTasks.filter { $0.status == .failed || $0.status == .budgetExceeded }.count
    }

    var totalRuns: Int {
        guard let cutoff = timeFilter.cutoff else { return runs.count }
        return runs.filter { $0.startedAt >= cutoff }.count
    }

    var body: some View {
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
                    StatCard(title: "Total Tasks", value: "\(filteredTasks.count)", icon: "list.bullet", color: Stanford.lagunita)
                    StatCard(title: "Completed", value: "\(completedCount)", icon: "checkmark.circle", color: Stanford.paloAltoGreen)
                    StatCard(title: "Failed", value: "\(failedCount)", icon: "xmark.circle", color: Stanford.cardinalRed)
                    StatCard(title: "Total Runs", value: "\(totalRuns)", icon: "arrow.triangle.2.circlepath", color: Stanford.driftwood)
                }

                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 12) {
                    StatCard(title: "Total Tokens", value: Formatters.formatTokens(totalTokens), icon: "number", color: Stanford.poppy)
                    StatCard(title: "Total Cost", value: String(format: "$%.2f", totalCost), icon: "dollarsign.circle", color: Stanford.sky)
                }

                // Per-task breakdown
                if !filteredTasks.isEmpty {
                    Text("Per-Task Breakdown")
                        .font(Stanford.heading(16))
                        .foregroundStyle(Stanford.black)
                        .padding(.top, 8)

                    ForEach(filteredTasks.sorted(by: { $0.createdAt > $1.createdAt })) { task in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.title)
                                    .font(Stanford.body())
                                    .lineLimit(1)
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
                                .tint(task.budgetProgress > 0.9 ? Stanford.cardinalRed : Stanford.lagunita)
                        }
                        .padding(.vertical, 4)
                        Divider()
                    }
                }
            }
            .padding()
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

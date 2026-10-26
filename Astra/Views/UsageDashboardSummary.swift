import Foundation
import SwiftData
import ASTRAModels

enum TimeFilter: String, CaseIterable, Sendable {
    case allTime = "All Time"
    case last7Days = "7 Days"
    case today = "Today"

    func cutoff(now: Date) -> Date? {
        switch self {
        case .allTime: nil
        case .last7Days: Calendar.current.date(byAdding: .day, value: -7, to: now)
        case .today: Calendar.current.startOfDay(for: now)
        }
    }
}

/// Values crossing the reader boundary contain neither live SwiftData models
/// nor run output. The persistent models remain the only domain owners.
struct UsageDashboardSummary: Sendable, Equatable {
    struct TaskRow: Identifiable, Sendable, Equatable {
        let id: UUID
        let title: String
        let status: TaskStatus
        let tokensUsed: Int
        let costUSD: Double
        let budgetProgress: Double
        var requestUsageReconciliationPending: Bool = false
    }

    let tasks: [TaskRow]
    let totalTokens: Int
    let totalCost: Double
    let completedCount: Int
    let failedCount: Int
    let totalRuns: Int

    static func read(context: ModelContext, timeFilter: TimeFilter, now: Date = Date()) throws -> Self {
        let cutoff = timeFilter.cutoff(now: now)
        var tasks = FetchDescriptor<AgentTask>(sortBy: [SortDescriptor(\AgentTask.createdAt, order: .reverse)])
        var runs = FetchDescriptor<TaskRun>()
        if let cutoff {
            tasks.predicate = #Predicate { $0.createdAt >= cutoff }
            runs.predicate = #Predicate { $0.startedAt >= cutoff }
        }
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            PerformanceTelemetry.logIfNeeded("usage_summary_build", start: start, thresholdMilliseconds: 15,
                fields: ["filter": timeFilter.rawValue.replacingOccurrences(of: " ", with: "_"), "isolation": "background"])
        }
        let rows = try context.fetch(tasks).map { task in
            let budget = task.latestRequestBudget
            return TaskRow(id: task.id, title: task.title, status: task.status, tokensUsed: task.tokensUsed,
                    costUSD: task.costUSD, budgetProgress: budget?.progress ?? task.budgetProgress,
                    requestUsageReconciliationPending: budget?.reconciliationPending ?? false)
        }
        return Self(tasks: rows, totalTokens: rows.reduce(0) { $0 + $1.tokensUsed },
                    totalCost: rows.reduce(0) { $0 + $1.costUSD },
                    completedCount: rows.filter { $0.status == .completed }.count,
                    failedCount: rows.filter { $0.status == .failed || $0.status == .budgetExceeded }.count,
                    totalRuns: try context.fetchCount(runs))
    }
}

/// A fresh context per read avoids stale values after saves from other
/// contexts. No managed object survives the read or crosses an actor boundary.
actor UsageDashboardReader {
    let container: ModelContainer

    init(container: ModelContainer) { self.container = container }

    func read(timeFilter: TimeFilter) throws -> UsageDashboardSummary {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return try UsageDashboardSummary.read(context: context, timeFilter: timeFilter)
    }
}

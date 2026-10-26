import Foundation
import SwiftData
import ASTRAModels

/// Retains provider billing/timing without inventing a measured token count.
enum AgentUsageMetadataRecorder {
    @MainActor
    static func record(cost: Double?, duration: Int?, turns: Int?, task: AgentTask,
                       run: TaskRun, context: ModelContext, mode: AgentRuntimeRecordingMode) {
        if let cost, cost.isFinite, cost >= 0 {
            let baseline = ProviderSessionUsageEpoch.baseline(for: run, in: task)
            let share = max(0, cost - baseline.cost)
            if mode == .initial { task.costUSD = max(task.costUSD, share) }
            else { task.costUSD += max(0, share - run.costUSD) }
            run.costUSD = max(run.costUSD, share)
        }
        let details = [cost.map { String(format: "cost: $%.4f", $0) },
                       duration.map { "duration: \($0)ms" }, turns.map { "turns: \($0)" }]
            .compactMap { $0 }.joined(separator: " | ")
        guard !details.isEmpty else { return }
        context.insert(TaskEvent(task: task, eventType: TaskEventTypes.Task.stats,
            payload: "provider metadata: " + details, run: run))
    }
}

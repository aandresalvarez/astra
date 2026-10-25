import Foundation
import SwiftData
import ASTRAModels

enum RuntimeSupervisionUsageRecorder {
    @MainActor static func record(_ reservation: Int, task: AgentTask, run: TaskRun, modelContext: ModelContext) {
        guard reservation > 0,
              !task.events.contains(where: { $0.run?.id == run.id && $0.type == TaskEventTypes.System.runtimeSupervisionUsage.rawValue }) else { return }
        // Utility providers do not all report billable usage. Charge the bounded
        // allocation conservatively and label it explicitly, never as exact usage.
        run.tokensUsed = RuntimeUsageArithmetic.adding(run.tokensUsed, reservation)
        task.tokensUsed = RuntimeUsageArithmetic.adding(task.tokensUsed, reservation)
        modelContext.insert(TaskEvent(task: task, eventType: TaskEventTypes.System.runtimeSupervisionUsage,
            payload: "{\"estimatedTokenAllocation\":\(reservation),\"exactBillableUsageAvailable\":false}", run: run))
    }
}

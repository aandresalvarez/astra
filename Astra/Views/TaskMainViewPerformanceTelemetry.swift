import Foundation
import SwiftData
import ASTRAModels

/// Why a plan-state read was attempted. Recorded so log review can tell an
/// exact, event-driven refresh apart from the run-output recovery fallback.
enum TaskPlanStateRefreshReason: String {
    /// Task opened, or the view switched to a different task.
    case taskOpen = "task_open"
    /// A durable plan-relevant event landed, or the task status changed.
    case planEvent = "plan_event"
    /// A thread snapshot changed, so run-output protocol progress may need
    /// re-applying. Only reached while a plan already exists.
    case recoveredProgress = "recovered_progress"
}

enum TaskMainViewPerformanceTelemetry {
    @MainActor
    static func refreshedPlanStateSnapshot(
        task: AgentTask,
        modelContext: ModelContext,
        cached: TaskPlanStateSnapshot,
        reason: TaskPlanStateRefreshReason
    ) -> TaskPlanStateSnapshot? {
        PerformanceTelemetry.measure(
            "plan_state_refresh",
            thresholdMilliseconds: PerformanceTelemetry.uiFrameThresholdMilliseconds,
            fields: planStateFields(task: task, reason: reason),
            resultFields: { snapshot in
                [
                    "refreshed": PerformanceTelemetryFields.bool(snapshot != nil)
                ]
            }
        ) {
            do {
                return try TaskPlanStateSnapshot.refreshed(
                    for: task,
                    modelContext: modelContext,
                    cached: cached
                )
            } catch {
                AppLogger.error(
                    "Could not refresh task plan state: \(error.localizedDescription)",
                    category: "UI"
                )
                return nil
            }
        }
    }

    private static func planStateFields(
        task: AgentTask,
        reason: TaskPlanStateRefreshReason
    ) -> [String: String] {
        return [
            "task_id": PerformanceTelemetryFields.abbreviatedID(task.id),
            "status": task.status.rawValue,
            "reason": reason.rawValue
        ]
    }
}

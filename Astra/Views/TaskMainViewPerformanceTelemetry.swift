import Foundation
import SwiftData
import ASTRAModels

enum TaskMainViewPerformanceTelemetry {
    @MainActor
    static func refreshedPlanStateSnapshot(
        task: AgentTask,
        modelContext: ModelContext,
        cached: TaskPlanStateSnapshot
    ) -> TaskPlanStateSnapshot? {
        PerformanceTelemetry.measure(
            "plan_state_refresh",
            thresholdMilliseconds: PerformanceTelemetry.uiFrameThresholdMilliseconds,
            fields: planStateFields(task: task),
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

    private static func planStateFields(task: AgentTask) -> [String: String] {
        return [
            "task_id": PerformanceTelemetryFields.abbreviatedID(task.id),
            "status": task.status.rawValue
        ]
    }
}

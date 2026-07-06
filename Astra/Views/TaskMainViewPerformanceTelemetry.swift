import Foundation
import ASTRAModels

enum TaskMainViewPerformanceTelemetry {
    static func chatOpenFields(task: AgentTask, source: String) -> [String: String] {
        let latestRun = task.runs.max { $0.startedAt < $1.startedAt }
        let latestOutputChars = latestRun?.output.utf8.count ?? 0
        return [
            "source": source,
            "task_id": PerformanceTelemetryFields.abbreviatedID(task.id),
            "workspace_id": PerformanceTelemetryFields.abbreviatedID(task.workspace?.id),
            "status": task.status.rawValue,
            "event_count": PerformanceTelemetryFields.count(task.events.count),
            "run_count": PerformanceTelemetryFields.count(task.runs.count),
            "latest_run_output_chars": PerformanceTelemetryFields.count(latestOutputChars),
            "latest_run_output_bucket": PerformanceTelemetryFields.byteBucket(latestOutputChars)
        ]
    }

    static func refreshedPlanStateSnapshot(
        task: AgentTask,
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
            TaskPlanStateSnapshot.refreshed(for: task, cached: cached)
        }
    }

    private static func planStateFields(task: AgentTask) -> [String: String] {
        let maxRunOutputChars = task.runs.reduce(0) { max($0, $1.output.utf8.count) }
        let planEventCount = task.events.reduce(0) { count, event in
            TaskPlanService.stateMutationCode(for: event.type) == nil ? count : count + 1
        }
        return [
            "task_id": PerformanceTelemetryFields.abbreviatedID(task.id),
            "event_count": PerformanceTelemetryFields.count(task.events.count),
            "run_count": PerformanceTelemetryFields.count(task.runs.count),
            "plan_event_count": PerformanceTelemetryFields.count(planEventCount),
            "max_run_output_bucket": PerformanceTelemetryFields.byteBucket(maxRunOutputChars)
        ]
    }
}

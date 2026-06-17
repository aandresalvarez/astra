import Foundation
import SwiftData

@MainActor
enum StoreScalePerformanceSnapshot {
    static func fields(modelContext: ModelContext) -> [String: String] {
        do {
            return try buildFields(modelContext: modelContext)
        } catch {
            return [
                "error_type": String(describing: type(of: error))
            ]
        }
    }

    static func log(modelContext: ModelContext) {
        PerformanceTelemetry.measure(
            "store_scale_snapshot",
            thresholdMilliseconds: 0,
            level: .info,
            resultFields: { $0 }
        ) {
            fields(modelContext: modelContext)
        }
    }

    private static func buildFields(modelContext: ModelContext) throws -> [String: String] {
        let workspaceCount = try count(Workspace.self, modelContext: modelContext)
        let taskCount = try count(AgentTask.self, modelContext: modelContext)
        let runCount = try count(TaskRun.self, modelContext: modelContext)
        let eventCount = try count(TaskEvent.self, modelContext: modelContext)
        let artifactCount = try count(Artifact.self, modelContext: modelContext)

        let events = try modelContext.fetch(FetchDescriptor<TaskEvent>())
        let runs = try modelContext.fetch(FetchDescriptor<TaskRun>())

        var eventsByTaskID: [UUID: Int] = [:]
        for event in events {
            guard let taskID = event.task?.id else { continue }
            eventsByTaskID[taskID, default: 0] += 1
        }

        var runsByTaskID: [UUID: Int] = [:]
        var maxRunOutputChars = 0
        var runOutputSizes: [Int] = []
        for run in runs {
            if let taskID = run.task?.id {
                runsByTaskID[taskID, default: 0] += 1
            }
            let outputSize = run.output.utf8.count
            runOutputSizes.append(outputSize)
            maxRunOutputChars = max(maxRunOutputChars, outputSize)
        }

        return [
            "workspace_count": PerformanceTelemetryFields.count(workspaceCount),
            "task_count": PerformanceTelemetryFields.count(taskCount),
            "run_count": PerformanceTelemetryFields.count(runCount),
            "event_count": PerformanceTelemetryFields.count(eventCount),
            "artifact_count": PerformanceTelemetryFields.count(artifactCount),
            "max_events_per_task": PerformanceTelemetryFields.count(eventsByTaskID.values.max() ?? 0),
            "max_runs_per_task": PerformanceTelemetryFields.count(runsByTaskID.values.max() ?? 0),
            "p95_events_per_task": PerformanceTelemetryFields.count(percentile(Array(eventsByTaskID.values), percentile: 0.95)),
            "p95_runs_per_task": PerformanceTelemetryFields.count(percentile(Array(runsByTaskID.values), percentile: 0.95)),
            "max_run_output_chars": PerformanceTelemetryFields.count(maxRunOutputChars),
            "max_run_output_bucket": PerformanceTelemetryFields.byteBucket(maxRunOutputChars),
            "p50_run_output_bucket": PerformanceTelemetryFields.byteBucket(percentile(runOutputSizes, percentile: 0.50)),
            "p95_run_output_bucket": PerformanceTelemetryFields.byteBucket(percentile(runOutputSizes, percentile: 0.95)),
            "event_count_bucket": PerformanceTelemetryFields.countBucket(eventCount),
            "run_count_bucket": PerformanceTelemetryFields.countBucket(runCount),
            "task_count_bucket": PerformanceTelemetryFields.countBucket(taskCount)
        ]
    }

    private static func percentile(_ values: [Int], percentile: Double) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let clamped = min(max(percentile, 0), 1)
        let index = Int((Double(sorted.count - 1) * clamped).rounded(.up))
        return sorted[index]
    }

    private static func count<T: PersistentModel>(
        _ type: T.Type,
        modelContext: ModelContext
    ) throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<T>())
    }
}

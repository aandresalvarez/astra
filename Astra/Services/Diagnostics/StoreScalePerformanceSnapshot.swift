import Foundation
import SwiftData

@MainActor
enum StoreScalePerformanceSnapshot {
    private static let detailedFetchLimit = 10_000

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

    static func shouldBuildDetailedFields(eventCount: Int, runCount: Int) -> Bool {
        eventCount < detailedFetchLimit && runCount < detailedFetchLimit
    }

    private static func buildFields(modelContext: ModelContext) throws -> [String: String] {
        let workspaceCount = try count(Workspace.self, modelContext: modelContext)
        let taskCount = try count(AgentTask.self, modelContext: modelContext)
        let runCount = try count(TaskRun.self, modelContext: modelContext)
        let eventCount = try count(TaskEvent.self, modelContext: modelContext)
        let artifactCount = try count(Artifact.self, modelContext: modelContext)
        var fields = [
            "workspace_count": PerformanceTelemetryFields.count(workspaceCount),
            "task_count": PerformanceTelemetryFields.count(taskCount),
            "run_count": PerformanceTelemetryFields.count(runCount),
            "event_count": PerformanceTelemetryFields.count(eventCount),
            "artifact_count": PerformanceTelemetryFields.count(artifactCount),
            "event_count_bucket": PerformanceTelemetryFields.countBucket(eventCount),
            "run_count_bucket": PerformanceTelemetryFields.countBucket(runCount),
            "task_count_bucket": PerformanceTelemetryFields.countBucket(taskCount)
        ]

        guard shouldBuildDetailedFields(eventCount: eventCount, runCount: runCount) else {
            fields["details_skipped"] = "large_store"
            return fields
        }

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

        fields["max_events_per_task"] = PerformanceTelemetryFields.count(eventsByTaskID.values.max() ?? 0)
        fields["max_runs_per_task"] = PerformanceTelemetryFields.count(runsByTaskID.values.max() ?? 0)
        fields["p95_events_per_task"] = PerformanceTelemetryFields.count(percentile(Array(eventsByTaskID.values), percentile: 0.95))
        fields["p95_runs_per_task"] = PerformanceTelemetryFields.count(percentile(Array(runsByTaskID.values), percentile: 0.95))
        fields["max_run_output_chars"] = PerformanceTelemetryFields.count(maxRunOutputChars)
        fields["max_run_output_bucket"] = PerformanceTelemetryFields.byteBucket(maxRunOutputChars)
        fields["p50_run_output_bucket"] = PerformanceTelemetryFields.byteBucket(percentile(runOutputSizes, percentile: 0.50))
        fields["p95_run_output_bucket"] = PerformanceTelemetryFields.byteBucket(percentile(runOutputSizes, percentile: 0.95))
        return fields
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

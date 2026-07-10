import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA

private func makePerformanceTelemetryContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

@Suite("Performance telemetry")
@MainActor
struct PerformanceTelemetryTests {
    @Test("Telemetry field helpers sanitize values and bucket counts")
    func fieldHelpersSanitizeAndBucketValues() {
        let id = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")

        #expect(PerformanceTelemetryFields.abbreviatedID(id) == "01234567")
        #expect(PerformanceTelemetryFields.abbreviatedID("abcdef1234567890") == "abcdef12")
        #expect(PerformanceTelemetryFields.abbreviatedID(nil as UUID?) == "none")
        #expect(PerformanceTelemetryFields.bool(true) == "true")
        #expect(PerformanceTelemetryFields.bool(false) == "false")

        #expect(PerformanceTelemetryFields.byteBucket(0) == "0")
        #expect(PerformanceTelemetryFields.byteBucket(512) == "1b_1kb")
        #expect(PerformanceTelemetryFields.byteBucket(2_048) == "1kb_10kb")
        #expect(PerformanceTelemetryFields.byteBucket(50_000) == "10kb_100kb")
        #expect(PerformanceTelemetryFields.byteBucket(500_000) == "100kb_1mb")
        #expect(PerformanceTelemetryFields.byteBucket(2_000_000) == "1mb_plus")

        #expect(PerformanceTelemetryFields.countBucket(0) == "0")
        #expect(PerformanceTelemetryFields.countBucket(9) == "1_9")
        #expect(PerformanceTelemetryFields.countBucket(49) == "10_49")
        #expect(PerformanceTelemetryFields.countBucket(199) == "50_199")
        #expect(PerformanceTelemetryFields.countBucket(999) == "200_999")
        #expect(PerformanceTelemetryFields.countBucket(1_000) == "1000_plus")

        let sanitized = PerformanceTelemetryFields.safeValue("  hello world=secret\nvalue  ")
        #expect(sanitized == "hello_world_secret_value")
        #expect(!sanitized.contains(" "))
        #expect(!sanitized.contains("="))

        let truncated = PerformanceTelemetryFields.safeValue(String(repeating: "x", count: 20), maxLength: 10)
        #expect(truncated == "xxxxxxxxxx")
    }

    @Test("Store scale snapshot reports counts and buckets without content fields")
    func storeScaleSnapshotReportsCountsAndBucketsWithoutContentFields() throws {
        let container = try makePerformanceTelemetryContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Secret Workspace", primaryPath: "/private/path/should/not/log")
        let firstTask = AgentTask(title: "Secret Title", goal: "Secret Goal", workspace: workspace)
        let secondTask = AgentTask(title: "Other Secret", goal: "Other Goal", workspace: workspace)
        context.insert(workspace)
        context.insert(firstTask)
        context.insert(secondTask)

        let firstRun = TaskRun(task: firstTask)
        firstRun.output = String(repeating: "x", count: 512)
        let secondRun = TaskRun(task: firstTask)
        secondRun.output = String(repeating: "y", count: 2_048)
        context.insert(firstRun)
        context.insert(secondRun)

        context.insert(TaskEvent(task: firstTask, type: "agent.response", payload: "secret payload", run: firstRun))
        context.insert(TaskEvent(task: firstTask, type: "tool.result", payload: "secret payload", run: firstRun))
        context.insert(TaskEvent(task: secondTask, type: "user.message", payload: "secret payload"))
        context.insert(Artifact(task: firstTask, type: "markdown", path: "/private/path/should/not/log/report.md"))

        try context.save()

        let fields = StoreScalePerformanceSnapshot.fields(modelContext: context)

        #expect(fields["workspace_count"] == "1")
        #expect(fields["task_count"] == "2")
        #expect(fields["run_count"] == "2")
        #expect(fields["event_count"] == "3")
        #expect(fields["artifact_count"] == "1")
        #expect(fields["max_events_per_task"] == "2")
        #expect(fields["max_runs_per_task"] == "2")
        #expect(fields["max_run_output_bytes"] == "2048")
        #expect(fields["max_run_output_bucket"] == "1kb_10kb")
        #expect(fields["p95_events_per_task"] == "2")
        #expect(fields["p95_runs_per_task"] == "2")

        let forbiddenKeys = ["title", "goal", "payload", "path", "content"]
        for key in forbiddenKeys {
            #expect(fields[key] == nil)
        }

        let joinedValues = fields.values.joined(separator: " ")
        #expect(!joinedValues.contains("Secret"))
        #expect(!joinedValues.contains("/private/path"))
        #expect(!joinedValues.contains("payload"))
    }

    @Test("Store scale snapshot skips detailed fetches for large stores")
    func storeScaleSnapshotSkipsDetailedFetchesForLargeStores() {
        #expect(StoreScalePerformanceSnapshot.shouldBuildDetailedFields(eventCount: 9_999, runCount: 9_999))
        #expect(!StoreScalePerformanceSnapshot.shouldBuildDetailedFields(eventCount: 10_000, runCount: 0))
        #expect(!StoreScalePerformanceSnapshot.shouldBuildDetailedFields(eventCount: 0, runCount: 10_000))
    }

    @Test("Startup store snapshot defers detailed event and run scans")
    func startupStoreSnapshotDefersDetailedScans() throws {
        let container = try makePerformanceTelemetryContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Workspace", primaryPath: "/tmp/workspace")
        let task = AgentTask(title: "Task", goal: "Goal", workspace: workspace)
        context.insert(workspace)
        context.insert(task)
        context.insert(TaskRun(task: task))
        context.insert(TaskEvent(task: task, type: "agent.response", payload: "ignored"))
        try context.save()

        let fields = StoreScalePerformanceSnapshot.fields(
            modelContext: context,
            includeDetailedFields: false
        )

        #expect(fields["workspace_count"] == "1")
        #expect(fields["task_count"] == "1")
        #expect(fields["run_count"] == "1")
        #expect(fields["event_count"] == "1")
        #expect(fields["details_skipped"] == "deferred_from_startup")
        #expect(fields["max_events_per_task"] == nil)
        #expect(fields["max_run_output_bytes"] == nil)
    }
}

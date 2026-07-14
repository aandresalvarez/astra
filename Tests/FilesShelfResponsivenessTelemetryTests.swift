import Foundation
import Testing
@testable import ASTRA

@Suite("Files shelf responsiveness telemetry", .serialized)
struct FilesShelfResponsivenessTelemetryTests {
    @Test("Milestone result contains only safe correlation and scale fields")
    func milestoneResultIsPrivacySafe() {
        let taskID = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
        let workspaceID = UUID(uuidString: "ABCDEF01-2345-6789-ABCD-EF0123456789")!
        let trace = FilesShelfResponsivenessTrace(
            traceID: "files-shelf-01234567",
            source: "shelf_action",
            taskID: taskID,
            workspaceID: workspaceID,
            startedAtUptimeNanoseconds: 10_000_000
        )

        let result = trace.result(
            event: "files_shelf_to_first_results",
            at: 85_000_000,
            fields: ["scope": "task", "node_count_bucket": "200_999"]
        )

        #expect(result.durationMilliseconds == 75)
        #expect(result.fields["task_id"] == "01234567")
        #expect(result.fields["workspace_id"] == "ABCDEF01")
        #expect(result.fields["scope"] == "task")
        for forbidden in ["path", "title", "content", "name"] {
            #expect(result.fields[forbidden] == nil)
        }
    }

    @MainActor
    @Test("Chrome first-results and index-ready milestones log once per trace")
    func lifecycleLogsEachMilestoneOnce() {
        let taskID = UUID()
        let scope = UUID()
        AppLogger.resetForTesting()
        FilesShelfResponsivenessTelemetry.resetForTesting()
        FilesShelfResponsivenessTelemetry.begin(
            source: "shelf_action",
            taskID: taskID,
            workspaceID: UUID(),
            scope: scope
        )

        FilesShelfResponsivenessTelemetry.chromeReady(scope: scope)
        FilesShelfResponsivenessTelemetry.chromeReady(scope: scope)
        FilesShelfResponsivenessTelemetry.firstResultsReady(
            scope: scope,
            fileScope: "task",
            cacheState: "hit",
            rootCount: 2,
            nodeCount: 25
        )
        FilesShelfResponsivenessTelemetry.firstResultsReady(
            scope: scope,
            fileScope: "task",
            cacheState: "refresh",
            rootCount: 2,
            nodeCount: 26
        )
        FilesShelfResponsivenessTelemetry.indexReady(
            scope: scope,
            fileScope: "task",
            cacheState: "refresh",
            rootCount: 2,
            nodeCount: 26,
            errorCount: 0,
            isTruncated: false
        )
        AppLogger.flushForTesting()

        let messages = AppLogger.entries
            .filter { $0.category == "Performance" && $0.taskID == taskID }
            .map(\.message)
        #expect(messages.filter { $0.contains("event=files_shelf_to_chrome_ready") }.count == 1)
        #expect(messages.filter { $0.contains("event=files_shelf_to_first_results") }.count == 1)
        #expect(messages.filter { $0.contains("event=files_shelf_to_index_ready") }.count == 1)
        #expect(messages.contains { $0.contains("cache_state=hit") })
        #expect(messages.contains { $0.contains("node_count=26") })
        FilesShelfResponsivenessTelemetry.resetForTesting()
    }

    @Test("Files shelf samples participate in responsiveness diagnostics")
    func diagnosticsIncludeFilesShelfSamples() {
        let report = UIResponsivenessDiagnostics.makeReport(entries: [
            LogEntry(
                level: .warning,
                category: "Performance",
                message: "event=files_shelf_to_index_ready duration_ms=1200.00 cache_state=miss scope=task task_id=01234567 trace_id=files-shelf-safe"
            )
        ])

        #expect(report.eventSummaries.map(\.event) == ["files_shelf_to_index_ready"])
        #expect(report.eventSummaries.first?.cacheStates == ["miss": 1])
        #expect(report.slowestTraces.first?.traceID == "files-shelf-safe")
    }
}

import Foundation
import Testing
import ASTRAPersistence
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

    @MainActor
    @Test("An empty fast index does not discard the later chrome milestone")
    func indexReadyBeforeChromeKeepsTraceUntilChrome() {
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

        FilesShelfResponsivenessTelemetry.indexReady(
            scope: scope,
            fileScope: "task",
            cacheState: "not_applicable",
            rootCount: 0,
            nodeCount: 0,
            errorCount: 0,
            isTruncated: false
        )
        FilesShelfResponsivenessTelemetry.chromeReady(scope: scope)
        AppLogger.flushForTesting()

        let messages = AppLogger.entries
            .filter { $0.category == "Performance" && $0.taskID == taskID }
            .map(\.message)
        #expect(messages.filter { $0.contains("event=files_shelf_to_index_ready") }.count == 1)
        #expect(messages.filter { $0.contains("event=files_shelf_to_chrome_ready") }.count == 1)
        #expect(!messages.contains { $0.contains("event=files_shelf_cancelled") })
        FilesShelfResponsivenessTelemetry.resetForTesting()
    }

    @MainActor
    @Test("An in-place index refresh does not start a new presentation trace")
    func refreshDoesNotRestartCompletedPresentationTrace() {
        let taskID = UUID()
        let scope = UUID()
        FilesShelfResponsivenessTelemetry.resetForTesting()
        FilesShelfResponsivenessTelemetry.begin(
            source: "shelf_action",
            taskID: taskID,
            workspaceID: UUID(),
            scope: scope
        )
        FilesShelfResponsivenessTelemetry.chromeReady(scope: scope)
        FilesShelfResponsivenessTelemetry.indexReady(
            scope: scope,
            fileScope: "task",
            cacheState: "not_applicable",
            rootCount: 0,
            nodeCount: 0,
            errorCount: 0,
            isTruncated: false
        )
        AppLogger.flushForTesting()
        AppLogger.resetForTesting()

        let controller = ShelfFileIndexController(store: WorkspaceFileIndexStore())
        controller.refresh(
            allRoots: [],
            scope: .task,
            includeHidden: false,
            force: true,
            reason: "scope_change",
            taskID: taskID,
            responsivenessScope: scope
        )
        AppLogger.flushForTesting()

        #expect(!AppLogger.entries.contains {
            $0.category == "Performance"
                && $0.taskID == taskID
                && $0.message.contains("event=files_shelf_to_")
        })
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

    @Test("Files shelf diagnostics exclude internal and cancelled timings")
    func diagnosticsExcludeNonReadinessFilesShelfSamples() {
        let report = UIResponsivenessDiagnostics.makeReport(entries: [
            filesShelfMeasurement("files_shelf_to_chrome_ready", 20),
            filesShelfMeasurement("files_shelf_to_first_results", 60),
            filesShelfMeasurement("files_shelf_to_index_ready", 120),
            filesShelfMeasurement("files_shelf_cancelled", 500),
            filesShelfMeasurement("files_shelf_index_scan", 1_500),
            filesShelfMeasurement("files_shelf_preview_load", 2_000)
        ])

        #expect(Set(report.eventSummaries.map(\.event)) == [
            "files_shelf_to_chrome_ready",
            "files_shelf_to_first_results",
            "files_shelf_to_index_ready"
        ])
        #expect(report.slowestTraces.first?.event == "files_shelf_to_index_ready")
    }

    private func filesShelfMeasurement(_ event: String, _ duration: Double) -> LogEntry {
        LogEntry(
            level: .info,
            category: "Performance",
            message: "event=\(event) duration_ms=\(duration) task_id=01234567 trace_id=files-shelf-safe"
        )
    }
}

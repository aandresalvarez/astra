import Foundation
import Testing
@testable import ASTRA

@Suite("UI responsiveness diagnostics")
struct UIResponsivenessDiagnosticsTests {
    @Test("Summarizes p50 p95 cache cohorts and slow correlated traces")
    func summarizesResponsivenessMeasurements() {
        let entries = [
            measurement("task_selection_to_transcript_ready", 10, traceID: "trace-fast", cacheState: "hit"),
            measurement("task_selection_to_transcript_ready", 20, traceID: "trace-fast", cacheState: "hit"),
            measurement("task_selection_to_transcript_ready", 30, traceID: "trace-medium", cacheState: "miss"),
            measurement("task_selection_to_transcript_ready", 40, traceID: "trace-medium", cacheState: "miss"),
            measurement("task_selection_to_transcript_ready", 500, traceID: "trace-slow", cacheState: "miss", level: .warning),
            LogEntry(level: .debug, category: "Performance", message: "event=task_open_phase trace_id=trace-slow phase=thread_reset duration_ms=72.00"),
            LogEntry(level: .debug, category: "Performance", message: "event=task_open_phase trace_id=trace-slow phase=task_initialization duration_ms=85.00"),
            LogEntry(level: .info, category: "UI", message: "unrelated=true duration_ms=999")
        ]

        let report = UIResponsivenessDiagnostics.makeReport(entries: entries)
        let summary = try! #require(report.eventSummaries.first)
        let slowTrace = try! #require(report.slowestTraces.first)

        #expect(summary.event == "task_selection_to_transcript_ready")
        #expect(summary.sampleCount == 5)
        #expect(summary.p50Milliseconds == 30)
        #expect(summary.p95Milliseconds == 500)
        #expect(summary.maxMilliseconds == 500)
        #expect(summary.warningCount == 1)
        #expect(summary.cacheStates == ["hit": 2, "miss": 3])
        #expect(slowTrace.traceID == "trace-slow")
        #expect(slowTrace.durationMilliseconds == 500)
        #expect(slowTrace.phases == ["task_initialization", "thread_reset"])
    }

    @Test("Diagnostic report renders the responsiveness summary without raw content")
    func diagnosticsReportRendersSummary() {
        let report = LogDiagnosticsService.makeReport(entries: [
            measurement("task_selection_to_shell_visible", 80, traceID: "safe-trace", cacheState: "not_applicable")
        ])

        #expect(report.responsiveness.eventSummaries.count == 1)
        #expect(report.markdown.contains("## UI Responsiveness"))
        #expect(report.markdown.contains("task_selection_to_shell_visible"))
        #expect(!report.markdown.contains("Sensitive task goal"))
    }

    private func measurement(
        _ event: String,
        _ duration: Double,
        traceID: String,
        cacheState: String,
        level: LogLevel = .info
    ) -> LogEntry {
        let formattedDuration = String(format: "%.2f", duration)
        return LogEntry(
            level: level,
            category: "Performance",
            message: "event=\(event) duration_ms=\(formattedDuration) snapshot_cache_state=\(cacheState) task_id=01234567 trace_id=\(traceID)"
        )
    }
}

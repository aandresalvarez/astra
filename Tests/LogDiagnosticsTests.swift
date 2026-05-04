import Foundation
import Testing
@testable import ASTRA

@Suite("Log Diagnostics")
struct LogDiagnosticsTests {
    @Test("Report summarizes clean logs without issues")
    func cleanLogs() {
        let report = LogDiagnosticsService.makeReport(entries: [
            LogEntry(level: .info, category: "App", message: "app.started channel=dev"),
            LogEntry(level: .debug, category: "Worker", message: "runtime.command_planned runtime=copilot_cli model=gpt-5")
        ], generatedAt: Date(timeIntervalSince1970: 0))

        #expect(report.entryCount == 2)
        #expect(report.errorCount == 0)
        #expect(report.warningCount == 0)
        #expect(report.issueCount == 0)
        #expect(report.markdown.contains("No error or warning signals were found"))
    }

    @Test("Report groups runtime failure diagnostics and redacts evidence")
    func runtimeFailureReport() {
        let taskID = UUID(uuidString: "437BF453-D7D2-48AC-B316-971AF314ADB4")!
        let report = LogDiagnosticsService.makeReport(entries: [
            LogEntry(level: .info, category: "Worker", message: "task.started runtime=copilot_cli model=gpt-5", taskID: taskID),
            LogEntry(
                level: .error,
                category: "Worker",
                message: "runtime.failure_diagnostic error_summary=OPENAI_API_KEY=sk-test-secret failure_category=model_unavailable model=gpt-5 raw_error_chars=90 runtime=copilot_cli",
                taskID: taskID
            ),
            LogEntry(level: .warning, category: "Worker", message: "runtime.empty_output runtime=copilot_cli raw_lines=1", taskID: taskID)
        ], generatedAt: Date(timeIntervalSince1970: 0))

        #expect(report.issueCount == 2)
        #expect(report.issues.first?.title == "Selected model unavailable")
        #expect(report.markdown.contains("runtime.failure_diagnostic failure_category=model_unavailable"))
        #expect(report.markdown.contains("437BF453"))
        #expect(report.markdown.contains("gpt-5"))
        #expect(!report.markdown.contains("sk-test-secret"))
        #expect(!report.markdown.contains("OPENAI_API_KEY"))
        #expect(report.markdown.contains("[redacted-secret]") || report.markdown.contains("[redacted-secret-key]"))
    }

    @Test("Report writer creates markdown document")
    func writeReport() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-log-diagnostics-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let report = LogDiagnosticsService.makeReport(entries: [
            LogEntry(level: .error, category: "Keychain", message: "keychain.save_failed error=missing")
        ], generatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let url = try LogDiagnosticsService.writeReport(report, directory: directory)
        let content = try String(contentsOf: url, encoding: .utf8)

        #expect(url.lastPathComponent == "ASTRA-Diagnostics-20231114-221320.md")
        #expect(content.contains("# ASTRA Diagnostics Report"))
        #expect(content.contains("Keychain operation failed"))
    }

    @Test("Collects persisted app and task log entries")
    func collectPersistedLogs() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-log-collect-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try """
        [13:20:00.000] [INFO] [App] app.started channel=dev
        [13:20:01.000] [ERROR] [Worker task:0C48773F] runtime.failure_diagnostic failure_category=model_unavailable model=gpt-5 error_summary=provider_failed
        """.write(to: directory.appendingPathComponent("astra.log"), atomically: true, encoding: .utf8)
        try """
        [13:20:02.000] [WARNING] [Worker task:0C48773F] runtime.empty_output raw_lines=1
        """.write(to: directory.appendingPathComponent("task-0C48773F.log"), atomically: true, encoding: .utf8)

        let entries = LogDiagnosticsService.collectCurrentEntries(inMemoryEntries: [], logDirectory: directory)
        let report = LogDiagnosticsService.makeReport(entries: entries)

        #expect(entries.count == 3)
        #expect(entries.contains { $0.message.contains("task_short=0C48773F") })
        #expect(report.issueCount == 2)
        #expect(report.markdown.contains("task_short=0C48773F"))
        #expect(report.issues.contains { $0.affectedTasks == ["0C48773F"] })
    }

    @Test("Current in-memory entries ignore persisted app logs but keep task logs")
    func currentEntriesIgnorePersistedAppLogsButKeepTaskLogs() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-log-stale-filter-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try """
        [01:00:00.000] [ERROR] [Persistence] workspace.exported result=auto_export_failed workspace_id=OLD
        """.write(to: directory.appendingPathComponent("astra.log"), atomically: true, encoding: .utf8)
        try """
        [01:00:01.000] [WARNING] [Worker task:0C48773F] runtime.empty_output raw_lines=1
        """.write(to: directory.appendingPathComponent("task-0C48773F.log"), atomically: true, encoding: .utf8)

        let anchor = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: anchor], ofItemAtPath: directory.appendingPathComponent("astra.log").path)
        try FileManager.default.setAttributes([.modificationDate: anchor], ofItemAtPath: directory.appendingPathComponent("task-0C48773F.log").path)

        let currentEntry = LogEntry(
            level: .info,
            category: "Diagnostics",
            message: "diagnostics.generated entries=1 issues=0",
            timestamp: Date(timeInterval: 60 * 60 * 12, since: anchor)
        )
        let entries = LogDiagnosticsService.collectCurrentEntries(inMemoryEntries: [currentEntry], logDirectory: directory)
        let report = LogDiagnosticsService.makeReport(entries: entries)

        #expect(!entries.contains { $0.message.contains("workspace.exported") })
        #expect(entries.contains { $0.message.contains("runtime.empty_output") })
        #expect(!report.issues.contains { $0.signal == AuditEvent.diagnosticsGenerated.rawValue })
        #expect(report.issues.contains { $0.signal == AuditEvent.runtimeEmptyOutput.rawValue })
    }

    @Test("Report classifies actionable issues without duplicating successful recovery steps")
    func actionableIssueClassification() {
        let report = LogDiagnosticsService.makeReport(entries: [
            LogEntry(level: .warning, category: "App", message: "data.store.recovered error_type=SwiftDataError stage=model_container_failed"),
            LogEntry(level: .info, category: "Persistence", message: "workspace.store_backed_up result=completed"),
            LogEntry(level: .info, category: "App", message: "data.store.recovered result=model_container_recreated"),
            LogEntry(level: .info, category: "Persistence", message: "workspace.recovered imported_count=1"),
            LogEntry(level: .error, category: "Persistence", message: "workspace.exported error_code=4 error_description=The file doesn't exist. error_domain=NSCocoaErrorDomain parent_exists=false parent_writable=false result=auto_export_failed workspace_id=ABC"),
            LogEntry(level: .warning, category: "Keychain", message: "connector.tested connector_id=JIRA http_status=401 result=invalid_credentials service_type=jira")
        ], generatedAt: Date(timeIntervalSince1970: 0))

        #expect(report.issues.contains { $0.title == "SwiftData store was recovered" })
        #expect(report.issues.contains { $0.title == "Workspace auto-export failed" })
        #expect(report.issues.contains { $0.title == "Connector credentials were rejected" })
        #expect(!report.issues.contains { $0.signal == AuditEvent.workspaceStoreBackedUp.rawValue })
        #expect(!report.markdown.contains("[redacted-[redacted-secret-key]-key]"))
    }
}

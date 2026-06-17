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
        #expect(report.markdown.contains("App build:"))
        #expect(report.markdown.contains("No actionable issue signals were found"))
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

        #expect(report.issueCount == 1)
        #expect(report.issues.first?.title == "Selected model unavailable")
        #expect(report.markdown.contains("runtime.failure_diagnostic failure_category=model_unavailable"))
        #expect(report.markdown.contains("437BF453"))
        #expect(report.markdown.contains("gpt-5"))
        #expect(!report.markdown.contains("sk-test-secret"))
        #expect(!report.markdown.contains("OPENAI_API_KEY"))
        #expect(report.markdown.contains("[redacted-secret]") || report.markdown.contains("[redacted-secret-key]"))
        #expect(!report.issues.contains { $0.title == "Runtime returned no visible response" })
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

    @Test("Archive writer creates a diagnostics zip with windowed artifacts")
    func writeArchiveBundle() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-log-diagnostics-archive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let logDirectory = root.appendingPathComponent("logs", isDirectory: true)
        let outputDirectory = root.appendingPathComponent("out", isDirectory: true)
        let crashDirectory = root.appendingPathComponent("crashes-source", isDirectory: true)
        let extractDirectory = root.appendingPathComponent("extract", isDirectory: true)
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: crashDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: extractDirectory, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let inside = now.addingTimeInterval(-120)
        let outside = now.addingTimeInterval(-60 * 60)
        let appLog = logDirectory.appendingPathComponent("astra.log")
        let taskLog = logDirectory.appendingPathComponent("task-0C48773F.log")
        let oldTaskLog = logDirectory.appendingPathComponent("task-OLD.log")
        let browserFlight = logDirectory.appendingPathComponent("browser-flight-0C48773F.jsonl")
        let breadcrumbs = logDirectory.appendingPathComponent("last-actions.jsonl")
        let crashURL = crashDirectory.appendingPathComponent("ASTRA Dev-2023-11-14-120000.ips")

        try "[13:20:00.000] [INFO] [App] app.started channel=dev\n".write(to: appLog, atomically: true, encoding: .utf8)
        try "[13:20:01.000] [ERROR] [Worker task:0C48773F] runtime.failure_diagnostic failure_category=model_unavailable\n".write(to: taskLog, atomically: true, encoding: .utf8)
        try "[12:20:00.000] [ERROR] [Worker task:OLD] stale\n".write(to: oldTaskLog, atomically: true, encoding: .utf8)
        try "{\"action\":\"click\",\"result\":\"failed\"}\n".write(to: browserFlight, atomically: true, encoding: .utf8)
        try "{\"action\":\"open_logs\"}\n".write(to: breadcrumbs, atomically: true, encoding: .utf8)
        try "crash report".write(to: crashURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: inside], ofItemAtPath: appLog.path)
        try FileManager.default.setAttributes([.modificationDate: inside], ofItemAtPath: taskLog.path)
        try FileManager.default.setAttributes([.modificationDate: outside], ofItemAtPath: oldTaskLog.path)
        try FileManager.default.setAttributes([.modificationDate: inside], ofItemAtPath: browserFlight.path)
        try FileManager.default.setAttributes([.modificationDate: inside], ofItemAtPath: breadcrumbs.path)
        try FileManager.default.setAttributes([.modificationDate: inside], ofItemAtPath: crashURL.path)

        let entries = [
            LogEntry(level: .info, category: "App", message: "app.started channel=dev", timestamp: inside),
            LogEntry(level: .error, category: "Worker", message: "stale.failure", timestamp: outside)
        ]
        let history = LogDiagnosticsHistory.empty
        let report = LogDiagnosticsService.makeReport(
            entries: entries,
            generatedAt: now,
            scope: .last15Minutes,
            history: history,
            crashReports: [
                CrashReportSummary(url: crashURL, appName: "ASTRA Dev", modifiedAt: inside, sizeBytes: 12)
            ]
        )
        let analyzedEntries = LogDiagnosticsService.analyzedEntries(
            entries,
            generatedAt: now,
            scope: .last15Minutes,
            history: history
        )
        let interval = LogDiagnosticsService.analysisDateInterval(scope: .last15Minutes, generatedAt: now)

        let archive = try LogDiagnosticsService.writeArchive(
            report: report,
            analyzedEntries: analyzedEntries,
            analysisInterval: interval,
            logDirectory: logDirectory,
            directory: outputDirectory,
            crashReports: report.crashReports
        )

        #expect(archive.url.pathExtension == "zip")
        #expect(archive.artifactCount >= 7)
        #expect(archive.crashReportCount == 1)

        try extractZip(archive.url, to: extractDirectory)
        let bundleRoot = extractDirectory.appendingPathComponent(archive.url.deletingPathExtension().lastPathComponent, isDirectory: true)
        let manifest = try String(contentsOf: bundleRoot.appendingPathComponent("manifest.json"), encoding: .utf8)
        let analyzedLog = try String(
            contentsOf: bundleRoot.appendingPathComponent("logs/analyzed-log-entries.jsonl"),
            encoding: .utf8
        )

        #expect(FileManager.default.fileExists(atPath: bundleRoot.appendingPathComponent("ASTRA-Diagnostics-20231114-221320.md").path))
        #expect(FileManager.default.fileExists(atPath: bundleRoot.appendingPathComponent("logs/astra.log").path))
        #expect(FileManager.default.fileExists(atPath: bundleRoot.appendingPathComponent("logs/task-0C48773F.log").path))
        #expect(!FileManager.default.fileExists(atPath: bundleRoot.appendingPathComponent("logs/task-OLD.log").path))
        #expect(FileManager.default.fileExists(atPath: bundleRoot.appendingPathComponent("logs/browser-flight-0C48773F.jsonl").path))
        #expect(FileManager.default.fileExists(atPath: bundleRoot.appendingPathComponent("logs/last-actions.jsonl").path))
        #expect(FileManager.default.fileExists(atPath: bundleRoot.appendingPathComponent("crashes/ASTRA Dev-2023-11-14-120000.ips").path))
        #expect(manifest.contains("browser_flight_logs_when_present"))
        #expect(analyzedLog.contains("app.started"))
        #expect(!analyzedLog.contains("stale.failure"))
    }

    @Test("Crash report locator finds recent ASTRA crash reports")
    func crashReportLocatorFindsRecentAstraReports() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-crash-diagnostics-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let newest = directory.appendingPathComponent("ASTRA Dev-2023-11-14-120000.ips")
        let older = directory.appendingPathComponent("ASTRA Dev-2023-11-13-120000.crash")
        let stale = directory.appendingPathComponent("ASTRA Dev-2023-10-01-120000.ips")
        let unrelated = directory.appendingPathComponent("Other App-2023-11-14-120000.ips")

        try "newest".write(to: newest, atomically: true, encoding: .utf8)
        try "older".write(to: older, atomically: true, encoding: .utf8)
        try "stale".write(to: stale, atomically: true, encoding: .utf8)
        try "unrelated".write(to: unrelated, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-60)], ofItemAtPath: newest.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-120)], ofItemAtPath: older.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-60 * 60 * 24 * 60)], ofItemAtPath: stale.path)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: unrelated.path)

        let reports = CrashDiagnosticsService.recentReports(
            limit: 10,
            withinDays: 30,
            prefixes: ["ASTRA Dev"],
            searchDirectories: [directory],
            now: now
        )

        #expect(reports.map(\.fileName) == [
            "ASTRA Dev-2023-11-14-120000.ips",
            "ASTRA Dev-2023-11-13-120000.crash"
        ])
        #expect(reports.allSatisfy { $0.appName == "ASTRA Dev" })
        #expect(reports.allSatisfy { $0.sizeBytes > 0 })
    }

    @Test("Report includes crash report retrieval details")
    func reportIncludesCrashReports() {
        let crashURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports/ASTRA Dev-2023-11-14-120000.ips")
        let crash = CrashReportSummary(
            url: crashURL,
            appName: "ASTRA Dev",
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sizeBytes: 42_000
        )

        let report = LogDiagnosticsService.makeReport(
            entries: [
                LogEntry(level: .info, category: "App", message: "app.started channel=dev")
            ],
            generatedAt: Date(timeIntervalSince1970: 1_700_000_100),
            crashReports: [crash]
        )

        #expect(report.crashReports == [crash])
        #expect(report.markdown.contains("## Crash Reports"))
        #expect(report.markdown.contains("ASTRA Dev-2023-11-14-120000.ips"))
        #expect(report.markdown.contains("$HOME/Library/Logs/DiagnosticReports"))
        #expect(report.markdown.contains("Crashes button"))
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
        #expect(report.issueCount == 1)
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

    @Test("Query Shelf BigQuery CLI failures are classified specifically")
    func queryShelfBigQueryCLIFailureIsSpecific() {
        let report = LogDiagnosticsService.makeReport(entries: [
            LogEntry(
                level: .error,
                category: "QueryShelf",
                message: "Query shelf schema failed connection=BigQuery - demo error=BigQuery CLI (`bq`) was not found. Install the Google Cloud SDK, make sure `bq` is on PATH, then retry."
            )
        ], generatedAt: Date(timeIntervalSince1970: 0))

        #expect(report.issues.first?.title == "Query Shelf could not find BigQuery CLI")
        #expect(report.issues.first?.signal == "query_shelf bq_missing")
        #expect(report.markdown.contains("Verify Google Cloud SDK installation and PATH"))
    }

    @Test("Resolved setup failures are reported as non-actionable")
    func resolvedSetupFailuresBecomeNotices() {
        let report = LogDiagnosticsService.makeReport(entries: [
            LogEntry(
                level: .warning,
                category: "Capabilities",
                message: "validation.failed check_count=2 failed_count=2 package_id=gcloud-workflow package_name=GoogleCloud result=failed source=setup_sheet",
                timestamp: Date(timeIntervalSince1970: 1_000)
            ),
            LogEntry(
                level: .info,
                category: "Capabilities",
                message: "validation.passed check_count=2 failed_count=0 package_id=gcloud-workflow package_name=GoogleCloud result=passed source=setup_sheet",
                timestamp: Date(timeIntervalSince1970: 1_010)
            ),
            LogEntry(
                level: .warning,
                category: "Keychain",
                message: "connector.tested connector_id=JIRA-1 http_status=401 result=invalid_credentials service_type=jira",
                timestamp: Date(timeIntervalSince1970: 1_020)
            ),
            LogEntry(
                level: .info,
                category: "Keychain",
                message: "connector.tested connector_id=JIRA-1 http_status=200 result=success service_type=jira",
                timestamp: Date(timeIntervalSince1970: 1_030)
            )
        ], generatedAt: Date(timeIntervalSince1970: 1_100))

        #expect(!report.issues.contains { $0.title == "Application warning" })
        #expect(!report.issues.contains { $0.title == "Connector credentials were rejected" })
        #expect(report.notices.contains { $0.title == "Capability setup failure was resolved" })
        #expect(report.notices.contains { $0.title == "Connector authentication failure was resolved" })
        #expect(report.markdown.contains("## Resolved / Non-Actionable Events"))
    }

    @Test("Since last report notes previous diagnostics with issues")
    func sinceLastReportNotesPreviousDiagnosticsWithIssues() {
        let previous = Date(timeIntervalSince1970: 1_000)
        let report = LogDiagnosticsService.makeReport(
            entries: [
                LogEntry(
                    level: .info,
                    category: "Diagnostics",
                    message: "diagnostics.generated crash_reports=0 delivery=file entries=1116 errors=8 issues=7 notices=13 previous_report=none scope=sinceLastReport warnings=27",
                    timestamp: previous.addingTimeInterval(-0.1)
                ),
                LogEntry(
                    level: .info,
                    category: "Diagnostics",
                    message: "diagnostics.generated crash_reports=0 delivery=file entries=1 errors=0 issues=0 notices=0 previous_report=1000 scope=sinceLastReport warnings=0",
                    timestamp: previous.addingTimeInterval(1)
                )
            ],
            generatedAt: previous.addingTimeInterval(2),
            scope: .sinceLastReport,
            history: LogDiagnosticsHistory(lastGeneratedAt: previous, knownIssueFingerprints: [])
        )

        #expect(report.entryCount == 1)
        #expect(report.markdown.contains("Scope note: A recent earlier diagnostics export"))
        #expect(report.markdown.contains("7 issue groups"))
        #expect(report.markdown.contains("8 errors"))
        #expect(report.markdown.contains("Last 15 minutes or All retained logs"))
    }

    @Test("Jira connector diagnostics do not collapse permission failures into invalid token")
    func jiraConnectorPermissionDiagnosticsAreSpecific() {
        let report = LogDiagnosticsService.makeReport(entries: [
            LogEntry(
                level: .warning,
                category: "Keychain",
                message: "connector.tested endpoint_kind=jira.project_permissions http_status=200 permission=CREATE_ISSUES project_count=1 result=missing_permission service_type=jira"
            ),
            LogEntry(
                level: .warning,
                category: "Keychain",
                message: "connector.tested endpoint_kind=jira.project_permissions http_status=404 project_count=1 result=project_not_visible service_type=jira"
            ),
            LogEntry(
                level: .warning,
                category: "Keychain",
                message: "connector.tested endpoint_kind=jira.mypermissions fallback_endpoint_kind=jira.myself fallback_http_status=200 http_status=401 result=endpoint_scope_failure service_type=jira"
            )
        ], generatedAt: Date(timeIntervalSince1970: 0))

        #expect(report.issues.contains { $0.title == "Connector authenticated but lacks permission" })
        #expect(report.issues.contains { $0.title == "Jira project is not visible" })
        #expect(report.issues.contains { $0.title == "Connector auth probe needs scope or endpoint review" })
        #expect(!report.markdown.contains("Re-enter or refresh the token"))
    }

    @Test("Connector diagnostics detect credentials that stopped authenticating")
    func connectorCredentialRegressionDiagnostics() {
        let report = LogDiagnosticsService.makeReport(entries: [
            LogEntry(
                level: .info,
                category: "Keychain",
                message: "connector.tested auth_verified=true connector_id=JIRA-1 credential_evidence=connector_auth_v1 credential_state=authenticated endpoint_kind=jira.myself result=authenticated service_type=jira",
                timestamp: Date(timeIntervalSince1970: 1_000)
            ),
            LogEntry(
                level: .warning,
                category: "Keychain",
                message: "connector.tested auth_verified=false connector_id=JIRA-1 credential_evidence=connector_auth_v1 credential_state=rejected endpoint_kind=jira.myself http_status=401 result=auth_failed service_type=jira",
                timestamp: Date(timeIntervalSince1970: 1_100)
            )
        ], generatedAt: Date(timeIntervalSince1970: 1_200))

        #expect(report.issues.contains { $0.title == "Connector credentials stopped authenticating" })
        #expect(report.issues.first { $0.title == "Connector credentials stopped authenticating" }?.severity == .error)
        #expect(report.markdown.contains("previously authenticated"))
        #expect(report.markdown.contains("credential_state=authenticated"))
        #expect(report.markdown.contains("credential_state=rejected"))
    }

    @Test("Connector scope failures are not reported as auth regressions")
    func connectorScopeFailureDoesNotBecomeCredentialRegression() {
        let report = LogDiagnosticsService.makeReport(entries: [
            LogEntry(
                level: .info,
                category: "Keychain",
                message: "connector.tested auth_verified=true connector_id=JIRA-1 credential_evidence=connector_auth_v1 credential_state=authenticated endpoint_kind=jira.myself result=authenticated service_type=jira",
                timestamp: Date(timeIntervalSince1970: 1_000)
            ),
            LogEntry(
                level: .warning,
                category: "Keychain",
                message: "connector.tested auth_verified=true connector_id=JIRA-1 credential_evidence=connector_auth_v1 credential_state=authenticated endpoint_kind=jira.mypermissions fallback_endpoint_kind=jira.myself fallback_http_status=200 http_status=401 result=endpoint_scope_failure service_type=jira",
                timestamp: Date(timeIntervalSince1970: 1_100)
            )
        ], generatedAt: Date(timeIntervalSince1970: 1_200))

        #expect(!report.issues.contains { $0.title == "Connector credentials stopped authenticating" })
        #expect(report.issues.contains { $0.title == "Connector auth probe needs scope or endpoint review" })
    }

    @Test("Connector preflight failure is reported as task-blocking")
    func connectorPreflightFailureIsTaskBlocking() {
        let report = LogDiagnosticsService.makeReport(entries: [
            LogEntry(
                level: .error,
                category: "Worker",
                message: "task_short=EFE79794 connector.tested connector_id=JIRA connector_name=Jira result=preflight_failed service_type=jira"
            )
        ], generatedAt: Date(timeIntervalSince1970: 0))

        #expect(report.issues.contains { $0.title == "Connector preflight blocked task launch" })
        #expect(report.markdown.contains("Fix the connector configuration"))
    }

    @Test("Budget metric field names are preserved in diagnostics")
    func budgetMetricFieldNamesArePreserved() {
        let report = LogDiagnosticsService.makeReport(entries: [
            LogEntry(
                level: .error,
                category: "Worker",
                message: "worker.budget_exceeded configured_task_budget=50000 estimated_input_tokens=120000 launch_overhead_tokens=120000 reason=prompt_budget_estimate_exceeded token_budget=50000"
            )
        ], generatedAt: Date(timeIntervalSince1970: 0))

        #expect(report.markdown.contains("estimated_input_tokens=120000"))
        #expect(report.markdown.contains("token_budget=50000"))
        #expect(!report.markdown.contains("redacted_key=120000"))
    }

    @Test("Runtime model selection is reported as diagnostic context")
    func runtimeModelSelectionIsContext() {
        let report = LogDiagnosticsService.makeReport(entries: [
            LogEntry(
                level: .info,
                category: "Worker",
                message: "runtime.model_selection available_model_count=3 model_changed=true phase=run requested_model=claude-sonnet-4-6 resolved_model=claude-sonnet-4.6 runtime=copilot_cli selection_reason=known_other_runtime_model selection_source=built_in_defaults"
            )
        ], generatedAt: Date(timeIntervalSince1970: 0))

        #expect(report.issueCount == 0)
        #expect(report.notices.contains { $0.title == "Runtime model selection was recorded" })
        #expect(report.markdown.contains("selection_reason=known_other_runtime_model"))
    }

    @Test("GitHub CLI local tool preflight failures are specific")
    func githubLocalToolPreflightFailureIsSpecific() {
        let report = LogDiagnosticsService.makeReport(entries: [
            LogEntry(
                level: .warning,
                category: "Worker",
                message: "local_tool.tested command=gh phase=run result=auth_failed source=task_preflight"
            )
        ], generatedAt: Date(timeIntervalSince1970: 0))

        #expect(report.issues.contains { $0.title == "Local tool preflight failed" })
        #expect(report.markdown.contains("gh auth status"))
    }

    @Test("Capability chat context gap is reported")
    func capabilityChatContextGapIsReported() {
        let report = LogDiagnosticsService.makeReport(entries: [
            LogEntry(
                level: .info,
                category: "UI",
                message: "capability.enabled package_id=jira package_name=Jira_Workflow workspace_id=WS skills_count=1 connectors_count=1 tools_count=0"
            ),
            LogEntry(
                level: .info,
                category: "UI",
                message: "capability.chat_context source=new_task_plan_chat workspace_id=WS workspace_enabled_capabilities_count=1 workspace_enabled_global_skills_count=1 workspace_enabled_global_connectors_count=1 workspace_enabled_global_tools_count=0 available_skill_count=0 selected_skill_count=0 excluded_skill_count=0"
            )
        ], generatedAt: Date(timeIntervalSince1970: 0))

        #expect(report.issues.contains { $0.title == "Chat had no active capability context" })
        #expect(report.notices.contains { $0.title == "Capability was enabled" })
        #expect(report.markdown.contains("capability.chat_context"))
        #expect(report.markdown.contains("workspace_enabled_capabilities_count=1"))
    }

    @Test("Pruned capability scopes are not reported as missing capability context")
    func prunedCapabilityScopesAreNotReportedAsMissingCapabilityContext() {
        let report = LogDiagnosticsService.makeReport(entries: [
            LogEntry(
                level: .debug,
                category: "Worker",
                message: "capability.chat_context source=connector_preflight_candidates capability_scope=provider_launch scope_pruned=true scope_excluded_skill_names=GitHub Agent workspace_enabled_capabilities_count=1 workspace_enabled_global_skills_count=1 workspace_enabled_global_connectors_count=0 workspace_enabled_global_tools_count=0 selected_skill_count=0 resolved_skill_count=0 task_skill_count=0 connector_count=0 local_tool_count=0"
            ),
            LogEntry(
                level: .debug,
                category: "Worker",
                message: "capability.resolved capability_scope=provider_launch scope_pruned=true scope_excluded_skill_names=GitHub Agent workspace_enabled_capabilities_count=1 workspace_enabled_global_skills_count=1 workspace_enabled_global_connectors_count=0 workspace_enabled_global_tools_count=0 resolved_skill_count=0 connector_count=0 local_tool_count=0"
            )
        ], generatedAt: Date(timeIntervalSince1970: 0))

        #expect(!report.issues.contains { $0.title == "Chat had no active capability context" })
        #expect(!report.issues.contains { $0.title == "Task resolved no capability resources" })
        #expect(report.notices.contains { $0.title == "Chat capability context was captured" })
        #expect(report.notices.contains { $0.title == "Task capability context was resolved" })
    }

    @Test("Unpruned capability resolution gap is reported")
    func unprunedCapabilityResolutionGapIsReported() {
        let report = LogDiagnosticsService.makeReport(entries: [
            LogEntry(
                level: .debug,
                category: "Worker",
                message: "capability.resolved capability_scope=provider_launch scope_pruned=false scope_excluded_skill_names=none workspace_enabled_capabilities_count=1 workspace_enabled_global_skills_count=1 workspace_enabled_global_connectors_count=0 workspace_enabled_global_tools_count=0 resolved_skill_count=0 connector_count=0 local_tool_count=0"
            )
        ], generatedAt: Date(timeIntervalSince1970: 0))

        #expect(report.issues.contains { $0.title == "Task resolved no capability resources" })
    }

    @Test("Successful capability interactions are retained as notices")
    func successfulCapabilityInteractionsAreRetainedAsNotices() {
        let report = LogDiagnosticsService.makeReport(entries: [
            LogEntry(
                level: .info,
                category: "UI",
                message: "capability.enable_started source=configure package_id=jira package_name=Jira_Workflow workspace_id=WS skills_count=1 connectors_count=1 tools_count=0"
            ),
            LogEntry(
                level: .info,
                category: "UI",
                message: "capability.enabled source=configure package_id=jira package_name=Jira_Workflow workspace_id=WS skills_count=1 connectors_count=1 tools_count=0"
            ),
            LogEntry(
                level: .info,
                category: "Keychain",
                message: "connector.tested source=configure_test_button result=started connector_id=JIRA service_type=jira workspace_id=WS"
            ),
            LogEntry(
                level: .info,
                category: "Keychain",
                message: "connector.tested source=configure_test_button result=authenticated auth_verified=true credential_state=authenticated connector_id=JIRA service_type=jira workspace_id=WS"
            ),
            LogEntry(
                level: .info,
                category: "UI",
                message: "capability.chat_context source=new_task_plan_chat workspace_id=WS workspace_enabled_capabilities_count=1 workspace_enabled_global_skills_count=1 workspace_enabled_global_connectors_count=1 selected_skill_count=1 selected_skill_names=Jira_Workflow"
            )
        ], generatedAt: Date(timeIntervalSince1970: 0))

        #expect(report.issueCount == 0)
        #expect(report.notices.contains { $0.title == "Capability enable was attempted" })
        #expect(report.notices.contains { $0.title == "Capability was enabled" })
        #expect(report.notices.contains { $0.title == "Connector test was attempted" })
        #expect(report.notices.contains { $0.title == "Connector test succeeded" })
        #expect(report.notices.contains { $0.title == "Chat capability context was captured" })
        #expect(report.markdown.contains("## Resolved / Non-Actionable Events"))
        #expect(report.markdown.contains("connector.tested result=authenticated"))
    }

    @Test("Jira skill without active Jira connector is reported")
    func jiraSkillWithoutActiveConnectorIsReported() {
        let report = LogDiagnosticsService.makeReport(entries: [
            LogEntry(
                level: .debug,
                category: "Worker",
                message: "task_short=688EC1FE capability.chat_context source=connector_preflight_candidates resolved_skill_count=2 resolved_skill_names=Jira Agent,Safe Bash connector_count=2 connector_names=Google Cloud,New Connector connector_service_types=gcloud,custom preflight_connector_count=0 workspace_enabled_capabilities_count=1 workspace_enabled_global_skills_count=1 workspace_enabled_global_connectors_count=1"
            )
        ], generatedAt: Date(timeIntervalSince1970: 0))

        #expect(report.issues.contains { $0.title == "Jira skill resolved without an active Jira connector" })
        #expect(report.markdown.contains("connector_service_types!=jira"))
    }

    @Test("Capability runtime integrity failure is reported")
    func capabilityRuntimeIntegrityFailureIsReported() {
        let report = LogDiagnosticsService.makeReport(entries: [
            LogEntry(
                level: .error,
                category: "Worker",
                message: "task_short=688EC1FE capability.runtime_integrity result=missing_resources source=capability_runtime_integrity missing_count=1 package_names=Jira resource_kinds=connector resource_names=Jira sources=selected_package_skill"
            )
        ], generatedAt: Date(timeIntervalSince1970: 0))

        #expect(report.issues.contains { $0.title == "Capability runtime resources are missing" })
        #expect(report.markdown.contains("capability.runtime_integrity result=missing_resources"))
    }

    @Test("Optional browser behavior validation failure is non-actionable when assertion is skipped")
    func optionalBrowserBehaviorValidationFailureIsNonActionableWhenAssertionIsSkipped() {
        let planID = "52E2B9EE-258F-43A2-88B4-D1A4447D2E1E"
        let assertionID = "browser-3-index-html"
        let report = LogDiagnosticsService.makeReport(entries: [
            LogEntry(
                level: .warning,
                category: "Validation",
                message: "validation.behavior.failed action_count=0 assertion_id=\(assertionID) evidence_path=/tmp/evidence.md failure_reason=expected_text_missing path=/tmp/index.html plan_id=\(planID) screenshot_path=none url=file:///tmp/index.html",
                timestamp: Date(timeIntervalSince1970: 1_000)
            ),
            LogEntry(
                level: .info,
                category: "Validation",
                message: "validation.assertion.skipped assertion_id=\(assertionID) assertion_method=browser_behavior assertion_scope=plan exit_code=none failure_reason=expected_text_missing path=/tmp/index.html plan_id=\(planID) required=false result=skipped run_id=RUN",
                timestamp: Date(timeIntervalSince1970: 1_001)
            ),
            LogEntry(
                level: .info,
                category: "Validation",
                message: "validation.contract.passed failed_required= plan_id=\(planID) required_passed=1 required_total=1 run_id=RUN",
                timestamp: Date(timeIntervalSince1970: 1_002)
            )
        ], generatedAt: Date(timeIntervalSince1970: 1_100))

        #expect(report.issueCount == 0)
        #expect(report.notices.contains { $0.title == "Optional browser behavior validation was skipped" })
        #expect(!report.markdown.contains("Application warning"))
    }

    @Test("Required browser behavior validation failure is reported specifically")
    func requiredBrowserBehaviorValidationFailureIsReportedSpecifically() {
        let report = LogDiagnosticsService.makeReport(entries: [
            LogEntry(
                level: .warning,
                category: "Validation",
                message: "validation.behavior.failed action_count=0 assertion_id=browser-required evidence_path=/tmp/evidence.md failure_reason=expected_text_missing path=/tmp/index.html plan_id=PLAN screenshot_path=none url=file:///tmp/index.html",
                timestamp: Date(timeIntervalSince1970: 1_000)
            ),
            LogEntry(
                level: .warning,
                category: "Validation",
                message: "validation.assertion.failed assertion_id=browser-required assertion_method=browser_behavior assertion_scope=plan exit_code=none failure_reason=expected_text_missing path=/tmp/index.html plan_id=PLAN required=true result=failed run_id=RUN",
                timestamp: Date(timeIntervalSince1970: 1_001)
            )
        ], generatedAt: Date(timeIntervalSince1970: 1_100))

        #expect(report.issues.contains { $0.title == "Browser behavior validation failed" })
        #expect(!report.markdown.contains("Application warning"))
    }

    @Test("Browser behavior failure remains actionable when skip outcome is not optional")
    func browserBehaviorFailureRemainsActionableWhenSkipOutcomeIsNotOptional() {
        let report = LogDiagnosticsService.makeReport(entries: [
            LogEntry(
                level: .warning,
                category: "Validation",
                message: "validation.behavior.failed action_count=0 assertion_id=browser-required evidence_path=/tmp/evidence.md failure_reason=expected_text_missing path=/tmp/index.html plan_id=PLAN screenshot_path=none url=file:///tmp/index.html",
                timestamp: Date(timeIntervalSince1970: 1_000)
            ),
            LogEntry(
                level: .info,
                category: "Validation",
                message: "validation.assertion.skipped assertion_id=browser-required assertion_method=browser_behavior assertion_scope=plan exit_code=none failure_reason=expected_text_missing path=/tmp/index.html plan_id=PLAN required=true result=skipped run_id=RUN",
                timestamp: Date(timeIntervalSince1970: 1_001)
            )
        ], generatedAt: Date(timeIntervalSince1970: 1_100))

        #expect(report.issues.contains { $0.title == "Browser behavior validation failed" })
        #expect(!report.notices.contains { $0.title == "Optional browser behavior validation was skipped" })
        #expect(!report.markdown.contains("Application warning"))
    }

    @Test("Trace IDs group capability and connector attempts")
    func traceIDsGroupCapabilityAndConnectorAttempts() {
        let traceID = "capability-enable-1234abcd"
        let taskID = UUID(uuidString: "20DBCF1C-C0E6-42B1-BB70-BBE9F341C896")!
        let report = LogDiagnosticsService.makeReport(entries: [
            LogEntry(
                level: .info,
                category: "Capabilities",
                message: "user.action action=enable_capability_clicked package_id=jira package_name=Jira_Workflow source=configure trace_id=\(traceID) workspace_id=WS",
                timestamp: Date(timeIntervalSince1970: 1_000)
            ),
            LogEntry(
                level: .info,
                category: "Capabilities",
                message: "capability.enable_started package_id=jira package_name=Jira_Workflow source=install trace_id=\(traceID) workspace_id=WS",
                timestamp: Date(timeIntervalSince1970: 1_001)
            ),
            LogEntry(
                level: .info,
                category: "Keychain",
                message: "connector.tested connector_id=JIRA result=started service_type=jira source=configure_test_button trace_id=\(traceID) workspace_id=WS",
                timestamp: Date(timeIntervalSince1970: 1_002)
            ),
            LogEntry(
                level: .warning,
                category: "UI",
                message: "capability.chat_context source=new_task_plan_chat trace_id=\(traceID) workspace_enabled_capabilities_count=1 workspace_enabled_global_skills_count=1 workspace_enabled_global_connectors_count=1 selected_skill_count=0 resolved_skill_count=0 connector_count=0 local_tool_count=0 workspace_id=WS",
                taskID: taskID,
                timestamp: Date(timeIntervalSince1970: 1_003)
            )
        ], generatedAt: Date(timeIntervalSince1970: 1_100))

        #expect(report.markdown.contains("## Trace Timelines"))
        #expect(report.markdown.contains("`\(traceID)`"))
        #expect(report.markdown.contains("enable_capability_clicked"))
        #expect(report.markdown.contains("configure_test_button"))
        #expect(report.markdown.contains("20DBCF1C"))
    }

    @Test("Startup recovery interruption is reported as non-actionable")
    func startupRecoveryInterruptionIsNonActionable() {
        let report = LogDiagnosticsService.makeReport(entries: [
            LogEntry(
                level: .warning,
                category: "App",
                message: "task.interrupted events_inserted=2 runs_updated=2 source=startup_recovery tasks_updated=0",
                timestamp: Date(timeIntervalSince1970: 1_000)
            )
        ], generatedAt: Date(timeIntervalSince1970: 1_100))

        #expect(report.warningCount == 1)
        #expect(report.issueCount == 0)
        #expect(report.notices.count == 1)
        #expect(report.notices.first?.title == "Startup recovered stale running runs")
        #expect(report.markdown.contains("No actionable issue signals were found"))
        #expect(report.markdown.contains("## Resolved / Non-Actionable Events"))
        #expect(report.markdown.contains("task.interrupted source=startup_recovery"))
        #expect(!report.markdown.contains("Application warning"))
    }

    @Test("Superseded run interruption is reported as non-actionable")
    func supersededRunInterruptionIsNonActionable() {
        let taskID = UUID(uuidString: "20DBCF1C-C0E6-42B1-BB70-BBE9F341C896")!
        let report = LogDiagnosticsService.makeReport(entries: [
            LogEntry(
                level: .warning,
                category: "UI",
                message: "task.interrupted next_action=continue_session running_runs_cancelled=1 source=superseded_by_new_run",
                taskID: taskID,
                timestamp: Date(timeIntervalSince1970: 1_000)
            )
        ], generatedAt: Date(timeIntervalSince1970: 1_100))

        #expect(report.issueCount == 0)
        #expect(report.notices.first?.title == "Previous run was superseded")
        #expect(report.markdown.contains("task.interrupted source=superseded_by_new_run"))
        #expect(!report.markdown.contains("Application warning"))
    }

    @Test("UI timeout snapshots are not classified as runtime timeouts")
    func uiTimeoutSnapshotIsNotRuntimeTimeout() {
        let timedOutTask = UUID(uuidString: "437BF453-D7D2-48AC-B316-971AF314ADB4")!
        let unrelatedTask = UUID(uuidString: "011185C8-0000-4000-8000-000000000000")!
        let report = LogDiagnosticsService.makeReport(entries: [
            LogEntry(
                level: .debug,
                category: "UI",
                message: "thread.snapshot_built latest_run_status=timeout status=failed event_count=84",
                taskID: timedOutTask,
                timestamp: Date(timeIntervalSince1970: 1_000)
            ),
            LogEntry(
                level: .debug,
                category: "UI",
                message: "thread.snapshot_built latest_run_status=running status=running event_count=62",
                taskID: unrelatedTask,
                timestamp: Date(timeIntervalSince1970: 1_010)
            )
        ], generatedAt: Date(timeIntervalSince1970: 1_100))

        #expect(report.issueCount == 0)
        #expect(!report.markdown.contains("Runtime timeout"))
        #expect(report.markdown.contains("Tasks with issues: none"))
        #expect(report.markdown.contains("Other tasks seen: 011185C8, 437BF453"))
    }

    @Test("Real runtime timeout events are still classified")
    func realRuntimeTimeoutIsClassified() {
        let taskID = UUID(uuidString: "437BF453-D7D2-48AC-B316-971AF314ADB4")!
        let report = LogDiagnosticsService.makeReport(entries: [
            LogEntry(
                level: .warning,
                category: "Worker",
                message: "worker.timeout idle_seconds=300 runtime=claude_code",
                taskID: taskID,
                timestamp: Date(timeIntervalSince1970: 1_000)
            )
        ], generatedAt: Date(timeIntervalSince1970: 1_100))

        #expect(report.issues.contains { $0.id == "worker.timeout" })
        #expect(report.markdown.contains("Tasks with issues: 437BF453"))
    }

    @Test("Mirrored task log lines are deduplicated in issue counts")
    func mirroredTaskLinesAreDeduplicated() {
        let taskID = UUID(uuidString: "7E734355-0000-4000-8000-000000000000")!
        let first = Date(timeIntervalSince1970: 1_000)
        let second = Date(timeIntervalSince1970: 1_600)
        let report = LogDiagnosticsService.makeReport(entries: [
            LogEntry(
                level: .error,
                category: "Worker",
                message: "worker.budget_exceeded reason=max_budget_reached redacted_key=200000",
                taskID: taskID,
                timestamp: first
            ),
            LogEntry(
                level: .error,
                category: "Worker",
                message: "task_short=7E734355 worker.budget_exceeded reason=max_budget_reached redacted_key=200000",
                timestamp: first
            ),
            LogEntry(
                level: .debug,
                category: "Persistence",
                message: "runtime.persistence_summary file_changes=1 result=swiftdata_save_succeeded run_output_chars=2768 run_status=budget_exceeded task_status=budget_exceeded",
                taskID: taskID,
                timestamp: first.addingTimeInterval(1)
            ),
            LogEntry(
                level: .debug,
                category: "UI",
                message: "thread.snapshot_built latest_run_status=completed status=completed",
                taskID: UUID(uuidString: "011185C8-0000-4000-8000-000000000000")!,
                timestamp: second.addingTimeInterval(-1)
            ),
            LogEntry(
                level: .error,
                category: "Worker",
                message: "worker.budget_exceeded phase=resume reason=max_budget_reached redacted_key=1001909",
                taskID: taskID,
                timestamp: second
            ),
            LogEntry(
                level: .error,
                category: "Worker",
                message: "task_short=7E734355 worker.budget_exceeded phase=resume reason=max_budget_reached redacted_key=1001909",
                timestamp: second
            ),
            LogEntry(
                level: .debug,
                category: "Persistence",
                message: "task_short=7E734355 runtime.persistence_summary file_changes=1 result=swiftdata_save_succeeded run_output_chars=839 run_status=budget_exceeded task_status=budget_exceeded",
                timestamp: second.addingTimeInterval(1)
            )
        ], generatedAt: Date(timeIntervalSince1970: 1_700))

        let issue = report.issues.first { $0.id == "worker.budget_exceeded" }
        #expect(issue?.count == 2)
        #expect(issue?.affectedTasks == ["7E734355"])
        #expect(issue?.analysis.contains("visible output") == true)
        #expect(issue?.analysis.contains("file change") == true)
        #expect(issue?.evidence.contains { $0.contains("task_short=011185C8") || $0.contains("thread.snapshot_built") } == false)
        #expect(report.markdown.contains("Tasks with issues: 7E734355"))
        #expect(report.markdown.contains("Other tasks seen: 011185C8"))
    }

    @Test("Debug title generation candidate failures are non-actionable")
    func debugTitleGenerationCandidateFailureIsNonActionable() {
        let debugReport = LogDiagnosticsService.makeReport(entries: [
            LogEntry(
                level: .debug,
                category: "Worker",
                message: "spec.extraction_failed error_summary=model unavailable exit_code=1 model=claude-haiku-4-5-20251001 operation=title_generation result=candidate_failed",
                timestamp: Date(timeIntervalSince1970: 1_000)
            )
        ], generatedAt: Date(timeIntervalSince1970: 1_100))

        #expect(debugReport.issueCount == 0)
        #expect(!debugReport.markdown.contains("Thread title generation failed"))

        let warningReport = LogDiagnosticsService.makeReport(entries: [
            LogEntry(
                level: .warning,
                category: "Worker",
                message: "spec.extraction_failed candidate_count=2 error_summary=model unavailable operation=title_generation result=all_candidates_failed",
                timestamp: Date(timeIntervalSince1970: 1_000)
            )
        ], generatedAt: Date(timeIntervalSince1970: 1_100))

        #expect(warningReport.issues.contains { $0.id == "spec.title_generation.failed" })
    }

    @Test("Report scopes entries and labels issue freshness")
    func reportScopeAndFreshness() {
        let previous = Date(timeIntervalSince1970: 1_200)
        let oldEntry = LogEntry(
            level: .error,
            category: "Persistence",
            message: "workspace.exported result=auto_export_failed workspace_id=OLD",
            timestamp: Date(timeIntervalSince1970: 1_000)
        )
        let recurringBefore = LogEntry(
            level: .warning,
            category: "Worker",
            message: "runtime.empty_output runtime=copilot_cli raw_lines=1",
            timestamp: Date(timeIntervalSince1970: 1_100)
        )
        let recurringAfter = LogEntry(
            level: .warning,
            category: "Worker",
            message: "runtime.empty_output runtime=copilot_cli raw_lines=1",
            timestamp: Date(timeIntervalSince1970: 1_300)
        )
        let newEntry = LogEntry(
            level: .warning,
            category: "Keychain",
            message: "connector.tested connector_id=JIRA http_status=401 result=invalid_credentials service_type=jira",
            timestamp: Date(timeIntervalSince1970: 1_350)
        )

        let retained = LogDiagnosticsService.makeReport(
            entries: [oldEntry, recurringBefore, recurringAfter, newEntry],
            generatedAt: Date(timeIntervalSince1970: 1_400),
            scope: .allRetained,
            history: LogDiagnosticsHistory(
                lastGeneratedAt: previous,
                knownIssueFingerprints: ["runtime.empty_output"]
            )
        )

        #expect(retained.entryCount == 4)
        #expect(retained.issues.first { $0.id == "workspace.export.auto_export_failed.write_failed" }?.freshness == .old)
        #expect(retained.issues.first { $0.id == "runtime.empty_output" }?.freshness == .recurring)
        #expect(retained.issues.first { $0.id == "connector.tested.unauthorized" }?.freshness == .new)
        #expect(retained.markdown.contains("Scope: All retained logs"))
        #expect(retained.markdown.contains("Analyzed window:"))
        #expect(retained.markdown.contains("- Freshness: recurring"))

        let sinceLast = LogDiagnosticsService.makeReport(
            entries: [oldEntry, recurringBefore, recurringAfter, newEntry],
            generatedAt: Date(timeIntervalSince1970: 1_400),
            scope: .sinceLastReport,
            history: LogDiagnosticsHistory(
                lastGeneratedAt: previous,
                knownIssueFingerprints: ["runtime.empty_output"]
            )
        )

        #expect(sinceLast.entryCount == 2)
        #expect(!sinceLast.issues.contains { $0.id == "workspace.export.auto_export_failed.write_failed" })
        #expect(sinceLast.issues.first { $0.id == "runtime.empty_output" }?.freshness == .recurring)
    }

    @Test("Diagnostics history persists last run and issue fingerprints")
    func diagnosticsHistoryPersistence() throws {
        let suiteName = "astra-diagnostics-history-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let report = LogDiagnosticsService.makeReport(
            entries: [
                LogEntry(level: .warning, category: "Worker", message: "runtime.empty_output runtime=copilot_cli raw_lines=1")
            ],
            generatedAt: Date(timeIntervalSince1970: 1_700)
        )
        LogDiagnosticsService.saveHistory(from: report, defaults: defaults)
        let history = LogDiagnosticsService.loadHistory(defaults: defaults)

        #expect(history.lastGeneratedAt == Date(timeIntervalSince1970: 1_700))
        #expect(history.knownIssueFingerprints.contains("runtime.empty_output"))
    }

    @Test("Recovered permission warning is not reported as unresolved")
    func recoveredPermissionWarningIsSuppressed() {
        let taskID = UUID(uuidString: "20DBCF1C-C0E6-42B1-BB70-BBE9F341C896")!
        let report = LogDiagnosticsService.makeReport(
            entries: [
                LogEntry(
                    level: .warning,
                    category: "Worker",
                    message: "worker.permission_denied reason_summary=approval-needed source=copilot_stream tool=Bash",
                    taskID: taskID,
                    timestamp: Date(timeIntervalSince1970: 1_000)
                ),
                LogEntry(
                    level: .debug,
                    category: "Worker",
                    message: "runtime.progress_state event_count=4 output_chars=120 reason=health run_id=20DBCF1C state=active",
                    taskID: taskID,
                    timestamp: Date(timeIntervalSince1970: 1_060)
                )
            ],
            generatedAt: Date(timeIntervalSince1970: 1_400)
        )

        #expect(!report.issues.contains { $0.id.hasPrefix("worker.permission_denied") })
        #expect(!report.markdown.contains("Runtime permission warning needs follow-up"))
    }

    @Test("Stale permission warning is reported after quiet threshold")
    func stalePermissionWarningIsReported() {
        let taskID = UUID(uuidString: "20DBCF1C-C0E6-42B1-BB70-BBE9F341C896")!
        let report = LogDiagnosticsService.makeReport(
            entries: [
                LogEntry(
                    level: .warning,
                    category: "Worker",
                    message: "worker.permission_denied reason_summary=approval-needed source=copilot_stream tool=Bash",
                    taskID: taskID,
                    timestamp: Date(timeIntervalSince1970: 1_000)
                )
            ],
            generatedAt: Date(timeIntervalSince1970: 1_301)
        )

        #expect(report.issues.contains { $0.id == "worker.permission_denied.Bash" })
        #expect(report.markdown.contains("Runtime permission warning needs follow-up"))
    }

    @Test("Completed task suppresses earlier permission warning")
    func completedTaskSuppressesPermissionWarning() {
        let taskID = UUID(uuidString: "20DBCF1C-C0E6-42B1-BB70-BBE9F341C896")!
        let report = LogDiagnosticsService.makeReport(
            entries: [
                LogEntry(
                    level: .warning,
                    category: "Worker",
                    message: "worker.permission_denied reason_summary=approval-needed source=copilot_stream tool=Bash",
                    taskID: taskID,
                    timestamp: Date(timeIntervalSince1970: 1_000)
                ),
                LogEntry(
                    level: .info,
                    category: "Worker",
                    message: "worker.exited exit_code=0 phase=resume runtime=copilot_cli",
                    taskID: taskID,
                    timestamp: Date(timeIntervalSince1970: 1_380)
                )
            ],
            generatedAt: Date(timeIntervalSince1970: 1_500)
        )

        #expect(!report.issues.contains { $0.id.hasPrefix("worker.permission_denied") })
    }

    @Test("Runtime failure suppresses duplicate worker exit warnings")
    func runtimeFailureSuppressesDuplicateWorkerExitWarnings() {
        let taskID = UUID(uuidString: "BEB972EC-3D4C-45F9-9A42-3E134BD11103")!
        let report = LogDiagnosticsService.makeReport(
            entries: [
                LogEntry(
                    level: .error,
                    category: "Worker",
                    message: "runtime.failure_diagnostic failure_category=permission_denied runtime=copilot_cli exit_code=15",
                    taskID: taskID,
                    timestamp: Date(timeIntervalSince1970: 1_000)
                ),
                LogEntry(
                    level: .warning,
                    category: "Worker",
                    message: "worker.exited exit_code=15 phase=run runtime=copilot_cli",
                    taskID: taskID,
                    timestamp: Date(timeIntervalSince1970: 1_001)
                ),
                LogEntry(
                    level: .warning,
                    category: "Worker",
                    message: "task_short=BEB972EC worker.exited exit_code=15 phase=run runtime=copilot_cli",
                    timestamp: Date(timeIntervalSince1970: 1_001)
                )
            ],
            generatedAt: Date(timeIntervalSince1970: 1_100)
        )

        #expect(report.issues.map(\.id) == ["runtime.failure_diagnostic.permission_denied"])
        #expect(!report.markdown.contains("Application warning"))
    }

    @Test("Generic task_short warning uses underlying signal")
    func genericTaskShortWarningUsesUnderlyingSignal() {
        let report = LogDiagnosticsService.makeReport(
            entries: [
                LogEntry(
                    level: .warning,
                    category: "Worker",
                    message: "task_short=BEB972EC worker.exited exit_code=15 phase=run runtime=copilot_cli",
                    timestamp: Date(timeIntervalSince1970: 1_000)
                )
            ],
            generatedAt: Date(timeIntervalSince1970: 1_100)
        )

        #expect(report.issues.first?.id == "warning.worker.exited")
        #expect(report.issues.first?.signal == "worker.exited")
    }

    @Test("Possibly stalled runtime progress state is reported")
    func possiblyStalledProgressStateIsReported() {
        let taskID = UUID(uuidString: "20DBCF1C-C0E6-42B1-BB70-BBE9F341C896")!
        let report = LogDiagnosticsService.makeReport(
            entries: [
                LogEntry(
                    level: .warning,
                    category: "Worker",
                    message: "runtime.progress_state event_count=12 output_chars=121 reason=timer run_id=20DBCF1C state=possibly_stalled warning_tool=Bash",
                    taskID: taskID,
                    timestamp: Date(timeIntervalSince1970: 1_500)
                )
            ],
            generatedAt: Date(timeIntervalSince1970: 1_500)
        )

        #expect(report.issues.contains { $0.id == "runtime.progress_state.possibly_stalled" })
        #expect(report.markdown.contains("Running task may be stalled"))
    }

    @Test("Blocked plan step is reported when unresolved")
    func unresolvedPlanStepBlockerIsReported() {
        let taskID = UUID(uuidString: "20DBCF1C-C0E6-42B1-BB70-BBE9F341C896")!
        let report = LogDiagnosticsService.makeReport(
            entries: [
                LogEntry(
                    level: .warning,
                    category: "Plan",
                    message: "plan.step.blocked blocked_reason=Need approval latest_run_status=running plan_id=PLAN step_id=step-2 step_status=blocked",
                    taskID: taskID,
                    timestamp: Date(timeIntervalSince1970: 1_000)
                )
            ],
            generatedAt: Date(timeIntervalSince1970: 1_100)
        )

        #expect(report.issues.contains { $0.id == "plan.step.blocked.step-2" })
        #expect(report.markdown.contains("Plan execution is blocked"))
        #expect(report.markdown.contains("20DBCF1C"))
    }

    @Test("Resolved plan step blocker is suppressed")
    func resolvedPlanStepBlockerIsSuppressed() {
        let taskID = UUID(uuidString: "20DBCF1C-C0E6-42B1-BB70-BBE9F341C896")!
        let report = LogDiagnosticsService.makeReport(
            entries: [
                LogEntry(
                    level: .warning,
                    category: "Plan",
                    message: "plan.step.blocked blocked_reason=Need approval latest_run_status=running plan_id=PLAN step_id=step-2 step_status=blocked",
                    taskID: taskID,
                    timestamp: Date(timeIntervalSince1970: 1_000)
                ),
                LogEntry(
                    level: .debug,
                    category: "Plan",
                    message: "plan.step.state_changed latest_run_status=running plan_id=PLAN step_id=step-2 step_status=done summary=Finished",
                    taskID: taskID,
                    timestamp: Date(timeIntervalSince1970: 1_030)
                )
            ],
            generatedAt: Date(timeIntervalSince1970: 1_100)
        )

        #expect(!report.issues.contains { $0.id.hasPrefix("plan.step.blocked") })
        #expect(!report.markdown.contains("Plan execution is blocked"))
    }

    @Test("Failed plan execution suppresses earlier plan blocker")
    func failedPlanExecutionSuppressesEarlierPlanBlocker() {
        let taskID = UUID(uuidString: "BEB972EC-3D4C-45F9-9A42-3E134BD11103")!
        let report = LogDiagnosticsService.makeReport(
            entries: [
                LogEntry(
                    level: .warning,
                    category: "Plan",
                    message: "plan.step.blocked blocked_reason=Need approval latest_run_status=running plan_id=PLAN step_id=step-2 step_status=blocked",
                    taskID: taskID,
                    timestamp: Date(timeIntervalSince1970: 1_000)
                ),
                LogEntry(
                    level: .error,
                    category: "Worker",
                    message: "runtime.failure_diagnostic failure_category=permission_denied runtime=copilot_cli exit_code=15",
                    taskID: taskID,
                    timestamp: Date(timeIntervalSince1970: 1_030)
                ),
                LogEntry(
                    level: .info,
                    category: "Plan",
                    message: "plan.execution.failed plan_id=PLAN reason=failed",
                    taskID: taskID,
                    timestamp: Date(timeIntervalSince1970: 1_031)
                )
            ],
            generatedAt: Date(timeIntervalSince1970: 1_100)
        )

        #expect(!report.issues.contains { $0.id.hasPrefix("plan.step.blocked") })
        #expect(report.issues.contains { $0.id == "runtime.failure_diagnostic.permission_denied" })
    }

    private func extractZip(_ archive: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, destination.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(
                domain: "LogDiagnosticsTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: output]
            )
        }
    }
}

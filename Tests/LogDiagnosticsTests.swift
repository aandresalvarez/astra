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
}

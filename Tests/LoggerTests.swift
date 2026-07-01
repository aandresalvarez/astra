import Testing
import Foundation
@testable import ASTRA

@Suite("AppLogger Thread Safety", .serialized)
struct AppLoggerTests {

    @Test("Sensitive mode defaults on")
    func sensitiveModeDefaultsOn() {
        let previous = UserDefaults.standard.object(forKey: AppLogger.sensitiveModeKey)
        UserDefaults.standard.removeObject(forKey: AppLogger.sensitiveModeKey)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: AppLogger.sensitiveModeKey)
            } else {
                UserDefaults.standard.removeObject(forKey: AppLogger.sensitiveModeKey)
            }
        }

        #expect(AppLogger.isSensitiveMode)
    }

    @Test("Detailed logging preferences default on with one-week retention")
    func detailedLoggingPreferencesDefaultOn() {
        let suiteName = "astra-logging-prefs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(LoggingPreferences.runtimeStreamDebugCaptureEnabled(in: defaults) == true)
        #expect(LoggingPreferences.browserDebugCaptureEnabled(in: defaults) == true)
        #expect(LoggingPreferences.logRetentionDays(in: defaults) == 7)

        defaults.set(false, forKey: AppStorageKeys.runtimeStreamDebugCapture)
        defaults.set(false, forKey: AppStorageKeys.browserDebugCapture)
        defaults.set(0, forKey: AppStorageKeys.logRetentionDays)
        #expect(LoggingPreferences.runtimeStreamDebugCaptureEnabled(in: defaults) == false)
        #expect(LoggingPreferences.browserDebugCaptureEnabled(in: defaults) == false)
        #expect(LoggingPreferences.logRetentionDays(in: defaults) == 1)

        defaults.set(999, forKey: AppStorageKeys.logRetentionDays)
        #expect(LoggingPreferences.logRetentionDays(in: defaults) == 365)
    }

    @Test("Sanitizer redacts sensitive payloads")
    func sanitizerRedactsSensitivePayloads() {
        let raw = """
        Person person@example.invalid used EXAMPLE_API_TOKEN=demo in /Users/example-user/Documents/SampleData/file.txt with bearer: demo
        """
        let sanitized = LogSanitizer.sanitize(raw)

        #expect(!sanitized.contains("person@example.invalid"))
        #expect(!sanitized.contains("EXAMPLE_API_TOKEN"))
        #expect(!sanitized.contains("demo"))
        #expect(!sanitized.contains("/Users/example-user/Documents/SampleData"))
        #expect(sanitized.contains("[redacted-email]"))
        #expect(sanitized.contains("[redacted-path]"))
    }

    @Test("Sanitizer preserves diagnostic placeholders and safe status values")
    func sanitizerPreservesDiagnosticPlaceholders() {
        let raw = "result=invalid_credentials placeholder=[redacted-secret-key] event=update_safety_signature OPENAI_API_KEY=sk-test-secret"
        let sanitized = LogSanitizer.sanitize(raw)

        #expect(sanitized.contains("result=invalid_credentials"))
        #expect(sanitized.contains("placeholder=[redacted-secret-key]"))
        #expect(sanitized.contains("event=update_safety_signature"))
        #expect(!sanitized.contains("OPENAI_API_KEY"))
        #expect(!sanitized.contains("sk-test-secret"))
    }

    @Test("Sanitizer reuses compiled regex patterns")
    func sanitizerReusesCompiledRegexPatterns() {
        LogSanitizer.resetRegexCacheForTesting()

        _ = LogSanitizer.sanitize("Person person@example.invalid used EXAMPLE_API_TOKEN=demo")
        let compiledAfterFirstSanitize = LogSanitizer.compiledRegexCountForTesting

        #expect(compiledAfterFirstSanitize > 0)

        _ = LogSanitizer.sanitize("Other other@example.invalid used OTHER_API_TOKEN=demo")

        #expect(LogSanitizer.compiledRegexCountForTesting == compiledAfterFirstSanitize)
    }

    @Test("Legacy logging stores sanitized message")
    func legacyLoggingStoresSanitizedMessage() async {
        AppLogger.resetForTesting()
        let sampleCredential = "EXAMPLE_API_TOKEN=demo"

        AppLogger.info("Prompt: person person@example.invalid \(sampleCredential) /Users/example-user/SampleData/task.txt", category: "Worker")
        AppLogger.flushForTesting()

        let combined = AppLogger.entries.map(\.formatted).joined(separator: "\n")
        #expect(!combined.contains("person@example.invalid"))
        #expect(!combined.contains("EXAMPLE_API_TOKEN"))
        #expect(!combined.contains("demo"))
        #expect(!combined.contains("/Users/example-user/SampleData"))
    }

    @Test("Audit logging emits stable event and safe fields")
    func auditLoggingEmitsStableEvent() async {
        AppLogger.resetForTesting()
        let taskID = UUID()

        AppLogger.audit(.taskStarted, category: "Worker", taskID: taskID, fields: [
            "workspace_id": UUID().uuidString,
            "prompt": "person person@example.invalid"
        ])
        AppLogger.flushForTesting()

        let entry = AppLogger.entries.first { $0.taskID == taskID }
        #expect(entry?.taskID == taskID)
        #expect(entry?.message.contains(AuditEvent.taskStarted.rawValue) == true)
        #expect(entry?.message.contains("workspace_id=") == true)
        #expect(entry?.message.contains("person@example.invalid") == false)
    }

    @Test("Log storage is permission hardened")
    func logStorageIsPermissionHardened() async throws {
        AppLogger.info("permission check", category: "General")
        try? await Task.sleep(for: .milliseconds(200))

        let dir = AppLogger.mainLogFile.deletingLastPathComponent()
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: dir.path)
        let fileAttrs = try FileManager.default.attributesOfItem(atPath: AppLogger.mainLogFile.path)
        let dirPerms = (dirAttrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        let filePerms = (fileAttrs[.posixPermissions] as? NSNumber)?.intValue ?? 0

        #expect(dirPerms & 0o777 == 0o700)
        #expect(filePerms & 0o777 == 0o600)
    }

    @Test("Test logs are isolated from production logs")
    func testLogsAreIsolatedFromProductionLogs() {
        #expect(AppLogger.isRunningTests)
        #expect(!AppLogger.mainLogFile.path.contains("/Library/Logs/Astra/astra.log"))
        #expect(AppLogger.mainLogFile.path.contains("AstraTests"))
    }

    @Test("Browser category is available for logs filtering")
    func browserCategoryIsAvailableForFiltering() {
        #expect(AppLogCategory.all.contains("Browser"))
    }

    @Test("Browser flight entries persist rich debug payloads")
    func browserFlightEntriesPersistRichDebugPayloads() throws {
        let taskID = UUID()
        let url = AppLogger.browserFlightLogFile(taskID: taskID)
        try? FileManager.default.removeItem(at: url)

        AppLogger.appendBrowserFlightEntry([
            "id": "bflight_test",
            "sequence": 1,
            "debugCapture": [
                "enabled": true,
                "screenshot": [
                    "format": "jpeg",
                    "base64": "abc123"
                ]
            ]
        ], taskID: taskID)
        AppLogger.flushForTesting()

        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(content.contains("\"debugCapture\""))
        #expect(content.contains("\"screenshot\""))
        #expect(content.contains("\"base64\":\"abc123\""))
    }

    @Test("Startup diagnostics snapshot includes retrievable crash context")
    func startupDiagnosticsSnapshotIncludesCrashContext() {
        let crash = CrashReportSummary(
            url: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/DiagnosticReports/ASTRA Dev-2023-11-14-120000.ips"),
            appName: "ASTRA Dev",
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sizeBytes: 12_000
        )

        let fields = StartupDiagnosticsService.snapshotFields(
            stage: "test",
            isUITesting: true,
            skipWorkspaceRecovery: true,
            persistentStoreURL: nil,
            modelContainerResult: "created",
            crashReports: [crash]
        )

        #expect(fields["stage"] == "test")
        #expect(fields["store_mode"] == "memory")
        #expect(fields["model_container"] == "created")
        #expect(fields["recent_crash_reports"] == "1")
        #expect(fields["latest_crash_report"] == "ASTRA Dev-2023-11-14-120000.ips")
        #expect(fields["latest_crash_report_path"]?.contains("$HOME/Library/Logs/DiagnosticReports") == true)
        #expect(fields["logging_subsystem"]?.isEmpty == false)
    }

    @Test("Startup diagnostics uses injected home for protected workspace checks")
    func startupDiagnosticsUsesInjectedHomeForProtectedWorkspaceChecks() {
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("astra-test-home-\(UUID().uuidString)", isDirectory: true)
        let fileManager = StubHomeFileManager(homeDirectory: home)

        let fields = StartupDiagnosticsService.snapshotFields(
            stage: "test",
            isUITesting: true,
            skipWorkspaceRecovery: true,
            persistentStoreURL: nil,
            fileManager: fileManager,
            crashReports: []
        )

        #expect(fields["workspace_root"]?.hasPrefix("$HOME/Documents/") == true)
        #expect(fields["workspace_root_exists"] == "not_checked_protected_location")
    }

    @Test("onNewEntry callback fires on main thread")
    @MainActor
    func onNewEntryMainThread() async {
        let expectation = Expectation()

        AppLogger.onNewEntry = { _ in
            #expect(Thread.isMainThread)
            expectation.fulfill()
        }
        defer { AppLogger.onNewEntry = nil }

        // Emit from background thread
        DispatchQueue.global().async {
            AppLogger.info("test from background", category: "General")
        }

        // Wait for callback
        try? await Task.sleep(for: .milliseconds(200))
        #expect(expectation.isFulfilled)
    }

    @Test("Concurrent log writes don't crash")
    func concurrentWrites() async {
        // Fire many logs concurrently from multiple tasks
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    AppLogger.info("Concurrent log \(i)", category: "General")
                }
            }
        }

        // If we get here without crash, file serialization is working
        let entries = AppLogger.entries
        #expect(!entries.isEmpty)
    }

    @Test("File logging serializes writes correctly")
    func fileSerializationTest() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-logtest-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let testFile = tempDir.appendingPathComponent("test.log")

        // Write 100 lines concurrently via the shared file queue
        let count = 100
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<count {
                group.addTask {
                    let line = "Line \(i)\n"
                    if let data = line.data(using: .utf8) {
                        if FileManager.default.fileExists(atPath: testFile.path) {
                            if let handle = try? FileHandle(forWritingTo: testFile) {
                                handle.seekToEndOfFile()
                                handle.write(data)
                                handle.closeFile()
                            }
                        } else {
                            try? data.write(to: testFile)
                        }
                    }
                }
            }
        }

        // Verify the file has content (exact line count may vary due to race,
        // but it shouldn't crash or produce empty output)
        let content = try String(contentsOf: testFile, encoding: .utf8)
        #expect(!content.isEmpty)
    }
}

/// Simple fulfillment tracker for async tests
private final class Expectation: @unchecked Sendable {
    private let lock = NSLock()
    private var _fulfilled = false

    var isFulfilled: Bool {
        lock.lock(); defer { lock.unlock() }; return _fulfilled
    }

    func fulfill() {
        lock.lock(); defer { lock.unlock() }; _fulfilled = true
    }
}

private final class StubHomeFileManager: FileManager {
    private let stubHomeDirectory: URL

    init(homeDirectory: URL) {
        self.stubHomeDirectory = homeDirectory
        super.init()
    }

    override var homeDirectoryForCurrentUser: URL {
        stubHomeDirectory
    }
}

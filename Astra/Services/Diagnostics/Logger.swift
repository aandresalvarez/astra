import Foundation
import os

extension Notification.Name {
    static let appLoggerDidAppendEntry = Notification.Name("AppLogger.didAppendEntry")
}

// MARK: - Log Level

enum LogLevel: String, Comparable, CaseIterable {
    case debug
    case info
    case warning
    case error

    var osLogType: OSLogType {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .warning: return .default
        case .error: return .error
        }
    }

    var symbol: String {
        switch self {
        case .debug: return "🔍"
        case .info: return "ℹ️"
        case .warning: return "⚠️"
        case .error: return "❌"
        }
    }

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        let order: [LogLevel] = [.debug, .info, .warning, .error]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

// MARK: - Audit Event

enum AuditEvent: String, CaseIterable {
    case appStarted = "app.started"
    case appActivated = "app.activated"
    case startupDiagnostics = "startup.diagnostics"
    case userAction = "user.action"
    case dataStoreSelected = "data.store.selected"
    case dataStoreRecovered = "data.store.recovered"
    case diagnosticsGenerated = "diagnostics.generated"
    case diagnosticsGenerationFailed = "diagnostics.generation_failed"
    case crashReportsRevealed = "crash_reports.revealed"

    case taskCreated = "task.created"
    case taskStarted = "task.started"
    case taskAssigned = "task.assigned"
    case taskDequeued = "task.dequeued"
    case taskResumed = "task.resumed"
    case taskCancelled = "task.cancelled"
    case taskInterrupted = "task.interrupted"
    case taskApproved = "task.approved"
    case taskRetried = "task.retried"
    case taskDeleted = "task.deleted"
    case taskCompleted = "task.completed"
    case taskFailed = "task.failed"
    case taskStats = "task.stats"
    case taskChained = "task.chained"

    case workerStarted = "worker.started"
    case workerExited = "worker.exited"
    case workerBlocked = "worker.blocked"
    case workerTimeout = "worker.timeout"
    case workerBudgetExceeded = "worker.budget_exceeded"
    case workerSessionStarted = "worker.session_started"
    case workerSessionCleared = "worker.session_cleared"
    case workerPermissionDenied = "worker.permission_denied"
    case workerEnvironmentInjected = "worker.environment_injected"
    case runtimeCommandPlanned = "runtime.command_planned"
    case runtimeModelSelection = "runtime.model_selection"
    case runtimeModelAvailability = "runtime.model_availability"
    case runtimeProviderDetected = "runtime.provider_detected"
    case runtimeStreamSummary = "runtime.stream_summary"
    case runtimeUnknownEvent = "runtime.unknown_event"
    case runtimeEmptyOutput = "runtime.empty_output"
    case runtimeFailureDiagnostic = "runtime.failure_diagnostic"
    case runtimePersistenceSummary = "runtime.persistence_summary"
    case runtimeProgressState = "runtime.progress_state"
    case runtimeStreamDebug = "runtime.stream_debug"
    case runtimeStreamDebugSample = "runtime.stream_debug_sample"
    case contextStateUpdated = "context.state_updated"
    case contextPromptDiagnostics = "context.prompt_diagnostics"

    case planCreated = "plan.created"
    case planUpdated = "plan.updated"
    case planApproved = "plan.approved"
    case planCancelled = "plan.cancelled"
    case planExecutionStarted = "plan.execution.started"
    case planExecutionCompleted = "plan.execution.completed"
    case planExecutionFailed = "plan.execution.failed"
    case planStepStateChanged = "plan.step.state_changed"
    case planStepBlocked = "plan.step.blocked"

    case specExtractionStarted = "spec.extraction_started"
    case specExtractionCompleted = "spec.extraction_completed"
    case specExtractionFailed = "spec.extraction_failed"
    case skillGenerated = "skill.generated"

    case validationStarted = "validation.started"
    case validationPassed = "validation.passed"
    case validationFailed = "validation.failed"
    case validationError = "validation.error"
    case validationContractCreated = "validation.contract.created"
    case validationContractUpdated = "validation.contract.updated"
    case validationAssertionDefined = "validation.assertion.defined"
    case validationAssertionStarted = "validation.assertion.started"
    case validationAssertionPassed = "validation.assertion.passed"
    case validationAssertionFailed = "validation.assertion.failed"
    case validationAssertionSkipped = "validation.assertion.skipped"
    case validationAssertionReviewed = "validation.assertion.reviewed"
    case validationContractPassed = "validation.contract.passed"
    case validationContractFailed = "validation.contract.failed"
    case validationBehaviorStarted = "validation.behavior.started"
    case validationBehaviorPassed = "validation.behavior.passed"
    case validationBehaviorFailed = "validation.behavior.failed"
    case validationBehaviorEvidenceAttached = "validation.behavior.evidence.attached"
    case deliverableVerificationPassed = "deliverable.verification.passed"
    case deliverableVerificationReviewNeeded = "deliverable.verification.review_needed"
    case deliverableVerificationFailed = "deliverable.verification.failed"
    case verifierStarted = "verifier.started"
    case verifierCompleted = "verifier.completed"
    case verifierFailed = "verifier.failed"
    case handoffCreated = "handoff.created"
    case handoffUpdated = "handoff.updated"
    case handoffMissing = "handoff.missing"
    case correctiveStepCreated = "corrective.step.created"
    case correctiveStepApproved = "corrective.step.approved"
    case correctiveStepDismissed = "corrective.step.dismissed"
    case correctiveTaskCreated = "corrective.task.created"
    case resourceLockRequested = "resource.lock.requested"
    case resourceLockWaiting = "resource.lock.waiting"
    case resourceLockAcquired = "resource.lock.acquired"
    case resourceLockReleased = "resource.lock.released"
    case missionActionApproved = "mission.action.approved"
    case missionActionDismissed = "mission.action.dismissed"
    case missionActionRetryRequested = "mission.action.retry_requested"
    case missionActionCorrectionCreated = "mission.action.correction_created"
    case missionMilestoneCreated = "mission.milestone.created"
    case missionMilestoneCompleted = "mission.milestone.completed"
    case missionCheckpointCreated = "mission.checkpoint.created"
    case missionAuditBundleCreated = "mission.audit_bundle.created"
    case roleProfileSelected = "role.profile.selected"
    case roleProfileChanged = "role.profile.changed"

    case connectorCreated = "connector.created"
    case connectorUpdated = "connector.updated"
    case connectorDeleted = "connector.deleted"
    case connectorSecretAdded = "connector.secret.added"
    case connectorSecretRemoved = "connector.secret.removed"
    case connectorTested = "connector.tested"

    case skillCreated = "skill.created"
    case skillDeleted = "skill.deleted"
    case skillSecretAdded = "skill.secret.added"
    case skillSecretRemoved = "skill.secret.removed"
    case skillToolPermissionChanged = "skill.tool_permission.changed"
    case localToolCreated = "local_tool.created"
    case localToolUpdated = "local_tool.updated"
    case localToolDeleted = "local_tool.deleted"
    case localToolTested = "local_tool.tested"
    case templateCreated = "template.created"
    case templateDeleted = "template.deleted"

    case pluginInstalled = "plugin.installed"
    case capabilityInstalled = "capability.installed"
    case capabilityEnableStarted = "capability.enable_started"
    case capabilityEnableFailed = "capability.enable_failed"
    case capabilityEnabled = "capability.enabled"
    case capabilityApprovalChanged = "capability.approval_changed"
    case capabilityDisableStarted = "capability.disable_started"
    case capabilityDisabled = "capability.disabled"
    case capabilityChatContext = "capability.chat_context"
    case capabilityResolved = "capability.resolved"
    case capabilityRuntimeIntegrity = "capability.runtime_integrity"
    case workspaceImported = "workspace.imported"
    case workspaceExported = "workspace.exported"
    case workspaceRecovered = "workspace.recovered"
    case workspaceRecoveryFailed = "workspace.recovery_failed"
    case workspaceStoreBackedUp = "workspace.store_backed_up"
    case workspaceStoreMigrated = "workspace.store_migrated"

    case keychainSaveFailed = "keychain.save_failed"
    case keychainDeleteFailed = "keychain.delete_failed"
    case keychainSecretsMigrated = "keychain.secrets_migrated"

    case isolationPrepared = "isolation.prepared"
    case isolationCleanedUp = "isolation.cleaned_up"
    case isolationFailed = "isolation.failed"
    case sandboxApplied = "sandbox.applied"
    case sandboxSkipped = "sandbox.skipped"
    case sandboxFallback = "sandbox.fallback"
    case sandboxFailed = "sandbox.failed"
    case gitBranchCreated = "git.branch_created"
    case gitStageFile = "git.stage_file"
    case gitUnstageFile = "git.unstage_file"
    case gitCommit = "git.commit"
    case gitPush = "git.push"
    case gitPull = "git.pull"
    case gitCheckout = "git.checkout"
    case gitStatusRefresh = "git.status_refresh"
    case gitAuthoringStarted = "git.authoring_started"
    case gitAuthoringCompleted = "git.authoring_completed"
    case gitAuthoringFailed = "git.authoring_failed"
    case gitPullRequestLookup = "git.pull_request_lookup"
    case gitPullRequestCreate = "git.pull_request_create"
    case gitPullRequestComments = "git.pull_request_comments"
    case gitPullRequestAddressTask = "git.pull_request_address_task"
    case gitRepositoryScan = "git.repository_scan"
    case gitActiveRepositoryChanged = "git.active_repository_changed"
    case gitChangedFileOpenedInShelf = "git.changed_file_opened_in_shelf"
    case gitChangedFileDiffViewed = "git.changed_file_diff_viewed"

    case schedulerStarted = "scheduler.started"
    case schedulerStopped = "scheduler.stopped"
    case scheduleFired = "schedule.fired"

    case appUpdateCheckStarted = "app_update.check_started"
    case appUpdateAvailable = "app_update.available"
    case appUpdateNotAvailable = "app_update.not_available"
    case appUpdateBlocked = "app_update.blocked"
    case appUpdateBackupCreated = "app_update.backup_created"
    case appUpdateInstallRequested = "app_update.install_requested"
    case threadSnapshotBuilt = "thread.snapshot_built"
    case shelfBrowserNavigation = "shelf.browser.navigation"
    case shelfBrowserPreview = "shelf.browser.preview"
    case shelfBrowserContext = "shelf.browser.context"
    case shelfBrowserAction = "shelf.browser.action"
}

enum AuditTrace {
    static func make(_ prefix: String) -> String {
        let cleaned = prefix
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            .lowercased()
        let safePrefix = cleaned.isEmpty ? "trace" : cleaned
        return "\(safePrefix)-\(UUID().uuidString.prefix(8).lowercased())"
    }
}

enum AppLogCategory {
    static let all = [
        "App", "Audit", "Worker", "Queue", "UI", "Isolation", "Validation",
        "Reflection", "SSH", "Persistence", "PluginCatalog", "Scheduler",
        "Keychain", "Updater", "Performance", "Capabilities", "Browser",
        "Diagnostics", "Plan", "Git", "General"
    ]
}

// MARK: - Log Sanitizer

enum LogSanitizer {
    private static let maxMessageLength = 600
    private static let maxFieldLength = 120

    static func sanitize(_ text: String, maxLength: Int = maxMessageLength) -> String {
        var output = text
        output = replace(pattern: #"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, in: output, with: "[redacted-email]")
        output = replace(pattern: #"(?i)\bhttps?://[^/\s:@]+:[^@\s]+@[^\s]+"#, in: output, with: "[redacted-url]")
        output = replace(pattern: #"(?i)(authorization|bearer|token|api[_-]?key|secret|password|credential)\s*[:=]\s*['"]?[^'"\s,;)]+"#, in: output, with: "$1=[redacted-secret]")
        output = replace(pattern: #"\b[A-Z0-9_]*(TOKEN|SECRET|PASSWORD|API_KEY|ACCESS_KEY|PRIVATE_KEY|CREDENTIAL|AUTH)[A-Z0-9_]*\b"#, in: output, with: "[redacted-secret-key]")
        output = replace(pattern: #"/Users/[^,\s\)\"']+"#, in: output, with: "[redacted-path]")
        output = replace(pattern: #"(?<![A-Za-z0-9_])(?:/[A-Za-z0-9._ -]+){2,}"#, in: output, with: "[redacted-path]")
        output = replace(pattern: #"\b[A-Fa-f0-9]{32,}\b"#, in: output, with: "[redacted-token]")
        output = replace(pattern: #"\b[A-Za-z0-9_\-]{40,}\b"#, in: output, with: "[redacted-token]")
        output = output.replacingOccurrences(of: "\n", with: " ")
        output = output.replacingOccurrences(of: "\r", with: " ")
        while output.contains("  ") {
            output = output.replacingOccurrences(of: "  ", with: " ")
        }
        output = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.count > maxLength {
            output = String(output.prefix(maxLength)) + " [truncated]"
        }
        return output
    }

    static func sanitizeFields(_ fields: [String: String], maxLength: Int = maxFieldLength) -> [String: String] {
        fields.reduce(into: [:]) { result, pair in
            let key = sanitizeFieldKey(pair.key)
            result[key] = sanitize(pair.value, maxLength: maxLength)
        }
    }

    private static func sanitizeFieldKey(_ key: String) -> String {
        let cleaned = key
            .filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "field" }
        let upper = cleaned.uppercased()
        if isSafeMetricKey(upper) {
            return cleaned
        }
        if upper.contains("TOKEN") || upper.contains("SECRET") || upper.contains("PASSWORD") || upper.contains("API_KEY") {
            return "redacted_key"
        }
        return cleaned
    }

    private static func isSafeMetricKey(_ upper: String) -> Bool {
        let unsafeFragments = [
            "API_TOKEN",
            "AUTH_TOKEN",
            "ACCESS_TOKEN",
            "REFRESH_TOKEN",
            "BEARER_TOKEN",
            "PRIVATE_TOKEN",
            "SECRET_TOKEN"
        ]
        if unsafeFragments.contains(where: upper.contains) {
            return false
        }
        let safeFragments = [
            "TOKEN_BUDGET",
            "TOKEN_COUNT",
            "TOKENS",
            "ESTIMATED_INPUT_TOKENS",
            "LAUNCH_OVERHEAD_TOKENS",
            "INPUT_TOKENS",
            "OUTPUT_TOKENS",
            "TOTAL_TOKENS"
        ]
        return safeFragments.contains { upper == $0 || upper.contains($0) }
    }

    private static func replace(pattern: String, in text: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
    }
}

// MARK: - Log Entry

struct LogEntry: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let level: String
    let category: String
    let message: String
    let taskID: UUID?

    init(level: LogLevel, category: String, message: String, taskID: UUID? = nil, timestamp: Date = Date()) {
        self.id = UUID()
        self.timestamp = timestamp
        self.level = level.rawValue
        self.category = category
        self.message = message
        self.taskID = taskID
    }

    var logLevel: LogLevel {
        LogLevel(rawValue: level) ?? .info
    }

    var formatted: String {
        let ts = Self.formatter.string(from: timestamp)
        let taskStr = taskID.map { " task:\(String($0.uuidString.prefix(8)))" } ?? ""
        return "[\(ts)] [\(level.uppercased())] [\(category)\(taskStr)] \(message)"
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

// MARK: - AppLogger

enum AppLogger {
    static let sensitiveModeKey = "sensitiveMode"
    private static let maxLogFileSize: UInt64 = 5_000_000
    private static let maxRotatedGenerations = 2
    static let defaultRetentionDays = LoggingPreferences.defaultLogRetentionDays

    static var isSensitiveMode: Bool {
        if UserDefaults.standard.object(forKey: sensitiveModeKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: sensitiveModeKey)
    }

    // os.Logger instances by category
    private static let loggers: [String: os.Logger] = {
        var dict: [String: os.Logger] = [:]
        for cat in AppLogCategory.all {
            dict[cat] = os.Logger(subsystem: AppChannel.current.loggingSubsystem, category: cat)
        }
        return dict
    }()

    static var isRunningTests: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil {
            return true
        }
        let processName = ProcessInfo.processInfo.processName.lowercased()
        if processName.contains("xctest") || processName.contains("packagetests") {
            return true
        }
        if Bundle.main.bundlePath.hasSuffix(".xctest") {
            return true
        }
        if Bundle.allBundles.contains(where: { $0.bundlePath.hasSuffix(".xctest") }) {
            return true
        }
        return ProcessInfo.processInfo.arguments.contains {
            $0.hasSuffix(".xctest") || $0.contains("/xctest") || $0.contains("PackageTests")
        }
    }

    private static let logDir: URL = {
        let dir: URL
        if isRunningTests {
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("AstraTests", isDirectory: true)
                .appendingPathComponent("Logs-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        } else {
            dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs")
                .appendingPathComponent(AppChannel.current.logsDirectoryName)
        }
        ensureDirectory(at: dir)
        return dir
    }()

    static let mainLogFile: URL = logDir.appendingPathComponent("astra.log")
    static let breadcrumbLogFile: URL = logDir.appendingPathComponent("last-actions.jsonl")

    /// In-memory ring buffer of recent entries (last 2000)
    private static let bufferQueue = DispatchQueue(label: "com.astra.logbuffer")
    private static var _entries: [LogEntry] = []
    private static let maxEntries = 2000

    static var entries: [LogEntry] {
        bufferQueue.sync { _entries }
    }

    static var entryCount: Int {
        bufferQueue.sync { _entries.count }
    }

    /// Callback for live UI updates
    static var onNewEntry: ((LogEntry) -> Void)?

    // MARK: - Public API

    static func debug(_ message: String, category: String = "General", taskID: UUID? = nil) {
        emit(.debug, LogSanitizer.sanitize(message), category: category, taskID: taskID)
    }

    static func info(_ message: String, category: String = "General", taskID: UUID? = nil) {
        emit(.info, LogSanitizer.sanitize(message), category: category, taskID: taskID)
    }

    static func warning(_ message: String, category: String = "General", taskID: UUID? = nil) {
        emit(.warning, LogSanitizer.sanitize(message), category: category, taskID: taskID)
    }

    static func error(_ message: String, category: String = "General", taskID: UUID? = nil) {
        emit(.error, LogSanitizer.sanitize(message), category: category, taskID: taskID)
    }

    static func audit(
        _ event: AuditEvent,
        category: String = "Audit",
        taskID: UUID? = nil,
        fields: [String: String] = [:],
        level: LogLevel = .info,
        fieldMaxLength: Int = 120
    ) {
        let safeFields = LogSanitizer.sanitizeFields(fields, maxLength: fieldMaxLength)
        let suffix = safeFields
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        let message = suffix.isEmpty ? event.rawValue : "\(event.rawValue) \(suffix)"
        emit(level, message, category: category, taskID: taskID)
    }

    @discardableResult
    static func breadcrumb(
        action: String,
        category: String = "UI",
        taskID: UUID? = nil,
        traceID: String = AuditTrace.make("ui"),
        fields: [String: String] = [:],
        level: LogLevel = .info,
        fieldMaxLength: Int = 120
    ) -> String {
        var auditFields = fields
        auditFields["action"] = action
        auditFields["trace_id"] = traceID
        audit(.userAction, category: category, taskID: taskID, fields: auditFields, level: level, fieldMaxLength: fieldMaxLength)
        writeBreadcrumb(
            action: action,
            category: category,
            taskID: taskID,
            traceID: traceID,
            level: level,
            fields: LogSanitizer.sanitizeFields(auditFields, maxLength: fieldMaxLength)
        )
        return traceID
    }

    /// Legacy compatibility — parses category from "[Category]" prefix
    static func log(_ message: String) {
        let (category, cleanMessage) = parseCategory(message)
        emit(.info, cleanMessage, category: category, taskID: nil)
    }

    // MARK: - Per-Task Logs

    static func taskLogFile(taskID: UUID) -> URL {
        logDir.appendingPathComponent("task-\(String(taskID.uuidString.prefix(8))).log")
    }

    static func browserFlightLogFile(taskID: UUID?) -> URL {
        let suffix = taskID.map { String($0.uuidString.prefix(8)) } ?? "unbound"
        return logDir.appendingPathComponent("browser-flight-\(suffix).jsonl")
    }

    static func appendBrowserFlightEntry(_ entry: [String: Any], taskID: UUID?) {
        fileQueue.async {
            let url = browserFlightLogFile(taskID: taskID)
            rotateFileIfNeeded(url)
            guard JSONSerialization.isValidJSONObject(entry),
                  let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
                  let line = String(data: data, encoding: .utf8)
            else { return }
            appendToFile(line + "\n", at: url)
            cleanupOldLogsThrottledOnFileQueue()
        }
    }

    static func readTaskLog(taskID: UUID) -> String {
        let path = taskLogFile(taskID: taskID)
        return readLogText(at: path) ?? ""
    }

    static func readBreadcrumbs(maxLines: Int = 100) -> String {
        tailLines(from: breadcrumbLogFile, maxLines: maxLines).joined(separator: "\n")
    }

    private static func readLogText(at url: URL) -> String? {
        try? HostFileAccessBroker().readString(
            at: url,
            encoding: .utf8,
            intent: .astraManagedStorage(root: url.deletingLastPathComponent())
        )
    }

    // MARK: - Log Rotation

    static func rotateIfNeeded() {
        rotateFileIfNeeded(mainLogFile)
        cleanupOldLogs()
    }

    static var configuredRetentionDays: Int {
        LoggingPreferences.logRetentionDays()
    }

    // MARK: - Internal

    /// Serial queue for all file I/O to prevent interleaved writes.
    private static let fileQueue = DispatchQueue(label: "com.astra.logfile")

    private static var lastCleanupAt: Date?
    private static let cleanupThrottleInterval: TimeInterval = 60

    /// Throttled retention cleanup for the hot per-line paths. `cleanupOldLogs`
    /// enumerates the whole log directory and stats each file, which is wasteful
    /// to repeat on every emitted line; once a minute is ample for pruning by
    /// age. Must be called on `fileQueue` (single-threaded access keeps
    /// `lastCleanupAt` race-free without a lock).
    private static func cleanupOldLogsThrottledOnFileQueue(now: Date = Date()) {
        if let last = lastCleanupAt, now.timeIntervalSince(last) < cleanupThrottleInterval {
            return
        }
        lastCleanupAt = now
        cleanupOldLogs(now: now)
    }

    private static func emit(_ level: LogLevel, _ message: String, category: String, taskID: UUID?) {
        let entry = LogEntry(level: level, category: category, message: message, taskID: taskID)

        // os.Logger
        let logger = loggers[category] ?? loggers["General"]!
        logger.log(level: level.osLogType, "\(message, privacy: .public)")

        // Ring buffer
        bufferQueue.async {
            _entries.append(entry)
            if _entries.count > maxEntries {
                _entries.removeFirst(_entries.count - maxEntries)
            }
        }

        // File logging — serialized to prevent interleaved writes
        let line = entry.formatted + "\n"
        fileQueue.async {
            rotateFileIfNeeded(mainLogFile)
            appendToFile(line, at: mainLogFile)
            if let tid = taskID {
                let taskLog = taskLogFile(taskID: tid)
                rotateFileIfNeeded(taskLog)
                appendToFile(line, at: taskLog)
            }
            cleanupOldLogsThrottledOnFileQueue()
        }

        // Live callback — dispatch to main thread for UI safety
        if let callback = onNewEntry {
            DispatchQueue.main.async {
                callback(entry)
            }
        }

        NotificationCenter.default.post(
            name: .appLoggerDidAppendEntry,
            object: nil,
            userInfo: ["entry": entry]
        )

        if !isSensitiveMode {
            print(entry.formatted, terminator: "\n")
        }
    }

    /// Append text to a log file. Must be called on `fileQueue`.
    private static func appendToFile(_ text: String, at url: URL) {
        guard let data = text.data(using: .utf8) else { return }
        ensureDirectory(at: url.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            FileManager.default.createFile(atPath: url.path, contents: data, attributes: [
                .posixPermissions: 0o600
            ])
        }
    }

    private static func writeBreadcrumb(
        action: String,
        category: String,
        taskID: UUID?,
        traceID: String,
        level: LogLevel,
        fields: [String: String]
    ) {
        var record: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "level": level.rawValue,
            "category": category,
            "action": LogSanitizer.sanitize(action, maxLength: 80),
            "trace_id": traceID,
            "fields": fields
        ]
        if let taskID {
            record["task_id"] = taskID.uuidString
        }

        fileQueue.async {
            guard JSONSerialization.isValidJSONObject(record),
                  let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
                  let line = String(data: data, encoding: .utf8)
            else { return }
            appendToFile(line + "\n", at: breadcrumbLogFile)
            trimFile(breadcrumbLogFile, maxLines: 100)
        }
    }

    private static func tailLines(from url: URL, maxLines: Int) -> [String] {
        guard maxLines > 0,
              let text = readLogText(at: url) else { return [] }
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(maxLines)
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// Trim a log-like file to the last N lines. Must be called on `fileQueue`.
    private static func trimFile(_ url: URL, maxLines: Int) {
        guard maxLines > 0,
              let text = readLogText(at: url) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > maxLines else { return }
        let trimmed = lines.suffix(maxLines).map(String.init).joined(separator: "\n") + "\n"
        try? trimmed.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func ensureDirectory(at url: URL) {
        let attrs: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: attrs)
        try? FileManager.default.setAttributes(attrs, ofItemAtPath: url.path)
    }

    private static func rotateFileIfNeeded(_ url: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64,
              size > maxLogFileSize else { return }

        for index in stride(from: maxRotatedGenerations, through: 1, by: -1) {
            let source = rotatedURL(for: url, generation: index)
            let destination = rotatedURL(for: url, generation: index + 1)
            if index == maxRotatedGenerations {
                try? FileManager.default.removeItem(at: source)
            } else if FileManager.default.fileExists(atPath: source.path) {
                try? FileManager.default.removeItem(at: destination)
                try? FileManager.default.moveItem(at: source, to: destination)
            }
        }
        let first = rotatedURL(for: url, generation: 1)
        try? FileManager.default.removeItem(at: first)
        try? FileManager.default.moveItem(at: url, to: first)
    }

    private static func rotatedURL(for url: URL, generation: Int) -> URL {
        let ext = url.pathExtension
        let base = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        let name = ext.isEmpty ? "\(base).\(generation)" : "\(base).\(generation).\(ext)"
        return url.deletingLastPathComponent().appendingPathComponent(name)
    }

    private static func cleanupOldLogs(now: Date = Date()) {
        guard let files = try? HostFileAccessBroker().contentsOfDirectory(
            at: logDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            intent: .astraManagedStorage(root: logDir)
        ) else { return }
        let retentionSeconds = TimeInterval(configuredRetentionDays) * 24 * 60 * 60
        let cutoff = now.addingTimeInterval(-retentionSeconds)
        for file in files where ["log", "jsonl"].contains(file.pathExtension) {
            guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    #if DEBUG
    static func resetForTesting() {
        bufferQueue.sync {
            _entries.removeAll()
        }
    }

    static func flushForTesting() {
        bufferQueue.sync {}
        fileQueue.sync {}
    }
    #endif

    private static func parseCategory(_ message: String) -> (String, String) {
        // Parse "[Worker] message" -> ("Worker", "message")
        guard message.hasPrefix("["),
              let closeBracket = message.firstIndex(of: "]") else {
            return ("General", message)
        }
        let cat = String(message[message.index(after: message.startIndex)..<closeBracket])
        let rest = String(message[message.index(after: closeBracket)...]).trimmingCharacters(in: .whitespaces)
        return (cat, rest)
    }
}

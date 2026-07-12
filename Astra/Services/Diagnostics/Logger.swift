import Foundation
import os
import ASTRAPersistence
import ASTRACore
import ASTRAModels
@_exported import ASTRALogging

// MARK: - AppLogger
//
// `LogLevel`, `AuditEvent`, `AuditTrace`, `AppLogCategory`, `LogSanitizer`,
// and `LogEntry` (plus the `Notification.Name.appLoggerDidAppendEntry`
// extension) live in the `ASTRALogging` leaf SwiftPM target — they depend on
// nothing but Foundation/os. The `@_exported import` above re-exports them
// here so every existing call site across the app (hundreds of files)
// keeps working unqualified, with no per-file import changes required.
//
// `AppLogger` itself stays in the app target: it needs `AppChannel`/
// `LoggingPreferences` (Services/Settings) for channel-scoped subsystem/
// directory naming and `HostFileAccessBroker` (Services/Security) for
// sandboxed file reads, neither of which belongs in a dependency-free leaf
// target. See docs/architecture/swiftpm-target-extraction-models-persistence.md.

enum AppLogger: Sendable {
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
        let line = entry.persistedFormatted + "\n"
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

import Foundation
import ASTRACore
import ASTRAModels

struct LogDiagnosticsIssue: Equatable, Identifiable {
    let id: String
    let title: String
    let severity: LogLevel
    let signal: String
    let count: Int
    let affectedTasks: [String]
    let evidence: [String]
    let analysis: String
    let firstSeenAt: Date
    let lastSeenAt: Date
    let freshness: LogDiagnosticsFreshness
}

struct LogDiagnosticsNotice: Equatable, Identifiable {
    let id: String
    let title: String
    let signal: String
    let count: Int
    let evidence: [String]
    let analysis: String
    let firstSeenAt: Date
    let lastSeenAt: Date
}

private struct PreviousDiagnosticsContext: Equatable {
    let generatedAt: Date
    let entryCount: Int
    let errorCount: Int
    let warningCount: Int
    let issueCount: Int
}

private struct LogDiagnosticsTraceSummary: Equatable {
    let id: String
    let count: Int
    let firstSeenAt: Date
    let lastSeenAt: Date
    let categories: [String]
    let sources: [String]
    let actions: [String]
    let affectedTasks: [String]
    let evidence: [String]
}

struct LogDiagnosticsReport: Equatable {
    let generatedAt: Date
    let scope: LogDiagnosticsScope
    let analysisStart: Date?
    let analysisEnd: Date?
    let previousGeneratedAt: Date?
    let entryCount: Int
    let errorCount: Int
    let warningCount: Int
    let issueCount: Int
    let issueFingerprints: [String]
    let issues: [LogDiagnosticsIssue]
    let notices: [LogDiagnosticsNotice]
    let crashReports: [CrashReportSummary]
    let markdown: String
}

struct LogDiagnosticsArchiveResult: Equatable {
    let url: URL
    let artifactCount: Int
    let crashReportCount: Int
    let includedRelativePaths: [String]
}

enum LogDiagnosticsFreshness: String, Codable, Equatable {
    case new
    case recurring
    case old

    var label: String { rawValue }
}

enum LogDiagnosticsScope: String, Codable, CaseIterable, Identifiable {
    case sinceLastReport
    case last15Minutes
    case lastHour
    case today
    case allRetained

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sinceLastReport: "Since last report"
        case .last15Minutes: "Last 15 minutes"
        case .lastHour: "Last hour"
        case .today: "Today"
        case .allRetained: "All retained logs"
        }
    }
}

struct LogDiagnosticsHistory: Equatable {
    var lastGeneratedAt: Date?
    var knownIssueFingerprints: Set<String>

    static let empty = LogDiagnosticsHistory(lastGeneratedAt: nil, knownIssueFingerprints: [])
}

enum LogDiagnosticsService {
    static let maxIssueGroups = 12
    static let maxEvidenceLinesPerIssue = 14
    static let maxMainLogLines = 5_000
    static let maxTaskLogLines = 300
    static let maxTaskLogFiles = 30
    static let maxArchiveLogFiles = 80
    static let maxArchiveCrashReports = 50
    private static let permissionWarningQuietThreshold: TimeInterval = 5 * 60
    private static let historyLastGeneratedAtKey = "astra.diagnostics.history.lastGeneratedAt.v1"
    private static let historyKnownFingerprintsKey = "astra.diagnostics.history.knownFingerprints.v1"

    static func collectCurrentEntries(
        inMemoryEntries: [LogEntry] = AppLogger.entries,
        logDirectory: URL = AppLogger.mainLogFile.deletingLastPathComponent()
    ) -> [LogEntry] {
        var collected = inMemoryEntries
        var seen = Set(inMemoryEntries.map(entrySignature))

        for file in diagnosticLogFiles(in: logDirectory) {
            let isAppLog = isAppLogFile(file)
            if isAppLog, !inMemoryEntries.isEmpty {
                continue
            }
            let maxLines = file.lastPathComponent.hasPrefix("task-") ? maxTaskLogLines : maxMainLogLines
            for line in tailLines(from: file, maxLines: maxLines) {
                guard let entry = parseLogLine(line, dateAnchor: modificationDate(file)) else { continue }
                let signature = entrySignature(entry)
                guard !seen.contains(signature) else { continue }
                seen.insert(signature)
                collected.append(entry)
            }
        }
        return collected
    }

    static func makeReport(
        entries: [LogEntry],
        generatedAt: Date = Date(),
        scope: LogDiagnosticsScope = .allRetained,
        history: LogDiagnosticsHistory = .empty,
        crashReports: [CrashReportSummary] = []
    ) -> LogDiagnosticsReport {
        let orderedEntries = analyzedEntries(
            entries,
            generatedAt: generatedAt,
            scope: scope,
            history: history
        )
        let previousDiagnosticsContext = previousDiagnosticsContext(
            from: entries,
            generatedAt: generatedAt,
            scope: scope,
            previousGeneratedAt: history.lastGeneratedAt
        )
        let issueGroups = buildIssueGroups(
            from: orderedEntries,
            generatedAt: generatedAt,
            previousGeneratedAt: history.lastGeneratedAt,
            knownIssueFingerprints: history.knownIssueFingerprints
        )
        let visibleIssues = Array(issueGroups.prefix(maxIssueGroups))
        let notices = buildNotices(from: orderedEntries)
        let markdown = renderMarkdown(
            entries: orderedEntries,
            generatedAt: generatedAt,
            scope: scope,
            previousGeneratedAt: history.lastGeneratedAt,
            previousDiagnosticsContext: previousDiagnosticsContext,
            issues: visibleIssues,
            notices: notices,
            crashReports: crashReports,
            omittedIssueCount: max(0, issueGroups.count - visibleIssues.count)
        )

        return LogDiagnosticsReport(
            generatedAt: generatedAt,
            scope: scope,
            analysisStart: orderedEntries.first?.timestamp,
            analysisEnd: orderedEntries.last?.timestamp,
            previousGeneratedAt: history.lastGeneratedAt,
            entryCount: orderedEntries.count,
            errorCount: orderedEntries.filter { $0.logLevel == .error }.count,
            warningCount: orderedEntries.filter { $0.logLevel == .warning }.count,
            issueCount: issueGroups.count,
            issueFingerprints: issueGroups.map(\.id).sorted(),
            issues: visibleIssues,
            notices: notices,
            crashReports: crashReports,
            markdown: markdown
        )
    }

    static func analyzedEntries(
        _ entries: [LogEntry],
        generatedAt: Date = Date(),
        scope: LogDiagnosticsScope = .allRetained,
        history: LogDiagnosticsHistory = .empty
    ) -> [LogEntry] {
        uniqueDiagnosticEntries(filteredEntries(
            entries,
            scope: scope,
            generatedAt: generatedAt,
            previousGeneratedAt: history.lastGeneratedAt
        ).sorted { $0.timestamp < $1.timestamp })
    }

    static func filteredEntries(
        _ entries: [LogEntry],
        scope: LogDiagnosticsScope,
        generatedAt: Date = Date(),
        previousGeneratedAt: Date? = nil,
        calendar: Calendar = .current
    ) -> [LogEntry] {
        let start: Date?
        switch scope {
        case .sinceLastReport:
            start = previousGeneratedAt
        case .last15Minutes:
            start = generatedAt.addingTimeInterval(-15 * 60)
        case .lastHour:
            start = generatedAt.addingTimeInterval(-60 * 60)
        case .today:
            start = calendar.startOfDay(for: generatedAt)
        case .allRetained:
            start = nil
        }

        guard let start else { return entries }
        return entries.filter { $0.timestamp >= start && $0.timestamp <= generatedAt }
    }

    static func analysisDateInterval(
        scope: LogDiagnosticsScope,
        generatedAt: Date = Date(),
        previousGeneratedAt: Date? = nil,
        calendar: Calendar = .current
    ) -> DateInterval? {
        let start: Date?
        switch scope {
        case .sinceLastReport:
            start = previousGeneratedAt
        case .last15Minutes:
            start = generatedAt.addingTimeInterval(-15 * 60)
        case .lastHour:
            start = generatedAt.addingTimeInterval(-60 * 60)
        case .today:
            start = calendar.startOfDay(for: generatedAt)
        case .allRetained:
            start = nil
        }

        guard let start else { return nil }
        let boundedStart = min(start, generatedAt)
        return DateInterval(start: boundedStart, end: generatedAt)
    }

    static func writeReport(
        _ report: LogDiagnosticsReport,
        directory: URL = defaultDiagnosticsDirectory()
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [
            .posixPermissions: 0o700
        ])
        let url = directory.appendingPathComponent("ASTRA-Diagnostics-\(fileTimestamp(report.generatedAt)).md")
        try report.markdown.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    static func writeArchive(
        report: LogDiagnosticsReport,
        analyzedEntries: [LogEntry],
        analysisInterval: DateInterval?,
        logDirectory: URL = AppLogger.mainLogFile.deletingLastPathComponent(),
        directory: URL = defaultDiagnosticsDirectory(),
        crashReports: [CrashReportSummary] = [],
        fileManager: FileManager = .default
    ) throws -> LogDiagnosticsArchiveResult {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [
            .posixPermissions: 0o700
        ])

        let archiveName = "ASTRA-Diagnostics-\(fileTimestamp(report.generatedAt))"
        let stagingParent = directory.appendingPathComponent(".staging-\(archiveName)-\(UUID().uuidString)", isDirectory: true)
        let stagingRoot = stagingParent.appendingPathComponent(archiveName, isDirectory: true)
        defer { try? fileManager.removeItem(at: stagingParent) }

        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true, attributes: [
            .posixPermissions: 0o700
        ])

        var includedRelativePaths: [String] = []
        func record(_ url: URL) {
            let rootPath = stagingRoot.path + "/"
            if url.path.hasPrefix(rootPath) {
                includedRelativePaths.append(String(url.path.dropFirst(rootPath.count)))
            }
        }

        let reportURL = stagingRoot.appendingPathComponent("ASTRA-Diagnostics-\(fileTimestamp(report.generatedAt)).md")
        try report.markdown.write(to: reportURL, atomically: true, encoding: .utf8)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: reportURL.path)
        record(reportURL)

        let entriesURL = stagingRoot
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("analyzed-log-entries.jsonl")
        try writeAnalyzedEntries(analyzedEntries, to: entriesURL, fileManager: fileManager)
        record(entriesURL)

        let manifestURL = stagingRoot.appendingPathComponent("manifest.json")
        try writeArchiveManifest(
            report: report,
            analysisInterval: analysisInterval,
            analyzedEntries: analyzedEntries,
            crashReports: crashReports,
            logDirectory: logDirectory,
            to: manifestURL,
            fileManager: fileManager
        )
        record(manifestURL)

        let readmeURL = stagingRoot.appendingPathComponent("README.txt")
        try archiveReadme(report: report, analysisInterval: analysisInterval)
            .write(to: readmeURL, atomically: true, encoding: .utf8)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: readmeURL.path)
        record(readmeURL)

        for file in archiveLogFiles(in: logDirectory, interval: analysisInterval, fileManager: fileManager) {
            if let copied = try copyArtifact(file, into: stagingRoot.appendingPathComponent("logs", isDirectory: true), fileManager: fileManager) {
                record(copied)
            }
        }

        for report in crashReports.prefix(maxArchiveCrashReports) {
            if let copied = try copyArtifact(report.url, into: stagingRoot.appendingPathComponent("crashes", isDirectory: true), fileManager: fileManager) {
                record(copied)
            }
        }

        let archiveURL = directory.appendingPathComponent("\(archiveName).zip")
        if fileManager.fileExists(atPath: archiveURL.path) {
            try fileManager.removeItem(at: archiveURL)
        }
        try createZipArchive(from: stagingRoot, to: archiveURL)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archiveURL.path)

        return LogDiagnosticsArchiveResult(
            url: archiveURL,
            artifactCount: includedRelativePaths.count,
            crashReportCount: min(crashReports.count, maxArchiveCrashReports),
            includedRelativePaths: includedRelativePaths.sorted()
        )
    }

    static func loadHistory(defaults: UserDefaults = .standard) -> LogDiagnosticsHistory {
        let timestamp = defaults.object(forKey: historyLastGeneratedAtKey) as? Double
        let known = defaults.stringArray(forKey: historyKnownFingerprintsKey) ?? []
        return LogDiagnosticsHistory(
            lastGeneratedAt: timestamp.map(Date.init(timeIntervalSince1970:)),
            knownIssueFingerprints: Set(known)
        )
    }

    static func saveHistory(from report: LogDiagnosticsReport, defaults: UserDefaults = .standard) {
        let known = Set(defaults.stringArray(forKey: historyKnownFingerprintsKey) ?? [])
            .union(report.issueFingerprints)
        defaults.set(report.generatedAt.timeIntervalSince1970, forKey: historyLastGeneratedAtKey)
        defaults.set(Array(known).sorted(), forKey: historyKnownFingerprintsKey)
    }

    static func defaultDiagnosticsDirectory() -> URL {
        AppLogger.mainLogFile
            .deletingLastPathComponent()
            .appendingPathComponent("Diagnostics", isDirectory: true)
    }

    private static func writeAnalyzedEntries(
        _ entries: [LogEntry],
        to url: URL,
        fileManager: FileManager
    ) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let lines = entries.map { entry -> String in
            let object: [String: Any] = [
                "timestamp": archiveISOFormatter.string(from: entry.timestamp),
                "level": entry.level,
                "category": entry.category,
                "taskID": entry.taskID?.uuidString ?? "",
                "message": LogSanitizer.sanitize(entry.message, maxLength: 1_200)
            ]
            guard JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                  let line = String(data: data, encoding: .utf8)
            else {
                return ""
            }
            return line
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
        try (lines + (lines.isEmpty ? "" : "\n")).write(to: url, atomically: true, encoding: .utf8)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func writeArchiveManifest(
        report: LogDiagnosticsReport,
        analysisInterval: DateInterval?,
        analyzedEntries: [LogEntry],
        crashReports: [CrashReportSummary],
        logDirectory: URL,
        to url: URL,
        fileManager: FileManager
    ) throws {
        let logFiles = archiveLogFiles(in: logDirectory, interval: analysisInterval, fileManager: fileManager)
        let manifest: [String: Any] = [
            "formatVersion": 1,
            "generatedAt": archiveISOFormatter.string(from: report.generatedAt),
            "scope": report.scope.rawValue,
            "scopeLabel": report.scope.label,
            "analysisInterval": archiveIntervalObject(analysisInterval),
            "analyzedEntryCount": analyzedEntries.count,
            "errorCount": report.errorCount,
            "warningCount": report.warningCount,
            "issueCount": report.issueCount,
            "noticeCount": report.notices.count,
            "appChannel": AppChannel.current.displayName,
            "appBuild": AppBuildInfo.current.provenanceSummary,
            "sensitiveMode": AppLogger.isSensitiveMode,
            "logDirectory": CrashDiagnosticsService.userFacingPath(logDirectory),
            "artifactKinds": [
                "markdown_report",
                "manifest",
                "analyzed_log_entries_jsonl",
                "app_and_task_logs",
                "browser_flight_logs_when_present",
                "macos_crash_reports_when_present",
                "macos_crash_hang_reports_when_present",
                "macos_diagnostic_reports_when_present"
            ],
            "sourceLogFiles": logFiles.map { file in
                [
                    "name": file.lastPathComponent,
                    "path": CrashDiagnosticsService.userFacingPath(file),
                    "modifiedAt": archiveISOFormatter.string(from: modificationDate(file)),
                    "sizeBytes": fileSize(file, fileManager: fileManager)
                ] as [String: Any]
            },
            "crashReports": crashReports.prefix(maxArchiveCrashReports).map { report in
                [
                    "name": report.fileName,
                    "appName": report.appName,
                    "kind": report.kind.rawValue,
                    "path": report.displayPath,
                    "modifiedAt": archiveISOFormatter.string(from: report.modifiedAt),
                    "sizeBytes": report.sizeBytes
                ] as [String: Any]
            }
        ]
        try writeJSONObject(manifest, to: url, fileManager: fileManager)
    }

    private static func archiveReadme(report: LogDiagnosticsReport, analysisInterval: DateInterval?) -> String {
        let intervalText: String
        if let analysisInterval {
            intervalText = "\(displayTimestamp(analysisInterval.start)) to \(displayTimestamp(analysisInterval.end))"
        } else {
            intervalText = "all retained ASTRA diagnostic logs"
        }
        return """
        ASTRA Diagnostics Bundle

        Generated: \(displayTimestamp(report.generatedAt))
        Scope: \(report.scope.label)
        Time window: \(intervalText)

        Contents:
        - ASTRA-Diagnostics-*.md: sanitized human-readable diagnostics report.
        - manifest.json: machine-readable index of included diagnostics artifacts.
        - logs/analyzed-log-entries.jsonl: sanitized log entries used by the report.
        - logs/*.log and logs/browser-flight-*.jsonl: relevant app, task, breadcrumb, and browser debug artifacts from the selected time window.
        - crashes/*.ips, *.crash, *.hang, or *.spin: matching macOS diagnostic reports from the selected time window, when present.

        Browser flight logs may include compact page evidence and screenshot thumbnails only when Browser Debug Capture was enabled.
        """
    }

    private static func writeJSONObject(_ object: [String: Any], to url: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func archiveIntervalObject(_ interval: DateInterval?) -> Any {
        guard let interval else { return NSNull() }
        return [
            "start": archiveISOFormatter.string(from: interval.start),
            "end": archiveISOFormatter.string(from: interval.end)
        ]
    }

    private static func archiveLogFiles(
        in directory: URL,
        interval: DateInterval?,
        fileManager: FileManager
    ) -> [URL] {
        let broker = HostFileAccessBroker(fileManager: fileManager)
        guard let files = try? broker.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles],
            intent: .astraManagedStorage(root: directory)
        ) else { return [] }

        return Array(files
            .filter { file in
                guard isArchiveDiagnosticFile(file),
                      let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                      values.isRegularFile == true else {
                    return false
                }
                guard let interval else { return true }
                let modified = values.contentModificationDate ?? .distantPast
                return modified >= interval.start && modified <= interval.end
            }
            .sorted { lhs, rhs in
                let lhsDate = modificationDate(lhs)
                let rhsDate = modificationDate(rhs)
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return lhs.lastPathComponent < rhs.lastPathComponent
            }
            .prefix(maxArchiveLogFiles))
    }

    private static func isArchiveDiagnosticFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name == "astra.log"
            || name == AppLogger.breadcrumbLogFile.lastPathComponent
            || (name.hasPrefix("astra.") && name.hasSuffix(".log"))
            || (name.hasPrefix("task-") && name.hasSuffix(".log"))
            || (name.hasPrefix("browser-flight-") && name.hasSuffix(".jsonl"))
    }

    private static func copyArtifact(_ source: URL, into directory: URL, fileManager: FileManager) throws -> URL? {
        guard let values = try? source.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else {
            return nil
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [
            .posixPermissions: 0o700
        ])
        let destination = uniqueDestination(for: source.lastPathComponent, in: directory, fileManager: fileManager)
        try fileManager.copyItem(at: source, to: destination)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return destination
    }

    private static func uniqueDestination(for fileName: String, in directory: URL, fileManager: FileManager) -> URL {
        let safeName = fileName.isEmpty ? "artifact" : fileName
        let original = directory.appendingPathComponent(safeName)
        guard fileManager.fileExists(atPath: original.path) else { return original }

        let ext = original.pathExtension
        let base = ext.isEmpty ? original.lastPathComponent : original.deletingPathExtension().lastPathComponent
        for index in 2...999 {
            let candidateName = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return directory.appendingPathComponent("\(UUID().uuidString)-\(safeName)")
    }

    private static func createZipArchive(from stagingRoot: URL, to archiveURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.currentDirectoryURL = stagingRoot.deletingLastPathComponent()
        process.arguments = [
            "-c",
            "-k",
            "--sequesterRsrc",
            "--keepParent",
            stagingRoot.lastPathComponent,
            archiveURL.path
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw ZipArchiveError(status: process.terminationStatus, output: output)
        }
    }

    private struct ZipArchiveError: LocalizedError {
        let status: Int32
        let output: String

        var errorDescription: String? {
            let suffix = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if suffix.isEmpty {
                return "Failed to create diagnostics zip with status \(status)."
            }
            return "Failed to create diagnostics zip with status \(status): \(LogSanitizer.sanitize(suffix))"
        }
    }

    private struct IssueBucket {
        let key: String
        var title: String
        var severity: LogLevel
        var signal: String
        var indexes: [Int]
        var affectedTasks: Set<String>
        var analysis: String
    }

    private struct NoticeBucket {
        let key: String
        var title: String
        var signal: String
        var indexes: [Int]
        var analysis: String
    }

    private static func previousDiagnosticsContext(
        from entries: [LogEntry],
        generatedAt: Date,
        scope: LogDiagnosticsScope,
        previousGeneratedAt: Date?
    ) -> PreviousDiagnosticsContext? {
        guard scope == .sinceLastReport,
              let previousGeneratedAt else {
            return nil
        }

        let lookback = previousGeneratedAt.addingTimeInterval(-5 * 60)
        let candidates = entries.filter { entry in
            let lower = entry.message.lowercased()
            return lower.contains(AuditEvent.diagnosticsGenerated.rawValue)
                && entry.timestamp >= lookback
                && entry.timestamp <= previousGeneratedAt.addingTimeInterval(1)
        }
        return candidates.compactMap { previous -> PreviousDiagnosticsContext? in
            let issueCount = intField("issues", in: previous.message)
            let errorCount = intField("errors", in: previous.message)
            let warningCount = intField("warnings", in: previous.message)
            guard issueCount > 0 || errorCount > 0 || warningCount > 0 else {
                return nil
            }
            return PreviousDiagnosticsContext(
                generatedAt: previous.timestamp,
                entryCount: intField("entries", in: previous.message),
                errorCount: errorCount,
                warningCount: warningCount,
                issueCount: issueCount
            )
        }
        .max { $0.generatedAt < $1.generatedAt }
    }

    private static func buildIssueGroups(
        from entries: [LogEntry],
        generatedAt: Date,
        previousGeneratedAt: Date?,
        knownIssueFingerprints: Set<String>
    ) -> [LogDiagnosticsIssue] {
        var buckets: [String: IssueBucket] = [:]
        var seenIssueEvents: Set<String> = []

        for (index, entry) in entries.enumerated() {
            if isRecoveredOrPendingPermissionWarning(entry, entries: entries, generatedAt: generatedAt) {
                continue
            }
            if isResolvedPlanBlocker(entry, entries: entries) {
                continue
            }
            if isGenericRuntimeWarningCoveredBySpecificFailure(entry, entries: entries) {
                continue
            }
            if classifyNotice(entry, index: index, entries: entries) != nil {
                continue
            }
            if isValidationBehaviorFailureCoveredByAssertionOutcome(entry, index: index, entries: entries) {
                continue
            }
            guard let classification = classifyConnectorCredentialRegression(
                entry,
                index: index,
                entries: entries
            ) ?? classify(entry) else { continue }
            let signature = diagnosticEventSignature(for: entry, classificationKey: classification.key)
            guard seenIssueEvents.insert(signature).inserted else { continue }
            let task = taskIdentifier(for: entry)
            var bucket = buckets[classification.key] ?? IssueBucket(
                key: classification.key,
                title: classification.title,
                severity: classification.severity,
                signal: classification.signal,
                indexes: [],
                affectedTasks: [],
                analysis: classification.analysis
            )
            bucket.severity = maxSeverity(bucket.severity, classification.severity)
            bucket.indexes.append(index)
            if let task { bucket.affectedTasks.insert(task) }
            buckets[classification.key] = bucket
        }

        return buckets.values
            .sorted { lhs, rhs in
                if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
                if lhs.indexes.count != rhs.indexes.count { return lhs.indexes.count > rhs.indexes.count }
                return lhs.title < rhs.title
            }
            .map { bucket in
                let firstSeenAt = bucket.indexes.compactMap { entries.indices.contains($0) ? entries[$0].timestamp : nil }.min() ?? Date(timeIntervalSince1970: 0)
                let lastSeenAt = bucket.indexes.compactMap { entries.indices.contains($0) ? entries[$0].timestamp : nil }.max() ?? firstSeenAt
                return LogDiagnosticsIssue(
                    id: bucket.key,
                    title: bucket.title,
                    severity: bucket.severity,
                    signal: bucket.signal,
                    count: bucket.indexes.count,
                    affectedTasks: bucket.affectedTasks.sorted(),
                    evidence: evidenceLines(for: bucket.indexes, entries: entries),
                    analysis: issueAnalysis(for: bucket, entries: entries),
                    firstSeenAt: firstSeenAt,
                    lastSeenAt: lastSeenAt,
                    freshness: freshness(
                        key: bucket.key,
                        firstSeenAt: firstSeenAt,
                        lastSeenAt: lastSeenAt,
                        previousGeneratedAt: previousGeneratedAt,
                        knownIssueFingerprints: knownIssueFingerprints
                    )
                )
            }
    }

    private static func buildNotices(from entries: [LogEntry]) -> [LogDiagnosticsNotice] {
        var buckets: [String: NoticeBucket] = [:]
        var seenNoticeEvents: Set<String> = []

        for (index, entry) in entries.enumerated() {
            guard let classification = classifyNotice(entry, index: index, entries: entries) else { continue }
            let signature = diagnosticEventSignature(for: entry, classificationKey: classification.key)
            guard seenNoticeEvents.insert(signature).inserted else { continue }
            var bucket = buckets[classification.key] ?? NoticeBucket(
                key: classification.key,
                title: classification.title,
                signal: classification.signal,
                indexes: [],
                analysis: classification.analysis
            )
            bucket.indexes.append(index)
            buckets[classification.key] = bucket
        }

        return buckets.values
            .sorted { lhs, rhs in
                guard lhs.indexes.count == rhs.indexes.count else {
                    return lhs.indexes.count > rhs.indexes.count
                }
                return lhs.title < rhs.title
            }
            .map { bucket in
                let firstSeenAt = bucket.indexes.compactMap { entries.indices.contains($0) ? entries[$0].timestamp : nil }.min() ?? Date(timeIntervalSince1970: 0)
                let lastSeenAt = bucket.indexes.compactMap { entries.indices.contains($0) ? entries[$0].timestamp : nil }.max() ?? firstSeenAt
                return LogDiagnosticsNotice(
                    id: bucket.key,
                    title: bucket.title,
                    signal: bucket.signal,
                    count: bucket.indexes.count,
                    evidence: evidenceLines(for: bucket.indexes, entries: entries),
                    analysis: bucket.analysis,
                    firstSeenAt: firstSeenAt,
                    lastSeenAt: lastSeenAt
                )
            }
    }

    private static func freshness(
        key: String,
        firstSeenAt: Date,
        lastSeenAt: Date,
        previousGeneratedAt: Date?,
        knownIssueFingerprints: Set<String>
    ) -> LogDiagnosticsFreshness {
        guard let previousGeneratedAt else { return .new }
        if lastSeenAt <= previousGeneratedAt { return .old }
        if firstSeenAt <= previousGeneratedAt || knownIssueFingerprints.contains(key) {
            return .recurring
        }
        return .new
    }

    private static func issueAnalysis(for bucket: IssueBucket, entries: [LogEntry]) -> String {
        guard bucket.key == "worker.budget_exceeded" else {
            return bucket.analysis
        }

        let relatedEntries = entriesForTasks(bucket.affectedTasks, in: entries)
        let persistenceEntries = uniqueEntries(relatedEntries.filter { entry in
            let lower = entry.message.lowercased()
            return lower.contains(AuditEvent.runtimePersistenceSummary.rawValue)
                && field("run_status", in: entry.message) == "budget_exceeded"
        })

        let outputChars = sumIntField("run_output_chars", in: persistenceEntries)
        let fileChanges = sumIntField("file_changes", in: persistenceEntries)
        let savedState = persistenceEntries.contains {
            $0.message.lowercased().contains("result=swiftdata_save_succeeded")
        }

        guard outputChars > 0 || fileChanges > 0 || savedState else {
            return bucket.analysis
        }

        let outputText = outputChars > 0 ? "\(outputChars) visible output character\(outputChars == 1 ? "" : "s")" : "visible output"
        let fileText = fileChanges > 0 ? " and \(fileChanges) file change\(fileChanges == 1 ? "" : "s")" : ""
        let saveText = savedState ? " ASTRA saved the run state successfully." : ""
        return "The task reached its configured budget after producing \(outputText)\(fileText).\(saveText) Resume with a narrower prompt, split the work into smaller tasks, or increase the budget when the broader run is intentional."
    }

    private static func classifyConnectorCredentialRegression(
        _ entry: LogEntry,
        index: Int,
        entries: [LogEntry]
    ) -> (
        key: String,
        title: String,
        severity: LogLevel,
        signal: String,
        analysis: String
    )? {
        let message = entry.message
        let lower = message.lowercased()
        guard lower.contains(AuditEvent.connectorTested.rawValue) else { return nil }
        let explicitlyRejected = lower.contains("credential_state=rejected")
            || lower.contains("result=auth_failed")
        let rejectedAuthProbe = lower.contains("auth_verified=false")
            && lower.contains("http_status=401")
        guard explicitlyRejected || rejectedAuthProbe
        else { return nil }
        guard let evidenceKey = connectorEvidenceKey(for: entry) else { return nil }
        guard entries.indices.contains(index), index > entries.startIndex else { return nil }

        let hadEarlierAuth = entries[..<index].contains { prior in
            guard connectorEvidenceKey(for: prior) == evidenceKey else { return false }
            let priorLower = prior.message.lowercased()
            guard priorLower.contains(AuditEvent.connectorTested.rawValue) else { return false }
            return priorLower.contains("credential_state=authenticated")
                || priorLower.contains("auth_verified=true")
                || priorLower.contains("result=authenticated")
                || priorLower.contains("result=success")
        }
        guard hadEarlierAuth else { return nil }

        let service = field("service_type", in: message) ?? "connector"
        return (
            key: "connector.tested.auth_regressed.\(evidenceKey)",
            title: "Connector credentials stopped authenticating",
            severity: .error,
            signal: "connector.tested credential_state changed authenticated_to_rejected",
            analysis: "This \(service) connector previously authenticated in the retained logs but later had its credentials rejected. The external token, account access, or auth policy likely changed; rotate or re-enter the credentials and then re-run the connector test."
        )
    }

    private static func connectorEvidenceKey(for entry: LogEntry) -> String? {
        let message = entry.message
        if let connectorID = field("connector_id", in: message), !connectorID.isEmpty {
            return "id:\(connectorID)"
        }
        if let serviceType = field("service_type", in: message), !serviceType.isEmpty {
            return "service:\(serviceType)"
        }
        return nil
    }

    private static func isResolvedCapabilityValidationFailure(
        _ entry: LogEntry,
        index: Int,
        entries: [LogEntry]
    ) -> Bool {
        let lower = entry.message.lowercased()
        guard lower.contains("validation.failed"),
              let packageID = field("package_id", in: entry.message),
              entries.indices.contains(index) else {
            return false
        }

        return entries[(index + 1)...].contains { candidate in
            guard candidate.timestamp >= entry.timestamp,
                  field("package_id", in: candidate.message) == packageID else {
                return false
            }
            let candidateLower = candidate.message.lowercased()
            return candidateLower.contains("validation.passed")
                || candidateLower.contains(AuditEvent.capabilityEnabled.rawValue)
        }
    }

    private static func isOptionalValidationBehaviorFailure(
        _ entry: LogEntry,
        index: Int,
        entries: [LogEntry]
    ) -> Bool {
        guard entry.message.lowercased().contains(AuditEvent.validationBehaviorFailed.rawValue) else {
            return false
        }
        return matchingValidationAssertionOutcome(
            after: index,
            entries: entries,
            entry: entry,
            event: AuditEvent.validationAssertionSkipped.rawValue,
            required: "false",
            result: "skipped"
        )
    }

    private static func isValidationBehaviorFailureCoveredByAssertionOutcome(
        _ entry: LogEntry,
        index: Int,
        entries: [LogEntry]
    ) -> Bool {
        guard entry.message.lowercased().contains(AuditEvent.validationBehaviorFailed.rawValue) else {
            return false
        }
        return matchingValidationAssertionOutcome(
            after: index,
            entries: entries,
            entry: entry,
            event: AuditEvent.validationAssertionFailed.rawValue
        ) || matchingValidationAssertionOutcome(
            after: index,
            entries: entries,
            entry: entry,
            event: AuditEvent.validationAssertionSkipped.rawValue,
            required: "false",
            result: "skipped"
        )
    }

    private static func matchingValidationAssertionOutcome(
        after index: Int,
        entries: [LogEntry],
        entry: LogEntry,
        event: String,
        required: String? = nil,
        result: String? = nil
    ) -> Bool {
        guard index + 1 < entries.endIndex,
              let assertionID = field("assertion_id", in: entry.message),
              !assertionID.isEmpty else {
            return false
        }
        let planID = field("plan_id", in: entry.message)
        return entries[(index + 1)..<entries.endIndex].contains { candidate in
            guard candidate.timestamp >= entry.timestamp,
                  candidate.message.lowercased().contains(event),
                  field("assertion_id", in: candidate.message) == assertionID else {
                return false
            }
            if let planID, !planID.isEmpty, field("plan_id", in: candidate.message) != planID {
                return false
            }
            if let required, field("required", in: candidate.message)?.lowercased() != required {
                return false
            }
            if let result, field("result", in: candidate.message)?.lowercased() != result {
                return false
            }
            return true
        }
    }

    private static func isResolvedConnectorTestFailure(
        _ entry: LogEntry,
        index: Int,
        entries: [LogEntry]
    ) -> Bool {
        let lower = entry.message.lowercased()
        guard lower.contains(AuditEvent.connectorTested.rawValue),
              connectorTestFailureNeedsFollowUp(lower),
              let evidenceKey = connectorEvidenceKey(for: entry),
              entries.indices.contains(index) else {
            return false
        }

        return entries[(index + 1)...].contains { candidate in
            guard candidate.timestamp >= entry.timestamp,
                  connectorEvidenceKey(for: candidate) == evidenceKey else {
                return false
            }
            let candidateLower = candidate.message.lowercased()
            guard candidateLower.contains(AuditEvent.connectorTested.rawValue) else {
                return false
            }
            if candidateLower.contains("http_status=200") {
                return true
            }
            guard let result = field("result", in: candidate.message) else {
                return false
            }
            return connectorTestResultIsNonActionable(result)
        }
    }

    private static func connectorTestFailureNeedsFollowUp(_ lower: String) -> Bool {
        lower.contains("http_status=401")
            || lower.contains("unauthorized")
            || lower.contains("credential_state=rejected")
            || lower.contains("result=auth_failed")
            || lower.contains("result=preflight_failed")
    }

    private static func entriesForTasks(_ tasks: Set<String>, in entries: [LogEntry]) -> [LogEntry] {
        guard !tasks.isEmpty else { return [] }
        return entries.filter { entry in
            guard let task = taskIdentifier(for: entry) else { return false }
            return tasks.contains(task)
        }
    }

    private static func uniqueEntries(_ entries: [LogEntry]) -> [LogEntry] {
        var seen: Set<String> = []
        return entries.filter { entry in
            seen.insert(diagnosticEventSignature(for: entry, classificationKey: "related")).inserted
        }
    }

    private static func sumIntField(_ name: String, in entries: [LogEntry]) -> Int {
        entries.reduce(0) { partial, entry in
            partial + (Int(field(name, in: entry.message) ?? "0") ?? 0)
        }
    }

    private static func isRecoveredOrPendingPermissionWarning(
        _ entry: LogEntry,
        entries: [LogEntry],
        generatedAt: Date
    ) -> Bool {
        let lower = entry.message.lowercased()
        guard lower.contains(AuditEvent.workerPermissionDenied.rawValue) else {
            return false
        }

        guard generatedAt.timeIntervalSince(entry.timestamp) >= permissionWarningQuietThreshold else {
            return true
        }

        guard let task = taskIdentifier(for: entry) else {
            return false
        }

        if entries.contains(where: { candidate in
            candidate.timestamp > entry.timestamp
                && taskIdentifier(for: candidate) == task
                && candidate.message.lowercased().contains(AuditEvent.runtimeProgressState.rawValue)
                && candidate.message.lowercased().contains("state=possibly_stalled")
        }) {
            return true
        }

        return entries.contains { candidate in
            candidate.timestamp > entry.timestamp
                && taskIdentifier(for: candidate) == task
                && isTaskProgressOrCompletionEntry(candidate)
        }
    }

    private static func isTaskProgressOrCompletionEntry(_ entry: LogEntry) -> Bool {
        let lower = entry.message.lowercased()
        if lower.contains(AuditEvent.taskCompleted.rawValue) {
            return true
        }
        if lower.contains(AuditEvent.workerExited.rawValue),
           lower.contains("exit_code=0") {
            return true
        }
        if lower.contains(AuditEvent.runtimePersistenceSummary.rawValue),
           (lower.contains("run_status=completed") || lower.contains("task_status=completed")) {
            return true
        }
        if lower.contains(AuditEvent.runtimeStreamSummary.rawValue) {
            if let outputChars = Int(field("run_output_chars", in: entry.message) ?? "0"), outputChars > 0 {
                return true
            }
            if let textEvents = Int(field("text_events", in: entry.message) ?? "0"), textEvents > 0 {
                return true
            }
            if let toolResults = Int(field("tool_result_events", in: entry.message) ?? "0"), toolResults > 0 {
                return true
            }
        }
        if lower.contains(AuditEvent.taskStats.rawValue) {
            return true
        }
        if lower.contains(AuditEvent.runtimeProgressState.rawValue),
           (lower.contains("state=active") || lower.contains("state=recovered_warning")) {
            return true
        }
        return false
    }

    private static func isResolvedPlanBlocker(_ entry: LogEntry, entries: [LogEntry]) -> Bool {
        let lower = entry.message.lowercased()
        guard lower.contains(AuditEvent.planStepBlocked.rawValue) else {
            return false
        }

        guard let task = taskIdentifier(for: entry) else {
            return false
        }

        let planID = field("plan_id", in: entry.message)
        let stepID = field("step_id", in: entry.message)

        return entries.contains { candidate in
            guard candidate.timestamp > entry.timestamp,
                  taskIdentifier(for: candidate) == task else {
                return false
            }

            let candidateLower = candidate.message.lowercased()
            if candidateLower.contains(AuditEvent.planCancelled.rawValue) ||
                candidateLower.contains(AuditEvent.planExecutionCompleted.rawValue) ||
                candidateLower.contains(AuditEvent.planExecutionFailed.rawValue) ||
                candidateLower.contains(AuditEvent.taskCompleted.rawValue) {
                return samePlan(candidate, planID: planID)
            }

            guard candidateLower.contains(AuditEvent.planStepStateChanged.rawValue) ||
                    candidateLower.contains(TaskPlanEventTypes.stepCompleted) ||
                    candidateLower.contains(TaskPlanEventTypes.stepSkipped) ||
                    candidateLower.contains(TaskPlanEventTypes.stepStarted) else {
                return false
            }

            guard samePlan(candidate, planID: planID), sameStep(candidate, stepID: stepID) else {
                return false
            }

            guard let status = field("step_status", in: candidate.message)
                ?? field("status", in: candidate.message)
            else {
                return false
            }
            return ["done", "skipped", "running"].contains(status)
        }
    }

    private static func isGenericRuntimeWarningCoveredBySpecificFailure(_ entry: LogEntry, entries: [LogEntry]) -> Bool {
        guard entry.logLevel == .warning else { return false }
        let lower = entry.message.lowercased()
        let isCoveredSymptom = lower.contains(AuditEvent.workerExited.rawValue) ||
            lower.contains(AuditEvent.runtimeStreamSummary.rawValue) ||
            lower.contains(AuditEvent.runtimeEmptyOutput.rawValue)
        guard isCoveredSymptom else { return false }
        guard let task = taskIdentifier(for: entry) else { return false }

        return entries.contains { candidate in
            guard taskIdentifier(for: candidate) == task else { return false }
            let candidateLower = candidate.message.lowercased()
            return candidateLower.contains(AuditEvent.runtimeFailureDiagnostic.rawValue) ||
                candidateLower.contains(AuditEvent.workerTimeout.rawValue) ||
                candidateLower.contains(AuditEvent.workerBudgetExceeded.rawValue)
        }
    }

    private static func samePlan(_ entry: LogEntry, planID: String?) -> Bool {
        guard let planID, !planID.isEmpty else { return true }
        return field("plan_id", in: entry.message) == planID
    }

    private static func sameStep(_ entry: LogEntry, stepID: String?) -> Bool {
        guard let stepID, !stepID.isEmpty else { return true }
        return field("step_id", in: entry.message) == stepID
    }

    private static func classifyNotice(
        _ entry: LogEntry,
        index: Int,
        entries: [LogEntry]
    ) -> (
        key: String,
        title: String,
        signal: String,
        analysis: String
    )? {
        let message = entry.message
        let lower = message.lowercased()

        if isOptionalValidationBehaviorFailure(entry, index: index, entries: entries) {
            let assertionID = field("assertion_id", in: message) ?? "browser_behavior"
            return (
                key: "validation.browser_behavior.optional_skipped.\(assertionID)",
                title: "Optional browser behavior validation was skipped",
                signal: "validation.behavior.failed followed_by=validation.assertion.skipped required=false",
                analysis: "A browser behavior evidence check did not match the optional assertion, then ASTRA marked that assertion skipped and allowed the required validation contract to continue."
            )
        }

        if isResolvedCapabilityValidationFailure(entry, index: index, entries: entries) {
            let package = field("package_name", in: message) ?? field("package_id", in: message) ?? "capability"
            return (
                key: "capability.validation.resolved.\(field("package_id", in: message) ?? package)",
                title: "Capability setup failure was resolved",
                signal: "validation.failed followed_by=validation.passed",
                analysis: "\(package) validation failed earlier in the analyzed window, then passed later. Treat the earlier failure as setup churn unless a later task still reports missing resources."
            )
        }

        if isResolvedConnectorTestFailure(entry, index: index, entries: entries) {
            let service = field("service_type", in: message) ?? "connector"
            return (
                key: "connector.tested.auth_resolved.\(connectorEvidenceKey(for: entry) ?? service)",
                title: "Connector authentication failure was resolved",
                signal: "connector.tested failure followed_by=success",
                analysis: "A \(service) connector test failed earlier in the analyzed window, then authenticated successfully later. Treat the earlier failure as resolved unless a newer task still reports connector preflight failures."
            )
        }

        if lower.contains(AuditEvent.taskInterrupted.rawValue),
           let source = field("source", in: message) {
            switch source {
            case TaskRunInterruptionSource.appRestart.auditSource:
                return (
                    key: "task.interrupted.startup_recovery",
                    title: "Startup recovered stale running runs",
                    signal: "task.interrupted source=startup_recovery",
                    analysis: "ASTRA found run records left marked as running from a previous app session and marked those runs interrupted during startup recovery. This is expected after app restarts or local app updates and is not actionable unless paired with new task failures."
                )
            case TaskRunInterruptionSource.supersededByNewRun.auditSource:
                return (
                    key: "task.interrupted.superseded_by_new_run",
                    title: "Previous run was superseded",
                    signal: "task.interrupted source=superseded_by_new_run",
                    analysis: "ASTRA interrupted an older run because the user retried or continued the task. This is an expected lifecycle transition and does not indicate a runtime failure by itself."
                )
            default:
                break
            }
        }

        if lower.contains(AuditEvent.userAction.rawValue),
           let action = field("action", in: message) {
            return (
                key: "user.action.\(action)",
                title: "User action was captured",
                signal: "user.action action=\(action)",
                analysis: "ASTRA recorded a sanitized UI action breadcrumb. Use its `trace_id` to follow the related capability, connector, chat, or worker events in the Trace Timelines section."
            )
        }

        if lower.contains(AuditEvent.capabilityEnableStarted.rawValue) {
            return (
                key: "capability.enable_started",
                title: "Capability enable was attempted",
                signal: AuditEvent.capabilityEnableStarted.rawValue,
                analysis: "The user or UI started enabling a capability. This preserves the attempt even if a later configuration, credential, or installation step failed."
            )
        }

        if lower.contains(AuditEvent.capabilityEnabled.rawValue) {
            return (
                key: "capability.enabled",
                title: "Capability was enabled",
                signal: AuditEvent.capabilityEnabled.rawValue,
                analysis: "A capability package was attached to the workspace. Compare its package and workspace fields with later chat-context or task-resolution events if the agent did not use it."
            )
        }

        if lower.contains(AuditEvent.capabilityDisabled.rawValue) {
            return (
                key: "capability.disabled",
                title: "Capability was disabled",
                signal: AuditEvent.capabilityDisabled.rawValue,
                analysis: "A capability package was detached from the workspace. This is expected when the user disabled it from configuration or the right rail."
            )
        }

        if lower.contains(AuditEvent.capabilityChatContext.rawValue) {
            guard !isCapabilityChatContextGap(message) else { return nil }
            guard !isJiraSkillResolvedWithoutConnector(message) else { return nil }
            return (
                key: "capability.chat_context.\(field("source", in: message) ?? "unknown")",
                title: "Chat capability context was captured",
                signal: AuditEvent.capabilityChatContext.rawValue,
                analysis: "ASTRA recorded the capability context that was visible to a chat, plan-generation, or runtime-preflight path. This is non-actionable unless a related gap is reported under Issues."
            )
        }

        if lower.contains(AuditEvent.capabilityResolved.rawValue) {
            guard !isCapabilityResolutionGap(message) else { return nil }
            guard !isJiraSkillResolvedWithoutConnector(message) else { return nil }
            return (
                key: "capability.resolved",
                title: "Task capability context was resolved",
                signal: AuditEvent.capabilityResolved.rawValue,
                analysis: "The worker resolved the task's skills, connectors, and local tools before launching the runtime. This is useful when verifying that enabled workspace capabilities reached the agent."
            )
        }

        if lower.contains(AuditEvent.remoteWorkspacePreflight.rawValue) {
            return (
                key: "remote_workspace.preflight.\(field("workspace_id", in: message) ?? "unknown")",
                title: "Remote workspace preflight was recorded",
                signal: AuditEvent.remoteWorkspacePreflight.rawValue,
                analysis: "ASTRA detected SSH workspace metadata before launching the runtime and recorded the app build plus SSH alias count. Use this to verify that the run used the SSH-aware launch path before investigating VM state, gcloud auth, or provider sandbox errors."
            )
        }

        if lower.contains(AuditEvent.capabilityRuntimeIntegrity.rawValue),
           field("result", in: message) == "passed" {
            return (
                key: "capability.runtime_integrity.passed",
                title: "Capability runtime integrity passed",
                signal: "capability.runtime_integrity result=passed",
                analysis: "ASTRA verified that selected or enabled package capabilities had their declared runtime resources before launching the provider."
            )
        }

        if lower.contains(AuditEvent.connectorTested.rawValue),
           let result = field("result", in: message),
           connectorTestResultIsNonActionable(result) {
            return (
                key: "connector.tested.\(result).\(field("source", in: message) ?? "unknown")",
                title: result == "started" ? "Connector test was attempted" : "Connector test succeeded",
                signal: "connector.tested result=\(result)",
                analysis: "A connector test path ran and did not report a blocking auth or permission failure. The source field indicates whether this came from a configuration test button, task preflight, or another path."
            )
        }

        if lower.contains(AuditEvent.localToolTested.rawValue),
           let result = field("result", in: message),
           localToolTestResultIsNonActionable(result) {
            return (
                key: "local_tool.tested.\(field("command", in: message) ?? "tool").\(result)",
                title: "Local tool preflight succeeded",
                signal: "local_tool.tested result=\(result)",
                analysis: "A local CLI tool required by the active capability passed a task preflight check. This helps prove that the capability was not only visible to the agent, but also locally usable."
            )
        }

        if lower.contains(AuditEvent.runtimeModelSelection.rawValue) {
            let runtime = field("runtime", in: message) ?? "unknown"
            let reason = field("selection_reason", in: message) ?? "unknown"
            return (
                key: "runtime.model_selection.\(runtime).\(reason)",
                title: "Runtime model selection was recorded",
                signal: AuditEvent.runtimeModelSelection.rawValue,
                analysis: "ASTRA recorded the selected runtime, requested model, resolved model, model-source, and provider availability-cache state before launching the provider."
            )
        }

        if lower.contains(AuditEvent.runtimeModelAvailability.rawValue),
           field("result", in: message) == "available" {
            return (
                key: "runtime.model_availability.available.\(field("runtime", in: message) ?? "unknown")",
                title: "Runtime model availability was refreshed",
                signal: "runtime.model_availability result=available",
                analysis: "ASTRA refreshed the provider-specific model list and persisted it for future model pickers and runtime normalization."
            )
        }

        return nil
    }

    private static func classify(_ entry: LogEntry) -> (
        key: String,
        title: String,
        severity: LogLevel,
        signal: String,
        analysis: String
    )? {
        let message = entry.message
        let lower = message.lowercased()

        if lower.contains(AuditEvent.runtimeFailureDiagnostic.rawValue) {
            let category = field("failure_category", in: message) ?? "unknown"
            return (
                key: "runtime.failure_diagnostic.\(category)",
                title: runtimeFailureTitle(category),
                severity: .error,
                signal: "runtime.failure_diagnostic failure_category=\(category)",
                analysis: runtimeFailureAnalysis(category)
            )
        }

        if lower.contains(AuditEvent.runtimeProgressState.rawValue),
           lower.contains("state=possibly_stalled") {
            return (
                key: "runtime.progress_state.possibly_stalled",
                title: "Running task may be stalled",
                severity: .warning,
                signal: "runtime.progress_state state=possibly_stalled",
                analysis: "ASTRA still sees the task as running, but no output, tool result, or file-change progress arrived after a permission warning for at least five minutes. Check whether the provider is waiting for input or a tool permission change."
            )
        }

        if lower.contains(AuditEvent.workerPermissionDenied.rawValue) {
            let tool = field("tool", in: message) ?? "unknown"
            return (
                key: "worker.permission_denied.\(tool)",
                title: "Runtime permission warning needs follow-up",
                severity: .warning,
                signal: "worker.permission_denied tool=\(tool)",
                analysis: "A tool permission warning was emitted and no later progress or completion signal was found in the analyzed window after the five-minute quiet threshold. Review the task log to see whether the agent is waiting for approval or should be retried with different tools."
            )
        }

        if lower.contains(AuditEvent.planStepBlocked.rawValue) {
            let stepID = field("step_id", in: message) ?? "unknown"
            return (
                key: "plan.step.blocked.\(stepID)",
                title: "Plan execution is blocked",
                severity: .warning,
                signal: "plan.step.blocked step_id=\(stepID)",
                analysis: "A plan step reported a blocker and no later step progress, plan cancellation, or task completion resolved it in the analyzed window. Review the plan panel for the blocked step and decide whether to approve, edit, skip, or cancel the remaining work."
            )
        }

        if lower.contains(AuditEvent.runtimeEmptyOutput.rawValue) {
            return (
                key: "runtime.empty_output",
                title: "Runtime returned no visible response",
                severity: .warning,
                signal: AuditEvent.runtimeEmptyOutput.rawValue,
                analysis: "The runtime exited successfully or produced stream events, but ASTRA did not receive visible assistant text. Check provider event parsing, output format flags, and the raw stream counters nearby."
            )
        }

        if lower.contains(AuditEvent.runtimeUnknownEvent.rawValue) {
            let eventType = field("event_type", in: message) ?? "unknown"
            return (
                key: "runtime.unknown_event.\(eventType)",
                title: "Unparsed provider stream event",
                severity: .warning,
                signal: "runtime.unknown_event event_type=\(eventType)",
                analysis: "The provider emitted a stream event shape ASTRA did not fully understand. Update the runtime parser if this event carries visible output, tool activity, usage, or failure details."
            )
        }

        if lower.contains(AuditEvent.capabilityEnableFailed.rawValue) {
            let source = field("source", in: message) ?? "unknown"
            return (
                key: "capability.enable_failed.\(source)",
                title: "Capability enable failed",
                severity: maxSeverity(entry.logLevel, .warning),
                signal: AuditEvent.capabilityEnableFailed.rawValue,
                analysis: "ASTRA attempted to enable a capability but the install, credential, or configuration step failed. Check the source, package, and reason fields, then retry after fixing the missing requirement."
            )
        }

        if lower.contains(AuditEvent.capabilityChatContext.rawValue),
           isJiraSkillResolvedWithoutConnector(message) {
            return (
                key: "capability.jira_connector.missing",
                title: "Jira skill resolved without an active Jira connector",
                severity: .warning,
                signal: "capability.chat_context connector_service_types!=jira",
                analysis: "The task had Jira behavior instructions selected, but the worker did not resolve any connector with service_type=jira. Jira credentials and connector configuration were not injected, and Jira preflight had no connector candidate to test."
            )
        }

        if lower.contains(AuditEvent.capabilityResolved.rawValue),
           isJiraSkillResolvedWithoutConnector(message) {
            return (
                key: "capability.jira_connector.missing",
                title: "Jira skill resolved without an active Jira connector",
                severity: .warning,
                signal: "capability.resolved connector_service_types!=jira",
                analysis: "The task had Jira behavior instructions selected, but the worker did not resolve any connector with service_type=jira. Jira credentials and connector configuration were not injected, and Jira preflight had no connector candidate to test."
            )
        }

        if lower.contains(AuditEvent.capabilityRuntimeIntegrity.rawValue),
           field("result", in: message) == "missing_resources" {
            return (
                key: "capability.runtime_integrity.missing_resources",
                title: "Capability runtime resources are missing",
                severity: .error,
                signal: "capability.runtime_integrity result=missing_resources",
                analysis: "ASTRA blocked task launch because an enabled or selected package capability did not resolve its declared skill, connector, local tool, browser adapter, credential, or executable resource. Fix the capability or exclude it before retrying."
            )
        }

        if lower.contains(AuditEvent.capabilityChatContext.rawValue),
           isCapabilityChatContextGap(message) {
            return (
                key: "capability.chat_context.missing",
                title: "Chat had no active capability context",
                severity: .warning,
                signal: AuditEvent.capabilityChatContext.rawValue,
                analysis: "The workspace had enabled capabilities, but this chat or planning path recorded no selected skills, resolved connectors, or local tools. The provider may not know about a capability the user expected to use."
            )
        }

        if lower.contains(AuditEvent.capabilityResolved.rawValue),
           isCapabilityResolutionGap(message) {
            return (
                key: "capability.resolved.empty",
                title: "Task resolved no capability resources",
                severity: .warning,
                signal: AuditEvent.capabilityResolved.rawValue,
                analysis: "The workspace had enabled capabilities, but the worker resolved zero skills, connectors, and local tools for the task. Check whether the task was created before the capability was enabled or whether the capability package did not attach resources to the workspace."
            )
        }

        if lower.contains(AuditEvent.diagnosticsGenerated.rawValue) {
            return nil
        }

        if lower.contains(AuditEvent.diagnosticsGenerationFailed.rawValue) {
            return (
                key: "diagnostics.generation_failed",
                title: "Diagnostics report generation failed",
                severity: .error,
                signal: AuditEvent.diagnosticsGenerationFailed.rawValue,
                analysis: "The diagnostics report could not be written or revealed. Check the sanitized error field and the app log directory permissions."
            )
        }

        if lower.contains(AuditEvent.workspaceExported.rawValue),
           lower.contains("auto_export_failed") {
            let reason = field("reason", in: message)
            return (
                key: "workspace.export.auto_export_failed.\(reason ?? "write_failed")",
                title: "Workspace auto-export failed",
                severity: .error,
                signal: "workspace.exported result=auto_export_failed",
                analysis: "ASTRA saved workspace state in SwiftData but could not write the recovery config file into the workspace folder. Check the parent path, write permissions, and the error_domain/error_code fields in the extract."
            )
        }

        if lower.contains(AuditEvent.connectorTested.rawValue) {
            if lower.contains("result=preflight_failed") {
                return (
                    key: "connector.tested.preflight_failed",
                    title: "Connector preflight blocked task launch",
                    severity: .error,
                    signal: "connector.tested result=preflight_failed",
                    analysis: "ASTRA stopped the task before launching the agent because a required connector did not pass its own auth or permission check. Fix the connector configuration, then retry the task."
                )
            }
            if lower.contains("missing_count=") {
                return (
                    key: "connector.tested.missing_credentials",
                    title: "Connector configuration is incomplete",
                    severity: .warning,
                    signal: "connector.tested missing_count",
                    analysis: "A configured connector was tested before all required credential fields were available. The user needs to complete the connector configuration before this capability can be used."
                )
            }
            if lower.contains("result=project_not_visible") {
                return (
                    key: "connector.tested.jira_project_not_visible",
                    title: "Jira project is not visible",
                    severity: .warning,
                    signal: "connector.tested result=project_not_visible",
                    analysis: "Jira accepted the connector credentials, but at least one configured project was not visible or the project key is wrong. Check project membership, Browse Projects permission, and the configured project keys."
                )
            }
            if lower.contains("result=missing_permission") {
                let permission = field("permission", in: message) ?? "required permission"
                return (
                    key: "connector.tested.missing_permission.\(permission)",
                    title: "Connector authenticated but lacks permission",
                    severity: .warning,
                    signal: "connector.tested result=missing_permission",
                    analysis: "The connector authenticated successfully, but the account lacks \(permission). Grant the permission in the external service instead of rotating the token."
                )
            }
            if lower.contains("result=endpoint_scope_failure") {
                return (
                    key: "connector.tested.endpoint_scope_failure",
                    title: "Connector auth probe needs scope or endpoint review",
                    severity: .warning,
                    signal: "connector.tested result=endpoint_scope_failure",
                    analysis: "A connector credential probe was rejected, but the evidence is not enough to call the token invalid. Check scoped-token support, service-account auth mode, gateway URL requirements, and endpoint-specific scopes."
                )
            }
            if lower.contains("http_status=401") || lower.contains("unauthorized") {
                return (
                    key: "connector.tested.unauthorized",
                    title: "Connector credentials were rejected",
                    severity: .warning,
                    signal: "connector.tested http_status=401",
                    analysis: "A connector reached its service, but the service rejected the credentials. Re-enter or refresh the token for the affected connector."
                )
            }
        }

        if lower.contains(AuditEvent.localToolTested.rawValue) {
            let command = field("command", in: message) ?? "local tool"
            let result = field("result", in: message) ?? "failed"
            return (
                key: "local_tool.tested.\(command).\(result)",
                title: "Local tool preflight failed",
                severity: .warning,
                signal: "local_tool.tested result=\(result)",
                analysis: "A local CLI tool required by the active capability did not pass preflight. For GitHub workflows, verify that `gh` is installed and authenticated with `gh auth status` before retrying."
            )
        }

        if lower.contains(AuditEvent.validationAssertionFailed.rawValue),
           field("assertion_method", in: message) == "browser_behavior" {
            return (
                key: "validation.browser_behavior.failed.\(field("assertion_id", in: message) ?? "unknown")",
                title: "Browser behavior validation failed",
                severity: .warning,
                signal: "validation.assertion.failed assertion_method=browser_behavior",
                analysis: "A required browser behavior validation assertion failed. Inspect the evidence path and failure_reason fields, then fix the artifact or the expected browser-visible behavior."
            )
        }

        if lower.contains(AuditEvent.validationBehaviorFailed.rawValue) {
            return (
                key: "validation.browser_behavior.failed.\(field("assertion_id", in: message) ?? "unknown")",
                title: "Browser behavior validation failed",
                severity: .warning,
                signal: AuditEvent.validationBehaviorFailed.rawValue,
                analysis: "A browser behavior evidence check failed and no matching optional skipped assertion was found in the analyzed window. Inspect the related validation assertion and contract events."
            )
        }

        if lower.contains("query shelf") &&
            lower.contains("bigquery") &&
            (lower.contains("bq is not installed") ||
                lower.contains("bigquery cli (`bq`) was not found") ||
                lower.contains("bigquery cli") && lower.contains("not found")) {
            return (
                key: "query_shelf.bigquery_cli_missing",
                title: "Query Shelf could not find BigQuery CLI",
                severity: .error,
                signal: "query_shelf bq_missing",
                analysis: "Query Shelf attempted to inspect or run BigQuery SQL, but `bq` was not executable at the time of the operation. Verify Google Cloud SDK installation and PATH, then retry the Query Shelf action."
            )
        }

        if lower.contains(AuditEvent.runtimeModelAvailability.rawValue),
           field("result", in: message) == "unavailable" {
            let runtime = field("runtime", in: message) ?? "runtime"
            return (
                key: "runtime.model_availability.unavailable.\(runtime)",
                title: "Runtime model availability could not be refreshed",
                severity: .warning,
                signal: "runtime.model_availability result=unavailable",
                analysis: "ASTRA could not refresh the provider-specific model list, so the UI may fall back to cached or built-in suggestions. Check the reason field and provider auth state."
            )
        }

        if lower.contains(AuditEvent.workspaceStoreBackedUp.rawValue) {
            if lower.contains("result=failed") {
                return (
                    key: "workspace.store_backup.failed",
                    title: "Workspace store backup failed",
                    severity: .error,
                    signal: AuditEvent.workspaceStoreBackedUp.rawValue,
                    analysis: "ASTRA attempted to back up the SwiftData store during recovery but could not move one or more store files. Check the error fields and application support directory permissions."
                )
            }
            return nil
        }

        if lower.contains(AuditEvent.workspaceRecovered.rawValue) {
            return nil
        }

        if lower.contains(AuditEvent.workspaceRecoveryFailed.rawValue) {
            return (
                key: "workspace.recovery.failed",
                title: "Workspace recovery failed",
                severity: .error,
                signal: AuditEvent.workspaceRecoveryFailed.rawValue,
                analysis: "ASTRA found a workspace recovery config but could not import or save it. Check the config filename and error fields in the nearby log extract."
            )
        }

        if lower.contains(AuditEvent.dataStoreRecovered.rawValue) {
            if lower.contains("stage=") {
                return (
                    key: "data_store.recovered",
                    title: "SwiftData store was recovered",
                    severity: entry.logLevel,
                    signal: AuditEvent.dataStoreRecovered.rawValue,
                    analysis: "The initial SwiftData container open failed, so ASTRA backed up the old store and recreated the model container. Confirm the recovered workspaces and inspect the captured error fields."
                )
            }
            return nil
        }

        if lower.contains(AuditEvent.specExtractionFailed.rawValue),
           lower.contains("operation=title_generation") {
            guard entry.logLevel != .debug,
                  field("result", in: message) != "candidate_failed" else {
                return nil
            }
            return (
                key: "spec.title_generation.failed",
                title: "Thread title generation failed",
                severity: entry.logLevel,
                signal: "spec.extraction_failed operation=title_generation",
                analysis: "The optional title-generation helper failed after trying its model candidates. The task can still run, but check the model and error_summary fields if title backfill keeps failing."
            )
        }

        let isRuntimePersistenceTimeout = lower.contains(AuditEvent.runtimePersistenceSummary.rawValue)
            && (field("run_status", in: message) == "timeout"
                || field("run_stop_reason", in: message)?.contains("timeout") == true)
        if lower.contains(AuditEvent.workerTimeout.rawValue) || isRuntimePersistenceTimeout {
            return (
                key: "worker.timeout",
                title: "Runtime timeout",
                severity: entry.logLevel == .error ? .error : .warning,
                signal: "timeout",
                analysis: "The task stopped after a timeout or network wait. Check whether the provider produced output before the idle timeout and whether the workspace command hung."
            )
        }

        if lower.contains(AuditEvent.workerBudgetExceeded.rawValue) || lower.contains("budget.exceeded") {
            return (
                key: "worker.budget_exceeded",
                title: "Task budget exceeded",
                severity: .warning,
                signal: "budget_exceeded",
                analysis: "The task exceeded a configured token, turn, or repetition budget. This is usually a guardrail trigger rather than a crash."
            )
        }

        if lower.contains(AuditEvent.isolationFailed.rawValue) {
            return (
                key: "isolation.failed",
                title: "Workspace isolation failed",
                severity: .error,
                signal: AuditEvent.isolationFailed.rawValue,
                analysis: "ASTRA could not prepare the requested execution workspace. Check source paths, permissions, and isolation strategy."
            )
        }

        if lower.contains("keychain.") && lower.contains("failed") {
            return (
                key: "keychain.failed",
                title: "Keychain operation failed",
                severity: .error,
                signal: "keychain.failed",
                analysis: "A credential save/delete/read path failed. Check macOS Keychain access, app channel identity, and whether the credential item is locked or malformed."
            )
        }

        if lower.contains(AuditEvent.appUpdateBlocked.rawValue) {
            return (
                key: "app_update.blocked",
                title: "App update was blocked",
                severity: .warning,
                signal: AuditEvent.appUpdateBlocked.rawValue,
                analysis: "The updater refused to install because safety checks were not satisfied. Check the blocked reason and update channel/build metadata."
            )
        }

        if lower.contains(AuditEvent.taskFailed.rawValue) {
            return (
                key: "task.failed",
                title: "Task failed",
                severity: maxSeverity(entry.logLevel, .warning),
                signal: AuditEvent.taskFailed.rawValue,
                analysis: "A task entered a failed state. Check the same task ID for runtime, workspace, capability, and persistence events immediately before this line."
            )
        }

        if entry.logLevel == .error {
            return (
                key: "error.\(messagePrefix(message))",
                title: "Application error",
                severity: .error,
                signal: messagePrefix(message),
                analysis: "A generic error-level log was emitted. Review the surrounding context for the failing subsystem and task ID."
            )
        }

        if entry.logLevel == .warning {
            return (
                key: "warning.\(messagePrefix(message))",
                title: "Application warning",
                severity: .warning,
                signal: messagePrefix(message),
                analysis: "A warning-level log was emitted. Review whether it corresponds to a recoverable condition or a user-visible behavior."
            )
        }

        return nil
    }

    private static func evidenceLines(for indexes: [Int], entries: [LogEntry]) -> [String] {
        var selected = Set<Int>()
        for index in indexes.prefix(5) {
            guard entries.indices.contains(index) else { continue }
            let issueTask = taskIdentifier(for: entries[index])
            let issueCategory = entries[index].category
            for offset in -2...2 {
                let candidate = index + offset
                guard entries.indices.contains(candidate) else { continue }
                if let issueTask {
                    guard taskIdentifier(for: entries[candidate]) == issueTask else { continue }
                } else if entries[candidate].category != issueCategory {
                    continue
                }
                selected.insert(candidate)
            }
        }
        var seenLines: Set<String> = []
        return selected
            .sorted()
            .prefix(maxEvidenceLinesPerIssue)
            .compactMap { index in
                let entry = entries[index]
                let signature = diagnosticEventSignature(for: entry, classificationKey: "evidence")
                guard seenLines.insert(signature).inserted else { return nil }
                return sanitizedLine(entry)
            }
    }

    private static func renderMarkdown(
        entries: [LogEntry],
        generatedAt: Date,
        scope: LogDiagnosticsScope,
        previousGeneratedAt: Date?,
        previousDiagnosticsContext: PreviousDiagnosticsContext?,
        issues: [LogDiagnosticsIssue],
        notices: [LogDiagnosticsNotice],
        crashReports: [CrashReportSummary],
        omittedIssueCount: Int
    ) -> String {
        let errors = entries.filter { $0.logLevel == .error }.count
        let warnings = entries.filter { $0.logLevel == .warning }.count
        let tasksSeen = Set(entries.compactMap(taskIdentifier(for:))).sorted()
        let issueTaskIDs = Set(issues.flatMap(\.affectedTasks)).sorted()
        let otherTaskIDs = tasksSeen.filter { !issueTaskIDs.contains($0) }
        let taskIDMap = fullTaskIDMap(from: entries)
        let traceSummaries = buildTraceSummaries(from: entries)
        let categories = Dictionary(grouping: entries, by: \.category)
            .mapValues(\.count)
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .prefix(10)
            .map { "- \($0.key): \($0.value)" }
            .joined(separator: "\n")

        var lines: [String] = [
            "# ASTRA Diagnostics Report",
            "",
            "Generated: \(displayTimestamp(generatedAt))",
            "App channel: \(AppChannel.current.displayName)",
            "App build: \(AppBuildInfo.current.provenanceSummary)",
            "Log directory: \(LogSanitizer.sanitize(AppLogger.mainLogFile.deletingLastPathComponent().path))",
            "Breadcrumb file: \(LogSanitizer.sanitize(AppLogger.breadcrumbLogFile.path))",
            "Scope: \(scope.label)",
            "Previous diagnostics: \(previousGeneratedAt.map(displayTimestamp) ?? "none")",
            "Analyzed window: \(analysisWindow(entries: entries))",
        ]
        appendScopeNotes(
            scope: scope,
            previousGeneratedAt: previousGeneratedAt,
            previousDiagnosticsContext: previousDiagnosticsContext,
            entryCount: entries.count,
            to: &lines
        )
        lines += [
            "",
            "## Summary",
            "",
            "- Entries analyzed: \(entries.count)",
            "- Errors: \(errors)",
            "- Warnings: \(warnings)",
            "- Issue groups: \(issues.count + omittedIssueCount)",
            "- Resolved / non-actionable events: \(notices.count)",
            "- Diagnostic reports found: \(crashReports.count)",
            "- Trace groups: \(traceSummaries.count)",
            "- Tasks with issues: \(issueTaskIDs.isEmpty ? "none" : issueTaskIDs.joined(separator: ", "))",
            "- Other tasks seen: \(otherTaskIDs.isEmpty ? "none" : otherTaskIDs.joined(separator: ", "))",
            "- Full task IDs: \(taskIDMap.isEmpty ? "none captured" : taskIDMap.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))",
            "",
            "## Category Counts",
            "",
            categories.isEmpty ? "- none" : categories,
            "",
            "## Settings Snapshot",
            "",
            settingsSnapshotLines().joined(separator: "\n"),
        ]
        appendCrashReports(crashReports, to: &lines)
        appendTraceSummaries(traceSummaries, to: &lines)
        lines += ["", "## Issues"]

        if issues.isEmpty {
            lines += [
                "",
                "No actionable issue signals were found in the analyzed log buffer."
            ]
            appendNotices(notices, to: &lines)
            lines += [
                "",
                "## Developer Notes",
                "",
                warnings > 0 || errors > 0
                    ? "The report contains warning/error log lines, but diagnostics classified them as resolved or non-actionable for this scope."
                    : "The generated report is still useful as a point-in-time summary, but it did not detect actionable issue signals."
            ]
            return lines.joined(separator: "\n") + "\n"
        }

        for (index, issue) in issues.enumerated() {
            lines += [
                "",
                "### \(index + 1). \(issue.title)",
                "",
                "- Severity: \(issue.severity.rawValue)",
                "- Signal: `\(issue.signal)`",
                "- Freshness: \(issue.freshness.label)",
                "- Count: \(issue.count)",
                "- First seen in window: \(displayTimestamp(issue.firstSeenAt))",
                "- Last seen in window: \(displayTimestamp(issue.lastSeenAt))",
                "- Affected tasks: \(issue.affectedTasks.isEmpty ? "none" : issue.affectedTasks.joined(separator: ", "))",
                "",
                "Analysis: \(issue.analysis)",
                "",
                "Relevant log extract:",
                "",
                "```text"
            ]
            lines += issue.evidence
            lines += ["```"]
        }

        if omittedIssueCount > 0 {
            lines += [
                "",
                "Additional issue groups omitted from this report: \(omittedIssueCount). Narrow logs by task ID or time window if more detail is needed."
            ]
        }

        appendNotices(notices, to: &lines)

        lines += [
            "",
            "## Developer Checklist",
            "",
            "- Start with `runtime.failure_diagnostic` entries when present; they include classified provider failures and redacted stderr summaries.",
            "- Use the affected task IDs to open the matching `task-*.log` file for complete task-local context.",
            "- Compare `capability.enabled`, `capability.chat_context`, and `capability.resolved` entries when a user says an enabled capability was missing from chat.",
            "- If `runtime.unknown_event` appears, compare the sample shape against the runtime parser before assuming the provider returned no output.",
            "- If the report shows no provider error summary, verify pipe-drain behavior and whether the CLI wrote errors outside stderr/stdout."
        ]

        return lines.joined(separator: "\n") + "\n"
    }

    private static func appendScopeNotes(
        scope: LogDiagnosticsScope,
        previousGeneratedAt: Date?,
        previousDiagnosticsContext: PreviousDiagnosticsContext?,
        entryCount: Int,
        to lines: inout [String]
    ) {
        guard scope == .sinceLastReport,
              previousGeneratedAt != nil else {
            return
        }

        if let previousDiagnosticsContext {
            lines += [
                "Scope note: A recent earlier diagnostics export at \(displayTimestamp(previousDiagnosticsContext.generatedAt)) reported \(previousDiagnosticsContext.issueCount) issue group\(previousDiagnosticsContext.issueCount == 1 ? "" : "s"), \(previousDiagnosticsContext.errorCount) error\(previousDiagnosticsContext.errorCount == 1 ? "" : "s"), and \(previousDiagnosticsContext.warningCount) warning\(previousDiagnosticsContext.warningCount == 1 ? "" : "s") across \(previousDiagnosticsContext.entryCount) entries. This report only covers logs since that export; choose Last 15 minutes or All retained logs to include earlier context."
            ]
            return
        }

        if entryCount <= 3 {
            lines += [
                "Scope note: This report only covers entries since the previous diagnostics export. Back-to-back exports can look clean even when the copied raw logs contain earlier issues; choose Last 15 minutes or All retained logs for broader context."
            ]
        }
    }

    private static func appendCrashReports(_ crashReports: [CrashReportSummary], to lines: inout [String]) {
        lines += [
            "",
            "## Diagnostic Reports",
            ""
        ]

        guard !crashReports.isEmpty else {
            lines += [
                "No recent ASTRA diagnostic reports were found in `\(CrashDiagnosticsService.userFacingPath(CrashDiagnosticsService.defaultDiagnosticReportsDirectory))`."
            ]
            return
        }

        lines += [
            "Recent macOS diagnostic reports matching ASTRA app names:",
            ""
        ]

        for report in crashReports {
            lines.append(
                "- \(report.kind.displayName) report: `\(report.fileName)` | app: \(report.appName) | modified: \(displayTimestamp(report.modifiedAt)) | size: \(byteCount(report.sizeBytes)) | path: `\(report.displayPath)`"
            )
        }

        lines += [
            "",
            "Open `$HOME/Library/Logs/DiagnosticReports` or use the Diagnostic Reports button in the log viewer to reveal these files in Finder."
        ]
    }

    private static func appendNotices(_ notices: [LogDiagnosticsNotice], to lines: inout [String]) {
        guard !notices.isEmpty else { return }
        lines += [
            "",
            "## Resolved / Non-Actionable Events"
        ]
        for notice in notices {
            lines += [
                "",
                "### \(notice.title)",
                "",
                "- Signal: `\(notice.signal)`",
                "- Count: \(notice.count)",
                "- First seen in window: \(displayTimestamp(notice.firstSeenAt))",
                "- Last seen in window: \(displayTimestamp(notice.lastSeenAt))",
                "",
                "Analysis: \(notice.analysis)",
                "",
                "Relevant log extract:",
                "",
                "```text"
            ]
            lines += notice.evidence
            lines += ["```"]
        }
    }

    private static func appendTraceSummaries(_ summaries: [LogDiagnosticsTraceSummary], to lines: inout [String]) {
        guard !summaries.isEmpty else { return }
        lines += [
            "",
            "## Trace Timelines",
            "",
            "Recent related log lines grouped by `trace_id`. Use these to reconstruct a single user action across UI, capability, connector, and worker logs."
        ]
        for summary in summaries.prefix(8) {
            lines += [
                "",
                "### `\(summary.id)`",
                "",
                "- Count: \(summary.count)",
                "- First seen in window: \(displayTimestamp(summary.firstSeenAt))",
                "- Last seen in window: \(displayTimestamp(summary.lastSeenAt))",
                "- Actions: \(summary.actions.isEmpty ? "none" : summary.actions.joined(separator: ", "))",
                "- Sources: \(summary.sources.isEmpty ? "none" : summary.sources.joined(separator: ", "))",
                "- Categories: \(summary.categories.joined(separator: ", "))",
                "- Affected tasks: \(summary.affectedTasks.isEmpty ? "none" : summary.affectedTasks.joined(separator: ", "))",
                "",
                "Trace extract:",
                "",
                "```text"
            ]
            lines += summary.evidence
            lines += ["```"]
        }
        if summaries.count > 8 {
            let omitted = summaries.dropFirst(8).prefix(12).map { summary in
                let actionText = summary.actions.isEmpty ? "none" : summary.actions.joined(separator: ",")
                return "`\(summary.id)` actions=\(actionText) tasks=\(summary.affectedTasks.isEmpty ? "none" : summary.affectedTasks.joined(separator: ","))"
            }.joined(separator: "; ")
            lines += [
                "",
                "Additional trace groups omitted from this report: \(summaries.count - 8). Omitted index: \(omitted). Narrow the time window if more detail is needed."
            ]
        }
    }

    private static func buildTraceSummaries(from entries: [LogEntry]) -> [LogDiagnosticsTraceSummary] {
        struct Accumulator {
            var entries: [LogEntry] = []
            var categories: Set<String> = []
            var sources: Set<String> = []
            var actions: Set<String> = []
            var affectedTasks: Set<String> = []
        }

        var grouped: [String: Accumulator] = [:]
        for entry in entries {
            guard let traceID = field("trace_id", in: entry.message),
                  !traceID.isEmpty,
                  traceID.lowercased() != "none" else { continue }
            var acc = grouped[traceID] ?? Accumulator()
            acc.entries.append(entry)
            acc.categories.insert(entry.category)
            if let source = field("source", in: entry.message), !source.isEmpty {
                acc.sources.insert(source)
            }
            if let action = field("action", in: entry.message), !action.isEmpty {
                acc.actions.insert(action)
            }
            if let task = taskIdentifier(for: entry), !task.isEmpty {
                acc.affectedTasks.insert(task)
            }
            grouped[traceID] = acc
        }

        return grouped.compactMap { traceID, acc in
            let ordered = acc.entries.sorted { $0.timestamp < $1.timestamp }
            guard let first = ordered.first, let last = ordered.last else { return nil }
            let evidence = uniqueDiagnosticEntries(Array(ordered.suffix(12)))
                .suffix(8)
                .map(sanitizedLine)
            return LogDiagnosticsTraceSummary(
                id: traceID,
                count: ordered.count,
                firstSeenAt: first.timestamp,
                lastSeenAt: last.timestamp,
                categories: acc.categories.sorted(),
                sources: acc.sources.sorted(),
                actions: acc.actions.sorted(),
                affectedTasks: acc.affectedTasks.sorted(),
                evidence: evidence
            )
        }
        .sorted { lhs, rhs in
            if lhs.lastSeenAt != rhs.lastSeenAt { return lhs.lastSeenAt > rhs.lastSeenAt }
            return lhs.id < rhs.id
        }
    }

    private static func analysisWindow(entries: [LogEntry]) -> String {
        guard let first = entries.first?.timestamp, let last = entries.last?.timestamp else {
            return "no matching log entries"
        }
        return "\(displayTimestamp(first)) to \(displayTimestamp(last))"
    }

    private static func fullTaskIDMap(from entries: [LogEntry]) -> [String: String] {
        var map: [String: String] = [:]
        for entry in entries {
            guard let taskID = entry.taskID else { continue }
            map[String(taskID.uuidString.prefix(8))] = taskID.uuidString
        }
        return map
    }

    private static func settingsSnapshotLines(defaults: UserDefaults = .standard) -> [String] {
        let runtime = AgentRuntimeAdapterRegistry.registeredRuntime(rawValue: defaults.string(forKey: "defaultRuntimeID"))
        let defaultModel = defaults.string(forKey: "defaultModel") ?? TaskExecutionDefaults.model
        let validationModel = defaults.string(forKey: "validationModel") ?? "claude-haiku-4-5-20251001"
        let budget = defaults.object(forKey: AppStorageKeys.defaultTokenBudget) as? Int ?? TaskExecutionDefaults.tokenBudget
        let enforcement = BudgetEnforcementMode.configuredDefault(in: defaults)
        let claudeCache = RuntimeModelAvailability.cacheSummary(for: .claudeCode, defaults: defaults)
        let copilotCache = RuntimeModelAvailability.cacheSummary(for: .copilotCLI, defaults: defaults)

        return [
            "- Default runtime: \(runtime.rawValue)",
            "- Default task model: \(defaultModel)",
            "- Utility / validation model: \(validationModel)",
            "- Default task budget: \(budget)",
            "- Budget enforcement: \(enforcement.rawValue)",
            "- Claude model suggestions: \(claudeCache.count) (\(claudeCache.checkedAt.map { "checked \(displayTimestamp($0))" } ?? "built-in defaults"))",
            "- Copilot model suggestions: \(copilotCache.count) (\(copilotCache.checkedAt.map { "checked \(displayTimestamp($0))" } ?? "built-in defaults"))"
        ]
    }

    private static func byteCount(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private static func runtimeFailureTitle(_ category: String) -> String {
        switch category {
        case "authentication_failed": "Runtime authentication failed"
        case "model_unavailable": "Selected model unavailable"
        case "quota_exceeded": "Provider quota exceeded"
        case "rate_limited": "Provider rate limited the request"
        case "provider_configuration_invalid": "Provider configuration invalid"
        case "permission_denied": "Runtime permission approval blocked"
        case "unsupported_output_format": "Runtime output format unsupported"
        case "network_failed": "Provider network failure"
        case "runtime_timed_out": "Runtime timed out"
        case "budget_exceeded": "Runtime budget exceeded"
        case "no_visible_output": "Runtime returned no visible output"
        default: "Runtime provider failed"
        }
    }

    private static func runtimeFailureAnalysis(_ category: String) -> String {
        switch category {
        case "model_unavailable":
            "The runtime launched, but the selected model was rejected or unavailable for the user's account, organization policy, CLI version, quota tier, or provider configuration. This is not evidence that the model is globally invalid."
        case "authentication_failed":
            "The runtime could not authenticate with the provider. Re-run the provider login flow or verify configured tokens for this app channel."
        case "provider_configuration_invalid":
            "The provider path is configured but incomplete or invalid. Check BYOK/base URL/deployment/API key settings without exposing secret values."
        case "permission_denied":
            "The runtime was blocked by provider policy, organization policy, or an interactive CLI approval prompt. Check the redacted error summary for denied tools or workspace paths; this should surface quickly instead of waiting for the idle timeout."
        case "quota_exceeded", "rate_limited":
            "The provider accepted the runtime request path but refused service due to account limits. Retrying with the same model may continue to fail until the limit resets or billing/config changes."
        case "unsupported_output_format":
            "The CLI did not accept the flags ASTRA uses to stream structured output. Check CLI version and capability detection."
        case "no_visible_output":
            "The provider process produced no visible assistant response. Check stderr summary, raw stream counters, and unknown event samples."
        default:
            "The provider process failed. Use the redacted error summary and surrounding stream counters to identify whether this is auth, model, quota, parser, or process-level failure."
        }
    }

    private static func field(_ name: String, in message: String) -> String? {
        let prefix = "\(name)="
        guard let range = message.range(of: prefix) else { return nil }
        let remainder = message[range.upperBound...]
        let value = remainder.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first
        return value.map(String.init)
    }

    private static func intField(_ name: String, in message: String) -> Int {
        Int(field(name, in: message) ?? "0") ?? 0
    }

    private static func enabledCapabilityResourceCount(in message: String) -> Int {
        intField("workspace_enabled_capabilities_count", in: message)
            + intField("workspace_enabled_global_skills_count", in: message)
            + intField("workspace_enabled_global_connectors_count", in: message)
            + intField("workspace_enabled_global_tools_count", in: message)
    }

    private static func isIntentionalCapabilityPrune(_ message: String) -> Bool {
        if field("scope_pruned", in: message)?.lowercased() == "true" {
            return true
        }

        let excludedNames = field("scope_excluded_skill_names", in: message)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return excludedNames.map { !$0.isEmpty && $0 != "none" } ?? false
    }

    private static func isCapabilityChatContextGap(_ message: String) -> Bool {
        guard enabledCapabilityResourceCount(in: message) > 0 else { return false }
        guard !isIntentionalCapabilityPrune(message) else { return false }
        let source = field("source", in: message)?.lowercased() ?? ""
        guard source.contains("chat")
                || source.contains("generation")
                || source.contains("preflight")
        else { return false }

        let selectedSkills = intField("selected_skill_count", in: message)
        let resolvedSkills = intField("resolved_skill_count", in: message)
        let taskSkills = intField("task_skill_count", in: message)
        let connectors = intField("connector_count", in: message)
        let tools = intField("local_tool_count", in: message)
        return selectedSkills == 0
            && resolvedSkills == 0
            && taskSkills == 0
            && connectors == 0
            && tools == 0
    }

    private static func isCapabilityResolutionGap(_ message: String) -> Bool {
        guard enabledCapabilityResourceCount(in: message) > 0 else { return false }
        guard !isIntentionalCapabilityPrune(message) else { return false }
        return intField("resolved_skill_count", in: message) == 0
            && intField("connector_count", in: message) == 0
            && intField("local_tool_count", in: message) == 0
    }

    private static func isJiraSkillResolvedWithoutConnector(_ message: String) -> Bool {
        let lower = message.lowercased()
        guard lower.contains("jira agent")
                || lower.contains("skill_names=jira")
                || lower.contains("resolved_skill_names=jira")
                || lower.contains("selected_skill_names=jira")
        else { return false }

        if let serviceTypes = field("connector_service_types", in: message)?.lowercased() {
            let normalizedTypes = serviceTypes
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            return !normalizedTypes.contains("jira")
        }

        guard lower.contains("connector_count=") else { return false }
        guard intField("connector_count", in: message) == 0 else { return false }
        if lower.contains("preflight_connector_count=") {
            return intField("preflight_connector_count", in: message) == 0
        }
        return true
    }

    private static func connectorTestResultIsNonActionable(_ result: String) -> Bool {
        ["started", "success", "authenticated", "preflight_passed"].contains(result)
    }

    private static func localToolTestResultIsNonActionable(_ result: String) -> Bool {
        ["success", "authenticated"].contains(result)
    }

    private static func taskIdentifier(for entry: LogEntry) -> String? {
        if let taskID = entry.taskID {
            return String(taskID.uuidString.prefix(8))
        }
        return field("task_short", in: entry.message)
    }

    private static func diagnosticEventSignature(for entry: LogEntry, classificationKey: String) -> String {
        let timestampSecond = Int(entry.timestamp.timeIntervalSince1970)
        let task = taskIdentifier(for: entry) ?? "none"
        return [
            classificationKey,
            entry.logLevel.rawValue,
            entry.category,
            task,
            String(timestampSecond),
            canonicalMessage(entry.message)
        ].joined(separator: "|")
    }

    private static func canonicalMessage(_ message: String) -> String {
        let withoutTaskPrefix: Substring
        if message.hasPrefix("task_short=") {
            let pieces = message.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            withoutTaskPrefix = pieces.count > 1 ? pieces[1] : ""
        } else {
            withoutTaskPrefix = Substring(message)
        }
        return withoutTaskPrefix
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func messagePrefix(_ message: String) -> String {
        let normalized: Substring
        if message.hasPrefix("task_short=") {
            let pieces = message.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            normalized = pieces.count > 1 ? pieces[1] : ""
        } else {
            normalized = Substring(message)
        }
        let first = normalized.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first
        return first.map(String.init) ?? "unknown"
    }

    static func parseLogLine(_ line: String, dateAnchor: Date = Date()) -> LogEntry? {
        let pattern = #"^\[([0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,3})?)\]\s+\[([A-Z]+)\]\s+\[([^\]]+)\]\s+(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: nsRange),
              match.numberOfRanges == 5,
              let timestampRange = Range(match.range(at: 1), in: line),
              let levelRange = Range(match.range(at: 2), in: line),
              let categoryRange = Range(match.range(at: 3), in: line),
              let messageRange = Range(match.range(at: 4), in: line) else {
            return nil
        }

        let timestamp = logTimestamp(String(line[timestampRange]), anchoredTo: dateAnchor)
        let levelText = String(line[levelRange]).lowercased()
        let level = LogLevel(rawValue: levelText) ?? .info
        let categoryParts = String(line[categoryRange]).split(separator: " ")
        let category = categoryParts.first.map(String.init) ?? "General"
        let taskShort = categoryParts
            .first { $0.hasPrefix("task:") }
            .map { String($0.dropFirst("task:".count)) }
        let message = String(line[messageRange])
        let messageWithTask = taskShort.map { "task_short=\($0) \(message)" } ?? message
        return LogEntry(
            level: level,
            category: category,
            message: messageWithTask,
            timestamp: timestamp
        )
    }

    private static func diagnosticLogFiles(in directory: URL) -> [URL] {
        guard let files = try? HostFileAccessBroker().contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            intent: .astraManagedStorage(root: directory)
        ) else { return [] }

        let mainLogs = files
            .filter { file in
                let name = file.lastPathComponent
                return name == "astra.log" || (name.hasPrefix("astra.") && name.hasSuffix(".log"))
            }
            .sorted { modificationDate($0) > modificationDate($1) }

        let taskLogs = files
            .filter { $0.lastPathComponent.hasPrefix("task-") && $0.pathExtension == "log" }
            .sorted { modificationDate($0) > modificationDate($1) }
            .prefix(maxTaskLogFiles)

        return mainLogs + Array(taskLogs)
    }

    private static func isAppLogFile(_ file: URL) -> Bool {
        let name = file.lastPathComponent
        return name == "astra.log" || (name.hasPrefix("astra.") && name.hasSuffix(".log"))
    }

    private static func tailLines(from url: URL, maxLines: Int) -> [String] {
        guard let content = try? HostFileAccessBroker().readString(
            at: url,
            encoding: .utf8,
            intent: .astraManagedStorage(root: url.deletingLastPathComponent())
        ) else { return [] }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count > maxLines else { return lines }
        return Array(lines.suffix(maxLines))
    }

    private static func entrySignature(_ entry: LogEntry) -> String {
        "\(entry.level)|\(entry.category)|\(entry.taskID?.uuidString ?? "none")|\(entry.message)"
    }

    private static func uniqueDiagnosticEntries(_ entries: [LogEntry]) -> [LogEntry] {
        var seen: Set<String> = []
        return entries.filter { entry in
            let timestampSecond = Int(entry.timestamp.timeIntervalSince1970)
            let signature = [
                entry.level,
                entry.category,
                taskIdentifier(for: entry) ?? "none",
                String(timestampSecond),
                canonicalMessage(entry.message)
            ].joined(separator: "|")
            return seen.insert(signature).inserted
        }
    }

    private static func modificationDate(_ url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate ?? .distantPast
    }

    private static func fileSize(_ url: URL, fileManager: FileManager = .default) -> Int64 {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        if let size = attributes?[.size] as? NSNumber {
            return size.int64Value
        }
        return 0
    }

    private static func logTimestamp(_ timeText: String, anchoredTo date: Date) -> Date {
        let pieces = timeText.split(separator: ":")
        guard pieces.count == 3,
              let hour = Int(pieces[0]),
              let minute = Int(pieces[1]) else {
            return date
        }

        let secondPieces = pieces[2].split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let second = Int(secondPieces[0]) else { return date }
        let milliseconds = secondPieces.count > 1 ? Int(secondPieces[1].prefix(3)) ?? 0 : 0

        var components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        components.hour = hour
        components.minute = minute
        components.second = second
        components.nanosecond = milliseconds * 1_000_000
        return Calendar.current.date(from: components) ?? date
    }

    private static func sanitizedLine(_ entry: LogEntry) -> String {
        let task = entry.taskID.map { " task:\(String($0.uuidString.prefix(8)))" } ?? ""
        let line = "[\(displayTimestamp(entry.timestamp))] [\(entry.level.uppercased())] [\(entry.category)\(task)] \(entry.message)"
        return LogSanitizer.sanitize(line, maxLength: 1_000)
    }

    private static func maxSeverity(_ lhs: LogLevel, _ rhs: LogLevel) -> LogLevel {
        lhs > rhs ? lhs : rhs
    }

    private static func displayTimestamp(_ date: Date) -> String {
        displayFormatter.string(from: date)
    }

    private static func fileTimestamp(_ date: Date) -> String {
        fileFormatter.string(from: date)
    }

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        return formatter
    }()

    private static let fileFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private static let archiveISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

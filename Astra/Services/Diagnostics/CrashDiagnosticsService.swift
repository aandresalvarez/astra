import Foundation
import ASTRAPersistence
import ASTRACore
import ASTRAModels

enum CrashReportKind: String, Equatable, Codable {
    case crash
    case hang
    case spin
    case stackshot
    case unknown

    var displayName: String {
        switch self {
        case .crash: "Crash"
        case .hang: "Hang"
        case .spin: "Spin"
        case .stackshot: "Stackshot"
        case .unknown: "Diagnostic"
        }
    }
}

struct CrashReportSummary: Equatable, Identifiable, Sendable {
    let url: URL
    let appName: String
    let modifiedAt: Date
    let sizeBytes: Int64
    let kind: CrashReportKind

    init(
        url: URL,
        appName: String,
        modifiedAt: Date,
        sizeBytes: Int64,
        kind: CrashReportKind = .crash
    ) {
        self.url = url
        self.appName = appName
        self.modifiedAt = modifiedAt
        self.sizeBytes = sizeBytes
        self.kind = kind
    }

    var id: String { url.path }
    var fileName: String { url.lastPathComponent }
    var displayPath: String { CrashDiagnosticsService.userFacingPath(url) }
}

private struct CrashReportCandidate {
    let url: URL
    let appName: String
    let modifiedAt: Date
    let sizeBytes: Int64

    var fileName: String { url.lastPathComponent }
}

enum CrashDiagnosticsService {
    static let defaultRecentLimit = 8
    static let defaultRecentDays = 30
    static let supportedExtensions: Set<String> = ["ips", "crash", "hang", "spin"]
    private static let reportClassificationPrefixBytes = 64 * 1024

    static var defaultDiagnosticReportsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    }

    static func defaultSearchDirectories(fileManager: FileManager = .default) -> [URL] {
        [
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/CrashReporter", isDirectory: true)
        ]
    }

    static func reportNamePrefixes(for channel: AppChannel = .current) -> [String] {
        var prefixes: [String] = [channel.displayName]
        for candidate in ["ASTRA Dev", "ASTRA Beta", "ASTRA"] where !prefixes.contains(candidate) {
            prefixes.append(candidate)
        }
        return prefixes
    }

    static func recentReports(
        limit: Int = defaultRecentLimit,
        withinDays: Int? = defaultRecentDays,
        prefixes: [String] = reportNamePrefixes(),
        searchDirectories: [URL] = defaultSearchDirectories(),
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> [CrashReportSummary] {
        let interval = withinDays.map {
            DateInterval(
                start: now.addingTimeInterval(-TimeInterval(max(0, $0)) * 24 * 60 * 60),
                end: now
            )
        }
        return reports(
            limit: limit,
            modifiedIn: interval,
            prefixes: prefixes,
            searchDirectories: searchDirectories,
            fileManager: fileManager
        )
    }

    static func reports(
        limit: Int = defaultRecentLimit,
        modifiedIn interval: DateInterval?,
        prefixes: [String] = reportNamePrefixes(),
        searchDirectories: [URL] = defaultSearchDirectories(),
        fileManager: FileManager = .default
    ) -> [CrashReportSummary] {
        reports(
            limit: limit,
            modifiedIn: interval,
            prefixes: prefixes,
            searchDirectories: searchDirectories,
            fileManager: fileManager,
            kindForReport: reportKind(for:)
        )
    }

    static func reports(
        limit: Int = defaultRecentLimit,
        modifiedIn interval: DateInterval?,
        prefixes: [String] = reportNamePrefixes(),
        searchDirectories: [URL] = defaultSearchDirectories(),
        fileManager: FileManager = .default,
        kindForReport: (URL) -> CrashReportKind
    ) -> [CrashReportSummary] {
        let normalizedPrefixes = prefixes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !normalizedPrefixes.isEmpty, limit > 0 else { return [] }

        let candidates = searchDirectories.flatMap { directory -> [CrashReportCandidate] in
            let broker = HostFileAccessBroker(fileManager: fileManager)
            guard let files = try? broker.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles],
                intent: .astraManagedStorage(root: directory)
            ) else { return [] }

            return files.compactMap { file in
                guard supportedExtensions.contains(file.pathExtension.lowercased()) else { return nil }
                let fileName = file.lastPathComponent
                guard let appName = matchingAppName(for: fileName, prefixes: normalizedPrefixes) else {
                    return nil
                }

                guard let values = try? file.resourceValues(forKeys: [
                    .contentModificationDateKey,
                    .fileSizeKey,
                    .isRegularFileKey
                ]),
                      values.isRegularFile == true
                else { return nil }

                let modifiedAt = values.contentModificationDate ?? Date.distantPast
                if let interval, (modifiedAt < interval.start || modifiedAt > interval.end) {
                    return nil
                }

                return CrashReportCandidate(
                    url: file,
                    appName: appName,
                    modifiedAt: modifiedAt,
                    sizeBytes: Int64(values.fileSize ?? 0)
                )
            }
        }

        return candidates
            .sorted { lhs, rhs in
                if lhs.modifiedAt != rhs.modifiedAt {
                    return lhs.modifiedAt > rhs.modifiedAt
                }
                return lhs.fileName < rhs.fileName
            }
            .prefix(limit)
            .map { candidate in
                CrashReportSummary(
                    url: candidate.url,
                    appName: candidate.appName,
                    modifiedAt: candidate.modifiedAt,
                    sizeBytes: candidate.sizeBytes,
                    kind: kindForReport(candidate.url)
                )
            }
    }

    static func userFacingPath(_ url: URL, fileManager: FileManager = .default) -> String {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let path = url.path
        if path == home {
            return "$HOME"
        }
        if path.hasPrefix(home + "/") {
            return "$HOME/" + path.dropFirst(home.count + 1)
        }
        return path
    }

    private static func reportKind(for url: URL) -> CrashReportKind {
        switch url.pathExtension.lowercased() {
        case "crash":
            return .crash
        case "hang":
            return .hang
        case "spin":
            return .spin
        default:
            break
        }

        let prefix = reportClassificationPrefix(from: url)
        if let eventKind = eventReportKind(in: prefix) {
            return eventKind
        }
        if let structuredKind = structuredReportKind(in: prefix) {
            return structuredKind
        }

        let lowercasedPrefix = prefix.lowercased()
        if lowercasedPrefix.contains("exception type:") || lowercasedPrefix.contains("termination reason:") {
            return .crash
        }
        if lowercasedPrefix.contains("stackshot") {
            return .stackshot
        }
        return .unknown
    }

    private static func reportClassificationPrefix(from url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: reportClassificationPrefixBytes) else {
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func eventReportKind(in prefix: String) -> CrashReportKind? {
        for line in prefix.split(whereSeparator: \.isNewline).prefix(80) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.lowercased().hasPrefix("event:") else { continue }
            let event = trimmed.dropFirst("event:".count).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let kind = reportKind(fromEventText: event) {
                return kind
            }
        }
        return nil
    }

    private static func reportKind(fromEventText eventText: String) -> CrashReportKind? {
        let event = eventText.lowercased()
        if event.contains("hang") {
            return .hang
        }
        if event.contains("crash") {
            return .crash
        }
        if event.contains("spin") {
            return .spin
        }
        if event.contains("stackshot") {
            return .stackshot
        }
        return nil
    }

    private static func structuredReportKind(in prefix: String) -> CrashReportKind? {
        if let metadata = firstJSONMetadataObject(in: prefix) {
            if let event = metadata["event"] as? String,
               let eventKind = reportKind(fromEventText: event) {
                return eventKind
            }
            if String(describing: metadata["bug_type"] ?? "") == "309" {
                return .crash
            }
        }

        let compactPrefix = prefix
            .lowercased()
            .filter { !$0.isWhitespace }
        if compactPrefix.contains(#""exception":"#) ||
            compactPrefix.contains(#""exception":{"#) ||
            compactPrefix.contains(#""termination":"#) ||
            compactPrefix.contains(#""termination":{"#) {
            return .crash
        }
        return nil
    }

    private static func firstJSONMetadataObject(in prefix: String) -> [String: Any]? {
        for line in prefix.split(whereSeparator: \.isNewline).prefix(5) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else { continue }
            guard let data = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            return object
        }
        return nil
    }

    private static func matchingAppName(for fileName: String, prefixes: [String]) -> String? {
        prefixes.first { prefix in
            fileName.hasPrefix("\(prefix)-")
        }
    }
}

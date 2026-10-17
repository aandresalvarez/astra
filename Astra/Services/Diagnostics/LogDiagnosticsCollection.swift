import Foundation
import ASTRACore

struct LogDiagnosticsCoverage: Equatable, Sendable {
    var availableFiles = 0
    var sampledFiles = 0
    var omittedFiles = 0
    var truncatedFiles = 0
    var unreadableFiles = 0
    var bytesRead = 0

    var markdown: String {
        """
        ## Evidence coverage

        - Log files available: \(availableFiles); sampled: \(sampledFiles); omitted: \(omittedFiles).
        - Truncated files: \(truncatedFiles); unreadable: \(unreadableFiles); bytes read: \(bytesRead).
        - Collection is bounded to 8 MiB per file, 32 MiB total, and 80 files. A selected time window can stop a file read earlier. Omitted or truncated evidence is not proof that no other failures occurred.
        """
    }
}

struct LogDiagnosticsCollection: Sendable {
    let entries: [LogEntry]
    let coverage: LogDiagnosticsCoverage
}

/// Runs off the UI actor. Expands a tail read only until it covers the selected
/// time window or hits an explicit byte budget; never loads an unbounded log.
enum LogDiagnosticsCollector {
    static let maximumFileBytes = 8 * 1_024 * 1_024
    static let maximumTotalBytes = 32 * 1_024 * 1_024

    static func collect(inMemory: [LogEntry], directory: URL, includeAppLogs: Bool,
                        interval: DateInterval? = nil) -> LogDiagnosticsCollection {
        let broker = HostFileAccessBroker()
        let files = ((try? broker.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            intent: .astraManagedStorage(root: directory))) ?? []).filter {
                let name = $0.lastPathComponent
                return name == "astra.log" || (name.hasPrefix("astra.") && name.hasSuffix(".log"))
                    || (name.hasPrefix("task-") && name.hasSuffix(".log"))
            }.sorted {
                let leftApp = !$0.lastPathComponent.hasPrefix("task-")
                let rightApp = !$1.lastPathComponent.hasPrefix("task-")
                return leftApp != rightApp ? leftApp : modificationDate($0) > modificationDate($1)
            }
        var coverage = LogDiagnosticsCoverage(availableFiles: files.count)
        var entries = inMemory
        // Match the representation actually written to disk, including its
        // timestamp precision and abbreviated task identity.
        var seen = Set(entries.map(signature))
        var selectedFiles = 0
        for file in files {
            let isApp = !file.lastPathComponent.hasPrefix("task-")
            if isApp && !includeAppLogs && !inMemory.isEmpty {
                coverage.omittedFiles += 1
                continue
            }
            guard selectedFiles < 80, coverage.bytesRead < maximumTotalBytes else {
                coverage.omittedFiles += 1
                continue
            }
            selectedFiles += 1
            let remaining = maximumTotalBytes - coverage.bytesRead
            let fileSize = broker.fileSize(at: file, intent: .astraManagedStorage(root: directory)) ?? maximumFileBytes
            let cap = min(maximumFileBytes, remaining)
            var limit = min(256 * 1_024, cap)
            var parsed: [LogEntry] = []
            var readCount = 0
            do {
                while true {
                    let data = try broker.readData(at: file, maxBytes: limit, keeping: .suffix,
                        intent: .astraManagedStorage(root: directory))
                    readCount = data.count
                    coverage.bytesRead += data.count
                    var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
                    if fileSize > data.count, !lines.isEmpty { lines.removeFirst() }
                    parsed = PersistedLogEntryParser.parseLines(lines, dateAnchor: modificationDate(file))
                    let coversWindow = interval.map { window in parsed.first.map { $0.timestamp <= window.start } ?? false } ?? false
                    if data.count < limit || limit >= fileSize || coversWindow || limit >= cap { break }
                    let next = min(limit * 2, cap)
                    guard next <= maximumTotalBytes - coverage.bytesRead else { break }
                    limit = next
                }
                coverage.sampledFiles += 1
                if fileSize > readCount { coverage.truncatedFiles += 1 }
                for entry in parsed where seen.insert(signature(entry)).inserted { entries.append(entry) }
            } catch { coverage.unreadableFiles += 1 }
        }
        return LogDiagnosticsCollection(entries: entries, coverage: coverage)
    }

    private struct EntryIdentity: Hashable {
        let timestamp: String
        let level: String
        let category: String
        let task: String?
        let message: String
    }

    private static func signature(_ entry: LogEntry) -> EntryIdentity {
        var task = entry.taskID.map { String($0.uuidString.prefix(8)).uppercased() }
        var message = entry.message
        if task == nil, message.hasPrefix("task_short=") {
            let parts = message.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            let short = String(parts[0].dropFirst("task_short=".count))
            if short.count == 8, short.allSatisfy(\.isHexDigit) {
                task = short.uppercased()
                message = parts.count > 1 ? String(parts[1]) : ""
            }
        }
        return EntryIdentity(
            timestamp: String(entry.persistedFormatted.prefix { $0 != "]" }),
            level: entry.level,
            category: entry.category.split(separator: " ").first.map(String.init) ?? entry.category,
            task: task,
            message: String(message.drop(while: \.isWhitespace))
        )
    }

    private static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}

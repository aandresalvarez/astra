import Foundation
import ASTRALogging

/// Owns durable log-line compatibility. New lines carry absolute ISO-8601
/// timestamps; legacy time-only lines are reconstructed across midnight by
/// walking backward from the file's last-modified date.
enum PersistedLogEntryParser {
    static func parse(
        _ line: String,
        dateAnchor: Date = Date(),
        calendar: Calendar = .current
    ) -> LogEntry? {
        let pattern = #"^\[([^\]]+)\]\s+\[([A-Z]+)\]\s+\[([^\]]+)\]\s+(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: nsRange),
              match.numberOfRanges == 5,
              let timestampRange = Range(match.range(at: 1), in: line),
              let levelRange = Range(match.range(at: 2), in: line),
              let categoryRange = Range(match.range(at: 3), in: line),
              let messageRange = Range(match.range(at: 4), in: line),
              let timestamp = timestamp(
                String(line[timestampRange]), anchoredTo: dateAnchor, calendar: calendar
              ) else { return nil }

        let level = LogLevel(rawValue: String(line[levelRange]).lowercased()) ?? .info
        let categoryParts = String(line[categoryRange]).split(separator: " ")
        let category = categoryParts.first.map(String.init) ?? "General"
        let taskShort = categoryParts.first { $0.hasPrefix("task:") }
            .map { String($0.dropFirst("task:".count)) }
        let message = String(line[messageRange])
        return LogEntry(
            level: level,
            category: category,
            message: taskShort.map { "task_short=\($0) \(message)" } ?? message,
            timestamp: timestamp
        )
    }

    static func parseLines(
        _ lines: [String],
        dateAnchor: Date,
        calendar: Calendar = .current
    ) -> [LogEntry] {
        var nextTimestamp: Date?
        var reversed: [LogEntry] = []
        reversed.reserveCapacity(lines.count)
        for line in lines.reversed() {
            guard var entry = parse(line, dateAnchor: dateAnchor, calendar: calendar) else { continue }
            if !hasAbsoluteTimestamp(line), let nextTimestamp,
               entry.timestamp > nextTimestamp,
               let priorDay = calendar.date(byAdding: .day, value: -1, to: entry.timestamp) {
                entry = LogEntry(
                    level: entry.logLevel, category: entry.category, message: entry.message,
                    taskID: entry.taskID, timestamp: priorDay
                )
            }
            nextTimestamp = entry.timestamp
            reversed.append(entry)
        }
        return Array(reversed.reversed())
    }

    private static func timestamp(
        _ value: String,
        anchoredTo date: Date,
        calendar: Calendar
    ) -> Date? {
        if hasISO8601DatePrefix(value) {
            return iso8601.date(from: value) ?? iso8601WithoutFractionalSeconds.date(from: value)
        }
        let pieces = value.split(separator: ":")
        guard pieces.count == 3, let hour = Int(pieces[0]), let minute = Int(pieces[1]) else {
            return nil
        }
        let seconds = pieces[2].split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let second = Int(seconds[0]) else { return nil }
        let milliseconds = seconds.count > 1 ? Int(seconds[1].prefix(3)) ?? 0 : 0
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = hour; components.minute = minute; components.second = second
        components.nanosecond = milliseconds * 1_000_000
        return calendar.date(from: components)
    }

    private static func hasAbsoluteTimestamp(_ line: String) -> Bool {
        guard line.first == "[", line.count > 11 else { return false }
        let start = line.index(after: line.startIndex)
        return line.index(start, offsetBy: 4, limitedBy: line.endIndex).map { line[$0] == "-" } ?? false
    }

    private static func hasISO8601DatePrefix(_ value: String) -> Bool {
        value.count > 10 && value[value.index(value.startIndex, offsetBy: 4)] == "-"
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601WithoutFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

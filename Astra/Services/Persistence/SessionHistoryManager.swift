import Foundation
import ASTRACore

/// Manages a persistent session history file for each task.
/// After each turn (initial run or follow-up), appends a structured summary
/// to `session_history.md` in the task folder and saves full output to numbered files.
/// This allows the agent to recover context even when the conversation window compresses older turns.
enum SessionHistoryManager {

    /// Append a turn entry to the session history file after a run completes.
    static func recordTurn(
        taskFolder: String,
        taskTitle: String,
        turnMessage: String,
        output: String,
        tokensUsed: Int,
        costUSD: Double,
        fileChanges: [StoredFileChange],
        redactions: [String] = [],
        durationMs: Int? = nil
    ) {
        guard !taskFolder.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: taskFolder, withIntermediateDirectories: true)

        let historyPath = (taskFolder as NSString).appendingPathComponent("session_history.md")
        let turnNumber = nextTurnNumber(historyPath: historyPath, taskFolder: taskFolder)
        let timestamp = Self.formatTimestamp(Date())
        let redactedMessage = redactSensitiveContent(turnMessage, redactions: redactions)
        let redactedOutput = redactSensitiveContent(output, redactions: redactions)

        // Save full output to a separate file
        let outputDir = (taskFolder as NSString).appendingPathComponent("outputs")
        try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        let outputFile = (outputDir as NSString).appendingPathComponent("turn_\(String(format: "%03d", turnNumber)).md")
        let outputHeader = "# Turn \(turnNumber) — \(timestamp)\n\n**Ask**: \(redactedMessage.prefix(200))\n\n---\n\n"
        try? (outputHeader + redactedOutput).write(toFile: outputFile, atomically: true, encoding: .utf8)

        // Build summary entry for history file
        var entry = "\n## Turn \(turnNumber) — \(timestamp)\n\n"
        entry += "**Ask**: \(redactedMessage.prefix(300))\n\n"

        // Key output summary (first 600 chars, preserving structure)
        let outputSummary = summarizeOutput(redactedOutput, maxLength: 600)
        if !outputSummary.isEmpty {
            entry += "**Summary**: \(outputSummary)\n\n"
        }

        // Files changed
        if !fileChanges.isEmpty {
            entry += "**Files changed**:\n"
            for change in fileChanges {
                let icon = change.kind == .write ? "+" : "~"
                entry += "- [\(icon)] `\(change.path)`\n"
            }
            entry += "\n"
        }

        // Stats
        var stats: [String] = []
        if tokensUsed > 0 { stats.append("\(formatTokens(tokensUsed)) tokens") }
        if costUSD > 0 { stats.append(String(format: "$%.4f", costUSD)) }
        if let ms = durationMs { stats.append("\(ms / 1000)s") }
        if !stats.isEmpty {
            entry += "**Stats**: \(stats.joined(separator: " | "))\n"
        }

        entry += "\n**Full output**: [turn_\(String(format: "%03d", turnNumber)).md](outputs/turn_\(String(format: "%03d", turnNumber)).md)\n"
        entry += "\n---\n"

        // Create or append to history file
        if FileManager.default.fileExists(atPath: historyPath) {
            if let handle = FileHandle(forWritingAtPath: historyPath) {
                handle.seekToEndOfFile()
                if let data = entry.data(using: .utf8) {
                    handle.write(data)
                }
                handle.closeFile()
            }
        } else {
            let header = "# Session History: \(taskTitle)\n\n> This file tracks the conversation history for this task.\n> The agent can read this file to recover context from earlier turns.\n> Full outputs are stored in the `outputs/` subfolder.\n\n---\n"
            try? (header + entry).write(toFile: historyPath, atomically: true, encoding: .utf8)
        }
    }

    /// Path to the session history file for a task folder.
    static func historyPath(taskFolder: String) -> String {
        (taskFolder as NSString).appendingPathComponent("session_history.md")
    }

    // MARK: - Private

    private static func nextTurnNumber(historyPath: String, taskFolder: String) -> Int {
        let hostFileAccess = HostFileAccessBroker()
        let accessIntent = HostFileAccessIntent.astraManagedStorage(root: URL(fileURLWithPath: taskFolder, isDirectory: true))
        guard hostFileAccess.fileExists(at: URL(fileURLWithPath: historyPath), intent: accessIntent),
              let content = try? hostFileAccess.readString(
                at: URL(fileURLWithPath: historyPath),
                encoding: .utf8,
                intent: accessIntent
              ) else {
            return 1
        }
        // Count existing "## Turn N" headers
        let pattern = #"## Turn (\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 1 }
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: content.utf16.count))
        return matches.count + 1
    }

    private static func summarizeOutput(_ output: String, maxLength: Int) -> String {
        let summary = TaskRunAnswerPresentationPolicy.summaryText(rawText: output, maxLength: maxLength)
        guard !summary.isEmpty else { return "" }

        if summary.count <= maxLength {
            return summary
        }

        let prefix = String(summary.prefix(maxLength))
        if let lastPeriod = prefix.lastIndex(of: ".") {
            return String(prefix[prefix.startIndex...lastPeriod]) + " *(see full output)*"
        }
        if let lastNewline = prefix.lastIndex(of: "\n") {
            return String(prefix[prefix.startIndex..<lastNewline]) + "\n*(see full output)*"
        }
        return prefix + "... *(see full output)*"
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private static func formatTimestamp(_ date: Date) -> String {
        timestampFormatter.string(from: date)
    }

    private static func formatTokens(_ count: Int) -> String {
        Formatters.formatTokens(count)
    }

    private static func redactSensitiveContent(_ text: String, redactions: [String]) -> String {
        guard !text.isEmpty else { return text }

        var result = text
        let normalizedRedactions = Set(
            redactions
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count >= 2 }
        ).sorted { $0.count > $1.count }

        for secret in normalizedRedactions where !secret.isEmpty {
            result = result.replacingOccurrences(of: secret, with: "[REDACTED]")
        }

        let replacements: [(String, String)] = [
            (#"(?i)(authorization:\s*(?:bearer|basic)\s+)[^\s`"]+"#, "$1[REDACTED]"),
            (#"\bgithub_pat_[A-Za-z0-9_]+\b"#, "[REDACTED]"),
            (#"\bgh[pousr]_[A-Za-z0-9_]+\b"#, "[REDACTED]"),
            (#"\bAKIA[0-9A-Z]{16}\b"#, "[REDACTED]"),
            (#"\bsk-ant-[A-Za-z0-9_\-]+\b"#, "[REDACTED]"),
            (#"(?i)\b(sk-[A-Za-z0-9_\-]+)\b"#, "[REDACTED]"),
            (#"(?i)\b(api[_-]?key|token|secret|password)\s*[:=]\s*([^\s,;]+)"#, "$1=[REDACTED]")
        ]

        for (pattern, template) in replacements {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }

        return result
    }
}

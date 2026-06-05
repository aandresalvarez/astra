import Foundation

enum PromptContextIOSnapshotLoader {
    private static let recentSessionOutputFileLimit = 6
    private static let recentSessionFullOutputFileLimit = 4
    private static let recentSessionFullOutputMaxCharacters = 8_000
    private static let olderSessionOutputMaxCharacters = 2_000

    static func snapshot(for task: AgentTask) -> PromptContextIOSnapshot {
        snapshot(taskFolder: TaskWorkspaceAccess(task: task).taskFolder)
    }

    static func snapshot(taskFolder: String) -> PromptContextIOSnapshot {
        guard !taskFolder.isEmpty else { return .empty }
        return PromptContextIOSnapshot(
            recentConversationTranscript: recentSessionOutputTranscript(taskFolder: taskFolder),
            sessionHistorySummary: sessionHistorySummary(taskFolder: taskFolder)
        )
    }

    static func recentConversationTranscript(for task: AgentTask) -> String? {
        snapshot(for: task).recentConversationTranscript?.text
    }

    private static func recentSessionOutputTranscript(taskFolder: String) -> PromptContextSnapshotText? {
        let turnFiles = outputTurnFilePaths(taskFolder: taskFolder)
            .suffix(recentSessionOutputFileLimit)

        guard !turnFiles.isEmpty else { return nil }

        let transcriptSections = turnFiles.enumerated().compactMap { offset, path -> String? in
            guard let text = try? String(contentsOfFile: path, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            let recentIndex = turnFiles.count - offset
            let maxCharacters = recentIndex <= recentSessionFullOutputFileLimit
                ? recentSessionFullOutputMaxCharacters
                : olderSessionOutputMaxCharacters
            let excerpt = boundedText(text, maxCharacters: maxCharacters, keeping: .prefix)
            return "--- \((path as NSString).lastPathComponent) ---\n\(excerpt)"
        }

        guard !transcriptSections.isEmpty else { return nil }
        let sourcePointers = turnFiles.map {
            PromptContextSourcePointer(label: "turn output", target: $0)
        } + [
            PromptContextSourcePointer(
                label: "session history",
                target: SessionHistoryManager.historyPath(taskFolder: taskFolder)
            )
        ]
        return PromptContextSnapshotText(
            text: transcriptSections.joined(separator: "\n\n"),
            sourcePointers: sourcePointers
        )
    }

    private static func sessionHistorySummary(taskFolder: String) -> PromptContextSnapshotText? {
        let historyPath = SessionHistoryManager.historyPath(taskFolder: taskFolder)
        guard let history = try? String(contentsOfFile: historyPath, encoding: .utf8),
              !history.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return PromptContextSnapshotText(
            text: recentSessionHistorySummary(from: history),
            sourcePointers: [PromptContextSourcePointer(label: "session history", target: historyPath)]
        )
    }

    static func outputTurnFilePaths(taskFolder: String) -> [String] {
        let outputDirectory = (taskFolder as NSString).appendingPathComponent("outputs")
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: outputDirectory),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls
            .filter { url in
                let name = url.lastPathComponent
                return name.hasPrefix("turn_") && name.hasSuffix(".md")
            }
            .map(\.path)
            .sorted { ($0 as NSString).lastPathComponent < ($1 as NSString).lastPathComponent }
    }

    private static func recentSessionHistorySummary(from history: String) -> String {
        let marker = "\n## Turn "
        let pieces = history.components(separatedBy: marker)
        guard pieces.count > 1 else {
            return boundedText(history, maxCharacters: 4_000, keeping: .suffix)
        }

        let header = pieces[0]
        let recentTurns = pieces.dropFirst().suffix(recentSessionOutputFileLimit).map { "## Turn " + $0 }
        let summary = ([header] + recentTurns).joined(separator: "\n")
        return boundedText(summary, maxCharacters: 8_000, keeping: .suffix)
    }

    private enum TextBound {
        case prefix
        case suffix
    }

    private static func boundedText(_ text: String, maxCharacters: Int, keeping bound: TextBound) -> String {
        guard text.count > maxCharacters else { return text }
        switch bound {
        case .prefix:
            return String(text.prefix(maxCharacters)) + "\n... (truncated)"
        case .suffix:
            return "... (truncated)\n" + String(text.suffix(maxCharacters))
        }
    }
}

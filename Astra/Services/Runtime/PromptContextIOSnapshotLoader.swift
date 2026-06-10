import Foundation

enum PromptContextIOSnapshotLoader {
    /// How much raw turn history a rebuilt follow-up prompt may carry. Runtimes
    /// without provider-native session resume depend entirely on this window for
    /// multi-turn coherence, so they get the wider preset.
    struct TranscriptWindow: Sendable, Equatable {
        var fileLimit: Int
        var fullOutputFileLimit: Int
        var fullOutputMaxCharacters: Int
        var olderOutputMaxCharacters: Int

        static let standard = TranscriptWindow(
            fileLimit: 6,
            fullOutputFileLimit: 4,
            fullOutputMaxCharacters: 8_000,
            olderOutputMaxCharacters: 2_000
        )
        static let extended = TranscriptWindow(
            fileLimit: 12,
            fullOutputFileLimit: 8,
            fullOutputMaxCharacters: 12_000,
            olderOutputMaxCharacters: 3_000
        )
    }

    static func snapshot(for task: AgentTask, window: TranscriptWindow = .standard) -> PromptContextIOSnapshot {
        snapshot(taskFolder: TaskWorkspaceAccess(task: task).taskFolder, window: window)
    }

    static func snapshot(taskFolder: String, window: TranscriptWindow = .standard) -> PromptContextIOSnapshot {
        guard !taskFolder.isEmpty else { return .empty }
        return PromptContextIOSnapshot(
            recentConversationTranscript: recentSessionOutputTranscript(taskFolder: taskFolder, window: window),
            sessionHistorySummary: sessionHistorySummary(taskFolder: taskFolder)
        )
    }

    static func recentConversationTranscript(for task: AgentTask) -> String? {
        snapshot(for: task).recentConversationTranscript?.text
    }

    private static func recentSessionOutputTranscript(
        taskFolder: String,
        window: TranscriptWindow
    ) -> PromptContextSnapshotText? {
        let turnFiles = outputTurnFilePaths(taskFolder: taskFolder)
            .suffix(window.fileLimit)

        guard !turnFiles.isEmpty else { return nil }

        let transcriptSections = turnFiles.enumerated().compactMap { offset, path -> String? in
            guard let text = try? String(contentsOfFile: path, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            let recentIndex = turnFiles.count - offset
            let maxCharacters = recentIndex <= window.fullOutputFileLimit
                ? window.fullOutputMaxCharacters
                : window.olderOutputMaxCharacters
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
        let recentTurns = pieces.dropFirst().suffix(TranscriptWindow.standard.fileLimit).map { "## Turn " + $0 }
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

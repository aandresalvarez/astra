import Foundation

enum PromptContextIOSnapshotLoader {
    private static let maximumSnapshotReadBytes = 1_048_576

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
        let hostFileAccess = HostFileAccessBroker()
        let taskFolderURL = URL(fileURLWithPath: taskFolder, isDirectory: true)
        return PromptContextIOSnapshot(
            recentConversationTranscript: recentSessionOutputTranscript(
                taskFolder: taskFolder,
                window: window,
                hostFileAccess: hostFileAccess,
                accessRoot: taskFolderURL
            ),
            sessionHistorySummary: sessionHistorySummary(
                taskFolder: taskFolder,
                window: window,
                hostFileAccess: hostFileAccess,
                accessRoot: taskFolderURL
            )
        )
    }

    static func recentConversationTranscript(for task: AgentTask) -> String? {
        snapshot(for: task).recentConversationTranscript?.text
    }

    private static func recentSessionOutputTranscript(
        taskFolder: String,
        window: TranscriptWindow,
        hostFileAccess: HostFileAccessBroker,
        accessRoot: URL
    ) -> PromptContextSnapshotText? {
        let turnFiles = outputTurnFilePaths(
            taskFolder: taskFolder,
            hostFileAccess: hostFileAccess,
            accessRoot: accessRoot
        )
            .suffix(window.fileLimit)

        guard !turnFiles.isEmpty else { return nil }

        let intent = HostFileAccessIntent.astraManagedStorage(root: accessRoot)
        let transcriptSections = turnFiles.enumerated().compactMap { offset, path -> String? in
            let recentIndex = turnFiles.count - offset
            let maxCharacters = recentIndex <= window.fullOutputFileLimit
                ? window.fullOutputMaxCharacters
                : window.olderOutputMaxCharacters
            guard let text = try? boundedString(
                at: URL(fileURLWithPath: path),
                maxCharacters: maxCharacters,
                keeping: .prefix,
                hostFileAccess: hostFileAccess,
                intent: intent
            ),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
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

    private static func sessionHistorySummary(
        taskFolder: String,
        window: TranscriptWindow,
        hostFileAccess: HostFileAccessBroker,
        accessRoot: URL
    ) -> PromptContextSnapshotText? {
        let historyPath = SessionHistoryManager.historyPath(taskFolder: taskFolder)
        guard let history = try? boundedString(
            at: URL(fileURLWithPath: historyPath),
            maxCharacters: window.fullOutputMaxCharacters,
            keeping: .suffix,
            hostFileAccess: hostFileAccess,
            intent: .astraManagedStorage(root: accessRoot)
        ),
              !history.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return PromptContextSnapshotText(
            text: recentSessionHistorySummary(from: history, window: window),
            sourcePointers: [PromptContextSourcePointer(label: "session history", target: historyPath)]
        )
    }

    static func outputTurnFilePaths(
        taskFolder: String,
        hostFileAccess: HostFileAccessBroker = HostFileAccessBroker(),
        accessRoot: URL? = nil
    ) -> [String] {
        let root = accessRoot ?? URL(fileURLWithPath: taskFolder, isDirectory: true)
        let outputDirectory = (taskFolder as NSString).appendingPathComponent("outputs")
        guard let urls = try? hostFileAccess.contentsOfDirectory(
            at: URL(fileURLWithPath: outputDirectory),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles],
            intent: .astraManagedStorage(root: root)
        ) else { return [] }

        return urls
            .filter { url in
                let name = url.lastPathComponent
                return name.hasPrefix("turn_") && name.hasSuffix(".md")
            }
            .map(\.path)
            .sorted { ($0 as NSString).lastPathComponent < ($1 as NSString).lastPathComponent }
    }

    private static func recentSessionHistorySummary(from history: String, window: TranscriptWindow) -> String {
        let marker = "\n## Turn "
        let pieces = history.components(separatedBy: marker)
        guard pieces.count > 1 else {
            return boundedText(history, maxCharacters: 4_000, keeping: .suffix)
        }

        let header = pieces[0]
        let recentTurns = pieces.dropFirst().suffix(window.fileLimit).map { "## Turn " + $0 }
        let summary = ([header] + recentTurns).joined(separator: "\n")
        return boundedText(summary, maxCharacters: window.fullOutputMaxCharacters, keeping: .suffix)
    }

    private static func boundedString(
        at url: URL,
        maxCharacters: Int,
        keeping bound: TextBound,
        hostFileAccess: HostFileAccessBroker,
        intent: HostFileAccessIntent
    ) throws -> String {
        let data = try hostFileAccess.readData(
            at: url,
            maxBytes: byteLimit(for: maxCharacters),
            keeping: bound.fileReadBound,
            intent: intent
        )
        guard let string = utf8String(from: data, keeping: bound) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return string
    }

    static func byteLimit(for maxCharacters: Int) -> Int {
        guard maxCharacters > 0 else { return 0 }
        let scaledLimit = maxCharacters <= Int.max / 4
            ? maxCharacters * 4
            : Int.max
        return min(scaledLimit, maximumSnapshotReadBytes)
    }

    static func utf8String(from data: Data, keeping bound: TextBound) -> String? {
        if let string = String(data: data, encoding: .utf8) {
            return string
        }

        for trimCount in 1...min(3, data.count) {
            let repaired: Data
            switch bound {
            case .prefix:
                repaired = Data(data.dropLast(trimCount))
            case .suffix:
                repaired = Data(data.dropFirst(trimCount))
            }
            if let string = String(data: repaired, encoding: .utf8) {
                return string
            }
        }
        return nil
    }

    enum TextBound {
        case prefix
        case suffix

        var fileReadBound: HostFileReadBound {
            switch self {
            case .prefix:
                return .prefix
            case .suffix:
                return .suffix
            }
        }
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

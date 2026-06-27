import Foundation

enum AgentRuntimeAttachmentProjection {
    private static let attachmentHeaders: Set<String> = [
        "attached files:",
        "attached files/folders (dragged by user):"
    ]

    static func readablePaths(
        for task: AgentTask,
        contextText: String,
        fileManager: FileManager = .default
    ) -> [String] {
        var candidates = task.inputs
        candidates.append(contentsOf: attachmentBlockPaths(in: contextText))
        return normalizedExistingPaths(candidates, fileManager: fileManager)
    }

    static func attachmentBlockPaths(in text: String) -> [String] {
        var paths: [String] = []
        var isReadingAttachmentBlock = false

        for line in text.components(separatedBy: .newlines) {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            let lowercasedLine = trimmedLine.lowercased()
            if attachmentHeaders.contains(lowercasedLine) {
                isReadingAttachmentBlock = true
                continue
            }

            guard isReadingAttachmentBlock else { continue }
            guard !trimmedLine.isEmpty else {
                isReadingAttachmentBlock = false
                continue
            }
            guard trimmedLine.hasPrefix("- ") || trimmedLine.hasPrefix("* ") else {
                isReadingAttachmentBlock = false
                continue
            }

            let rawPath = String(trimmedLine.dropFirst(2))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            paths.append(stripPathDecoratorsForLaunchResources(rawPath))
        }

        return paths
    }

    private static func normalizedExistingPaths(
        _ paths: [String],
        fileManager: FileManager
    ) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []

        for path in paths {
            guard let normalized = normalizedExistingPath(path, fileManager: fileManager),
                  seen.insert(normalized).inserted else {
                continue
            }
            result.append(normalized)
        }

        return result
    }

    private static func normalizedExistingPath(
        _ rawPath: String,
        fileManager: FileManager
    ) -> String? {
        var path = stripPathDecoratorsForLaunchResources(rawPath)
        if path.hasPrefix("file://"), let url = URL(string: path), url.isFileURL {
            path = url.path
        }
        path = (path as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else { return nil }

        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }

        let standardized = URL(fileURLWithPath: path, isDirectory: isDirectory.boolValue)
            .standardizedFileURL
            .path
        return standardized
    }

    static func stripPathDecoratorsForLaunchResources(_ value: String) -> String {
        var cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        for pair in [("`", "`"), ("\"", "\""), ("'", "'")] where cleaned.hasPrefix(pair.0) && cleaned.hasSuffix(pair.1) {
            cleaned.removeFirst(pair.0.count)
            cleaned.removeLast(pair.1.count)
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned
    }
}

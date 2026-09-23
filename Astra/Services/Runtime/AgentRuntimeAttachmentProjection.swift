import Foundation
import ASTRACore
import ASTRAModels

enum AgentRuntimeAttachmentProjection {
    static func readablePaths(
        for task: AgentTask,
        contextText: String,
        fileManager: FileManager = .default
    ) -> [String] {
        var candidates = task.inputs
        candidates.append(contentsOf: TaskAttachmentBlock.paths(in: contextText))
        return normalizedExistingPaths(candidates, fileManager: fileManager)
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
        var path = TaskAttachmentBlock.stripPathDecorators(rawPath)
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
}

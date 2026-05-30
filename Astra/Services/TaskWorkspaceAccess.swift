import Foundation
import ASTRACore

struct TaskWorkspaceAccess {
    let task: AgentTask

    var effectiveWorkspacePath: String {
        task.workspace?.primaryPath ?? ""
    }

    var codeWorkingDirectory: String {
        // A thread pinned to a worktree always runs in that checkout, as long as
        // it still exists. If the worktree was removed, fall through to the
        // normal resolution so the thread degrades to the repository root
        // instead of failing on a missing directory.
        if let pinned = task.executionRootPath,
           !pinned.isEmpty,
           FileManager.default.fileExists(atPath: pinned) {
            return pinned
        }
        if let first = task.workspace?.additionalPaths.first,
           !first.isEmpty,
           FileManager.default.fileExists(atPath: first) {
            return first
        }
        return effectiveWorkspacePath
    }

    var runtimeAdditionalPaths: [String] {
        var paths = task.workspace?.additionalPaths ?? []
        paths.append(contentsOf: inputDirectoryPaths)

        var seen: Set<String> = []
        return paths.compactMap { rawPath in
            let path = (rawPath as NSString).expandingTildeInPath
            guard !path.isEmpty, !seen.contains(path) else { return nil }
            seen.insert(path)
            return path
        }
    }

    var taskFolder: String {
        WorkspaceFileLayout.readableTaskFolder(workspacePath: effectiveWorkspacePath, taskID: task.id)
    }

    var canonicalTaskFolder: String {
        WorkspaceFileLayout.taskFolder(workspacePath: effectiveWorkspacePath, taskID: task.id)
    }

    @discardableResult
    func ensureTaskFolder(fileSystem: FileSystem = RealFileSystem()) throws -> String {
        let path = WorkspaceFileLayout.migrateLegacyTaskFolderIfNeeded(
            workspacePath: effectiveWorkspacePath,
            taskID: task.id
        )
        guard !path.isEmpty else {
            AppLogger.audit(.taskFailed, category: "General", taskID: task.id, fields: [
                "reason": "task_folder_empty_path"
            ], level: .error)
            return ""
        }
        try fileSystem.createDirectory(at: URL(fileURLWithPath: path), withIntermediateDirectories: true)
        try fileSystem.createDirectory(
            at: URL(fileURLWithPath: path).appendingPathComponent("outputs", isDirectory: true),
            withIntermediateDirectories: true
        )
        return path
    }

    private var inputDirectoryPaths: [String] {
        task.inputs.compactMap { input in
            let path = (input as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return nil
            }
            return path
        }
    }
}

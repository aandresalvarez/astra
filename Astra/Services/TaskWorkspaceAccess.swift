import Foundation
import ASTRACore

struct TaskWorkspaceAccess {
    let task: AgentTask
    private let fileSystem: FileSystem

    init(task: AgentTask, fileSystem: FileSystem = RealFileSystem()) {
        self.task = task
        self.fileSystem = fileSystem
    }

    var effectiveWorkspacePath: String {
        task.workspace?.primaryPath ?? ""
    }

    var codeWorkingDirectory: String {
        // A thread pinned to a repository/worktree always runs in that code root,
        // as long as it still exists. If the pin was removed, fall through to the
        // workspace default instead of failing on a missing directory.
        if let pinned = task.executionRootPath,
           !pinned.isEmpty,
           fileSystem.fileExists(atPath: pinned) {
            return pinned
        }
        return task.workspace?.resolvedWorkingPath ?? effectiveWorkspacePath
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
    func ensureTaskFolder(fileSystem overrideFileSystem: FileSystem? = nil) throws -> String {
        let fileSystem = overrideFileSystem ?? self.fileSystem
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
            guard fileSystem.directoryExists(atPath: path) else {
                return nil
            }
            return path
        }
    }
}

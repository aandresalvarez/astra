import Foundation
import ASTRACore

struct TaskWorkspaceAccess {
    let task: AgentTask

    var effectiveWorkspacePath: String {
        task.workspace?.primaryPath ?? ""
    }

    var codeWorkingDirectory: String {
        if let first = task.workspace?.additionalPaths.first,
           !first.isEmpty,
           FileManager.default.fileExists(atPath: first) {
            return first
        }
        return effectiveWorkspacePath
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
        return path
    }
}

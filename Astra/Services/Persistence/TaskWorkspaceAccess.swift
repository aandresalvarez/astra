import Foundation
import ASTRACore
import ASTRAModels

public struct TaskWorkspaceAccess {
    public let task: AgentTask
    private let fileSystem: FileSystem

    public init(task: AgentTask, fileSystem: FileSystem = RealFileSystem()) {
        self.task = task
        self.fileSystem = fileSystem
    }

    public var effectiveWorkspacePath: String {
        task.workspace?.primaryPath ?? ""
    }

    public var codeWorkingDirectory: String {
        // A thread pinned to a repository/worktree always runs in that code root,
        // as long as it still exists. Legacy pins degrade to the workspace
        // default; an explicitly created task worktree must instead fail launch
        // if removed, never silently send work to the original checkout.
        if let pinned = task.executionRootPath,
           !pinned.isEmpty,
           fileSystem.fileExists(atPath: pinned) || worktreeEvent != nil {
            return pinned
        }
        if let workspace = task.workspace {
            let resolved = workspace.resolvedWorkingPath
            if resolved != workspace.primaryPath {
                return resolved
            }
            if let soleGitRepository = soleConfiguredGitRepository(in: workspace) {
                return soleGitRepository
            }
            return resolved
        }
        return effectiveWorkspacePath
    }

    public var runtimeWritablePaths: [String] {
        projectedRuntimePaths(task.workspace?.additionalPaths ?? [])
    }

    public var runtimeWorkspacePaths: [String] {
        guard let workspace = task.workspace else { return [] }
        return projectedRuntimePaths([workspace.primaryPath] + workspace.additionalPaths)
    }

    public var runtimeWorkspaceFolders: [WorkspacePathDescriptor] {
        let paths = runtimeWorkspacePaths
        return WorkspacePathPresentation.descriptors(
            primaryPath: paths.first ?? codeWorkingDirectory,
            additionalPaths: Array(paths.dropFirst())
        )
    }

    public var runtimeReadOnlyInputPaths: [String] {
        normalizedUniquePaths(inputPaths)
    }

    private var worktreeEvent: TaskEvent? {
        task.events.filter { $0.hasType(TaskEventTypes.Task.worktreePrepared) }
            .max { $0.timestamp < $1.timestamp }
    }

    private func projectedRuntimePaths(_ paths: [String]) -> [String] {
        guard let pinned = task.executionRootPath, let event = worktreeEvent else {
            return normalizedUniquePaths(paths)
        }
        let binding: TaskWorktreePayload
        switch event.decodePayload(as: TaskWorktreePayload.self) {
        case .success(let payload):
            binding = payload
        case .failure(let error):
            AuditLoggingSeam.required.audit(.taskFailed, category: "Persistence", taskID: task.id, fields: [
                "reason": "worktree_binding_invalid",
                "error": error.description
            ], level: .error)
            // Never restore access to the original checkout from a broken binding.
            return []
        }
        guard WorkspacePathPresentation.standardizedPath(pinned)
                == WorkspacePathPresentation.standardizedPath(binding.worktreePath) else {
            // A draft can still be explicitly retargeted from the Repository panel.
            return normalizedUniquePaths(paths)
        }
        let repository = URL(fileURLWithPath: binding.repositoryPath)
            .resolvingSymlinksInPath().standardizedFileURL.path
        return normalizedUniquePaths(paths.map { path in
            let resolved = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                .resolvingSymlinksInPath().standardizedFileURL.path
            if resolved == repository { return pinned }
            if resolved.hasPrefix(repository + "/") {
                return pinned + resolved.dropFirst(repository.count)
            }
            return path
        })
    }

    private func normalizedUniquePaths(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        return paths.compactMap { rawPath in
            let path = (rawPath as NSString).expandingTildeInPath
            guard !path.isEmpty, !seen.contains(path) else { return nil }
            seen.insert(path)
            return path
        }
    }

    public var taskFolder: String {
        WorkspaceFileLayout.readableTaskFolder(workspacePath: effectiveWorkspacePath, taskID: task.id)
    }

    public var canonicalTaskFolder: String {
        WorkspaceFileLayout.taskFolder(workspacePath: effectiveWorkspacePath, taskID: task.id)
    }

    @discardableResult
    public func ensureTaskFolder(fileSystem overrideFileSystem: FileSystem? = nil) throws -> String {
        let fileSystem = overrideFileSystem ?? self.fileSystem
        let path = WorkspaceFileLayout.migrateLegacyTaskFolderIfNeeded(
            workspacePath: effectiveWorkspacePath,
            taskID: task.id
        )
        guard !path.isEmpty else {
            AuditLoggingSeam.required.audit(.taskFailed, category: "General", taskID: task.id, fields: [
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

    /// Task inputs projected for read-only mounting. Includes both directories
    /// and single files (e.g. an attached PDF/config file outside the
    /// workspace) so containerized runs mount the same paths the host/Seatbelt
    /// launch-resource path already grants as read-only.
    private var inputPaths: [String] {
        task.inputs.compactMap { input in
            let path = (input as NSString).expandingTildeInPath
            guard fileSystem.fileExists(atPath: path) else {
                return nil
            }
            return path
        }
    }

    private func soleConfiguredGitRepository(in workspace: Workspace) -> String? {
        guard !isGitRepository(workspace.primaryPath) else { return nil }
        let gitRepositories = workspace.additionalPaths
            .map { ($0 as NSString).expandingTildeInPath }
            .filter { !$0.isEmpty && isGitRepository($0) }
        guard gitRepositories.count == 1 else { return nil }
        return gitRepositories[0]
    }

    private func isGitRepository(_ path: String) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        guard fileSystem.directoryExists(atPath: expanded) else { return false }
        return fileSystem.fileExists(
            atPath: (expanded as NSString).appendingPathComponent(".git")
        )
    }
}

/// Registered as the `TaskFolderResolvingSeam`
/// (`ASTRACore/TaskForkLifecycleSeams.swift`) backing implementation -
/// mirrors `taskFolder`/`ensureTaskFolder()` above exactly, since both were
/// already effectively primitive (`workspacePath`/`taskID` only).
public enum TaskFolderResolvingAdapter: TaskFolderResolving {
    public static func taskFolder(workspacePath: String, taskID: UUID) -> String {
        WorkspaceFileLayout.readableTaskFolder(workspacePath: workspacePath, taskID: taskID)
    }

    public static func ensureTaskFolder(workspacePath: String, taskID: UUID) throws -> String {
        let path = WorkspaceFileLayout.migrateLegacyTaskFolderIfNeeded(
            workspacePath: workspacePath,
            taskID: taskID
        )
        guard !path.isEmpty else {
            AuditLoggingSeam.required.audit(.taskFailed, category: "General", taskID: taskID, fields: [
                "reason": "task_folder_empty_path"
            ], level: .error)
            return ""
        }
        let fileSystem = RealFileSystem()
        try fileSystem.createDirectory(at: URL(fileURLWithPath: path), withIntermediateDirectories: true)
        try fileSystem.createDirectory(
            at: URL(fileURLWithPath: path).appendingPathComponent("outputs", isDirectory: true),
            withIntermediateDirectories: true
        )
        return path
    }
}

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
           fileSystem.fileExists(atPath: pinned) || hasWorktreeEvent {
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
        runtimePathProjection(task.workspace?.additionalPaths ?? []).writable
    }

    public var runtimeWorkspacePaths: [String] {
        guard let workspace = task.workspace else { return [] }
        return runtimePathProjection([workspace.primaryPath] + workspace.additionalPaths).writable
    }

    /// Configured folders that contain the source checkout of the task's
    /// worktree. Writing to them would reach that checkout, so they stay
    /// readable only and the worktree is the one writable copy.
    public var runtimeReadOnlyWorkspacePaths: [String] {
        guard let workspace = task.workspace else { return [] }
        return runtimePathProjection([workspace.primaryPath] + workspace.additionalPaths).readOnly
    }

    /// The Git directory the task's worktree shares with its source checkout.
    /// The worktree's index, refs, and objects live there, so Git commands in
    /// the worktree need it even though the source working tree is not
    /// granted. It is derived from the recorded source repository, never from
    /// the worktree's own `.git` file, which the task can rewrite.
    public var runtimeWorktreeGitMetadataPaths: [String] {
        guard let binding = worktreeBinding,
              let commonDirectory = TaskWorktreeBinding.gitCommonDirectory(for: binding) else {
            return []
        }
        return [commonDirectory]
    }

    /// The `task.worktree.prepared` event that binds the task to its pinned
    /// worktree. Nil for legacy pins, retargeted drafts, and unreadable
    /// bindings.
    public var worktreeBindingEvent: TaskEvent? {
        TaskWorktreeBinding.event(for: task)
    }

    public var worktreeBinding: TaskWorktreePayload? {
        TaskWorktreeBinding.payload(for: task)
    }

    public var runtimeWorkspaceFolders: [WorkspacePathDescriptor] {
        let paths = runtimeWorkspacePaths
        let writable = WorkspacePathPresentation.descriptors(
            primaryPath: paths.first ?? codeWorkingDirectory,
            additionalPaths: Array(paths.dropFirst())
        )
        let writablePaths = Set(writable.map(\.path))
        return writable + runtimeReadOnlyWorkspaceFolders.filter { !writablePaths.contains($0.path) }
    }

    public var runtimeReadOnlyWorkspaceFolders: [WorkspacePathDescriptor] {
        guard let workspace = task.workspace else { return [] }
        let paths = Set(runtimeReadOnlyWorkspacePaths.map(WorkspacePathPresentation.standardizedPath))
        return WorkspacePathPresentation.descriptors(
            primaryPath: workspace.primaryPath, additionalPaths: workspace.additionalPaths
        ).filter { paths.contains($0.path) }
    }

    public var runtimeReadOnlyInputPaths: [String] {
        normalizedUniquePaths(inputPaths)
    }

    private var hasWorktreeEvent: Bool {
        task.events.contains { !$0.isDeleted && $0.hasType(TaskEventTypes.Task.worktreePrepared) }
    }

    private struct RuntimePathProjection {
        var writable: [String]
        var readOnly: [String] = []
    }

    private func runtimePathProjection(_ paths: [String]) -> RuntimePathProjection {
        switch TaskWorktreeBinding.state(of: task) {
        case .none:
            return RuntimePathProjection(writable: normalizedUniquePaths(paths))
        case .invalid(let error):
            AuditLoggingSeam.required.audit(.taskFailed, category: "Persistence", taskID: task.id, fields: [
                "reason": "worktree_binding_invalid",
                "error": error
            ], level: .error)
            return RuntimePathProjection(writable: [])
        case .retargeted(let pinned):
            // The pin is still the checkout this task runs in.
            return RuntimePathProjection(writable: normalizedUniquePaths(paths + [pinned]))
        case .bound(let binding, _, let pinned):
            let repository = Self.resolvedPath(binding.repositoryPath)
            var writable: [String] = []
            var readOnly: [String] = []
            for path in paths {
                let resolved = Self.resolvedPath(path)
                if resolved == repository {
                    writable.append(pinned)
                } else if resolved.hasPrefix(repository + "/") {
                    // A nested repository or submodule is its own checkout,
                    // not a source folder of the worktree.
                    writable.append(crossesGitRoot(resolved, below: repository)
                        ? path
                        : pinned + resolved.dropFirst(repository.count))
                } else if repository.hasPrefix(resolved + "/") {
                    // A folder containing the source checkout stays readable;
                    // the worktree takes its writable place.
                    readOnly.append(path)
                    writable.append(pinned)
                } else {
                    writable.append(path)
                }
            }
            if !writable.contains(pinned) {
                writable.append(pinned)
            }
            return RuntimePathProjection(
                writable: normalizedUniquePaths(writable),
                readOnly: normalizedUniquePaths(readOnly)
            )
        }
    }

    private static func resolvedPath(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Whether a folder between `repository` (exclusive) and `path`
    /// (inclusive) is the root of another Git checkout.
    private func crossesGitRoot(_ path: String, below repository: String) -> Bool {
        var current = path
        while current.count > repository.count {
            if fileSystem.fileExists(atPath: (current as NSString).appendingPathComponent(".git")) {
                return true
            }
            current = (current as NSString).deletingLastPathComponent
        }
        return false
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

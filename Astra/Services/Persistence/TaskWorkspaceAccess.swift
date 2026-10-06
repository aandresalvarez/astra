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
        task.acceptedResourceScope?.workspacePath ?? task.workspace?.primaryPath ?? ""
    }

    public var codeWorkingDirectory: String {
        if let scope = task.acceptedResourceScope { return scope.workingDirectory }
        // A thread pinned to a repository/worktree always runs in that code root,
        // as long as it still exists. If the pin was removed, fall through to the
        // workspace default instead of failing on a missing directory.
        if let pinned = task.executionRootPath,
           !pinned.isEmpty,
           fileSystem.fileExists(atPath: pinned) {
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
        if let scope = task.acceptedResourceScope {
            return normalizedUniquePaths(scope.providerWritableFolders + scope.providerWritableGitMetadataFolders)
        }
        return normalizedUniquePaths(task.workspace?.additionalPaths ?? [])
    }

    public var runtimeReadOnlyInputPaths: [String] {
        if let scope = task.acceptedResourceScope {
            return normalizedUniquePaths(scope.resources.filter { $0.role == .input }.map(\.path))
        }
        return normalizedUniquePaths(inputPaths)
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
        if let scope = task.acceptedResourceScope {
            return scope.resources.first { $0.role == .taskStorage }?.path ?? ""
        }
        if let path = boundStoragePath { return path }
        return WorkspaceFileLayout.readableTaskFolder(workspacePath: effectiveWorkspacePath, taskID: task.id)
    }

    public var canonicalTaskFolder: String {
        if let scope = task.acceptedResourceScope {
            return scope.resources.first { $0.role == .taskStorage }?.canonicalPath ?? ""
        }
        if let path = boundStoragePath { return path }
        return WorkspaceFileLayout.taskFolder(workspacePath: effectiveWorkspacePath, taskID: task.id)
    }

    private var boundStoragePath: String? {
        do { return try TaskStorageBinding.load(for: task)?.path }
        catch {
            AuditLoggingSeam.required.audit(.taskFailed, category: "Persistence", taskID: task.id,
                fields: ["reason": "invalid_task_storage_binding", "error": error.localizedDescription], level: .error)
            return ""
        }
    }

    @discardableResult
    public func ensureTaskFolder(fileSystem overrideFileSystem: FileSystem? = nil) throws -> String {
        let fileSystem = overrideFileSystem ?? self.fileSystem
        let binding = try TaskStorageBinding.load(for: task)
        let path: String
        if let scope = task.acceptedResourceScope {
            guard scope.isValid, let storage = scope.resources.first(where: { $0.role == .taskStorage }),
                  scope.coversWrite(to: storage.path),
                  binding == nil || binding?.path == storage.canonicalPath else { throw TaskStorageBinding.BindingError.invalid }
            path = storage.canonicalPath
        } else if let binding {
            path = binding.path
            let legacy = WorkspaceFileLayout.legacyTaskFolder(workspacePath: binding.workspacePath, taskID: task.id)
            if !fileSystem.fileExists(atPath: path), fileSystem.fileExists(atPath: legacy) {
                let migrated = WorkspaceFileLayout.migrateLegacyTaskFolderIfNeeded(workspacePath: binding.workspacePath, taskID: task.id)
                guard migrated == path, !fileSystem.fileExists(atPath: legacy) else { throw TaskStorageBinding.BindingError.invalid }
            }
        } else {
            path = WorkspaceFileLayout.migrateLegacyTaskFolderIfNeeded(workspacePath: effectiveWorkspacePath, taskID: task.id)
        }
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

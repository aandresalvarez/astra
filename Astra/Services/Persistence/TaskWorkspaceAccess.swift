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

    /// Additional folders a write-capable run may modify. Admission claims,
    /// sandbox grants, Docker mounts, and provider directory arguments all
    /// derive from this list, so narrowing it narrows every projection at once.
    public var runtimeWritablePaths: [String] {
        let replaced = Set(replacedSourceCheckoutPaths)
        return normalizedUniquePaths(task.workspace?.additionalPaths ?? []).filter { !replaced.contains($0) }
    }

    /// Workspace folders (primary or additional) that are the root of another
    /// checkout of the same repository as the code working directory. Running
    /// in a linked worktree replaces that source checkout: sibling worktrees
    /// must not each hold it writable, or they serialize on a folder neither
    /// one edits. Subfolders, unrelated repositories, and non-Git folders keep
    /// their access. Identities are compared after resolving symlinks, so an
    /// aliased checkout path still matches Git's real admin path.
    public var replacedSourceCheckoutPaths: [String] {
        let codeRoot = codeWorkingDirectory
        guard !codeRoot.isEmpty,
              let commonDirectory = GitCheckoutLayout.commonDirectory(for: codeRoot).map(Self.resolvedIdentity)
        else { return [] }
        let codeCheckout = GitCheckoutLayout.worktreeRoot(containing: codeRoot).map(Self.resolvedIdentity)
        let folders = [task.workspace?.primaryPath ?? ""] + (task.workspace?.additionalPaths ?? [])
        return normalizedUniquePaths(folders).filter { path in
            guard let checkout = GitCheckoutLayout.worktreeRoot(containing: path) else { return false }
            return checkout == URL(fileURLWithPath: path).standardizedFileURL.path
                && Self.resolvedIdentity(checkout) != codeCheckout
                && GitCheckoutLayout.commonDirectory(for: path).map(Self.resolvedIdentity) == commonDirectory
        }
    }

    /// Workspace folders the run can read but not write: a replaced source
    /// checkout, or a workspace folder that is not the code root. Docker
    /// mounts them read-only so they stay visible inside the container.
    public var runtimeReadOnlyWorkspacePaths: [String] {
        let writable = Set(runtimeWritablePaths + normalizedUniquePaths([codeWorkingDirectory]))
        let folders = [task.workspace?.primaryPath ?? ""] + (task.workspace?.additionalPaths ?? [])
        return normalizedUniquePaths(folders).filter {
            !writable.contains($0) && fileSystem.directoryExists(atPath: $0)
        }
    }

    private static func resolvedIdentity(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    public var runtimeReadOnlyInputPaths: [String] {
        normalizedUniquePaths(inputPaths)
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

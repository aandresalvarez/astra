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

    /// Additional folders a write-capable run may modify. Admission claims,
    /// sandbox grants, Docker mounts, and provider directory arguments all
    /// derive from this list, so narrowing it narrows every projection at once.
    public var runtimeWritablePaths: [String] {
        let replaced = Set(replacedSourceCheckoutPaths)
        return runtimePathProjection(task.workspace?.additionalPaths ?? []).writable.filter { !replaced.contains($0) }
    }

    /// The code root a write-capable run may modify. Nil while the task's
    /// worktree binding cannot be verified, so an unverified checkout is never
    /// granted.
    public var runtimeWritableCodeRoot: String? {
        let codeRoot = codeWorkingDirectory
        guard !codeRoot.isEmpty else { return nil }
        if case .invalid = TaskWorktreeBinding.state(of: task) { return nil }
        return codeRoot
    }

    /// Every configured folder as this task sees it: a prepared worktree takes
    /// the place of its source checkout and of the folders inside it. This is
    /// presentation only; writable roots come from `runtimeWritablePaths` and
    /// `runtimeWritableCodeRoot`.
    public var runtimeWorkspacePaths: [String] {
        guard let workspace = task.workspace else { return [] }
        return runtimePathProjection([workspace.primaryPath] + workspace.additionalPaths).writable
    }

    /// Workspace folders (primary or additional) whose writable place the
    /// task's worktree takes: the root of another checkout of the code root's
    /// repository and, for a worktree ASTRA prepared, the source folders it
    /// projects into that worktree. Sibling worktrees must not each hold them
    /// writable, or they serialize on folders neither one edits. Unrelated
    /// repositories, non-Git folders, and an unbound task's subfolders keep
    /// their access. Identities are compared after resolving symlinks, so an
    /// aliased checkout path still matches Git's real admin path.
    public var replacedSourceCheckoutPaths: [String] {
        let state = TaskWorktreeBinding.state(of: task)
        let additionalPaths = task.workspace?.additionalPaths ?? []
        let folders = normalizedUniquePaths([task.workspace?.primaryPath ?? ""] + additionalPaths)
        let projected = Set(runtimePathProjection(folders, state: state).projected)
        let codeRoot = codeWorkingDirectory
        let commonDirectory: String?
        if case .bound(let binding, _, _) = state {
            // Read the verified binding, never the worktree's own `.git` file.
            commonDirectory = TaskWorktreeBinding.gitCommonDirectory(for: binding)
        } else {
            commonDirectory = codeRoot.isEmpty
                ? nil
                : GitCheckoutLayout.commonDirectory(for: codeRoot).map(Self.resolvedIdentity)
        }
        let codeCheckout = GitCheckoutLayout.worktreeRoot(containing: codeRoot).map(Self.resolvedIdentity)
        let candidates = folders.filter { path in
            if projected.contains(path) { return true }
            guard let commonDirectory,
                  let checkout = GitCheckoutLayout.worktreeRoot(containing: path) else { return false }
            return checkout == URL(fileURLWithPath: path).standardizedFileURL.path
                && Self.resolvedIdentity(checkout) != codeCheckout
                && GitCheckoutLayout.commonDirectory(for: path).map(Self.resolvedIdentity) == commonDirectory
        }
        // A checkout beneath an additional folder that stays writable is still
        // writable through that parent, so it is not treated as replaced. A
        // folder containing a prepared worktree's source is read-only, so it
        // never counts as such a parent.
        let writableParents = runtimePathProjection(additionalPaths, state: state).writable
            .filter { !candidates.contains($0) }
            .map(Self.resolvedIdentity)
        return candidates.filter { candidate in
            let path = Self.resolvedIdentity(candidate)
            return !writableParents.contains { $0 != path && path.hasPrefix($0 + "/") }
        }
    }

    /// Workspace folders the run can read but not write: a replaced source
    /// checkout, a folder containing a prepared worktree's source, or a
    /// workspace folder that is not the code root. Docker mounts them
    /// read-only so they stay visible inside the container. A prepared
    /// worktree's admission holds each of them shared, so a writer of the
    /// folder waits for the task.
    public var runtimeReadOnlyWorkspacePaths: [String] {
        let writable = Set(runtimeWritablePaths + normalizedUniquePaths([codeWorkingDirectory]))
        let folders = [task.workspace?.primaryPath ?? ""] + (task.workspace?.additionalPaths ?? [])
        return normalizedUniquePaths(folders).filter {
            !writable.contains($0) && fileSystem.directoryExists(atPath: $0)
        }
    }

    /// Configured folders that contain the source checkout of the task's
    /// prepared worktree. Writing to them would reach that checkout, so they
    /// stay read-only, and admission holds them shared so a writer to the
    /// folder waits for the task.
    public var runtimeWorktreeSourceAncestorPaths: [String] {
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

    /// The task's folders for prompts and context: `runtimeWorkspacePaths`,
    /// then each configured folder the task can only read.
    public var runtimeWorkspaceFolders: [WorkspacePathDescriptor] {
        let paths = runtimeWorkspacePaths
        let folders = WorkspacePathPresentation.descriptors(
            primaryPath: paths.first ?? codeWorkingDirectory,
            additionalPaths: Array(paths.dropFirst())
        )
        let listed = Set(folders.map(\.path))
        return folders + runtimeReadOnlyWorkspaceFolders.filter { !listed.contains($0.path) }
    }

    public var runtimeReadOnlyWorkspaceFolders: [WorkspacePathDescriptor] {
        guard let workspace = task.workspace else { return [] }
        let paths = Set(runtimeReadOnlyWorkspacePaths.map(WorkspacePathPresentation.standardizedPath))
        return WorkspacePathPresentation.descriptors(
            primaryPath: workspace.primaryPath, additionalPaths: workspace.additionalPaths
        ).filter { paths.contains($0.path) }
    }

    private static func resolvedIdentity(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
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
        /// Input folders a prepared worktree replaced with its own copy.
        var projected: [String] = []
    }

    private func runtimePathProjection(_ paths: [String]) -> RuntimePathProjection {
        let state = TaskWorktreeBinding.state(of: task)
        if case .invalid(let error) = state {
            AuditLoggingSeam.required.audit(.taskFailed, category: "Persistence", taskID: task.id, fields: [
                "reason": "worktree_binding_invalid",
                "error": error
            ], level: .error)
        }
        return runtimePathProjection(paths, state: state)
    }

    private func runtimePathProjection(_ paths: [String], state: TaskWorktreeBinding.State) -> RuntimePathProjection {
        switch state {
        case .none:
            return RuntimePathProjection(writable: normalizedUniquePaths(paths))
        case .invalid:
            return RuntimePathProjection(writable: [])
        case .retargeted(let pinned):
            // The pin is still the checkout this task runs in.
            return RuntimePathProjection(writable: normalizedUniquePaths(paths + [pinned]))
        case .bound(let binding, _, let pinned):
            let repository = Self.resolvedPath(binding.repositoryPath)
            var writable: [String] = []
            var readOnly: [String] = []
            var projected: [String] = []
            for path in paths {
                let resolved = Self.resolvedPath(path)
                if resolved == repository {
                    writable.append(pinned)
                    projected.append(path)
                } else if resolved.hasPrefix(repository + "/") {
                    // A nested repository or submodule is its own checkout,
                    // not a source folder of the worktree.
                    if crossesGitRoot(resolved, below: repository) {
                        writable.append(path)
                    } else {
                        writable.append(pinned + resolved.dropFirst(repository.count))
                        projected.append(path)
                    }
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
                readOnly: normalizedUniquePaths(readOnly),
                projected: normalizedUniquePaths(projected)
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

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

    /// Resolving the binding probes the repository's worktree registry on
    /// disk and most derived properties need it, so an instance reads it
    /// once. Instances are short-lived; a binding change needs a new one.
    private final class BindingStateCache {
        var state: TaskWorktreeBinding.State?
    }

    private let bindingStateCache = BindingStateCache()

    private var worktreeBindingState: TaskWorktreeBinding.State {
        if let state = bindingStateCache.state { return state }
        let state = TaskWorktreeBinding.state(of: task)
        bindingStateCache.state = state
        return state
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
        if case .invalid = worktreeBindingState { return nil }
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
        let state = worktreeBindingState
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
    /// the worktree's own `.git` file, which the task can rewrite. A draft
    /// retargeted to another linked checkout needs its shared Git directory
    /// the same way; one already inside the pinned checkout, as a primary
    /// checkout's `.git` is, comes with it.
    public var runtimeWorktreeGitMetadataPaths: [String] {
        switch worktreeBindingState {
        case .bound(let binding, _, _):
            return TaskWorktreeBinding.gitCommonDirectory(for: binding).map { [$0] } ?? []
        case .retargeted(let pinned, let commonDirectory):
            let checkout = Self.resolvedIdentity(pinned)
            let common = Self.resolvedIdentity(commonDirectory)
            return common == checkout || common.hasPrefix(checkout + "/") ? [] : [commonDirectory]
        case .none, .invalid:
            return []
        }
    }

    /// What Git in the task's checkout writes inside the shared Git
    /// directory: objects, refs, reflogs, a reftable, and the checkout's own
    /// registry entry, which holds its index and HEAD. The rest stays
    /// read-only: the source checkout's index and HEAD, sibling worktrees'
    /// entries, and the shared config and hooks, so a run can neither
    /// restage the source checkout nor plant configuration Git runs there.
    public var runtimeWorktreeGitWritableMetadataPaths: [String] {
        let checkout: String
        switch worktreeBindingState {
        case .bound(let binding, _, _): checkout = binding.worktreePath
        case .retargeted(let pinned, _): checkout = pinned
        case .none, .invalid: return []
        }
        guard let common = runtimeWorktreeGitMetadataPaths.first,
              let entry = TaskWorktreeBinding.registeredAdminEntry(checkout: checkout, commonDirectory: common)
        else { return [] }
        let shared = ["objects", "refs", "logs", "reftable"]
            .map { (common as NSString).appendingPathComponent($0) }
            .filter { fileSystem.directoryExists(atPath: $0) }
        return shared + [entry]
    }

    /// The `task.worktree.prepared` event that binds the task to its pinned
    /// worktree. Nil for legacy pins, retargeted drafts, and unreadable
    /// bindings.
    public var worktreeBindingEvent: TaskEvent? {
        guard case .bound(_, let event, _) = worktreeBindingState else { return nil }
        return event
    }

    public var worktreeBinding: TaskWorktreePayload? {
        guard case .bound(let payload, _, _) = worktreeBindingState else { return nil }
        return payload
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

    /// An invalid binding is reported once, at the launch gates
    /// (`TaskQueue.prepareTaskFolder`, `TaskLaunchResourceResolver`), not by
    /// every projection that reads it.
    private func runtimePathProjection(_ paths: [String]) -> RuntimePathProjection {
        runtimePathProjection(paths, state: worktreeBindingState)
    }

    private func runtimePathProjection(_ paths: [String], state: TaskWorktreeBinding.State) -> RuntimePathProjection {
        switch state {
        case .none:
            return RuntimePathProjection(writable: normalizedUniquePaths(paths))
        case .invalid:
            return RuntimePathProjection(writable: [])
        case .retargeted(let pinned, _):
            // The pin is still the checkout this task runs in. As for a bound
            // worktree, the checkouts its prepared worktrees came from, and
            // folders containing them, stay readable only: a parent grant
            // would otherwise reach the original checkout and its neighbors.
            let pin = Self.resolvedPath(pinned)
            let sources = preparedSourceRepositories.map(Self.resolvedPath)
            var writable: [String] = []
            var readOnly: [String] = []
            for path in paths {
                let resolved = Self.resolvedPath(path)
                let containsSource = sources.contains { $0.hasPrefix(resolved + "/") }
                let isOtherSource = resolved != pin && sources.contains(resolved)
                // A folder inside another source checkout is part of it, as
                // for a bound worktree, unless a nested repository's own.
                let isInOtherSource = sources.contains { source in
                    source != pin && resolved.hasPrefix(source + "/") && !crossesGitRoot(resolved, below: source)
                }
                if containsSource || isOtherSource || isInOtherSource {
                    readOnly.append(path)
                } else {
                    writable.append(path)
                }
            }
            return RuntimePathProjection(
                writable: normalizedUniquePaths(writable + [pinned]),
                readOnly: normalizedUniquePaths(readOnly)
            )
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
                } else if isInSiblingCheckout(resolved, of: binding, pinned: pinned) {
                    // Another checkout of the same repository, or a folder in
                    // one, is a copy of the source too: readable, not
                    // writable, so the task changes only its own worktree.
                    continue
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

    /// Whether the task runs in a checkout tied to a worktree prepared for
    /// it: that worktree, or a verified checkout it was retargeted to. Its
    /// source folders are read-only either way, so admission and Docker
    /// treat both alike.
    public var runsInPreparedCheckout: Bool {
        switch worktreeBindingState {
        case .bound, .retargeted: return true
        case .none, .invalid: return false
        }
    }

    /// The source checkouts the task must not write through: a bound
    /// worktree's source, or a retargeted draft's prepared sources other
    /// than the checkout it now runs in.
    public var protectedSourceCheckouts: [String] {
        switch worktreeBindingState {
        case .bound(let binding, _, _):
            return [binding.repositoryPath]
        case .retargeted(let pinned, _):
            let pin = Self.resolvedPath(pinned)
            return normalizedUniquePaths(preparedSourceRepositories.filter { Self.resolvedPath($0) != pin })
        case .none, .invalid:
            return []
        }
    }

    /// The source checkout of every worktree prepared for the task.
    private var preparedSourceRepositories: [String] {
        task.events.compactMap { event -> String? in
            guard !event.isDeleted, event.hasType(TaskEventTypes.Task.worktreePrepared),
                  case .success(let payload) = event.decodePayload(as: TaskWorktreePayload.self) else { return nil }
            return payload.repositoryPath
        }
    }

    private static func resolvedPath(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Whether `path` lies in a checkout, other than the task's worktree,
    /// that shares the bound repository's Git directory.
    private func isInSiblingCheckout(_ path: String, of binding: TaskWorktreePayload, pinned: String) -> Bool {
        guard let checkout = GitCheckoutLayout.worktreeRoot(containing: path),
              Self.resolvedPath(checkout) != Self.resolvedPath(pinned),
              let common = GitCheckoutLayout.commonDirectory(for: path),
              let bound = TaskWorktreeBinding.gitCommonDirectory(for: binding) else { return false }
        return Self.resolvedPath(common) == Self.resolvedPath(bound)
    }

    /// Whether a folder between `repository` (exclusive) and `path`
    /// (inclusive) is the root of another Git checkout.
    /// Whether a folder between `repository` and `path` holds a real Git
    /// checkout of its own: its `.git` leads to a valid Git directory other
    /// than the repository's. A stale or malformed `.git` doesn't count, or
    /// it would exempt part of the source checkout from protection.
    private func crossesGitRoot(_ path: String, below repository: String) -> Bool {
        let sourceCommon = GitCheckoutLayout.commonDirectory(for: repository).map(Self.resolvedIdentity)
        var current = path
        while current.count > repository.count {
            if fileSystem.fileExists(atPath: (current as NSString).appendingPathComponent(".git")),
               let common = GitCheckoutLayout.commonDirectory(for: current),
               GitCheckoutLayout.commonDirectory(ofGitDirectory: common) != nil,
               Self.resolvedIdentity(common) != sourceCommon {
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

import Foundation
import SwiftData
import ASTRAModels
import ASTRAPersistence

/// One claim on a checkout, captured on the main actor so the rest of an
/// evaluation can run anywhere.
struct WorktreeTaskHold: Equatable, Sendable {
    let taskTitle: String
    let rootPath: String
    /// `rootPath` with every symlink resolved, computed once.
    let canonicalRootPath: String
    let isTerminal: Bool
    let hasActiveTurnRequest: Bool
    let updatedAt: Date

    init(
        taskTitle: String,
        rootPath: String,
        isTerminal: Bool,
        hasActiveTurnRequest: Bool,
        updatedAt: Date,
        canonicalRootPath: String? = nil
    ) {
        self.taskTitle = taskTitle
        self.rootPath = rootPath
        self.canonicalRootPath = canonicalRootPath ?? WorktreePath.canonical(rootPath)
        self.isTerminal = isTerminal
        self.hasActiveTurnRequest = hasActiveTurnRequest
        self.updatedAt = updatedAt
    }
}

/// Single owner of "is a task using this worktree", shared by worktree
/// removal and artifact reclamation.
///
/// A task claims the checkout it is pinned to (`executionRootPath`), or, only
/// while it is queued or running unpinned, its workspace's active worktree.
/// While it executes it also claims every folder the runtime lets it write
/// (its workspace's additional paths). A queued follow-up turn claims the path
/// its request captured when it was submitted, where it will run even if the
/// task is re-pinned, plus the workspace resources the request claimed. A
/// claim anywhere inside a worktree counts, except inside another worktree
/// nested in it. The worktree is *in use* while a claiming task isn't terminal
/// (draft, queued, running, pending user) or a follow-up still waits.
enum WorktreeTaskUsage {
    /// Claims from live tasks.
    @MainActor
    static func holds(from tasks: some Sequence<AgentTask>) -> [WorktreeTaskHold] {
        var canonical = CanonicalPathMemo()
        return tasks.flatMap { task in
            claimedPaths(of: task).map { path in
                WorktreeTaskHold(
                    taskTitle: task.title,
                    rootPath: path,
                    isTerminal: task.isTerminal,
                    hasActiveTurnRequest: false,
                    updatedAt: task.updatedAt,
                    canonicalRootPath: canonical[path]
                )
            }
        }
    }

    /// Every path a task claims: where it runs code, plus, while it is
    /// queued or running, its working directory and the exact set the runtime
    /// lets it write (`AgentRuntimeProcessRunner.runtimeWritablePaths`, which
    /// includes the workspace's primary path), so a manual reclaim of the
    /// primary checkout can't run underneath it.
    @MainActor
    static func claimedPaths(of task: AgentTask) -> [String] {
        var paths = rootPath(of: task).map { [$0] } ?? []
        if task.status == .running || task.status == .queued {
            let executing = [TaskWorkspaceAccess(task: task).codeWorkingDirectory]
                + AgentRuntimeProcessRunner.runtimeWritablePaths(for: task)
            for path in executing where !path.isEmpty && !paths.contains(path) {
                paths.append(path)
            }
        }
        return paths
    }

    /// Reason reported when task state can't be read. Callers fail closed on
    /// it: nothing is reclaimed or removed until the store answers.
    static let unreadableTaskStateReason = "Task state couldn't be read"

    /// Claims from every task in the store plus every waiting, admitted or
    /// running follow-up turn. Throws when the store can't be read, so no
    /// caller mistakes a failed read for "nothing is running".
    @MainActor
    static func allHolds(in modelContext: ModelContext) throws -> [WorktreeTaskHold] {
        let tasks = try modelContext.fetch(FetchDescriptor<AgentTask>())
        let tasksByID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let requests = try TaskTurnRequestRepository.allActiveRequests(in: modelContext)
        var canonical = CanonicalPathMemo()
        let requestHolds: [WorktreeTaskHold] = requests.flatMap { request -> [WorktreeTaskHold] in
            let task = tasksByID[request.taskID]
            let captured = request.executionPolicySnapshot?.executionRootPath.flatMap { $0.isEmpty ? nil : $0 }
            var paths = (captured ?? task.flatMap(rootPath(of:))).map { [$0] } ?? []
            for claim in request.resourceClaims where claim.kind == .workspace && !claim.key.isEmpty && !paths.contains(claim.key) {
                paths.append(claim.key)
            }
            return paths.map { path in
                WorktreeTaskHold(
                    taskTitle: task?.title ?? "a queued turn",
                    rootPath: path,
                    isTerminal: task?.isTerminal ?? true,
                    hasActiveTurnRequest: true,
                    updatedAt: task?.updatedAt ?? request.submittedAt,
                    canonicalRootPath: canonical[path]
                )
            }
        }
        return holds(from: tasks) + requestHolds
    }

    /// Why a task holds the worktree at `path`, or nil when none does.
    /// `otherWorktreePaths` are the repository's other worktrees, so a claim
    /// inside a nested one isn't attributed to its parent.
    static func inUseReason(
        forWorktreePath path: String,
        holds: [WorktreeTaskHold],
        otherWorktreePaths: [String] = []
    ) -> String? {
        let scope = WorktreeScope(path: path, otherWorktreePaths: otherWorktreePaths)
        for hold in holds where scope.contains(canonicalPath: hold.canonicalRootPath) {
            if !hold.isTerminal { return "In use by task “\(hold.taskTitle)”" }
            if hold.hasActiveTurnRequest { return "Follow-up queued for task “\(hold.taskTitle)”" }
        }
        return nil
    }

    /// Latest `updatedAt` among tasks that worked in the worktree. Every task
    /// event, status change and finished run bumps it.
    static func latestActivity(
        forWorktreePath path: String,
        holds: [WorktreeTaskHold],
        otherWorktreePaths: [String] = []
    ) -> Date? {
        let scope = WorktreeScope(path: path, otherWorktreePaths: otherWorktreePaths)
        return holds.lazy
            .filter { scope.contains(canonicalPath: $0.canonicalRootPath) }
            .map(\.updatedAt)
            .max()
    }

    /// Where a task runs code: its pin, or its workspace's active worktree
    /// while it executes unpinned.
    @MainActor
    static func rootPath(of task: AgentTask) -> String? {
        if let pinned = task.executionRootPath, !pinned.isEmpty { return pinned }
        guard task.status == .running || task.status == .queued,
              let workspace = task.workspace, workspace.isUsingWorktree,
              let active = workspace.activeWorkingPath, !active.isEmpty else { return nil }
        return active
    }

    /// Paths automatic mode keeps like the primary checkout: each workspace's
    /// configured folders and the worktree it currently has selected.
    @MainActor
    static func protectedWorkspacePaths(of workspaces: [Workspace]) -> [String] {
        workspaces.flatMap { workspace -> [String] in
            var paths = [workspace.primaryPath] + workspace.additionalPaths
            if let active = workspace.activeWorkingPath, !active.isEmpty { paths.append(active) }
            return paths
        }
    }
}

/// Canonicalizes each distinct path once per batch: tasks share a handful of
/// roots, so this keeps symlink resolution off the per-task path.
private struct CanonicalPathMemo {
    private var resolved: [String: String] = [:]

    subscript(path: String) -> String {
        mutating get {
            if let known = resolved[path] { return known }
            let canonical = WorktreePath.canonical(path)
            resolved[path] = canonical
            return canonical
        }
    }
}

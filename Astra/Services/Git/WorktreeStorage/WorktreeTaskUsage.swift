import Foundation
import SwiftData
import ASTRAModels

/// One task's claim on a checkout, captured on the main actor so the rest of
/// an evaluation can run anywhere.
struct WorktreeTaskHold: Equatable, Sendable {
    let taskTitle: String
    let rootPath: String
    let isTerminal: Bool
    let hasActiveTurnRequest: Bool
    let updatedAt: Date
}

/// Single owner of "is a task using this worktree", shared by worktree
/// removal and artifact reclamation.
///
/// A task claims the checkout it is pinned to (`executionRootPath`), or, only
/// while it is queued or running unpinned, its workspace's active worktree.
/// The claim makes the worktree *in use* while the task isn't terminal (draft,
/// queued, running, pending user) or while a follow-up turn waits for it:
/// queuing a follow-up leaves a finished task's status untouched until the
/// turn is admitted. Paths compare canonically (see `WorktreePath`).
enum WorktreeTaskUsage {
    /// Claims from live tasks. `activeTurnRequestTaskIDs` are tasks with a
    /// waiting, admitted or running follow-up.
    @MainActor
    static func holds(
        from tasks: some Sequence<AgentTask>,
        activeTurnRequestTaskIDs: Set<UUID> = []
    ) -> [WorktreeTaskHold] {
        tasks.compactMap { task in
            guard let root = rootPath(of: task) else { return nil }
            return WorktreeTaskHold(
                taskTitle: task.title,
                rootPath: root,
                isTerminal: task.isTerminal,
                hasActiveTurnRequest: activeTurnRequestTaskIDs.contains(task.id),
                updatedAt: task.updatedAt
            )
        }
    }

    /// Why a task holds the worktree at `path`, or nil when none does.
    static func inUseReason(forWorktreePath path: String, holds: [WorktreeTaskHold]) -> String? {
        for hold in holds where WorktreePath.same(hold.rootPath, path) {
            if !hold.isTerminal { return "In use by task “\(hold.taskTitle)”" }
            if hold.hasActiveTurnRequest { return "Follow-up queued for task “\(hold.taskTitle)”" }
        }
        return nil
    }

    /// Latest `updatedAt` among tasks that worked in the worktree. Every task
    /// event, status change and finished run bumps it.
    static func latestActivity(forWorktreePath path: String, holds: [WorktreeTaskHold]) -> Date? {
        holds.lazy.filter { WorktreePath.same($0.rootPath, path) }.map(\.updatedAt).max()
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

    /// Task IDs with a waiting, admitted or running follow-up turn.
    @MainActor
    static func activeTurnRequestTaskIDs(in modelContext: ModelContext) -> Set<UUID> {
        let requests = (try? TaskTurnRequestRepository.allActiveRequests(in: modelContext)) ?? []
        return Set(requests.map(\.taskID))
    }

    /// Claims from every task in the store, including queued follow-ups.
    @MainActor
    static func allHolds(in modelContext: ModelContext) -> [WorktreeTaskHold] {
        let tasks = (try? modelContext.fetch(FetchDescriptor<AgentTask>())) ?? []
        return holds(from: tasks, activeTurnRequestTaskIDs: activeTurnRequestTaskIDs(in: modelContext))
    }
}

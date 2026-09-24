import Foundation
import SwiftData
import ASTRAModels
import ASTRAPersistence

extension Notification.Name {
    /// Posted on the main actor when a task's status changes into a terminal
    /// state (`AgentTask.isTerminal`). It fires from `TaskStateMachine` before
    /// the caller saves, while a worker may still hold the task, so observers
    /// should treat it as a cue to look again, not as settled state.
    static let taskDidReachTerminalState = Notification.Name("astra.taskDidReachTerminalState")
}

/// What finished, and the checkout it was working in.
struct TaskTerminalStateChange: Equatable, Sendable {
    let taskID: UUID
    let status: TaskStatus
    /// The task's pinned checkout, or its workspace's active worktree when the
    /// task wasn't pinned. Nil when it ran in the workspace's primary path.
    let workingPath: String?
    /// Folders the runtime let the task write (the same set it grants), plus
    /// what its most recent turn requests captured: a turn runs where its
    /// request's snapshot says, even if the task was re-pinned since.
    var writablePaths: [String] = []
}

@MainActor
enum TaskTerminalStateNotifier {
    static func post(for task: AgentTask) {
        let pinned = task.executionRootPath.flatMap { $0.isEmpty ? nil : $0 }
        let workspaceWorktree = task.workspace?.isUsingWorktree == true ? task.workspace?.activeWorkingPath : nil
        NotificationCenter.default.post(
            name: .taskDidReachTerminalState,
            object: TaskTerminalStateChange(
                taskID: task.id,
                status: task.status,
                workingPath: pinned ?? workspaceWorktree,
                writablePaths: AgentRuntimeProcessRunner.runtimeWritablePaths(for: task)
                    + recentRequestPaths(for: task)
            )
        )
    }

    /// Execution roots and workspace claims captured by the task's latest
    /// turn requests. A failed read only means fewer rechecks get scheduled.
    private static func recentRequestPaths(for task: AgentTask) -> [String] {
        guard let modelContext = task.modelContext else { return [] }
        let taskID = task.id
        var descriptor = FetchDescriptor<TaskTurnRequest>(
            predicate: #Predicate { $0.taskID == taskID },
            sortBy: [SortDescriptor(\.sequence, order: .reverse)]
        )
        descriptor.fetchLimit = 3
        let requests = (try? modelContext.fetch(descriptor)) ?? []
        var paths: [String] = []
        for request in requests {
            let captured = [request.executionPolicySnapshot?.executionRootPath].compactMap { $0 }
                + request.resourceClaims.filter { $0.kind == .workspace }.map(\.key)
            for path in captured where !path.isEmpty && !paths.contains(path) {
                paths.append(path)
            }
        }
        return paths
    }
}

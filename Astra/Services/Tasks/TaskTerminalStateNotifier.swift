import Foundation
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
    /// Folders the runtime let the task write besides `workingPath`.
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
                writablePaths: TaskWorkspaceAccess(task: task).runtimeWritablePaths
            )
        )
    }
}

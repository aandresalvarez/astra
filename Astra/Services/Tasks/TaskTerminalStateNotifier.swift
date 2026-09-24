import Foundation
import ASTRAModels
import ASTRAPersistence

extension Notification.Name {
    /// Posted on the main actor when a task's status changes into a terminal
    /// state (`AgentTask.isTerminal`). It fires from `TaskStateMachine` before
    /// the caller saves, while a worker may still hold the task, so observers
    /// should treat it as a cue to look again, not as settled state.
    static let taskDidReachTerminalState = Notification.Name("astra.taskDidReachTerminalState")

    /// Posted on the main actor when a turn request becomes completed, failed
    /// or cancelled (`TaskTurnRequestStateMachine`). A retracted follow-up
    /// releases what it held without any task status change.
    static let taskTurnRequestDidReachTerminalState = Notification.Name("astra.taskTurnRequestDidReachTerminalState")
}

/// What finished, and the checkout it was working in.
struct TaskTerminalStateChange: Equatable, Sendable {
    let taskID: UUID
    let status: TaskStatus
    /// The task's pinned checkout, or its workspace's active worktree when the
    /// task wasn't pinned. Nil when it ran in the workspace's primary path.
    let workingPath: String?
    /// Folders the runtime let the task write (the same set it grants).
    var writablePaths: [String] = []
}

/// A turn request that stopped holding what it captured.
struct TaskTurnRequestTerminalChange: Equatable, Sendable {
    let requestID: UUID
    let taskID: UUID
    let state: TaskTurnRequestState
    /// The execution root and workspace claims captured at submission. A turn
    /// runs there even if its task was re-pinned since.
    let capturedPaths: [String]
    /// True when the turn started, so it worked in those paths.
    let ran: Bool
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
            )
        )
    }

    /// Each request reports its own snapshot when it ends, so the turn that
    /// actually ran is covered however many follow-ups are queued behind it.
    static func post(for request: TaskTurnRequest) {
        var paths: [String] = []
        let captured = [request.executionPolicySnapshot?.executionRootPath].compactMap { $0 }
            + request.resourceClaims.filter { $0.kind == .workspace }.map(\.key)
        for path in captured where !path.isEmpty && !paths.contains(path) {
            paths.append(path)
        }
        NotificationCenter.default.post(
            name: .taskTurnRequestDidReachTerminalState,
            object: TaskTurnRequestTerminalChange(
                requestID: request.id,
                taskID: request.taskID,
                state: request.state,
                capturedPaths: paths,
                ran: request.startedAt != nil
            )
        )
    }
}

import Foundation
import ASTRACore

/// Which commit a new task worktree starts from. The default branch keeps
/// unmerged work on the current checkout out of the new task's branch.
public enum TaskWorktreeBaseChoice: String, Codable, Sendable, CaseIterable {
    case defaultBranch = "default_branch"
    case currentBranch = "current_branch"
}

/// The composer's "start in a new worktree" intent, recorded on a draft so the
/// choice survives reopening it; the worktree itself is created at launch.
public struct TaskWorktreeRequestPayload: Codable, Equatable, Sendable {
    public let enabled: Bool
    public let base: TaskWorktreeBaseChoice

    public init(enabled: Bool, base: TaskWorktreeBaseChoice) {
        self.enabled = enabled
        self.base = base
    }
}

public struct TaskWorktreePayload: Codable, Equatable, Sendable {
    public let repositoryPath: String
    public let worktreePath: String
    public let branch: String
    /// Ref the branch was created from, e.g. `origin/main` or `feature/x`.
    /// Absent on worktrees prepared before the base was recorded.
    public let baseRef: String?
    /// Exact commit the branch was created at. Cleanup only deletes a branch
    /// that still points here, so a branch with work on it is never removed.
    public let baseCommit: String?
    public let baseSource: TaskWorktreeBaseChoice?
    /// False when the remote could not be reached and the last fetched ref
    /// was used instead.
    public let baseFetched: Bool?

    public init(
        repositoryPath: String,
        worktreePath: String,
        branch: String,
        baseRef: String? = nil,
        baseCommit: String? = nil,
        baseSource: TaskWorktreeBaseChoice? = nil,
        baseFetched: Bool? = nil
    ) {
        self.repositoryPath = repositoryPath
        self.worktreePath = worktreePath
        self.branch = branch
        self.baseRef = baseRef
        self.baseCommit = baseCommit
        self.baseSource = baseSource
        self.baseFetched = baseFetched
    }
}

/// The durable link between a task and the worktree ASTRA prepared for it:
/// the newest `task.worktree.prepared` event whose worktree is still the
/// task's pin. Launch grants, the composer, cleanup, and derived tasks all
/// read the binding here so they cannot disagree about it.
public enum TaskWorktreeBinding {
    public enum State {
        /// No pin, or a legacy pin without a prepared worktree.
        case none
        /// An unreadable binding. It never restores access to the original
        /// checkout.
        case invalid(String)
        /// The pin no longer names a worktree ASTRA prepared for this task.
        case retargeted(pinned: String)
        case bound(TaskWorktreePayload, event: TaskEvent, pinned: String)
    }

    public static func state(of task: AgentTask) -> State {
        guard let pinned = task.executionRootPath, !pinned.isEmpty else { return .none }
        let events = task.events
            .filter { !$0.isDeleted && $0.hasType(TaskEventTypes.Task.worktreePrepared) }
            .sorted { $0.timestamp > $1.timestamp }
        guard !events.isEmpty else { return .none }
        let pin = WorkspacePathPresentation.standardizedPath(pinned)
        for event in events {
            switch event.decodePayload(as: TaskWorktreePayload.self) {
            case .success(let payload):
                if WorkspacePathPresentation.standardizedPath(payload.worktreePath) == pin {
                    return .bound(payload, event: event, pinned: pinned)
                }
            case .failure(let error):
                return .invalid(error.description)
            }
        }
        return .retargeted(pinned: pinned)
    }

    public static func event(for task: AgentTask) -> TaskEvent? {
        guard case .bound(_, let event, _) = state(of: task) else { return nil }
        return event
    }

    public static func payload(for task: AgentTask) -> TaskWorktreePayload? {
        guard case .bound(let payload, _, _) = state(of: task) else { return nil }
        return payload
    }

    /// Even an invalid or retargeted binding must follow its pin into a
    /// derived task, or a missing checkout would become a legacy fallback.
    public static func eventForInheritance(from task: AgentTask) -> TaskEvent? {
        event(for: task) ?? task.events
            .filter { !$0.isDeleted && $0.hasType(TaskEventTypes.Task.worktreePrepared) }
            .max { $0.timestamp < $1.timestamp }
    }

    /// Pins `target` to `source`'s checkout. Any prepared event travels with
    /// the pin, including an unreadable one, so a derived task cannot fall
    /// back to the source checkout. Returns the copy for the caller to insert.
    @discardableResult
    public static func inheritPin(from source: AgentTask, into target: AgentTask) -> TaskEvent? {
        target.executionRootPath = source.executionRootPath
        guard let binding = eventForInheritance(from: source) else { return nil }
        return copy(binding, to: target)
    }

    public static func copy(_ binding: TaskEvent, to target: AgentTask) -> TaskEvent {
        TaskEvent(task: target, eventType: TaskEventTypes.Task.worktreePrepared, payload: binding.payload)
    }
}

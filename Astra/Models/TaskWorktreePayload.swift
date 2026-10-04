import Foundation

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

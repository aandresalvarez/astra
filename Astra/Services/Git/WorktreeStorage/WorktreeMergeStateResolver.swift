import Foundation

/// Decides whether a worktree's work already landed, for the removal
/// suggestion only. Any doubt resolves to `.unknown`, which never suggests.
///
/// 1. `git merge-base --is-ancestor <head> <defaultBranch>` catches
///    fast-forward and merge-commit merges.
/// 2. Otherwise the branch's MERGED pull request, required because ASTRA
///    squash-merges. It counts only when the worktree's HEAD equals the PR's
///    head commit or is an ancestor of it: `gh --head` matches the branch name
///    alone, so a reused name or commits added after the merge must not read
///    as merged.
@MainActor
final class WorktreeMergeStateResolver {
    /// Breakers are scoped to the repository, not the branch: a rejected
    /// credential fails every branch alike.
    private static let repositoryScope = "(repository)"

    private let git: WorktreeStorageGitReading
    private let ghPathOverride: String?
    private var breakers: [String: GitPullRequestLookupBreaker] = [:]
    /// Merges GitHub confirmed, by repo, branch and HEAD: a merged pull
    /// request stays merged. Ancestry is never cached, because the base
    /// branch can be retargeted or force-pushed; it is a cheap local check.
    /// Unknown is never cached.
    private var mergedKeys: Set<String> = []
    /// Repositories whose lookup failed during the current pass. One failure
    /// is enough; each lookup can take minutes to time out.
    private var unavailableThisPass: Set<String> = []

    init(git: WorktreeStorageGitReading, ghPathOverride: String? = nil) {
        self.git = git
        self.ghPathOverride = ghPathOverride
    }

    /// Call once per evaluation pass.
    func beginPass() {
        unavailableThisPass.removeAll()
    }

    func resolve(
        worktree: GitWorktreeInfo,
        repoPath: String,
        defaultBranch: String,
        now: Date = Date()
    ) async -> WorktreeMergeState {
        guard let head = worktree.head, !head.isEmpty else { return .unknown("No HEAD commit") }
        let key = [repoPath, worktree.branch ?? "", head].joined(separator: "\u{1}")
        if mergedKeys.contains(key) { return .merged }

        let ancestry = await git.isAncestor(head, of: defaultBranch, at: repoPath)
        if ancestry == .ancestor { return .merged }
        guard let branch = worktree.branch, !branch.isEmpty else {
            return ancestry == .notAncestor ? .notMerged : .unknown("Detached HEAD")
        }
        guard !unavailableThisPass.contains(repoPath) else { return .unknown("GitHub lookup unavailable") }
        var breaker = breakers[repoPath] ?? GitPullRequestLookupBreaker()
        if breaker.shouldSkip(branch: Self.repositoryScope, repoPath: repoPath, now: now) {
            return .unknown("GitHub lookups paused after an authorization failure")
        }

        let lookup = await git.lookupMergedPullRequest(repoPath: repoPath, head: branch, ghPathOverride: ghPathOverride)
        switch lookup {
        case let .unavailable(message):
            breaker.recordFailure(detail: message, branch: Self.repositoryScope, repoPath: repoPath, now: now)
            breakers[repoPath] = breaker
            unavailableThisPass.insert(repoPath)
            return .unknown(message)
        case .none:
            breaker.recordSuccess()
            breakers[repoPath] = breaker
            return ancestry == .notAncestor ? .notMerged : .unknown("Ancestry unknown and no merged pull request")
        case let .found(pullRequest):
            breaker.recordSuccess()
            breakers[repoPath] = breaker
            if pullRequest.headRefOid == head {
                mergedKeys.insert(key)
                return .merged
            }
            switch await git.isAncestor(head, of: pullRequest.headRefOid, at: repoPath) {
            case .ancestor:
                mergedKeys.insert(key)
                return .merged
            case .notAncestor:
                // The worktree has commits the merged pull request didn't carry.
                return .notMerged
            case let .unknown(reason):
                return .unknown(reason)
            }
        }
    }
}

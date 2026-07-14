import Foundation
import ASTRACore
import ASTRAGitContracts

/// Authoritative remote ref lookup. This is intentionally distinct from
/// `getCommitSHA`, which may resolve a stale local remote-tracking ref.
enum GitRemoteCommitLookupResult: Equatable, Sendable {
    case found(String)
    case missing
    case unavailable(String)
}

protocol GitRepositoryOperating: AnyObject {
    func acquireIndexGuard() -> Bool
    func releaseIndexGuard()
    func scanForGitRepositories(primaryPath: String, additionalPaths: [String]) async -> [GitRepositoryInfo]
    func getCurrentBranch(at repoPath: String) async -> String
    func getCommitSHA(_ ref: String, at repoPath: String) async -> String?
    /// Resolves the exact tree currently represented by the index. Publication
    /// uses this immutable identity to ensure commit hooks did not change the
    /// reviewed content before a push.
    func getIndexTreeSHA(at repoPath: String) async -> String?
    func getCommitTreeSHA(_ commit: String, at repoPath: String) async -> String?
    /// Restores only the Git index to a previously captured immutable tree;
    /// working-tree bytes remain untouched. Typed publication uses this to
    /// recover mixed staged/unstaged paths after an interrupted commit.
    func restoreIndexTreeSHA(_ treeSHA: String, at repoPath: String) async throws
    /// Returns a Git object identity for the exact working-tree bytes at a
    /// selected untracked path. The publication service wraps this identity in
    /// its SHA-256 proposal fingerprint without persisting file contents.
    func getWorkingTreeContentDigest(relativePath: String, at repoPath: String) async -> String?
    func lookupRemoteCommitSHA(remote: String, branch: String, at repoPath: String) async -> GitRemoteCommitLookupResult
    func getLocalBranches(at repoPath: String) async -> [String]
    func checkoutBranch(_ branch: String, at repoPath: String) async throws
    func createBranch(_ branch: String, from base: String?, at repoPath: String) async throws
    func getStatusFiles(at repoPath: String) async -> [GitStatusFile]
    func stageFile(_ file: GitStatusFile, at repoPath: String) async throws
    func stageAll(at repoPath: String) async throws
    func unstageFile(_ file: GitStatusFile, at repoPath: String) async throws
    func unstageAll(at repoPath: String) async throws
    /// Moves the current branch ref while preserving file contents in the
    /// working tree. Used only to recover an ASTRA-created commit whose durable
    /// checkpoint could not be written.
    func resetBranchPreservingChanges(to commit: String, at repoPath: String) async throws
    func applyDiffPatchToIndex(_ patch: String, at repoPath: String, reverse: Bool) async throws
    func commit(message: String, at repoPath: String) async throws
    func pullRebase(at repoPath: String) async throws
    func push(at repoPath: String) async throws
    func pushSetUpstream(branch: String, remote: String, at repoPath: String) async throws
    func hasRemote(at repoPath: String) async -> Bool
    func lookupOpenPullRequest(repoPath: String, head: String, ghPathOverride: String?) async -> GitHubPullRequestLookupResult
    func lookupOpenPullRequest(
        repoPath: String,
        remoteURL: String,
        base: String,
        head: String,
        ghPathOverride: String?
    ) async -> GitHubPullRequestLookupResult
    func lookupPullRequestComments(repoPath: String, pullRequest: GitHubPullRequestRef, ghPathOverride: String?) async -> GitHubPullRequestCommentLookupResult
    func lookupPullRequestChecks(repoPath: String, pullRequest: GitHubPullRequestRef, ghPathOverride: String?) async -> GitHubPullRequestCheckLookupResult
    func getUnpushedCommitCount(at repoPath: String) async -> Int
    func getAheadBehind(at repoPath: String) async -> (ahead: Int, behind: Int)?
    func hasUpstream(at repoPath: String) async -> Bool
    func getDefaultRemote(at repoPath: String) async -> String?
    func getStagedDiff(at repoPath: String, limit: Int) async -> String
    func getFileDiff(at repoPath: String, file: GitStatusFile, limit: Int) async -> GitFileDiff
    func getRecentCommitSubjects(at repoPath: String, count: Int) async -> [String]
    func getDefaultBaseBranch(at repoPath: String, remote: String?) async -> String
    func getBranchLog(at repoPath: String, base: String, branch: String, limit: Int, maxBytes: Int) async -> String
    func getBranchDiffStat(at repoPath: String, base: String, branch: String, maxBytes: Int) async -> String
    func getDiffStats(at repoPath: String) async -> (additions: Int, deletions: Int)
    func listWorktrees(at repoPath: String) async -> [GitWorktreeInfo]
    func localBranchExists(_ branch: String, at repoPath: String) async -> Bool
    func addWorktree(
        repoPath: String,
        branch: String,
        createBranch: Bool,
        base: String?,
        worktreesRoot: String
    ) async throws -> String
    func removeWorktree(repoPath: String, worktreePath: String, force: Bool) async throws
    func getRemoteURL(at repoPath: String, remote: String?) async -> String?
    func createPullRequest(
        repoPath: String,
        base: String,
        head: String,
        title: String,
        body: String,
        ghPathOverride: String?
    ) async throws -> String
    func createPullRequest(
        repoPath: String,
        base: String,
        head: String,
        title: String,
        body: String,
        isDraft: Bool,
        ghPathOverride: String?
    ) async throws -> String
    func createPullRequest(
        repoPath: String,
        remoteURL: String,
        base: String,
        head: String,
        title: String,
        body: String,
        isDraft: Bool,
        ghPathOverride: String?
    ) async throws -> String
    func normalizeBaseBranch(_ raw: String) -> String
    func normalizeBaseBranch(_ raw: String, remote: String) -> String
}

extension GitRepositoryOperating {
    func resetBranchPreservingChanges(to commit: String, at repoPath: String) async throws {
        throw GitPullRequestPublishError.operationFailed(
            phase: .checkpoint,
            message: "This Git operator cannot restore an uncheckpointed publication commit."
        )
    }

    /// Older/test repository operators fail closed until they expose immutable
    /// ref resolution. The real GitService implementation resolves via
    /// `git rev-parse --verify`.
    func getCommitSHA(_ ref: String, at repoPath: String) async -> String? { nil }

    /// Publication operators fail closed unless they can prove that the commit
    /// tree is identical to the reviewed staged tree.
    func getIndexTreeSHA(at repoPath: String) async -> String? { nil }
    func getCommitTreeSHA(_ commit: String, at repoPath: String) async -> String? { nil }
    func restoreIndexTreeSHA(_ treeSHA: String, at repoPath: String) async throws {
        throw GitPullRequestPublishError.operationFailed(
            phase: .checkpoint,
            message: "This Git operator cannot restore a reviewed index tree."
        )
    }
    func getWorkingTreeContentDigest(relativePath: String, at repoPath: String) async -> String? { nil }

    /// Alternate operators fail closed until they provide an authoritative
    /// network-backed remote lookup.
    func lookupRemoteCommitSHA(
        remote: String,
        branch: String,
        at repoPath: String
    ) async -> GitRemoteCommitLookupResult {
        .unavailable("Authoritative remote commit lookup is not supported.")
    }

    func normalizeBaseBranch(_ raw: String, remote: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedRemote = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = normalizedRemote.isEmpty ? "" : "\(normalizedRemote)/"
        guard !prefix.isEmpty, trimmed.hasPrefix(prefix) else { return trimmed }
        return String(trimmed.dropFirst(prefix.count))
    }

    /// Source-compatible default for test doubles and alternate repository
    /// operators. GitService overrides this requirement to pass `--draft` to
    /// gh; legacy conformers still execute through their typed PR boundary.
    func createPullRequest(
        repoPath: String,
        base: String,
        head: String,
        title: String,
        body: String,
        isDraft: Bool,
        ghPathOverride: String?
    ) async throws -> String {
        try await createPullRequest(
            repoPath: repoPath,
            base: base,
            head: head,
            title: title,
            body: body,
            ghPathOverride: ghPathOverride
        )
    }

    func lookupOpenPullRequest(repoPath: String, head: String) async -> GitHubPullRequestLookupResult {
        await lookupOpenPullRequest(repoPath: repoPath, head: head, ghPathOverride: nil)
    }

    /// Alternate operators fail closed until they can bind `gh --repo` to the
    /// reviewed remote URL.
    func lookupOpenPullRequest(
        repoPath: String,
        remoteURL: String,
        base: String,
        head: String,
        ghPathOverride: String?
    ) async -> GitHubPullRequestLookupResult {
        .unavailable("Targeted pull request lookup is not supported by this Git operator.")
    }

    func lookupPullRequestComments(
        repoPath: String,
        pullRequest: GitHubPullRequestRef
    ) async -> GitHubPullRequestCommentLookupResult {
        await lookupPullRequestComments(repoPath: repoPath, pullRequest: pullRequest, ghPathOverride: nil)
    }

    func lookupPullRequestChecks(
        repoPath: String,
        pullRequest: GitHubPullRequestRef
    ) async -> GitHubPullRequestCheckLookupResult {
        await lookupPullRequestChecks(repoPath: repoPath, pullRequest: pullRequest, ghPathOverride: nil)
    }

    func getStagedDiff(at repoPath: String) async -> String {
        await getStagedDiff(at: repoPath, limit: 8 * 1024)
    }

    func createPullRequest(
        repoPath: String,
        base: String,
        head: String,
        title: String,
        body: String,
        isDraft: Bool
    ) async throws -> String {
        try await createPullRequest(
            repoPath: repoPath,
            base: base,
            head: head,
            title: title,
            body: body,
            isDraft: isDraft,
            ghPathOverride: nil
        )
    }

    /// Alternate operators fail closed until they can bind `gh --repo` to the
    /// reviewed remote URL.
    func createPullRequest(
        repoPath: String,
        remoteURL: String,
        base: String,
        head: String,
        title: String,
        body: String,
        isDraft: Bool,
        ghPathOverride: String?
    ) async throws -> String {
        throw GitHubCLIError.commandFailed(
            "Targeted pull request creation is not supported by this Git operator."
        )
    }

    func getFileDiff(at repoPath: String, file: GitStatusFile) async -> GitFileDiff {
        await getFileDiff(at: repoPath, file: file, limit: 48 * 1024)
    }

    func getRecentCommitSubjects(at repoPath: String) async -> [String] {
        await getRecentCommitSubjects(at: repoPath, count: 5)
    }

    func getBranchLog(at repoPath: String, base: String, branch: String) async -> String {
        await getBranchLog(at: repoPath, base: base, branch: branch, limit: 20, maxBytes: 12 * 1024)
    }

    func getBranchDiffStat(at repoPath: String, base: String, branch: String) async -> String {
        await getBranchDiffStat(at: repoPath, base: base, branch: branch, maxBytes: 12 * 1024)
    }

    func addWorktree(
        repoPath: String,
        branch: String,
        createBranch: Bool,
        base: String?
    ) async throws -> String {
        try await addWorktree(
            repoPath: repoPath,
            branch: branch,
            createBranch: createBranch,
            base: base,
            worktreesRoot: AppChannel.current.defaultWorktreesRoot
        )
    }

    func createPullRequest(
        repoPath: String,
        base: String,
        head: String,
        title: String,
        body: String
    ) async throws -> String {
        try await createPullRequest(
            repoPath: repoPath,
            base: base,
            head: head,
            title: title,
            body: body,
            ghPathOverride: nil
        )
    }
}

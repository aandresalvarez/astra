import Foundation
import ASTRACore
import ASTRAGitContracts

protocol GitRepositoryOperating: AnyObject {
    func acquireIndexGuard() -> Bool
    func releaseIndexGuard()
    func scanForGitRepositories(primaryPath: String, additionalPaths: [String]) async -> [GitRepositoryInfo]
    func getCurrentBranch(at repoPath: String) async -> String
    func getCommitSHA(_ ref: String, at repoPath: String) async -> String?
    func getLocalBranches(at repoPath: String) async -> [String]
    func checkoutBranch(_ branch: String, at repoPath: String) async throws
    func createBranch(_ branch: String, from base: String?, at repoPath: String) async throws
    func getStatusFiles(at repoPath: String) async -> [GitStatusFile]
    func stageFile(_ file: GitStatusFile, at repoPath: String) async throws
    func stageAll(at repoPath: String) async throws
    func unstageFile(_ file: GitStatusFile, at repoPath: String) async throws
    func unstageAll(at repoPath: String) async throws
    func applyDiffPatchToIndex(_ patch: String, at repoPath: String, reverse: Bool) async throws
    func commit(message: String, at repoPath: String) async throws
    func pullRebase(at repoPath: String) async throws
    func push(at repoPath: String) async throws
    func pushSetUpstream(branch: String, remote: String, at repoPath: String) async throws
    func hasRemote(at repoPath: String) async -> Bool
    func lookupOpenPullRequest(repoPath: String, head: String, ghPathOverride: String?) async -> GitHubPullRequestLookupResult
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
    func normalizeBaseBranch(_ raw: String) -> String
}

extension GitRepositoryOperating {
    /// Older/test repository operators fail closed until they expose immutable
    /// ref resolution. The real GitService implementation resolves via
    /// `git rev-parse --verify`.
    func getCommitSHA(_ ref: String, at repoPath: String) async -> String? { nil }

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

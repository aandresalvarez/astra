import Foundation
import ASTRACore

/// Answer of `git merge-base --is-ancestor`.
enum GitAncestry: Equatable, Sendable {
    case ancestor
    case notAncestor
    /// Git couldn't answer (missing commit or ref, timeout).
    case unknown(String)
}

/// A merged pull request for a head branch, with the head commit GitHub merged.
struct GitMergedPullRequest: Equatable, Sendable, Decodable {
    let number: Int
    let url: String
    let headRefOid: String
    let mergedAt: String?
}

enum GitMergedPullRequestLookupResult: Equatable, Sendable {
    case found(GitMergedPullRequest)
    case none
    case unavailable(String)
}

/// The git reads worktree storage needs, kept separate from
/// `GitRepositoryOperating` so its test doubles stay small. `GitService`
/// conforms; tests stub it.
protocol WorktreeStorageGitReading: AnyObject {
    func scanForGitRepositories(primaryPath: String, additionalPaths: [String]) async -> [GitRepositoryInfo]
    func listWorktrees(at repoPath: String) async -> [GitWorktreeInfo]
    func getDefaultBaseBranch(at repoPath: String, remote: String?) async -> String
    func isAncestor(_ ancestor: String, of descendant: String, at repoPath: String) async -> GitAncestry
    func commitDate(of commit: String, at repoPath: String) async -> Date?
    /// True when `git status` lists tracked or untracked changes; nil when git
    /// can't tell (for example, the worktree is gone).
    func hasUncommittedChanges(at worktreePath: String) async -> Bool?
    /// The worktree-relative directories among `relativePaths` that hold at
    /// least one file in git's index; nil when git can't tell.
    func trackedDirectories(among relativePaths: [String], at worktreePath: String) async -> Set<String>?
    func lookupMergedPullRequest(repoPath: String, head: String, ghPathOverride: String?) async -> GitMergedPullRequestLookupResult
}

extension GitService: WorktreeStorageGitReading {
    func isAncestor(_ ancestor: String, of descendant: String, at repoPath: String) async -> GitAncestry {
        do {
            _ = try await runGit(
                at: repoPath,
                arguments: ["merge-base", "--is-ancestor", ancestor, descendant],
                // Exit 1 is the ordinary "no" answer, not a failure.
                failureLogLevel: .debug
            )
            return .ancestor
        } catch let error as NSError where error.domain == "GitError" && error.code == 1 {
            return .notAncestor
        } catch {
            return .unknown(error.localizedDescription)
        }
    }

    func commitDate(of commit: String, at repoPath: String) async -> Date? {
        guard let output = try? await runGit(
            at: repoPath,
            arguments: ["show", "-s", "--format=%ct", commit],
            failureLogLevel: .debug
        ), let seconds = TimeInterval(output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
    }

    func hasUncommittedChanges(at worktreePath: String) async -> Bool? {
        // `GIT_OPTIONAL_LOCKS=0` (see `gitEnvironment`) keeps this read from
        // rewriting the index, so asking doesn't itself look like activity.
        guard let output = try? await runGit(
            at: worktreePath,
            arguments: ["status", "--porcelain", "--untracked-files=normal"],
            failureLogLevel: .debug
        ) else { return nil }
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func trackedDirectories(among relativePaths: [String], at worktreePath: String) async -> Set<String>? {
        guard !relativePaths.isEmpty else { return [] }
        // The index, not HEAD: a file staged under `.build` is tracked too.
        // Literal pathspecs, so a folder name is never read as a glob.
        guard let output = try? await runGit(
            at: worktreePath,
            arguments: ["--literal-pathspecs", "ls-files", "-z", "--"] + relativePaths,
            failureLogLevel: .debug
        ) else { return nil }
        var tracked: Set<String> = []
        for file in output.split(separator: "\0") where tracked.count < relativePaths.count {
            if let directory = relativePaths.first(where: { file == $0 || file.hasPrefix($0 + "/") }) {
                tracked.insert(directory)
            }
        }
        return tracked
    }

    /// The most recent MERGED pull request whose head branch has this name.
    /// ASTRA squash-merges, so the ancestor check alone misses most merged
    /// branches. `--head` matches the name only; callers must compare
    /// `headRefOid` with the worktree's HEAD before trusting it.
    func lookupMergedPullRequest(
        repoPath: String,
        head: String,
        ghPathOverride: String?
    ) async -> GitMergedPullRequestLookupResult {
        let trimmedHead = head.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHead.isEmpty else { return .unavailable("Branch is empty.") }
        do {
            let output = try await runGitHubCLI(
                at: repoPath,
                arguments: [
                    "pr", "list",
                    "--head", trimmedHead,
                    "--state", "merged",
                    "--json", "number,url,headRefOid,mergedAt",
                    "--limit", "1"
                ],
                label: "gh pr list --state merged",
                ghPathOverride: ghPathOverride
            )
            guard let decoded = try? JSONDecoder().decode([GitMergedPullRequest].self, from: Data(output.utf8)) else {
                auditMergedLookup(head: trimmedHead, result: "unavailable", level: .warning, extra: [
                    "reason": "invalid_json",
                    "stdout_sample": String(output.prefix(240))
                ])
                return .unavailable("GitHub CLI returned PR data ASTRA could not read.")
            }
            guard let pullRequest = decoded.first else {
                auditMergedLookup(head: trimmedHead, result: "none", level: .debug)
                return .none
            }
            auditMergedLookup(head: trimmedHead, result: "found", level: .debug, extra: ["number": "\(pullRequest.number)"])
            return .found(pullRequest)
        } catch {
            auditMergedLookup(head: trimmedHead, result: "unavailable", level: .warning, extra: [
                "reason": error.localizedDescription
            ])
            return .unavailable(error.localizedDescription)
        }
    }

    private func auditMergedLookup(head: String, result: String, level: LogLevel, extra: [String: String] = [:]) {
        var fields = extra
        fields["head"] = head
        fields["state"] = "merged"
        fields["result"] = result
        AppLogger.audit(.gitPullRequestLookup, category: "Git", fields: fields, level: level, fieldMaxLength: 240)
    }
}

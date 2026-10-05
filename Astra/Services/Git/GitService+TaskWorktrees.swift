import Foundation

/// Git primitives for task worktrees: refreshing the base branch a new
/// worktree starts from, and removing the branch again when an unused draft
/// is discarded.
extension GitService {
    /// A slow or offline remote must not hold task creation for the full
    /// network budget; the last fetched ref is used instead.
    static let taskWorktreeFetchTimeout: TimeInterval = 20

    /// Asks the remote itself which branch its HEAD names, so a default branch
    /// such as `develop`, or one renamed after this clone, is found even when
    /// `refs/remotes/<remote>/HEAD` is missing or stale. Never writes refs.
    func lookupRemoteHead(remote: String, at repoPath: String) async -> GitRemoteHeadLookupResult {
        guard Self.isSafeRefComponent(remote) else { return .unavailable }
        do {
            let output = try await runGit(
                at: repoPath,
                arguments: ["ls-remote", "--symref", remote, "HEAD"],
                timeout: Self.taskWorktreeFetchTimeout,
                failureLogLevel: .warning
            )
            return Self.remoteHead(fromLsRemote: output)
        } catch {
            return .unavailable
        }
    }

    /// Parses `ref: refs/heads/<branch>\tHEAD` from `git ls-remote --symref`.
    /// A remote with an unborn HEAD prints nothing.
    static func remoteHead(fromLsRemote output: String) -> GitRemoteHeadLookupResult {
        let prefix = "ref: refs/heads/"
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 2, fields[1] == "HEAD", fields[0].hasPrefix(prefix) else { continue }
            let branch = String(fields[0].dropFirst(prefix.count))
            return isSafeRefComponent(branch) ? .branch(branch) : .unnamed
        }
        return .unnamed
    }

    /// Refreshes one remote-tracking branch so a new worktree starts from the
    /// remote's current tip. Returns false when the fetch failed; callers then
    /// fall back to the existing remote-tracking ref.
    func fetchRemoteBranch(remote: String, branch: String, at repoPath: String) async -> Bool {
        guard Self.isSafeRefComponent(remote), Self.isSafeRefComponent(branch) else { return false }
        do {
            _ = try await runGit(
                at: repoPath,
                arguments: [
                    "fetch", "--no-tags", "--quiet", remote,
                    "+refs/heads/\(branch):refs/remotes/\(remote)/\(branch)"
                ],
                timeout: Self.taskWorktreeFetchTimeout,
                failureLogLevel: .warning
            )
            return true
        } catch {
            return false
        }
    }

    /// Deletes a local branch only while it still points at `expectedCommit`,
    /// so a branch that gained commits after it was created is never dropped.
    func deleteLocalBranch(_ branch: String, ifAt expectedCommit: String, at repoPath: String) async throws {
        guard Self.isSafeRefComponent(branch), Self.isSafeRefComponent(expectedCommit) else {
            throw GitWorktreeError.invalidBranchName(branch)
        }
        _ = try await runGit(
            at: repoPath,
            arguments: ["update-ref", "-d", "refs/heads/\(branch)", expectedCommit]
        )
    }

    /// `git status` hides ignored files such as `.env` or local build output,
    /// yet a non-forced `git worktree remove` deletes them. Any listed entry,
    /// or a failure to list, means the checkout is kept.
    func hasIgnoredFiles(at repoPath: String) async -> Bool {
        do {
            let output = try await runGit(
                at: repoPath,
                arguments: [
                    "ls-files", "-z", "--others", "--ignored", "--exclude-standard",
                    "--directory", "--no-empty-directory"
                ]
            )
            return !output.isEmpty
        } catch {
            return true
        }
    }

    /// Conservative subset of `git check-ref-format` for names ASTRA splices
    /// into refspecs: rejects option-like, empty, and wildcard components.
    static func isSafeRefComponent(_ value: String) -> Bool {
        guard !value.isEmpty,
              !value.hasPrefix("-"),
              !value.hasPrefix("/"),
              !value.hasSuffix("/"),
              !value.hasSuffix("."),
              !value.hasSuffix(".lock"),
              !value.contains(".."),
              !value.contains("//"),
              !value.contains("@{") else { return false }
        let forbidden = CharacterSet(charactersIn: "~^:?*[\\")
            .union(.whitespacesAndNewlines)
            .union(.controlCharacters)
        return value.unicodeScalars.allSatisfy { !forbidden.contains($0) }
    }
}

import Foundation

/// Git primitives for task worktrees: refreshing the base branch a new
/// worktree starts from, and removing the branch again when an unused draft
/// is discarded.
extension GitService {
    /// A slow or offline remote must not hold task creation for the full
    /// network budget; the last fetched ref is used instead.
    static let taskWorktreeFetchTimeout: TimeInterval = 20

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

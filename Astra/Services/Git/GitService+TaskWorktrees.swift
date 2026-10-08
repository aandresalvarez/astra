import Foundation

/// What a worktree's submodules hold. Git refuses to remove a worktree that
/// stores submodule repositories, even empty folders a failed clone left,
/// unless forced, and forcing deletes them too, so cleanup forces only
/// `.unchanged`.
enum GitSubmoduleCheckoutState: Equatable, Sendable {
    /// No submodule is populated and none has stored data.
    case notPopulated
    /// Every populated submodule is at its recorded commit with nothing a
    /// forced removal would lose: no changes, untracked or ignored files, or
    /// commits that no remote-tracking branch holds. The worktree stores no
    /// other submodule repository; a failed clone's empty folders hold nothing.
    case unchanged
    /// A forced removal would lose local work, including the stored
    /// repository of a submodule that is no longer checked out.
    case changed
    /// The state couldn't be read.
    case unknown
}

/// A Git operator that can't populate submodules.
struct GitSubmoduleSetupUnsupported: LocalizedError {
    var errorDescription: String? { "This Git operator cannot set up submodules." }
}

/// Git primitives for task worktrees: refreshing the base branch a new
/// worktree starts from, populating its submodules, and removing the branch
/// again when an unused draft is discarded.
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

    /// `git worktree add` leaves submodule folders empty. Run in the new
    /// worktree, `update` without `--init` populates exactly the submodules
    /// the repository has initialized, since their activation lives in the
    /// shared config; each one's own submodules are then populated
    /// recursively. Submodules the repository never initialized stay empty,
    /// as they are in its checkout.
    static let taskWorktreeSubmoduleCommands: [[String]] = [
        ["submodule", "update"],
        ["submodule", "foreach", "--quiet", "git submodule update --init --recursive"]
    ]

    /// Run in each populated submodule; prints anything a forced removal
    /// would destroy: changes, untracked or ignored files, and commits that
    /// no remote-tracking branch holds.
    static let submoduleLocalWorkScript = [
        "git status --porcelain --ignore-submodules=none",
        "git ls-files --others --ignored --exclude-standard --directory --no-empty-directory",
        "git rev-list -n 1 --all --reflog --not --remotes"
    ].joined(separator: " && ")

    func initializeSubmodules(at worktreePath: String) async throws {
        for arguments in Self.taskWorktreeSubmoduleCommands {
            _ = try await runGit(
                at: worktreePath, arguments: arguments, timeout: Self.networkGitTimeout, failureLogLevel: .warning
            )
        }
    }

    func submoduleCheckoutState(at worktreePath: String) async -> GitSubmoduleCheckoutState {
        do {
            // A leading `-` marks a submodule that isn't populated.
            let status = try await runGit(
                at: worktreePath, arguments: ["submodule", "status", "--recursive"], failureLogLevel: .warning
            )
            let populated = status.split(whereSeparator: \.isNewline).contains { !$0.hasPrefix("-") }
            let gitDirectory = try await runGit(
                at: worktreePath, arguments: ["rev-parse", "--absolute-git-dir"], failureLogLevel: .warning
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            let stored = try Self.storedSubmoduleRepositories(
                in: URL(fileURLWithPath: gitDirectory, isDirectory: true).appendingPathComponent("modules")
            )
            guard populated else {
                guard let stored else { return .notPopulated }
                return stored.isEmpty ? .unchanged : .changed
            }
            let checkedOut = try await runGit(
                at: worktreePath,
                arguments: ["submodule", "foreach", "--quiet", "--recursive", "git rev-parse --absolute-git-dir"],
                failureLogLevel: .warning
            ).split(whereSeparator: \.isNewline).map { Self.repositoryKey(String($0)) }
            guard (stored ?? []).isSubset(of: checkedOut) else { return .changed }
            let changes = try await runGit(
                at: worktreePath, arguments: ["status", "--porcelain", "--ignore-submodules=none"],
                failureLogLevel: .warning
            )
            guard changes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .changed }
            let localWork = try await runGit(
                at: worktreePath,
                arguments: ["submodule", "foreach", "--quiet", "--recursive", Self.submoduleLocalWorkScript],
                failureLogLevel: .warning
            )
            return localWork.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .unchanged : .changed
        } catch {
            return .unknown
        }
    }

    /// The submodule repositories stored under a worktree's `modules` Git
    /// folder, nested ones included, or nil when that folder doesn't exist.
    /// Throws when any part of it can't be read.
    static func storedSubmoduleRepositories(in modules: URL) throws -> Set<String>? {
        let manager = FileManager.default
        guard manager.fileExists(atPath: modules.path) else { return nil }
        var failure: Error?
        guard let entries = manager.enumerator(
            at: modules, includingPropertiesForKeys: [.isDirectoryKey],
            errorHandler: { _, error in
                failure = error
                return false
            }
        ) else { throw CocoaError(.fileReadUnknown) }
        var repositories = Set<String>()
        for case let entry as URL in entries {
            guard try entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
            // Object stores can be large and never hold another repository.
            if entry.lastPathComponent == "objects" {
                entries.skipDescendants()
            } else if manager.fileExists(atPath: entry.appendingPathComponent("HEAD").path),
                      manager.fileExists(atPath: entry.appendingPathComponent("objects").path) {
                repositories.insert(repositoryKey(entry.path))
            }
        }
        if let failure { throw failure }
        return repositories
    }

    /// Git prints resolved paths; enumerated ones may use a symlinked prefix.
    static func repositoryKey(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
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

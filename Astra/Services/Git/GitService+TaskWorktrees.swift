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

    func addLockedTaskWorktree(
        repoPath: String, branch: String, base: String, worktreesRoot: String, lockReason: String
    ) async throws -> String {
        guard Self.isSafeRefComponent(branch), Self.isSafeRefComponent(base) else {
            throw GitWorktreeError.invalidBranchName(branch)
        }
        let destination = Self.worktreeLocation(repoPath: repoPath, branch: branch, worktreesRoot: worktreesRoot)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: destination).deletingLastPathComponent(), withIntermediateDirectories: true
        )
        _ = try await runGit(
            at: repoPath,
            // Reflogs are created now even where `core.logAllRefUpdates` is
            // off; Git keeps appending to a reflog that exists, so cleanup
            // can always see commits that were later reset away.
            arguments: [
                "-c", "core.logAllRefUpdates=true",
                "worktree", "add", "--lock", "--reason", lockReason, "-b", branch, destination, base
            ],
            timeout: Self.networkGitTimeout
        )
        return destination
    }

    func unlockWorktree(repoPath: String, worktreePath: String) async throws {
        _ = try await runGit(at: repoPath, arguments: ["worktree", "unlock", worktreePath], failureLogLevel: .warning)
    }

    /// Git reports nothing for files inside a gitlink folder whose submodule
    /// isn't populated, and a non-forced `git worktree remove` deletes them.
    /// Checks the worktree and every populated submodule in it; any failure
    /// to read counts as files present.
    func unpopulatedGitlinksHoldFiles(at worktreePath: String) async -> Bool {
        let fileManager = FileManager.default
        do {
            let populated = try await runGit(
                at: worktreePath, arguments: ["submodule", "foreach", "--quiet", "--recursive", "pwd"],
                failureLogLevel: .warning
            ).split(whereSeparator: \.isNewline).map(String.init)
            for root in [worktreePath] + populated {
                let entries = try await runGit(at: root, arguments: ["ls-files", "--stage", "-z"], failureLogLevel: .warning)
                for entry in entries.split(separator: "\0") where entry.hasPrefix("160000 ") {
                    guard let tab = entry.firstIndex(of: "\t") else { return true }
                    let folder = (root as NSString).appendingPathComponent(String(entry[entry.index(after: tab)...]))
                    var isDirectory = ObjCBool(false)
                    guard fileManager.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue,
                          !fileManager.fileExists(atPath: (folder as NSString).appendingPathComponent(".git")) else { continue }
                    if try !fileManager.contentsOfDirectory(atPath: folder).isEmpty { return true }
                }
            }
            return false
        } catch {
            return true
        }
    }

    /// `git status` and a non-forced `git worktree remove` both trust the
    /// index for entries marked assume-unchanged or skip-worktree, so a
    /// change to one is invisible yet deleted. Each such entry's type and
    /// mode are compared with the index, so an executable bit flipped or a
    /// file swapped for a link counts, and its content is hashed against the
    /// index blob. A skip-worktree file that is absent is unchanged only
    /// while the checkout's sparse rules exclude it, as a sparse checkout
    /// leaves it; otherwise its absence is a hidden deletion. An absent
    /// assume-unchanged file was deleted. Any failure to read counts as
    /// changed.
    func indexHiddenEntriesChanged(at worktreePath: String) async -> Bool {
        do {
            // `<tag> <mode> <object> <stage>\t<path>` per entry.
            let listing = try await runGit(
                at: worktreePath, arguments: ["ls-files", "-v", "-s", "-z"], failureLogLevel: .warning
            )
            var absentSkipWorktree: [String] = []
            for entry in listing.split(separator: "\0") {
                guard let tag = entry.first else { continue }
                let assumeUnchanged = tag.isLowercase
                let skipWorktree = tag == "S" || tag == "s"
                guard assumeUnchanged || skipWorktree else { continue }
                guard let tab = entry.firstIndex(of: "\t") else { return true }
                let fields = entry[entry.startIndex..<tab].split(separator: " ")
                guard fields.count == 4 else { return true }
                let mode = String(fields[1])
                let object = String(fields[2])
                let file = String(entry[entry.index(after: tab)...])
                let full = (worktreePath as NSString).appendingPathComponent(file)
                if mode == "160000" {
                    // A gitlink's own work is checked with its submodule, but
                    // its path must still be a folder or absent: a file or
                    // link put in its place is invisible to status and to the
                    // submodule checks, yet a removal deletes it.
                    if let type = (try? FileManager.default.attributesOfItem(atPath: full))?[.type] as? FileAttributeType,
                       type != .typeDirectory { return true }
                    continue
                }
                // Not following links: a symlink retargeted to a missing path
                // is still there, and is a change.
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: full) else {
                    if skipWorktree {
                        absentSkipWorktree.append(file)
                        continue
                    }
                    return true
                }
                switch (mode, attributes[.type] as? FileAttributeType) {
                case ("120000", .typeSymbolicLink?):
                    // A link's blob is its target path, byte for byte: a
                    // trailing newline is part of the target, never trimmed.
                    let indexed = try await runGit(at: worktreePath, arguments: ["cat-file", "blob", object], failureLogLevel: .warning)
                    let target = try FileManager.default.destinationOfSymbolicLink(atPath: full)
                    if Data(indexed.utf8) != Data(target.utf8) { return true }
                case ("100644", .typeRegular?), ("100755", .typeRegular?):
                    let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
                    let executable = permissions & 0o100 != 0
                    if executable != (mode == "100755") { return true }
                    let current = try await runGit(at: worktreePath, arguments: ["hash-object", "--", file], failureLogLevel: .warning)
                    if current.trimmingCharacters(in: .whitespacesAndNewlines) != object { return true }
                default:
                    // Another type than the index records, such as a file
                    // replaced by a folder or a link by a file.
                    return true
                }
            }
            return !(await sparseRulesExclude(absentSkipWorktree, at: worktreePath))
        } catch {
            return true
        }
    }

    /// Whether this checkout's sparse-checkout rules leave out every one of
    /// `files`. False when sparse checkout is off, since nothing then
    /// explains a skip-worktree file being absent, and on any failure.
    private func sparseRulesExclude(_ files: [String], at worktreePath: String) async -> Bool {
        guard !files.isEmpty else { return true }
        do {
            let enabled = try await runGit(
                at: worktreePath, arguments: ["config", "--bool", "--get", "core.sparseCheckout"], failureLogLevel: .debug
            )
            guard enabled.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else { return false }
            // Prints the paths the rules include.
            let included = try await runGit(
                at: worktreePath, arguments: ["sparse-checkout", "check-rules", "-z"], failureLogLevel: .warning,
                standardInput: Data(files.joined(separator: "\0").appending("\0").utf8)
            )
            return included.split(separator: "\0").isEmpty
        } catch {
            return false
        }
    }

    func pathIsHiddenFromStatus(_ path: String, in checkout: String) async -> Bool {
        if let mode = try? await runGit(at: checkout, arguments: ["config", "--get", "status.showUntrackedFiles"]),
           mode.trimmingCharacters(in: .whitespacesAndNewlines) == "no" {
            return true
        }
        // `check-ignore` exits nonzero for a path that isn't ignored, which
        // `runGit` reports as an error: either way, not hidden.
        return (try? await runGit(at: checkout, arguments: ["check-ignore", "-q", "--", path])) != nil
    }

    /// `for-each-ref` exits cleanly with no output for a missing ref and fails
    /// when the repository can't be read, so absence is positively verified.
    /// Its patterns match by prefix, so only the exact ref name counts.
    func localBranchTip(_ branch: String, at repoPath: String) async -> GitBranchLookupResult {
        guard Self.isSafeRefComponent(branch) else { return .unavailable }
        let ref = "refs/heads/\(branch)"
        do {
            let output = try await runGit(
                at: repoPath, arguments: ["for-each-ref", "--format=%(refname) %(objectname)", ref],
                failureLogLevel: .warning
            )
            for line in output.split(whereSeparator: \.isNewline) {
                let fields = line.split(separator: " ")
                if fields.count == 2, fields[0] == ref { return .commit(String(fields[1])) }
            }
            return .absent
        } catch {
            return .unavailable
        }
    }

    /// The same status `getStatusFiles` reads, but a failure is nil rather
    /// than an empty, clean-looking list. Untracked files are always listed:
    /// `status.showUntrackedFiles=no` would hide them, yet a non-forced
    /// `git worktree remove` deletes them.
    func worktreeIsClean(at repoPath: String) async -> Bool? {
        do {
            let output = try await runGit(
                at: repoPath,
                arguments: ["--no-optional-locks", "status", "--porcelain=v1", "--untracked-files=all", "-z"],
                failureLogLevel: .warning
            )
            return output.isEmpty
        } catch {
            return nil
        }
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

    func hasWorktreeReflogChanges(
        branch: String, baseCommit: String, worktreePath: String?, repoPath: String
    ) async -> Bool {
        var refs = [(repoPath, "refs/heads/\(branch)")]
        if let worktreePath { refs.append((worktreePath, "HEAD")) }
        do {
            for (path, ref) in refs {
                let output = try await runGit(at: path, arguments: ["reflog", "show", "--format=%H", ref])
                let entries = output.split(whereSeparator: \.isNewline)
                // No reflog proves nothing: with reflogs off, a commit reset
                // away leaves no trace, so the branch is kept.
                if entries.isEmpty || entries.contains(where: { $0 != baseCommit }) { return true }
            }
            return false
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
    /// would destroy: changes, untracked or ignored files, commits that no
    /// remote-tracking branch holds, a checkout away from the commit the
    /// superproject's index records (`$sha1`), which `git submodule status`
    /// hides when that gitlink is marked assume-unchanged or skip-worktree,
    /// and local refs: a branch that isn't exactly its upstream, and any
    /// unpacked tag. A clone packs what it fetched, so a loose tag was made or
    /// fetched since; even one at a remote-reachable commit is the user's.
    static let submoduleLocalWorkScript = [
        "git status --porcelain --untracked-files=all --ignore-submodules=none",
        "git ls-files --others --ignored --exclude-standard --directory --no-empty-directory",
        "git rev-list -n 1 --all --reflog --not --remotes",
        "{ test \"$sha1\" = \"$(git rev-parse HEAD)\" || echo \"moved $displaypath\"; }",
        "{ git for-each-ref --format='%(refname:short)' refs/heads | while read -r ref; do "
            + "test \"$(git rev-parse \"refs/heads/$ref\")\" = \"$(git rev-parse --verify -q \"$ref@{upstream}\")\" "
            + "|| echo \"branch $displaypath $ref\"; done; }",
        "{ find \"$(git rev-parse --git-path refs/tags)\" -type f 2>/dev/null; }"
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
            // A leading `-` marks a submodule that isn't populated, `+` one
            // checked out at another commit than the index records, and `U`
            // one with merge conflicts. The last two are changes even when
            // the gitlink is marked assume-unchanged or skip-worktree and
            // every status reads clean.
            let status = try await runGit(
                at: worktreePath, arguments: ["submodule", "status", "--recursive"], failureLogLevel: .warning
            )
            let lines = status.split(whereSeparator: \.isNewline)
            if lines.contains(where: { $0.hasPrefix("+") || $0.hasPrefix("U") }) { return .changed }
            let populated = lines.contains { !$0.hasPrefix("-") }
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
                at: worktreePath, arguments: ["status", "--porcelain", "--untracked-files=all", "--ignore-submodules=none"],
                failureLogLevel: .warning
            )
            guard changes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .changed }
            let localWork = try await runGit(
                at: worktreePath,
                arguments: ["submodule", "foreach", "--quiet", "--recursive", Self.submoduleLocalWorkScript],
                failureLogLevel: .warning
            )
            guard localWork.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .changed }
            // Status trusts the index in a submodule too, so an edit to a file
            // marked assume-unchanged or skip-worktree there is invisible to
            // all of the above, yet a forced removal deletes it.
            let populatedSubmodules = try await runGit(
                at: worktreePath, arguments: ["submodule", "foreach", "--quiet", "--recursive", "pwd"],
                failureLogLevel: .warning
            ).split(whereSeparator: \.isNewline).map(String.init)
            for submodule in populatedSubmodules where await indexHiddenEntriesChanged(at: submodule) {
                return .changed
            }
            return .unchanged
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

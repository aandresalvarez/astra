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
    /// Repository the draft explicitly chose. Absent on requests recorded
    /// before the repository was part of the intent. A nil draft pin means
    /// "follow the workspace default", so this path is what keeps an explicit
    /// primary-repository choice from drifting when that default changes.
    public let repositoryPath: String?
    /// The checkout of `repositoryPath` the composer showed: its root or one of
    /// its linked worktrees. Current branch starts from this checkout's HEAD,
    /// so reopening a draft must not fall back to the root. Nil in requests
    /// recorded before this field existed.
    public let checkoutPath: String?
    /// Position among the draft's requests, one more than the latest when
    /// recorded. Timestamps alone can tie once a recovery mirror stores them
    /// to the second. Not part of equality, which compares the choice.
    /// Absent on requests recorded before it existed.
    public var sequence: Int?

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.enabled == rhs.enabled && lhs.base == rhs.base
            && lhs.repositoryPath == rhs.repositoryPath && lhs.checkoutPath == rhs.checkoutPath
    }

    public init(
        enabled: Bool,
        base: TaskWorktreeBaseChoice,
        repositoryPath: String? = nil,
        checkoutPath: String? = nil
    ) {
        self.enabled = enabled
        self.base = base
        let trimmedRepo = repositoryPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.repositoryPath = trimmedRepo?.isEmpty == false ? trimmedRepo : nil
        let trimmedCheckout = checkoutPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.checkoutPath = trimmedCheckout?.isEmpty == false ? trimmedCheckout : nil
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
    /// The Git directory the worktree shares with its source, recorded at
    /// creation so cleanup can reach the repository if a linked-worktree
    /// source checkout is later removed. Never used to grant access.
    public let commonDirectory: String?
    /// A token written into the worktree's own Git admin folder at creation.
    /// Git deletes that folder with the worktree, so a worktree recreated at
    /// the same path, even of the same repository, lacks it, while switching
    /// branches inside the worktree keeps it. Absent on older bindings.
    public let identity: String?
    /// `commonDirectory`'s file identity at creation, so a cleanup resumed
    /// after the worktree is gone never acts on a replacement repository at
    /// the same path. Absent on older bindings.
    public let commonDirectoryID: String?

    public init(
        repositoryPath: String,
        worktreePath: String,
        branch: String,
        baseRef: String? = nil,
        baseCommit: String? = nil,
        baseSource: TaskWorktreeBaseChoice? = nil,
        baseFetched: Bool? = nil,
        commonDirectory: String? = nil,
        identity: String? = nil,
        commonDirectoryID: String? = nil
    ) {
        self.repositoryPath = repositoryPath
        self.worktreePath = worktreePath
        self.branch = branch
        self.baseRef = baseRef
        self.baseCommit = baseCommit
        self.baseSource = baseSource
        self.baseFetched = baseFetched
        self.commonDirectory = commonDirectory
        self.identity = identity
        self.commonDirectoryID = commonDirectoryID
    }
}

/// The durable link between a task and the worktree ASTRA prepared for it:
/// the newest `task.worktree.prepared` event whose worktree is still the
/// task's pin and is registered by its configured source repository. Launch
/// grants, the composer, cleanup, and derived tasks all read this binding.
public enum TaskWorktreeBinding {
    public enum ValidationError: LocalizedError {
        case invalid(String)

        public var errorDescription: String? {
            switch self {
            case .invalid(let reason): "ASTRA could not verify this task's worktree: \(reason)"
            }
        }
    }

    public enum State {
        /// No pin, or a legacy pin without a prepared worktree.
        case none
        /// An unreadable binding. It never restores access to the original
        /// checkout.
        case invalid(String)
        /// The pin no longer names a worktree ASTRA prepared for this task.
        /// `commonDirectory` is the shared Git directory the pinned checkout
        /// was verified against; a pin that can't be verified, even the
        /// configured repository folder itself, is invalid instead.
        case retargeted(pinned: String, commonDirectory: String)
        case bound(TaskWorktreePayload, event: TaskEvent, pinned: String)
    }

    public static func state(of task: AgentTask) -> State {
        state(of: task, pinned: task.executionRootPath)
    }

    /// Whether pinning `path` would leave the task's prepared worktrees
    /// verifiable. A draft that prepared one may move only to a checkout of
    /// that repository; any other choice would make its binding invalid and
    /// lock the picker that could undo it.
    public static func accepts(_ path: String?, for task: AgentTask) -> Bool {
        if case .invalid = state(of: task, pinned: path) { return false }
        return true
    }

    /// Whether the task's pin names a worktree it prepared, rather than a
    /// checkout it was retargeted to. A payload that can't be read counts.
    public static func pinsPreparedWorktree(_ task: AgentTask) -> Bool {
        guard let pinned = task.executionRootPath, !pinned.isEmpty else { return false }
        let pin = WorkspacePathPresentation.standardizedPath(pinned)
        return task.events.contains { event in
            guard !event.isDeleted, event.hasType(TaskEventTypes.Task.worktreePrepared) else { return false }
            guard case .success(let payload) = event.decodePayload(as: TaskWorktreePayload.self) else { return true }
            return WorkspacePathPresentation.standardizedPath(payload.worktreePath) == pin
        }
    }

    private static func state(of task: AgentTask, pinned candidate: String?) -> State {
        let events = task.events
            .filter { !$0.isDeleted && $0.hasType(TaskEventTypes.Task.worktreePrepared) }
            .sorted { $0.timestamp > $1.timestamp }
        guard let pinned = candidate, !pinned.isEmpty else {
            // A task that prepared a worktree but lost its pin must not fall
            // back to the workspace's default checkout.
            return events.isEmpty ? .none : .invalid("This task's worktree is no longer pinned.")
        }
        guard !events.isEmpty else { return .none }
        let pin = WorkspacePathPresentation.standardizedPath(pinned)
        var repositories: [String] = []
        for event in events {
            switch event.decodePayload(as: TaskWorktreePayload.self) {
            case .success(let payload):
                if WorkspacePathPresentation.standardizedPath(payload.worktreePath) == pin {
                    guard repositoryIsConfigured(payload.repositoryPath, for: task),
                          gitCommonDirectory(for: payload) != nil else {
                        return .invalid("The configured repository does not register \(pinned) as a linked worktree.")
                    }
                    return .bound(payload, event: event, pinned: pinned)
                }
                if repositoryIsConfigured(payload.repositoryPath, for: task) {
                    repositories.append(payload.repositoryPath)
                }
            case .failure(let error):
                return .invalid(error.description)
            }
        }
        // Repository evidence, never a matching path: the configured
        // repository folder replaced by a plain folder is not its checkout.
        for repository in repositories {
            if let common = verifiedCommonDirectory(checkout: pinned, repository: repository) {
                return .retargeted(pinned: pinned, commonDirectory: common)
            }
        }
        return .invalid("The selected checkout is not registered by this task's configured repository.")
    }

    /// The shared Git directory `checkout` uses while it is still a checkout
    /// of `repository`: the repository's primary checkout, whose own Git
    /// directory is that common directory, or a linked checkout whose own
    /// `.git` file points back to its registry entry. The primary checkout's
    /// `.git` is a directory, or a `gitdir:` file as a submodule or a
    /// separate Git directory has. A folder that merely sits where Git once
    /// registered a checkout, such as a replacement clone, a plain folder,
    /// or a symlink, is nil.
    public static func verifiedCommonDirectory(checkout: String, repository: String) -> String? {
        if let linked = registeredCommonDirectory(repositoryPath: repository, worktreePath: checkout) { return linked }
        guard let checkoutPath = resolvedPath(checkout),
              let common = checkoutCommonDirectory(repository) else { return nil }
        let fileManager = FileManager.default
        let dotGit = (checkoutPath as NSString).appendingPathComponent(".git")
        guard (try? fileManager.attributesOfItem(atPath: checkoutPath)[.type] as? FileAttributeType) == .typeDirectory
        else { return nil }
        let ownGitDirectory: String?
        switch try? fileManager.attributesOfItem(atPath: dotGit)[.type] as? FileAttributeType {
        case .typeDirectory?:
            ownGitDirectory = resolvedPath(dotGit)
        case .typeRegular?:
            guard let raw = try? String(contentsOfFile: dotGit, encoding: .utf8),
                  raw.lowercased().hasPrefix("gitdir:") else { return nil }
            ownGitDirectory = resolvedGitPath(String(raw.dropFirst("gitdir:".count)), relativeTo: checkoutPath)
        default:
            return nil
        }
        // Its own Git directory is the common directory, never a linked
        // worktree's admin entry inside it.
        guard let ownGitDirectory, ownGitDirectory == resolvedPath(common) else { return nil }
        return common
    }

    public static func validate(_ task: AgentTask) throws {
        if case .invalid(let reason) = state(of: task) {
            throw ValidationError.invalid(reason)
        }
    }

    public static func event(for task: AgentTask) -> TaskEvent? {
        guard case .bound(_, let event, _) = state(of: task) else { return nil }
        return event
    }

    public static func payload(for task: AgentTask) -> TaskWorktreePayload? {
        guard case .bound(let payload, _, _) = state(of: task) else { return nil }
        return payload
    }

    /// Validate through the source repository, never through the task-writable
    /// worktree's `.git` pointer. A binding that recorded an identity also
    /// needs the registered worktree to still carry it.
    public static func gitCommonDirectory(for payload: TaskWorktreePayload) -> String? {
        guard let registered = registeredEntry(repositoryPath: payload.repositoryPath, worktreePath: payload.worktreePath),
              holdsRegisteredCheckout(payload.worktreePath, entry: registered.entry)
        else { return nil }
        if let identity = payload.identity {
            let stored = try? String(contentsOf: registered.entry.appendingPathComponent(identityFileName), encoding: .utf8)
            guard stored?.trimmingCharacters(in: .whitespacesAndNewlines) == identity else { return nil }
        }
        return registered.commonDirectory
    }

    /// The path must be the registered checkout itself: a real folder, not a
    /// symlink standing in for one, whose own `.git` file points back at the
    /// registry entry. Resolving symlinks alone would let a link to the source
    /// checkout match a stale entry. This only ever denies, so reading the
    /// worktree's `.git` file is safe.
    private static func holdsRegisteredCheckout(_ worktreePath: String, entry: URL) -> Bool {
        let fileManager = FileManager.default
        let dotGit = (worktreePath as NSString).appendingPathComponent(".git")
        guard (try? fileManager.attributesOfItem(atPath: worktreePath)[.type] as? FileAttributeType) == .typeDirectory,
              (try? fileManager.attributesOfItem(atPath: dotGit)[.type] as? FileAttributeType) == .typeRegular,
              let raw = try? String(contentsOfFile: dotGit, encoding: .utf8),
              raw.lowercased().hasPrefix("gitdir:"),
              let pointed = resolvedGitPath(String(raw.dropFirst("gitdir:".count)), relativeTo: worktreePath)
        else { return false }
        return pointed == resolvedPath(entry.path)
    }

    static let identityFileName = "astra-task-worktree"

    /// The reason `git worktree add --lock` records for a creation with
    /// `identity`. Git writes it in the same command that creates the
    /// worktree, so it proves who created it even before ASTRA saved anything.
    public static func lockReason(forIdentity identity: String) -> String {
        "astra-task-worktree \(identity)"
    }

    public enum RegisteredHeadReflog: Equatable {
        case notRegistered
        case unreadable
        case commits([String])
    }

    /// The commits in the registered worktree's own HEAD reflog, which Git
    /// keeps in its registry entry even after the worktree folder is gone.
    public static func registeredHeadReflog(repositoryPath: String, worktreePath: String) -> RegisteredHeadReflog {
        guard let registered = registeredEntry(repositoryPath: repositoryPath, worktreePath: worktreePath) else {
            return .notRegistered
        }
        guard let log = try? String(
            contentsOf: registered.entry.appendingPathComponent("logs/HEAD"), encoding: .utf8
        ) else { return .unreadable }
        // The null object ID marks the entry that created HEAD. It is all
        // zeros at the repository's own hash length: 40 for SHA-1, 64 for
        // SHA-256.
        return .commits(log.split(whereSeparator: \.isNewline).flatMap { line in
            line.split(separator: " ").prefix(2).map(String.init)
        }.filter { !$0.allSatisfy { $0 == "0" } })
    }

    /// The identity token and the lock reason in `worktreePath`'s registry
    /// entry, or nil when the repository doesn't register that path.
    /// `unreadable` is set when a marker file exists but couldn't be read,
    /// which is never the same as its absence.
    public static func registeredMarkers(
        repositoryPath: String, worktreePath: String
    ) -> (identity: String?, lockReason: String?, unreadable: Bool)? {
        guard let registered = registeredEntry(repositoryPath: repositoryPath, worktreePath: worktreePath) else { return nil }
        var unreadable = false
        func read(_ name: String) -> String? {
            let url = registered.entry.appendingPathComponent(name)
            guard let value = try? String(contentsOf: url, encoding: .utf8) else {
                if (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil { unreadable = true }
                return nil
            }
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let identity = read(identityFileName)
        let lockReason = read("locked")
        return (identity, lockReason, unreadable)
    }

    /// Whether `worktreePath`'s registry entry holds per-worktree Git
    /// configuration, which `git config --worktree` writes there and a
    /// removal deletes. A file that can't be checked counts, since only a
    /// confirmed missing one is absent. Nil when the repository doesn't
    /// register the path.
    public static func registeredWorktreeHasLocalConfig(
        repositoryPath: String, worktreePath: String,
        attributes: (String) throws -> [FileAttributeKey: Any] = { try FileManager.default.attributesOfItem(atPath: $0) }
    ) -> Bool? {
        guard let registered = registeredEntry(repositoryPath: repositoryPath, worktreePath: worktreePath) else { return nil }
        let config = registered.entry.appendingPathComponent("config.worktree")
        do {
            return ((try attributes(config.path)[.size] as? NSNumber)?.intValue ?? 1) > 0
        } catch {
            return !isMissingFileError(error)
        }
    }

    /// What a registry entry holds for a worktree nobody has used: what
    /// `git worktree add` and ASTRA write, and what other checks cover
    /// (refs, reflogs, per-worktree config, submodule repositories).
    static let baselineEntryNames: Set<String> = [
        "HEAD", "ORIG_HEAD", "commondir", "gitdir", "index", "locked", "logs", "refs", "modules",
        "config.worktree", identityFileName, "astra-submodule-tags"
    ]

    /// Whether the registered worktree's entry holds anything beyond that
    /// baseline: state Git keeps for this worktree alone, which a removal
    /// deletes and no status, branch, or reflog shows, such as a merge or
    /// squash in progress (`MERGE_HEAD`, `SQUASH_MSG`), a rebase, a fetch's
    /// `FETCH_HEAD`, or a prepared commit message. Anything unknown counts,
    /// as does an entry that can't be listed. Nil when the repository
    /// doesn't register the path.
    public static func registeredWorktreeHasOwnState(repositoryPath: String, worktreePath: String) -> Bool? {
        guard let registered = registeredEntry(repositoryPath: repositoryPath, worktreePath: worktreePath) else { return nil }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: registered.entry.path) else { return true }
        return names.contains { !baselineEntryNames.contains($0) }
    }

    private static func isMissingFileError(_ error: any Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(nsError.code) { return true }
        // A path through a file can't exist either.
        if nsError.domain == NSPOSIXErrorDomain, [Int(ENOENT), Int(ENOTDIR)].contains(nsError.code) { return true }
        return (nsError.userInfo[NSUnderlyingErrorKey] as? NSError).map(isMissingFileError) ?? false
    }

    /// Whether the registered worktree has refs of its own, such as
    /// `refs/worktree/*` or a bisect in progress, which Git keeps in its
    /// registry entry and a removal deletes with it. A reftable repository
    /// keeps them in a table this doesn't read, and an entry that can't be
    /// listed may hold some, so both count. Nil when it isn't registered.
    public static func registeredWorktreeHasOwnRefs(repositoryPath: String, worktreePath: String) -> Bool? {
        guard let registered = registeredEntry(repositoryPath: repositoryPath, worktreePath: worktreePath) else { return nil }
        let fileManager = FileManager.default
        if (try? fileManager.attributesOfItem(atPath: registered.entry.appendingPathComponent("reftable").path)) != nil {
            return true
        }
        let refs = registered.entry.appendingPathComponent("refs", isDirectory: true)
        do {
            _ = try fileManager.attributesOfItem(atPath: refs.path)
        } catch {
            return !isMissingFileError(error)
        }
        var unreadable = false
        guard let items = fileManager.enumerator(
            at: refs, includingPropertiesForKeys: [.isDirectoryKey], errorHandler: { _, _ in unreadable = true; return false }
        ) else { return true }
        for case let item as URL in items {
            guard let values = try? item.resourceValues(forKeys: [.isDirectoryKey]) else { return true }
            if values.isDirectory != true { return true }
        }
        return unreadable
    }

    /// Marks the worktree `payload` names, just created, with its identity.
    public static func recordIdentity(of payload: TaskWorktreePayload) throws {
        guard let identity = payload.identity,
              let registered = registeredEntry(repositoryPath: payload.repositoryPath, worktreePath: payload.worktreePath)
        else { throw ValidationError.invalid("The new worktree at \(payload.worktreePath) is not registered.") }
        try Data((identity + "\n").utf8).write(
            to: registered.entry.appendingPathComponent(identityFileName), options: .atomic
        )
    }

    /// The source repository must itself be a configured folder, the same rule
    /// worktree creation applies. A configured subfolder or parent never
    /// vouches for a repository, so a binding cannot widen grants beyond it.
    public static func repositoryIsConfigured(_ path: String, for task: AgentTask) -> Bool {
        guard let workspace = task.workspace, let repository = resolvedPath(path) else { return false }
        return ([workspace.primaryPath] + workspace.additionalPaths).contains { resolvedPath($0) == repository }
    }

    /// The shared Git directory of a checkout the repository registers,
    /// only while the folder at `worktreePath` is still that checkout: its own
    /// `.git` file points back to the registry entry. A stale entry Git keeps
    /// after the folder was replaced by a plain folder or another repository
    /// doesn't count.
    private static func registeredCommonDirectory(repositoryPath: String, worktreePath: String) -> String? {
        guard let registered = registeredEntry(repositoryPath: repositoryPath, worktreePath: worktreePath),
              holdsRegisteredCheckout(worktreePath, entry: registered.entry) else { return nil }
        return registered.commonDirectory
    }

    /// The registry entry of `checkout` inside `commonDirectory`, where Git
    /// keeps that checkout's own index, HEAD, and logs, when the entry and
    /// the checkout's `.git` file point at each other.
    public static func registeredAdminEntry(checkout: String, commonDirectory: String) -> String? {
        guard let expected = resolvedPath((checkout as NSString).appendingPathComponent(".git")) else { return nil }
        let registry = URL(fileURLWithPath: commonDirectory).appendingPathComponent("worktrees", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: registry, includingPropertiesForKeys: nil),
              let entry = entries.first(where: { entry in
                  guard let raw = try? String(contentsOf: entry.appendingPathComponent("gitdir"), encoding: .utf8) else {
                      return false
                  }
                  return resolvedGitPath(raw, relativeTo: entry.path) == expected
              }),
              holdsRegisteredCheckout(checkout, entry: entry) else { return nil }
        // Spelled under `commonDirectory` as given, as its other grants are.
        return registry.appendingPathComponent(entry.lastPathComponent).path
    }

    /// The shared Git directory and the worktree's own registry entry in it.
    private static func registeredEntry(
        repositoryPath: String, worktreePath: String
    ) -> (commonDirectory: String, entry: URL)? {
        guard let expected = resolvedPath((worktreePath as NSString).appendingPathComponent(".git")),
              let commonDirectory = checkoutCommonDirectory(repositoryPath) else { return nil }
        let fileManager = FileManager.default
        let registry = URL(fileURLWithPath: commonDirectory).appendingPathComponent("worktrees", isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(at: registry, includingPropertiesForKeys: nil),
              let entry = entries.first(where: { entry in
                  guard let raw = try? String(contentsOf: entry.appendingPathComponent("gitdir"), encoding: .utf8) else {
                      return false
                  }
                  return resolvedGitPath(raw, relativeTo: entry.path) == expected
              }) else { return nil }
        return (commonDirectory, entry)
    }

    /// The shared Git directory of the checkout at `repositoryPath`, read
    /// from its own `.git` entry, with objects and refs present.
    private static func checkoutCommonDirectory(_ repositoryPath: String) -> String? {
        guard let repository = resolvedPath(repositoryPath) else { return nil }
        let fileManager = FileManager.default
        let dotGit = (repository as NSString).appendingPathComponent(".git")
        var isDirectory = ObjCBool(false)
        var gitDirectory = dotGit
        if !fileManager.fileExists(atPath: dotGit, isDirectory: &isDirectory) {
            // A Git directory used as the repository, as cleanup does once a
            // submodule's checkout is gone, is its own Git directory; objects
            // and refs are checked below.
            var headIsDirectory = ObjCBool(false)
            guard fileManager.fileExists(
                atPath: (repository as NSString).appendingPathComponent("HEAD"), isDirectory: &headIsDirectory
            ), !headIsDirectory.boolValue else { return nil }
            gitDirectory = repository
        } else if !isDirectory.boolValue {
            guard let raw = try? String(contentsOfFile: dotGit, encoding: .utf8),
                  raw.lowercased().hasPrefix("gitdir:"),
                  let resolved = resolvedGitPath(String(raw.dropFirst("gitdir:".count)), relativeTo: repository) else {
                return nil
            }
            gitDirectory = resolved
        }
        let commonDirectoryFile = (gitDirectory as NSString).appendingPathComponent("commondir")
        var commonDirectory = gitDirectory
        if fileManager.fileExists(atPath: commonDirectoryFile) {
            guard let raw = try? String(contentsOfFile: commonDirectoryFile, encoding: .utf8),
                  let resolved = resolvedGitPath(raw, relativeTo: gitDirectory) else { return nil }
            commonDirectory = resolved
        }
        for name in ["objects", "refs"] {
            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(
                atPath: (commonDirectory as NSString).appendingPathComponent(name), isDirectory: &isDirectory
            ), isDirectory.boolValue else { return nil }
        }
        return commonDirectory
    }

    /// Resolved through the deepest existing folder, so a path whose worktree
    /// folder is gone still matches the spelling Git recorded, such as
    /// `/private/var` for `/var`.
    private static func resolvedPath(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return WorkspacePathPresentation.resolvedPath((value as NSString).expandingTildeInPath)
    }

    private static func resolvedGitPath(_ rawValue: String, relativeTo base: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return resolvedPath(value.hasPrefix("/") ? value : (base as NSString).appendingPathComponent(value))
    }

    /// Even an invalid or retargeted binding must follow its pin into a
    /// derived task, or a missing checkout would become a legacy fallback.
    /// A retargeted task passes on the event whose repository verifies its
    /// current pin, so the derived task's binding verifies too; otherwise the
    /// newest event.
    public static func eventForInheritance(from task: AgentTask) -> TaskEvent? {
        if let bound = event(for: task) { return bound }
        let prepared = task.events
            .filter { !$0.isDeleted && $0.hasType(TaskEventTypes.Task.worktreePrepared) }
            .sorted { $0.timestamp > $1.timestamp }
        if case .retargeted(let pinned, _) = state(of: task),
           let verifying = prepared.first(where: { event in
               guard case .success(let payload) = event.decodePayload(as: TaskWorktreePayload.self) else { return false }
               return repositoryIsConfigured(payload.repositoryPath, for: task)
                   && verifiedCommonDirectory(checkout: pinned, repository: payload.repositoryPath) != nil
           }) {
            return verifying
        }
        return prepared.first
    }

    /// Pins `target` to `source`'s checkout. Any prepared event travels with
    /// the pin, including an unreadable one, so a derived task cannot fall
    /// back to the source checkout. Returns the copy for the caller to insert.
    @discardableResult
    public static func inheritPin(from source: AgentTask, into target: AgentTask) -> TaskEvent? {
        guard TaskWorktreeCheckoutReservation.commit(source.executionRootPath, to: target) else { return nil }
        guard let binding = eventForInheritance(from: source) else { return nil }
        applyIsolation(to: target, for: binding)
        return copy(binding, to: target)
    }

    /// A task pinned to the worktree `binding` names runs in it directly:
    /// branch and copy isolation are superseded by the worktree itself.
    /// Callers that pin a task to a binding's worktree apply this before
    /// inserting the copied event.
    public static func applyIsolation(to target: AgentTask, for binding: TaskEvent) {
        guard case .success(let payload) = binding.decodePayload(as: TaskWorktreePayload.self),
              target.executionRootPath.map(WorkspacePathPresentation.standardizedPath)
                == WorkspacePathPresentation.standardizedPath(payload.worktreePath) else { return }
        target.isolationStrategy = .sameDirectory
    }

    /// A copy of the binding event for `target`. It changes nothing else.
    public static func copy(_ binding: TaskEvent, to target: AgentTask) -> TaskEvent {
        TaskEvent(task: target, eventType: TaskEventTypes.Task.worktreePrepared, payload: binding.payload)
    }
}

/// Exclusive claim on a checkout path while unused-worktree cleanup removes
/// it. Task pins and workspace imports refuse the checkout, anything inside
/// it, or any folder that contains it, until the claim is released, so
/// neither a task nor a workspace root can be saved onto a checkout that
/// cleanup is deleting.
public enum TaskWorktreeCheckoutReservation {
    private static let lock = NSLock()
    private static var leases: [String: UUID] = [:]

    public struct Token: Sendable {
        fileprivate let path: String
        fileprivate let id: UUID
    }

    /// A competing cleanup retries instead of replacing another owner's lease.
    public static func acquire(_ path: String) -> Token? {
        guard let key = key(path) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard !leases.keys.contains(where: { keysOverlap(key, $0) }) else { return nil }
        let id = UUID()
        leases[key] = id
        return Token(path: key, id: id)
    }

    public static func release(_ token: Token) {
        lock.lock()
        if leases[token.path] == token.id {
            leases.removeValue(forKey: token.path)
        }
        lock.unlock()
    }

    /// True when `path` is a checkout cleanup is removing, lies inside one, or
    /// contains one: a root above the checkout still reaches it.
    public static func isReserved(_ path: String?) -> Bool {
        guard let path = key(path) else { return false }
        lock.lock()
        let reserved = leases.keys.contains { keysOverlap(path, $0) }
        lock.unlock()
        return reserved
    }

    /// True when two paths reach the same folder or one contains the other,
    /// including through symlinks. An empty path names no folder.
    public static func overlaps(_ lhs: String, _ rhs: String) -> Bool {
        guard let lhs = key(lhs), let rhs = key(rhs) else { return false }
        return keysOverlap(lhs, rhs)
    }

    private static func keysOverlap(_ lhs: String, _ rhs: String) -> Bool {
        func contains(_ root: String, _ path: String) -> Bool {
            path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
        return contains(lhs, rhs) || contains(rhs, lhs)
    }

    /// Copies `path` onto `task` unless cleanup currently owns it.
    @discardableResult
    public static func commit(_ path: String?, to task: AgentTask) -> Bool {
        guard !isReserved(path) else { return false }
        task.executionRootPath = path
        return true
    }

    private static func key(_ path: String?) -> String? {
        guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return WorkspacePathPresentation.resolvedPath(path)
    }
}

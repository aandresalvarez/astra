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

    public init(enabled: Bool, base: TaskWorktreeBaseChoice, repositoryPath: String? = nil) {
        self.enabled = enabled
        self.base = base
        let trimmed = repositoryPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.repositoryPath = trimmed?.isEmpty == false ? trimmed : nil
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
        case retargeted(pinned: String)
        case bound(TaskWorktreePayload, event: TaskEvent, pinned: String)
    }

    public static func state(of task: AgentTask) -> State {
        guard let pinned = task.executionRootPath, !pinned.isEmpty else { return .none }
        let events = task.events
            .filter { !$0.isDeleted && $0.hasType(TaskEventTypes.Task.worktreePrepared) }
            .sorted { $0.timestamp > $1.timestamp }
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
        guard repositories.contains(where: {
            resolvedPath($0) == resolvedPath(pinned)
                || registeredCommonDirectory(repositoryPath: $0, worktreePath: pinned) != nil
        }) else {
            return .invalid("The selected checkout is not registered by this task's configured repository.")
        }
        return .retargeted(pinned: pinned)
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
    /// worktree's `.git` pointer.
    public static func gitCommonDirectory(for payload: TaskWorktreePayload) -> String? {
        registeredCommonDirectory(repositoryPath: payload.repositoryPath, worktreePath: payload.worktreePath)
    }

    private static func repositoryIsConfigured(_ path: String, for task: AgentTask) -> Bool {
        guard let workspace = task.workspace, let repository = resolvedPath(path) else { return false }
        return ([workspace.primaryPath] + workspace.additionalPaths).contains { configured in
            guard let root = resolvedPath(configured) else { return false }
            return root == repository || repository.hasPrefix(root + "/") || root.hasPrefix(repository + "/")
        }
    }

    private static func registeredCommonDirectory(repositoryPath: String, worktreePath: String) -> String? {
        guard let repository = resolvedPath(repositoryPath),
              let expected = resolvedPath((worktreePath as NSString).appendingPathComponent(".git")) else { return nil }
        let fileManager = FileManager.default
        let dotGit = (repository as NSString).appendingPathComponent(".git")
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: dotGit, isDirectory: &isDirectory) else { return nil }
        var gitDirectory = dotGit
        if !isDirectory.boolValue {
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
        let registry = URL(fileURLWithPath: commonDirectory).appendingPathComponent("worktrees", isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(at: registry, includingPropertiesForKeys: nil),
              entries.contains(where: { entry in
                  guard let raw = try? String(contentsOf: entry.appendingPathComponent("gitdir"), encoding: .utf8) else {
                      return false
                  }
                  return resolvedGitPath(raw, relativeTo: entry.path) == expected
              }) else { return nil }
        return commonDirectory
    }

    private static func resolvedPath(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
            .resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func resolvedGitPath(_ rawValue: String, relativeTo base: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return resolvedPath(value.hasPrefix("/") ? value : (base as NSString).appendingPathComponent(value))
    }

    /// Even an invalid or retargeted binding must follow its pin into a
    /// derived task, or a missing checkout would become a legacy fallback.
    public static func eventForInheritance(from task: AgentTask) -> TaskEvent? {
        event(for: task) ?? task.events
            .filter { !$0.isDeleted && $0.hasType(TaskEventTypes.Task.worktreePrepared) }
            .max { $0.timestamp < $1.timestamp }
    }

    /// Pins `target` to `source`'s checkout. Any prepared event travels with
    /// the pin, including an unreadable one, so a derived task cannot fall
    /// back to the source checkout. Returns the copy for the caller to insert.
    @discardableResult
    public static func inheritPin(from source: AgentTask, into target: AgentTask) -> TaskEvent? {
        target.executionRootPath = source.executionRootPath
        guard let binding = eventForInheritance(from: source) else { return nil }
        return copy(binding, to: target)
    }

    public static func copy(_ binding: TaskEvent, to target: AgentTask) -> TaskEvent {
        TaskEvent(task: target, eventType: TaskEventTypes.Task.worktreePrepared, payload: binding.payload)
    }
}

import CryptoKit
import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

enum TaskWorktreeCleanupOutcome: Equatable {
    case removed
    case kept(String)
    case retry(String)

    var isTerminal: Bool {
        if case .retry = self { return false }
        return true
    }
}

/// An app-owned outbox, outside provider-writable workspaces. Each atomic
/// record, one per task worktree, survives deletion of its task and is cleared
/// only after removal or a deliberate decision to preserve the checkout.
struct TaskWorktreeCleanupStore: Sendable {
    let directory: URL
    /// Provenance that authorizes cleanup, kept beside the outbox.
    let ownership: TaskWorktreeOwnershipStore

    init(directory: URL = AppChannelStoragePaths.applicationSupportDirectory()
        .appendingPathComponent("WorktreeCleanup", isDirectory: true)) {
        self.directory = directory.standardizedFileURL
        self.ownership = TaskWorktreeOwnershipStore(
            directory: self.directory.deletingLastPathComponent()
                .appendingPathComponent("WorktreeOwnership", isDirectory: true)
        )
    }

    init(directory: URL, ownership: TaskWorktreeOwnershipStore) {
        self.directory = directory.standardizedFileURL
        self.ownership = ownership
    }

    enum StoreError: LocalizedError {
        case invalidRecord

        var errorDescription: String? { "The pending worktree cleanup record is invalid or has changed." }
    }

    func record(_ discard: TaskWorktreeDiscard) throws {
        let url = recordURL(for: discard)
        if FileManager.default.fileExists(atPath: url.path) {
            guard try read(url) == discard else { throw StoreError.invalidRecord }
            return
        }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(discard).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func pendingURLs() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey]
        ).filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
    }

    func read(_ url: URL) throws -> TaskWorktreeDiscard {
        guard url.isFileURL,
              url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
                == directory.resolvingSymlinksInPath().standardizedFileURL.path,
              try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw StoreError.invalidRecord
        }
        let discard = try JSONDecoder().decode(TaskWorktreeDiscard.self, from: Data(contentsOf: url))
        guard recordURL(for: discard).lastPathComponent == url.lastPathComponent else {
            throw StoreError.invalidRecord
        }
        return discard
    }

    func remove(_ discard: TaskWorktreeDiscard) throws {
        let url = recordURL(for: discard)
        guard try read(url) == discard else { throw StoreError.invalidRecord }
        try FileManager.default.removeItem(at: url)
    }

    /// A draft can own several worktrees, so a record is keyed by task and
    /// worktree path.
    func recordURL(for discard: TaskWorktreeDiscard) -> URL {
        recordURL(taskID: discard.taskID, worktreePath: discard.worktreePath)
    }

    func recordURL(taskID: UUID, worktreePath: String) -> URL {
        let worktree = WorkspacePathPresentation.standardizedPath(worktreePath)
        let digest = SHA256.hash(data: Data(worktree.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(taskID.uuidString.lowercased() + "-" + digest + ".json")
    }
}

extension TaskWorktreeOwnershipStore {
    /// Creation intents, written before `git worktree add` runs and cleared
    /// once the task's binding is saved. One left behind means creation was
    /// interrupted; startup recovery settles it like a cleanup record.
    var creationJournal: TaskWorktreeCleanupStore {
        TaskWorktreeCleanupStore(
            directory: directory.deletingLastPathComponent()
                .appendingPathComponent("WorktreeCreation", isDirectory: true),
            ownership: self
        )
    }
}

@MainActor
enum TaskWorktreeCleanupService {
    private static var activeRecords: Set<String> = []

    @discardableResult
    static func resumePending(
        modelContext: ModelContext,
        resourceQueue: TaskQueue?,
        store: TaskWorktreeCleanupStore = TaskWorktreeCleanupStore(),
        git: any GitRepositoryOperating = GitService.shared
    ) async -> Int {
        let urls: [URL]
        do {
            urls = try store.pendingURLs()
        } catch {
            logFailure("worktree_cleanup_outbox_read_failed", error: error)
            return 0
        }
        var removed = 0
        for url in urls {
            guard !Task.isCancelled else { break }
            do {
                let discard = try store.read(url)
                if await process(
                    discard, store: store, modelContext: modelContext, resourceQueue: resourceQueue, git: git
                ) { removed += 1 }
            } catch {
                logFailure("worktree_cleanup_record_read_failed", error: error)
            }
        }
        return removed
    }

    @discardableResult
    static func process(
        _ discard: TaskWorktreeDiscard,
        store: TaskWorktreeCleanupStore,
        modelContext: ModelContext,
        resourceQueue: TaskQueue?,
        git: any GitRepositoryOperating = GitService.shared,
        pinsOwnTask: Bool = true,
        worktreesRoot: String = AppChannel.current.defaultWorktreesRoot
    ) async -> Bool {
        let url = store.recordURL(for: discard)
        let key = activeKey(url)
        guard activeRecords.insert(key).inserted else { return false }
        defer { activeRecords.remove(key) }
        do {
            guard try store.read(url) == discard else { throw TaskWorktreeCleanupStore.StoreError.invalidRecord }
            if !store.ownership.owns(discard), createdByThisIntent(discard) {
                try store.ownership.record(.init(discard))
            }
            guard store.ownership.owns(discard) else {
                AppLogger.breadcrumb(action: "task_worktree_kept", category: "Git", taskID: discard.taskID, fields: [
                    "worktree": discard.worktreePath,
                    "branch": discard.branch,
                    "reason": "not_created_locally"
                ])
                try store.remove(discard)
                return false
            }
            let outcome = await TaskWorktreeService.discardOutcome(
                discard, modelContext: modelContext, resourceQueue: resourceQueue, git: git,
                ownership: store.ownership,
                checkoutPins: { context in
                    // A fresh context reads committed deletion/reference state,
                    // not a caller's unsaved deletion after a failed save.
                    let durable = ModelContext(context.container)
                    let taskID = discard.taskID
                    let descriptor = FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == taskID })
                    var pins = try TaskWorktreeService.durableCheckoutPins(modelContext: durable, worktreesRoot: worktreesRoot)
                    pins.formUnion(try TaskWorktreeService.durableCheckoutPins(modelContext: context, worktreesRoot: worktreesRoot))
                    // A saved task keeps a worktree it was deleted from or
                    // retargeted away from. An interrupted creation never
                    // bound its worktree, so only real pins keep that one.
                    if pinsOwnTask, try durable.fetchCount(descriptor) > 0 {
                        pins.insert(WorkspacePathPresentation.standardizedPath(discard.worktreePath))
                    }
                    return pins
                }
            )
            guard outcome.isTerminal else { return false }
            if outcome == .removed { store.ownership.forget(discard) }
            try store.remove(discard)
            AppLogger.breadcrumb(action: "task_worktree_cleanup_settled", category: "Git", taskID: discard.taskID, fields: [
                "worktree": discard.worktreePath,
                "outcome": outcome == .removed ? "removed" : "preserved"
            ])
            return outcome == .removed
        } catch {
            logFailure("worktree_cleanup_failed", taskID: discard.taskID, error: error)
            return false
        }
    }

    // MARK: - Creation journal

    /// Journals a worktree creation before Git runs, with the ownership
    /// record that lets recovery remove what Git leaves behind. Cleanup and
    /// recovery leave the record alone until the creation settles.
    static func beginCreation(_ discard: TaskWorktreeDiscard, journal: TaskWorktreeCleanupStore) throws {
        let key = activeKey(journal.recordURL(for: discard))
        guard activeRecords.insert(key).inserted else { throw TaskWorktreeCleanupStore.StoreError.invalidRecord }
        do {
            try journal.record(discard)
        } catch {
            activeRecords.remove(key)
            throw error
        }
    }

    /// Grants destructive-cleanup ownership once `git worktree add` has
    /// created the branch and folder. Recorded before Git ran, it would let
    /// a creation that failed on another process's branch or folder remove
    /// them; a crash in the moment between leaves the worktree unowned and
    /// kept, never removed.
    static func recordCreated(_ discard: TaskWorktreeDiscard, journal: TaskWorktreeCleanupStore) throws {
        try journal.ownership.record(.init(discard))
    }

    /// Clears the intent once the task's binding is saved. A record that
    /// can't be removed is settled at next launch, which finds the binding.
    static func finishCreation(_ discard: TaskWorktreeDiscard, journal: TaskWorktreeCleanupStore) {
        do {
            try journal.remove(discard)
        } catch {
            logFailure("worktree_creation_intent_clear_failed", taskID: discard.taskID, error: error)
        }
        activeRecords.remove(activeKey(journal.recordURL(for: discard)))
    }

    /// Removes what a creation that failed before its binding was saved left
    /// behind, with the checks any discarded worktree gets. Runs to the end
    /// even when the creation was cancelled.
    static func abandonCreation(
        _ discard: TaskWorktreeDiscard,
        journal: TaskWorktreeCleanupStore,
        modelContext: ModelContext,
        resourceQueue: TaskQueue?,
        git: any GitRepositoryOperating
    ) async {
        activeRecords.remove(activeKey(journal.recordURL(for: discard)))
        _ = await Task { @MainActor in
            await process(
                discard, store: journal, modelContext: modelContext, resourceQueue: resourceQueue, git: git, pinsOwnTask: false
            )
        }.value
    }

    /// Settles creations a crash or quit interrupted. A worktree whose task
    /// binding was saved stays; anything else Git created is removed under
    /// the usual checks. Ownership is recorded before Git runs, so an entry
    /// without it never touches Git. Returns how many worktrees were removed.
    @discardableResult
    static func resumeInterruptedCreations(
        modelContext: ModelContext,
        resourceQueue: TaskQueue?,
        journal: TaskWorktreeCleanupStore = TaskWorktreeCleanupStore().ownership.creationJournal,
        git: any GitRepositoryOperating = GitService.shared
    ) async -> Int {
        let urls: [URL]
        do {
            urls = try journal.pendingURLs()
        } catch {
            logFailure("worktree_creation_journal_read_failed", error: error)
            return 0
        }
        var removed = 0
        for url in urls {
            guard !Task.isCancelled else { break }
            do {
                let discard = try journal.read(url)
                guard !activeRecords.contains(activeKey(journal.recordURL(for: discard))) else { continue }
                if try bindingIsSaved(discard, modelContext: modelContext)
                    || !(journal.ownership.owns(discard) || createdByThisIntent(discard)) {
                    try journal.remove(discard)
                    continue
                }
                if await process(
                    discard, store: journal, modelContext: modelContext, resourceQueue: resourceQueue, git: git, pinsOwnTask: false
                ) {
                    removed += 1
                }
            } catch {
                logFailure("worktree_creation_intent_read_failed", error: error)
            }
        }
        return removed
    }

    /// True when a saved task, of any that share the ID, records preparing
    /// this worktree.
    private static func bindingIsSaved(_ discard: TaskWorktreeDiscard, modelContext: ModelContext) throws -> Bool {
        let taskID = discard.taskID
        let worktree = WorkspacePathPresentation.standardizedPath(discard.worktreePath)
        let tasks = try ModelContext(modelContext.container).fetch(
            FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == taskID })
        )
        return tasks.contains { task in
            task.events.contains { event in
                guard !event.isDeleted, event.hasType(TaskEventTypes.Task.worktreePrepared),
                      case .success(let binding) = event.decodePayload(as: TaskWorktreePayload.self) else { return false }
                return WorkspacePathPresentation.standardizedPath(binding.worktreePath) == worktree
            }
        }
    }

    /// A creation that stopped after `git worktree add` but before recording
    /// ownership is still recognized: Git recorded this intent's lock reason
    /// in the same command, which a competing worktree never carries.
    private static func createdByThisIntent(_ discard: TaskWorktreeDiscard) -> Bool {
        guard let identity = discard.identity,
              let markers = TaskWorktreeBinding.registeredMarkers(
                  repositoryPath: TaskWorktreeService.cleanupRepository(for: discard), worktreePath: discard.worktreePath
              ) else { return false }
        return markers.lockReason == TaskWorktreeBinding.lockReason(forIdentity: identity)
    }

    private static func activeKey(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func logFailure(_ reason: String, taskID: UUID? = nil, error: Error) {
        AppLogger.audit(.taskFailed, category: "Persistence", taskID: taskID, fields: [
            "reason": reason,
            "error": error.localizedDescription
        ], level: .error)
    }
}

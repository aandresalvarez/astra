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
/// record survives deletion of its task and is cleared only after removal or
/// a deliberate decision to preserve the checkout.
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

    enum StoreError: LocalizedError {
        case invalidRecord

        var errorDescription: String? { "The pending worktree cleanup record is invalid or has changed." }
    }

    func record(_ discard: TaskWorktreeDiscard) throws {
        let url = recordURL(for: discard.taskID)
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
        guard recordURL(for: discard.taskID).lastPathComponent == url.lastPathComponent else {
            throw StoreError.invalidRecord
        }
        return discard
    }

    func remove(_ discard: TaskWorktreeDiscard) throws {
        let url = recordURL(for: discard.taskID)
        guard try read(url) == discard else { throw StoreError.invalidRecord }
        try FileManager.default.removeItem(at: url)
    }

    func recordURL(for taskID: UUID) -> URL {
        directory.appendingPathComponent(taskID.uuidString.lowercased() + ".json")
    }
}

@MainActor
enum TaskWorktreeCleanupService {
    private static var activeRecords: Set<String> = []

    @discardableResult
    static func resumePending(
        modelContext: ModelContext,
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
                if await process(discard, store: store, modelContext: modelContext, git: git) { removed += 1 }
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
        git: any GitRepositoryOperating = GitService.shared
    ) async -> Bool {
        let url = store.recordURL(for: discard.taskID)
        let key = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard activeRecords.insert(key).inserted else { return false }
        defer { activeRecords.remove(key) }
        do {
            guard try store.read(url) == discard else { throw TaskWorktreeCleanupStore.StoreError.invalidRecord }
            let outcome = await TaskWorktreeService.discardOutcome(
                discard, modelContext: modelContext, git: git,
                checkoutPins: { context in
                    // A fresh context reads committed deletion/reference state,
                    // not a caller's unsaved deletion after a failed save.
                    let durable = ModelContext(context.container)
                    let taskID = discard.taskID
                    let descriptor = FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == taskID })
                    var pins = try TaskWorktreeService.durableCheckoutPins(modelContext: durable)
                    pins.formUnion(try TaskWorktreeService.durableCheckoutPins(modelContext: context))
                    if try durable.fetchCount(descriptor) > 0 {
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

    private static func logFailure(_ reason: String, taskID: UUID? = nil, error: Error) {
        AppLogger.audit(.taskFailed, category: "Persistence", taskID: taskID, fields: [
            "reason": reason,
            "error": error.localizedDescription
        ], level: .error)
    }
}

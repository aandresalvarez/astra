import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// A durable record of skill Keychain namespaces a deletion is about to
/// orphan: an activation's projected skills (Remove), or a plugin skill row
/// the migration replaces.
///
/// Those namespaces are named by IDs that exist only in the rows being
/// deleted: once the save lands, nothing in the store can derive them again.
/// So the record is written before the save, settled after it, taken back if
/// the save fails, and finished on the next launch if a quit came between.
/// A recorded namespace is cleaned only while nothing live still names it.
@MainActor
struct PluginSecretCleanupOutbox {
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL.standardizedFileURL
    }

    /// The outbox for the store `modelContext` writes to, beside the
    /// connector cleanup outbox. Nil for an in-memory store.
    init?(for modelContext: ModelContext) {
        guard let configuration = modelContext.container.configurations.first(where: { !$0.isStoredInMemoryOnly })
        else { return nil }
        let directory = ConnectorCredentialCleanupStore.directory(
            forStoreAt: configuration.url,
            applicationSupport: WorkspaceRecoveryService.applicationSupportDirectory
        ).deletingLastPathComponent()
        self.init(fileURL: directory.appendingPathComponent("PluginSecretCleanup.json"))
    }

    /// Records `skillIDs`, saves, then cleans them. Returns false, with the
    /// record taken back, when the record can't be written or the save fails.
    static func deleteThenClean(
        _ skillIDs: [UUID],
        modelContext: ModelContext,
        outbox: PluginSecretCleanupOutbox? = nil,
        save: () -> Bool
    ) -> Bool {
        let outbox = outbox ?? PluginSecretCleanupOutbox(for: modelContext)
        let unique = Array(Set(skillIDs))
        let previous: [UUID]
        do {
            previous = try outbox?.pending() ?? []
            try outbox?.write(Array(Set(previous + unique)))
        } catch {
            AppLogger.audit(.keychainDeleteFailed, category: "Keychain", fields: [
                "scope": "plugin_secret_cleanup", "reason": "intent_unwritable",
                "error_type": String(describing: type(of: error))
            ], level: .error)
            return false
        }
        guard save() else {
            try? outbox?.write(previous)
            return false
        }
        settle(unique, modelContext: modelContext, outbox: outbox)
        return true
    }

    /// Finishes cleanups a quit interrupted. Run at launch, once recovery
    /// allows credential cleanup.
    static func resumePending(modelContext: ModelContext, outbox: PluginSecretCleanupOutbox? = nil) {
        let outbox = outbox ?? PluginSecretCleanupOutbox(for: modelContext)
        guard let pending = try? outbox?.pending(), !pending.isEmpty else { return }
        settle(pending, modelContext: modelContext, outbox: outbox)
    }

    /// Cleans every recorded namespace nothing live names and drops it from
    /// the record; one still in use (re-added, restored) is dropped uncleaned.
    private static func settle(_ skillIDs: [UUID], modelContext: ModelContext, outbox: PluginSecretCleanupOutbox?) {
        // What is live can't be told without the store: every record stays.
        guard let live = liveSkillIDs(modelContext: modelContext) else {
            AppLogger.audit(.keychainDeleteFailed, category: "Keychain", fields: [
                "scope": "plugin_secret_cleanup", "reason": "store_unreadable_kept"
            ], level: .error)
            return
        }
        var settled = Set<UUID>()
        for id in skillIDs {
            if live.contains(id) || SkillKeychainCleanup(skillID: id).run() {
                settled.insert(id)
            }
        }
        guard let outbox, let pending = try? outbox.pending() else { return }
        try? outbox.write(pending.filter { !settled.contains($0) })
    }

    /// Skill IDs whose namespaces something still reads: stored skill rows,
    /// and every live activation's projected skills; nil when the store
    /// can't be read.
    static func liveSkillIDs(modelContext: ModelContext) -> Set<UUID>? {
        guard let skills = try? modelContext.fetch(FetchDescriptor<Skill>()),
              let activations = try? modelContext.fetch(FetchDescriptor<PluginActivation>()) else { return nil }
        var live = Set(skills.map(\.id))
        let packages = Dictionary(
            CapabilityRuntimeResourceMatcher.packageDefinitions().map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for activation in activations where !activation.isDeleted {
            live.formUnion(PluginRuntimeProjection.secretNamespaces(of: activation, package: packages[activation.pluginID]))
        }
        return live
    }

    func pending() throws -> [UUID] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([String].self, from: data).compactMap(UUID.init(uuidString:))
    }

    func write(_ skillIDs: [UUID]) throws {
        if skillIDs.isEmpty {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            return
        }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(skillIDs.map(\.uuidString).sorted())
        try data.write(to: fileURL, options: [.atomic])
    }
}

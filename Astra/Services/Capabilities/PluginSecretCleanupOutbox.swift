import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// A durable record of skill Keychain namespaces a deletion is about to
/// orphan: an activation's projected skills (Remove), or a plugin skill row
/// the migration replaces. It also records single secret settings an Update
/// releases from a component it keeps (`componentNamespace#KEY` entries).
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

    /// Records `skillIDs` (and single `keys`), saves, then cleans them.
    /// Returns false, with the record taken back, when the record can't be
    /// written or the save fails.
    static func deleteThenClean(
        _ skillIDs: [UUID],
        keys: [PluginUpdateService.StaleSecret] = [],
        modelContext: ModelContext,
        outbox: PluginSecretCleanupOutbox? = nil,
        save: () -> Bool
    ) -> Bool {
        let outbox = outbox ?? PluginSecretCleanupOutbox(for: modelContext)
        let unique = Array(Set(skillIDs))
        let uniqueKeys = Array(Set(keys))
        let previous: [String]
        do {
            previous = try outbox?.entries() ?? []
            try outbox?.writeEntries(Array(Set(previous + unique.map(\.uuidString) + uniqueKeys.map(Self.entry))))
        } catch {
            AppLogger.audit(.keychainDeleteFailed, category: "Keychain", fields: [
                "scope": "plugin_secret_cleanup", "reason": "intent_unwritable",
                "error_type": String(describing: type(of: error))
            ], level: .error)
            return false
        }
        guard save() else {
            try? outbox?.writeEntries(previous)
            return false
        }
        settle(unique, keys: uniqueKeys, modelContext: modelContext, outbox: outbox)
        return true
    }

    /// Finishes cleanups a quit interrupted. Run at launch, once recovery
    /// allows credential cleanup.
    static func resumePending(modelContext: ModelContext, outbox: PluginSecretCleanupOutbox? = nil) {
        let outbox = outbox ?? PluginSecretCleanupOutbox(for: modelContext)
        guard let pending = try? outbox?.pending(), let keys = try? outbox?.pendingKeys(),
              !pending.isEmpty || !keys.isEmpty else { return }
        settle(pending, keys: keys, modelContext: modelContext, outbox: outbox)
    }

    /// Cleans every recorded namespace nothing live names and drops it from
    /// the record; one still in use (re-added, restored) is dropped uncleaned.
    /// A recorded key is deleted unless a live activation records that
    /// secret again.
    private static func settle(
        _ skillIDs: [UUID],
        keys: [PluginUpdateService.StaleSecret],
        modelContext: ModelContext,
        outbox: PluginSecretCleanupOutbox?
    ) {
        // What is live can't be told without the store: every record stays.
        guard let live = liveSkillIDs(modelContext: modelContext),
              let liveKeys = liveSecretKeys(modelContext: modelContext) else {
            AppLogger.audit(.keychainDeleteFailed, category: "Keychain", fields: [
                "scope": "plugin_secret_cleanup", "reason": "store_unreadable_kept"
            ], level: .error)
            return
        }
        var settled = Set<String>()
        for id in skillIDs where live.contains(id) || SkillKeychainCleanup(skillID: id).run() {
            settled.insert(id.uuidString)
        }
        let persistence = SkillSecretSeam.required
        for key in keys where liveKeys.contains(key) || persistence.deleteSecret(key: key.key, skillID: key.skillID) {
            settled.insert(entry(key))
        }
        guard let outbox, let pending = try? outbox.entries() else { return }
        try? outbox.writeEntries(pending.filter { !settled.contains($0) })
    }

    /// The secret settings live activations record, by namespace; nil when
    /// the store can't be read.
    static func liveSecretKeys(modelContext: ModelContext) -> Set<PluginUpdateService.StaleSecret>? {
        guard let activations = try? modelContext.fetch(FetchDescriptor<PluginActivation>()) else { return nil }
        var live = Set<PluginUpdateService.StaleSecret>()
        for activation in activations where !activation.isDeleted {
            for settingKey in activation.secretSettingKeys {
                guard let componentID = PluginActivation.componentID(ofSettingKey: settingKey) else { continue }
                live.insert(PluginUpdateService.StaleSecret(
                    key: String(settingKey.dropFirst(componentID.count + 1)),
                    skillID: PluginRuntimeProjection.derivedID(of: activation, componentID: componentID)
                ))
            }
        }
        return live
    }

    private static func entry(_ key: PluginUpdateService.StaleSecret) -> String {
        "\(key.skillID.uuidString)#\(key.key)"
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

    /// The recorded namespaces.
    func pending() throws -> [UUID] {
        try entries().compactMap(UUID.init(uuidString:))
    }

    /// The recorded single secrets.
    func pendingKeys() throws -> [PluginUpdateService.StaleSecret] {
        try entries().compactMap { entry in
            guard let separator = entry.firstIndex(of: "#"),
                  let skillID = UUID(uuidString: String(entry[..<separator])) else { return nil }
            return PluginUpdateService.StaleSecret(key: String(entry[entry.index(after: separator)...]), skillID: skillID)
        }
    }

    func entries() throws -> [String] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([String].self, from: data)
    }

    /// Replaces the recorded namespaces, keeping recorded single secrets.
    func write(_ skillIDs: [UUID]) throws {
        let keys = try entries().filter { UUID(uuidString: $0) == nil }
        try writeEntries(skillIDs.map(\.uuidString) + keys)
    }

    func writeEntries(_ entries: [String]) throws {
        if entries.isEmpty {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            return
        }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Array(Set(entries)).sorted())
        try data.write(to: fileURL, options: [.atomic])
    }
}

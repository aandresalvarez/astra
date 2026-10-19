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
    ///
    /// `beforeSettling` runs once the save has landed, for a step the
    /// cleanup must wait on (the migration rewriting every mirror that still
    /// names a deleted row). When it fails the deletion stands, so this
    /// still returns true, but the record stays for `resumePending`, which
    /// cleans only once no mirror names the row.
    static func deleteThenClean(
        _ skillIDs: [UUID],
        modelContext: ModelContext,
        outbox: PluginSecretCleanupOutbox? = nil,
        save: () -> Bool,
        beforeSettling: () -> Bool = { true }
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
        guard beforeSettling() else {
            AppLogger.audit(.keychainDeleteFailed, category: "Keychain", fields: [
                "scope": "plugin_secret_cleanup", "reason": "held_for_mirror", "count": String(unique.count)
            ], level: .warning)
            return true
        }
        settle(unique, modelContext: modelContext, outbox: outbox)
        return true
    }

    /// Finishes cleanups a quit interrupted, or a mirror rewrite held back.
    /// Run at launch, once recovery allows credential cleanup.
    ///
    /// A recorded row a workspace mirror still lists, or a namespace an
    /// activation it lists derives (one a Remove held back), would come back
    /// from it without its secrets, so the stored workspaces whose mirror
    /// names one are exported first, and one any mirror still names waits,
    /// as does everything while a mirror can't be read.
    static func resumePending(modelContext: ModelContext, outbox: PluginSecretCleanupOutbox? = nil) {
        let outbox = outbox ?? PluginSecretCleanupOutbox(for: modelContext)
        guard let pending = try? outbox?.pending(), !pending.isEmpty else { return }
        guard let held = namedByMirrors(pending, modelContext: modelContext) else {
            AppLogger.audit(.keychainDeleteFailed, category: "Keychain", fields: [
                "scope": "plugin_secret_cleanup", "reason": "workspace_mirror_unreadable"
            ], level: .error)
            return
        }
        settle(pending.filter { !held.contains($0) }, modelContext: modelContext, outbox: outbox)
    }

    /// The recorded rows a workspace mirror still lists once the stored
    /// workspaces whose own mirror lists one are written again; nil when a
    /// mirror can't be read.
    private static func namedByMirrors(_ pending: [UUID], modelContext: ModelContext) -> Set<UUID>? {
        guard let before = ConnectorCredentialCleanup.connectorsInStoredMirrors(modelContext: modelContext),
              let beforeActivations = activationNamespacesInStoredMirrors(modelContext: modelContext) else { return nil }
        let named = Set(pending).intersection(before.skillIDs.union(beforeActivations.flatMap(\.1)))
        guard !named.isEmpty else { return [] }
        var exported = Set<UUID>()
        for (workspace, listed) in before.skillsByWorkspace + beforeActivations
        where !listed.isDisjoint(with: named) && exported.insert(workspace.id).inserted {
            WorkspaceConfigManager.exportMirrorNow(workspace: workspace, modelContext: modelContext)
        }
        guard let after = ConnectorCredentialCleanup.connectorsInStoredMirrors(modelContext: modelContext),
              let afterActivations = activationNamespacesInStoredMirrors(modelContext: modelContext) else { return nil }
        return named.intersection(after.skillIDs.union(afterActivations.flatMap(\.1)))
    }

    /// The secret namespaces each stored workspace's own mirror would give
    /// back with the activations it lists (`InstalledPluginRef`: every
    /// component it records, under its seed), which a launch recovery
    /// restores with the workspace's ID. Nil when a mirror can't be read.
    static func activationNamespacesInStoredMirrors(modelContext: ModelContext) -> [(Workspace, Set<UUID>)]? {
        struct Listed: Decodable {
            struct Plugin: Decodable {
                let id: String
                let settings: [String: String]?
                let overriddenComponentIDs: [String]?
                let knownComponentIDs: [String]?
                let secretSettingKeys: [String]?
                let namespaceSeed: String?
            }
            let installedPlugins: [Plugin]?
        }
        guard let workspaces = try? modelContext.fetch(FetchDescriptor<Workspace>()) else { return nil }
        var result: [(Workspace, Set<UUID>)] = []
        for workspace in workspaces {
            // Recovery reads the legacy mirror only without the current one.
            let files = [
                WorkspaceFileLayout.workspaceConfigFile(for: workspace.primaryPath),
                WorkspaceFileLayout.legacyWorkspaceConfigFile(for: workspace.primaryPath)
            ].filter { !$0.isEmpty }
            for file in files {
                let data: Data
                do {
                    data = try Data(contentsOf: URL(fileURLWithPath: file))
                } catch {
                    if WorkspaceFileLayout.isMissingFile(error) { continue }
                    return nil
                }
                guard let listed = try? JSONDecoder().decode(Listed.self, from: data) else { return nil }
                var namespaces = Set<UUID>()
                for plugin in listed.installedPlugins ?? [] {
                    let settingKeys = Array((plugin.settings ?? [:]).keys) + (plugin.secretSettingKeys ?? [])
                    let components = (plugin.knownComponentIDs ?? []) + (plugin.overriddenComponentIDs ?? [])
                        + settingKeys.compactMap(PluginActivation.componentID(ofSettingKey:))
                    for componentID in Set(components) {
                        namespaces.insert(PluginActivation.projectedID(
                            workspaceID: workspace.id, pluginID: plugin.id, componentID: componentID,
                            seed: plugin.namespaceSeed ?? ""
                        ))
                    }
                }
                result.append((workspace, namespaces))
                break
            }
        }
        return result
    }

    /// Settles what a Remove left pending before `package` is added to
    /// `workspace` again. With no activation of it there, the namespaces a
    /// new one would derive are nobody's, so they are cleaned now; while one
    /// is still pending (its delete failed, or the record can't be read) the
    /// Add must wait, or the new activation would read the old values.
    static func settleBeforeAdding(
        _ package: PluginPackage,
        to workspace: Workspace,
        modelContext: ModelContext,
        outbox: PluginSecretCleanupOutbox? = nil,
        clean: (UUID) -> Bool = { SkillKeychainCleanup(skillID: $0).run() }
    ) -> Bool {
        guard let outbox = outbox ?? PluginSecretCleanupOutbox(for: modelContext) else { return true }
        guard let pending = try? outbox.pending() else { return false }
        // The seed a Remove kept is the one the new activation derives with.
        let seed = WorkspaceCapabilityActivation.retiredActivations(of: workspace)
            .first { $0.pluginID == package.id }?.namespaceSeed ?? ""
        let derived = Set(PluginRuntimeProjection.componentIDs(of: package).map {
            PluginActivation.projectedID(workspaceID: workspace.id, pluginID: package.id, componentID: $0, seed: seed)
        })
        let reused = pending.filter(derived.contains)
        guard !reused.isEmpty else { return true }
        settle(reused, modelContext: modelContext, outbox: outbox, clean: clean)
        guard let after = try? outbox.pending() else { return false }
        return after.allSatisfy { !derived.contains($0) }
    }

    /// Cleans every recorded namespace nothing live names and drops it from
    /// the record; one still in use (re-added, restored) is dropped uncleaned.
    private static func settle(
        _ skillIDs: [UUID],
        modelContext: ModelContext,
        outbox: PluginSecretCleanupOutbox?,
        clean: (UUID) -> Bool = { SkillKeychainCleanup(skillID: $0).run() }
    ) {
        // What is live can't be told without the store: every record stays.
        guard let live = liveSkillIDs(modelContext: modelContext) else {
            AppLogger.audit(.keychainDeleteFailed, category: "Keychain", fields: [
                "scope": "plugin_secret_cleanup", "reason": "store_unreadable_kept"
            ], level: .error)
            return
        }
        var settled = Set<UUID>()
        for id in skillIDs {
            if live.contains(id) || clean(id) {
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

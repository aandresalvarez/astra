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
    ///
    /// `beforeSettling` runs once the save has landed, for a step the
    /// cleanup must wait on: rewriting every mirror the save changed (the
    /// migration's, an Update's, a Remove's), since one still naming what
    /// was released would bring it back without its secrets. When it fails
    /// the deletion stands, so this still returns true, but the record stays
    /// for `resumePending`.
    static func deleteThenClean(
        _ skillIDs: [UUID],
        keys: [PluginUpdateService.StaleSecret] = [],
        modelContext: ModelContext,
        outbox: PluginSecretCleanupOutbox? = nil,
        secrets: (any SkillSecretPersisting.Type)? = nil,
        save: () -> Bool,
        beforeSettling: () -> Bool = { true }
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
        guard beforeSettling() else {
            AppLogger.audit(.keychainDeleteFailed, category: "Keychain", fields: [
                "scope": "plugin_secret_cleanup", "reason": "held_for_mirror", "count": String(unique.count + uniqueKeys.count)
            ], level: .warning)
            return true
        }
        settle(unique, keys: uniqueKeys, modelContext: modelContext, outbox: outbox, secrets: secrets, clean: cleaner(secrets))
        return true
    }

    /// Finishes cleanups a quit interrupted, or a mirror rewrite held back.
    /// Run at launch, once recovery allows credential cleanup.
    ///
    /// Which mirrors still name what an Update or a Remove released isn't
    /// recorded, so every stored workspace's mirror is rewritten first, and
    /// nothing settles while one can't be. A recorded row a mirror still
    /// lists after that would come back from it without its secrets, so it
    /// waits, as does everything while a mirror can't be read.
    static func resumePending(
        modelContext: ModelContext,
        outbox: PluginSecretCleanupOutbox? = nil,
        secrets: (any SkillSecretPersisting.Type)? = nil,
        rewriteMirror: ((Workspace) -> Bool)? = nil
    ) {
        let outbox = outbox ?? PluginSecretCleanupOutbox(for: modelContext)
        guard let pending = try? outbox?.pending(), let keys = try? outbox?.pendingKeys(),
              !pending.isEmpty || !keys.isEmpty else { return }
        let rewrite = rewriteMirror ?? { WorkspaceConfigManager.exportMirrorNow(workspace: $0, modelContext: modelContext) }
        guard let workspaces = try? modelContext.fetch(FetchDescriptor<Workspace>()),
              workspaces.reduce(true, { rewrite($1) && $0 }) else {
            AppLogger.audit(.keychainDeleteFailed, category: "Keychain", fields: [
                "scope": "plugin_secret_cleanup", "reason": "mirror_rewrite_failed_kept"
            ], level: .error)
            return
        }
        guard let held = namedByMirrors(pending, modelContext: modelContext) else {
            AppLogger.audit(.keychainDeleteFailed, category: "Keychain", fields: [
                "scope": "plugin_secret_cleanup", "reason": "workspace_mirror_unreadable"
            ], level: .error)
            return
        }
        settle(
            pending.filter { !held.contains($0) }, keys: keys, modelContext: modelContext, outbox: outbox,
            secrets: secrets, clean: cleaner(secrets)
        )
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
        settle(reused, keys: [], modelContext: modelContext, outbox: outbox, clean: clean)
        guard let after = try? outbox.pending() else { return false }
        return after.allSatisfy { !derived.contains($0) }
    }

    /// Settles the recorded single secrets among `keys` (secret settings a
    /// definition declares that their activation doesn't record) before the
    /// definition is accepted: a value a failed cleanup left there would
    /// otherwise reach a run as the new setting's, and the next cleanup would
    /// delete a credential the person may have entered since. Returns the
    /// keys still pending: a delete failed, or (all of them) the record
    /// can't be read.
    static func settleRedeclared(
        _ keys: [PluginUpdateService.StaleSecret],
        modelContext: ModelContext?,
        outbox: PluginSecretCleanupOutbox? = nil,
        delete: (PluginUpdateService.StaleSecret) -> Bool
    ) -> [PluginUpdateService.StaleSecret] {
        guard !keys.isEmpty, let outbox = outbox ?? modelContext.flatMap(PluginSecretCleanupOutbox.init(for:)) else { return [] }
        guard let pending = try? outbox.pendingKeys() else { return keys }
        let redeclared = keys.filter(Set(pending).contains)
        let failed = redeclared.filter { !delete($0) }
        let settled = Set(redeclared.filter { !failed.contains($0) }.map(entry))
        if !settled.isEmpty, let entries = try? outbox.entries() {
            try? outbox.writeEntries(entries.filter { !settled.contains($0) })
        }
        return failed
    }

    /// Clears what is still journaled for deletion in the namespace a rename
    /// is about to move state into (`destination`, keys `keys`), keeping the
    /// keys the activation records there (`kept`): a component removed
    /// earlier whose cleanup failed must not hand its old values to the one
    /// now renamed onto its ID. A journaled namespace the activation records
    /// nothing in is cleared whole (`clean`): the failed cleanup may have
    /// left keys `keys` doesn't name, and a later version declaring one again
    /// would read it. Returns false while something is still pending there
    /// (a delete failed, or the record can't be read).
    static func settleRenameDestination(
        _ destination: UUID,
        keys: [String],
        kept: Set<String>,
        modelContext: ModelContext?,
        outbox: PluginSecretCleanupOutbox? = nil,
        clean: (UUID) -> Bool,
        delete: (String) -> Bool
    ) -> Bool {
        guard let outbox = outbox ?? modelContext.flatMap(PluginSecretCleanupOutbox.init(for:)) else { return true }
        guard let entries = try? outbox.entries() else { return false }
        let namespace = destination.uuidString
        let prefix = namespace + "#"
        let journaled = entries.filter { $0 == namespace || $0.hasPrefix(prefix) }
        guard !journaled.isEmpty else { return true }
        if journaled.contains(namespace), kept.isEmpty {
            guard clean(destination) else { return false }
        } else {
            var toDelete = Set(journaled.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
            // Secrets the activation records there keep it live, so it is
            // cleaned only of what isn't the person's (as `settle` would).
            if journaled.contains(namespace) { toDelete.formUnion(keys) }
            let failed = toDelete.subtracting(kept).filter { !delete($0) }
            guard failed.isEmpty else { return false }
        }
        try? outbox.writeEntries(entries.filter { !journaled.contains($0) })
        return (try? outbox.entries()).map { remaining in
            !remaining.contains { $0 == namespace || $0.hasPrefix(prefix) }
        } ?? false
    }

    /// How a namespace is cleared: through `secrets` when given.
    private static func cleaner(_ secrets: (any SkillSecretPersisting.Type)?) -> (UUID) -> Bool {
        guard let secrets else { return { SkillKeychainCleanup(skillID: $0).run() } }
        return { secrets.deleteAllSecretsReportingResult(skillID: $0) }
    }

    /// Cleans every recorded namespace nothing live names and drops it from
    /// the record; one still in use (re-added, restored) is dropped uncleaned.
    /// A recorded key is deleted unless a live activation records that
    /// secret again.
    private static func settle(
        _ skillIDs: [UUID],
        keys: [PluginUpdateService.StaleSecret],
        modelContext: ModelContext,
        outbox: PluginSecretCleanupOutbox?,
        secrets: (any SkillSecretPersisting.Type)? = nil,
        clean: (UUID) -> Bool = { SkillKeychainCleanup(skillID: $0).run() }
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
        for id in skillIDs where live.contains(id) || clean(id) {
            settled.insert(id.uuidString)
        }
        let persistence = secrets ?? SkillSecretSeam.required
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

    /// Records single secrets about to be written for an activation not yet
    /// saved (`PluginSecretSettingWriter.writeJournaled`): settled with its
    /// save (dropped while the activation records them), cleaned at launch
    /// when a quit came first.
    func journal(_ keys: [PluginUpdateService.StaleSecret]) throws {
        let pending = try entries()
        try writeEntries(Array(Set(pending + keys.map(Self.entry))))
    }

    /// Takes back single secrets `journal` recorded, for a write that
    /// didn't happen or was undone.
    func forget(_ keys: [PluginUpdateService.StaleSecret]) {
        let dropped = Set(keys.map(Self.entry))
        guard let pending = try? entries() else { return }
        try? writeEntries(pending.filter { !dropped.contains($0) })
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

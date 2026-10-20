import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// The row-level operations of the Plugins surface on the activation model:
/// a plugin skill's settings, the accounts bound to a connector component,
/// and deleting an account. Add, Turn off, Update and Remove live in the
/// installer, `CapabilityActivationDisabler`, `PluginUpdateService` and
/// `CapabilityUninstaller`; this is the rest of what a `PluginRow` offers.
///
/// Each operation saves once through `WorkspacePersistenceCoordinator` and
/// rolls back on failure. Secrets go to the Keychain, never SwiftData.
@MainActor
enum PluginOperations {
    enum OperationError: Error, Equatable, LocalizedError {
        case notAdded(pluginID: String)
        case secretSaveFailed(key: String)
        case secretDeleteFailed(key: String)
        /// The change wasn't saved and the Keychain couldn't take back the
        /// value it had already written or cleared.
        case secretRestoreFailed(key: String)
        case storeUnreadable
        case saveFailed

        var errorDescription: String? {
            switch self {
            case .notAdded: "Add the plugin to this workspace first."
            case .secretSaveFailed(let key): "Couldn't save \(key) to the Keychain."
            case .secretDeleteFailed(let key): "Couldn't clear \(key) from the Keychain; the old value is still in use."
            case .secretRestoreFailed(let key): "Couldn't save the change, and \(key) couldn't be put back as it was in the Keychain. Enter it again."
            case .storeUnreadable: "Couldn't read the workspaces that use this account."
            case .saveFailed: "Couldn't save the change."
            }
        }
    }

    // MARK: - Settings

    /// A plugin skill's setting in this workspace: the activation's value,
    /// else the plugin's default. Secret values are read from the Keychain.
    static func setting(
        _ key: String,
        of skill: PluginSkill,
        in activation: PluginActivation
    ) -> String {
        let componentID = CapabilityResourceOrigin.componentID(for: skill)
        if Skill.isSecretEnvironmentKey(key) {
            let skillID = PluginRuntimeProjection.derivedID(of: activation, componentID: componentID)
            return SkillSecretSeam.required.loadSecretValue(key: key, skillID: skillID, store: KeychainSecretStore()) ?? ""
        }
        if let value = activation.configuration(forComponent: componentID)[key] { return value }
        guard let index = skill.environmentKeys.firstIndex(of: key), index < skill.environmentValues.count else { return "" }
        return skill.environmentValues[index]
    }

    /// Sets a plugin skill's setting for this workspace. A secret value is
    /// written through `PluginSecretSettingWriter`: the activation records
    /// it, durably, before the Keychain has it. An empty secret clears it
    /// from the Keychain first; a clear the Keychain refuses throws, so the
    /// old credential is never reported gone while still in use, and a
    /// failed save after it puts the value back (one it can't put back is
    /// reported as such). An emptied non-secret setting is kept as empty.
    static func setSetting(
        _ key: String,
        to value: String,
        of skill: PluginSkill,
        pluginID: String,
        in workspace: Workspace,
        modelContext: ModelContext,
        secrets: (any SkillSecretPersisting.Type)? = nil,
        persist: (Workspace, ModelContext) throws -> Void = persistAndExport,
        rewriteMirror: ((Workspace) -> Bool)? = nil
    ) throws {
        guard let activation = WorkspaceCapabilityActivation.activation(for: pluginID, in: workspace) else {
            throw OperationError.notAdded(pluginID: pluginID)
        }
        let componentID = CapabilityResourceOrigin.componentID(for: skill)
        let settingKey = PluginActivation.settingKey(componentID: componentID, key: key)
        let snapshot = WorkspaceCapabilityActivation.snapshot(workspace)
        if Skill.isSecretEnvironmentKey(key) {
            let skillID = PluginRuntimeProjection.derivedID(of: activation, componentID: componentID)
            let persistence = secrets ?? SkillSecretSeam.required
            guard value.isEmpty else {
                try PluginSecretSettingWriter.write(
                    value, key: key, skillName: skill.name, settingKey: settingKey, skillID: skillID,
                    on: activation, persistence: persistence
                ) {
                    workspace.updatedAt = Date()
                    try save(workspace, modelContext: modelContext, restoring: snapshot, persist: persist)
                    // Written now, not queued: the mirror names the secret
                    // before the Keychain holds it.
                    guard rewriteMirror?(workspace)
                        ?? WorkspaceConfigManager.exportMirrorNow(workspace: workspace, modelContext: modelContext)
                    else { throw OperationError.saveFailed }
                }
                return
            }
            let previous = persistence.loadSecretValue(key: key, skillID: skillID, store: KeychainSecretStore())
            guard persistence.deleteSecret(key: key, skillID: skillID) else {
                throw OperationError.secretDeleteFailed(key: key)
            }
            // The record goes only once the Keychain value has.
            WorkspaceCapabilityActivation.setSecretRecorded(false, forKey: settingKey, on: activation)
            do {
                try save(workspace, modelContext: modelContext, restoring: snapshot, persist: persist)
            } catch {
                // The record went back to what it was; so does the Keychain.
                // A value it can't take back no longer matches the record.
                if let previous, !persistence.saveSecretValue(
                    previous, key: key, skillID: skillID, skillName: skill.name, allowUserInteraction: false
                ) {
                    throw OperationError.secretRestoreFailed(key: key)
                }
                throw error
            }
            return
        }
        // A secret an earlier definition kept under this now plain key is
        // the person's to replace: entering the setting clears it. The
        // cleared value is held for a save that fails, as the empty-secret
        // branch holds its: the record then goes back to naming a value
        // that is there again, or the loss is reported.
        var cleared: (persistence: any SkillSecretPersisting.Type, skillID: UUID, previous: String)?
        if activation.secretSettingKeys.contains(settingKey) {
            let persistence = secrets ?? SkillSecretSeam.required
            let skillID = PluginRuntimeProjection.derivedID(of: activation, componentID: componentID)
            let previous = persistence.loadSecretValue(key: key, skillID: skillID, store: KeychainSecretStore())
            guard persistence.deleteSecret(key: key, skillID: skillID) else {
                throw OperationError.secretDeleteFailed(key: key)
            }
            WorkspaceCapabilityActivation.setSecretRecorded(false, forKey: settingKey, on: activation)
            if let previous, !previous.isEmpty { cleared = (persistence, skillID, previous) }
        }
        WorkspaceCapabilityActivation.setConfigValue(value, forKey: settingKey, on: activation)
        workspace.updatedAt = Date()
        do {
            try save(workspace, modelContext: modelContext, restoring: snapshot, persist: persist)
        } catch {
            if let cleared, !cleared.persistence.saveSecretValue(
                cleared.previous, key: key, skillID: cleared.skillID, skillName: skill.name, allowUserInteraction: false
            ) {
                throw OperationError.secretRestoreFailed(key: key)
            }
            throw error
        }
    }

    /// Saves; the mirrors are written by the post-save hook in `save`
    /// (`PluginStateMirrors`).
    static func persistAndExport(_ workspace: Workspace, modelContext: ModelContext) throws {
        try WorkspacePersistenceCoordinator.saveWithoutAutoExportOrThrow(workspace: workspace, modelContext: modelContext)
    }

    // MARK: - Accounts

    /// A new account for a connector component, owned by this workspace and
    /// bound to its activation (the default when it is the first). The
    /// caller opens it for its credentials.
    @discardableResult
    static func addAccount(
        for connector: PluginConnector,
        of package: PluginPackage,
        in workspace: Workspace,
        modelContext: ModelContext
    ) throws -> Connector {
        guard let activation = WorkspaceCapabilityActivation.activation(for: package.id, in: workspace) else {
            throw OperationError.notAdded(pluginID: package.id)
        }
        let componentID = CapabilityResourceOrigin.componentID(for: connector)
        let snapshot = WorkspaceCapabilityActivation.snapshot(workspace)
        let account = Connector(
            name: WorkspaceCapabilityActivation.uniqueAlias(connector.name, serviceType: connector.serviceType, in: workspace),
            serviceType: connector.serviceType,
            icon: connector.icon,
            connectorDescription: connector.description,
            baseURL: connector.baseURL,
            authMethod: connector.authMethod
        )
        account.notes = connector.notes
        // A setting only a bundled definition may keep plain; any other is
        // a credential field of the account (`PluginConnectorFieldTrust`).
        let stored = PluginConnectorFieldTrust.asStored(connector, in: package)
        account.credentialKeys = stored.credentialHints.map(\.key)
        account.credentialValues = Array(repeating: "", count: account.credentialKeys.count)
        account.configKeys = stored.configHints.map(\.key)
        account.configValues = Array(repeating: "", count: account.configKeys.count)
        CapabilityResourceOrigin.stamp(account, package: package, componentID: componentID)
        modelContext.insert(account)
        account.workspace = workspace
        WorkspaceCapabilityActivation.bind(account, toComponent: componentID, of: activation)
        workspace.updatedAt = Date()
        try save(workspace, modelContext: modelContext, restoring: snapshot, accounts: [account])
        return account
    }

    /// Makes `account` the workspace's default for its service.
    static func makeDefault(
        _ account: Connector,
        componentID: String,
        pluginID: String,
        in workspace: Workspace,
        modelContext: ModelContext
    ) throws {
        guard let activation = WorkspaceCapabilityActivation.activation(for: pluginID, in: workspace) else {
            throw OperationError.notAdded(pluginID: pluginID)
        }
        let snapshot = WorkspaceCapabilityActivation.snapshot(workspace)
        WorkspaceCapabilityActivation.bind(account, toComponent: componentID, of: activation, isDefault: true)
        workspace.updatedAt = Date()
        try save(workspace, modelContext: modelContext, restoring: snapshot, accounts: [account])
    }

    /// Every workspace deleting `account` reaches, for the delete
    /// confirmation to name and the deletion to rewrite: each whose mirror
    /// carries it (`WorkspaceConfigManager.workspacesMirroring`: its owner,
    /// a plugin's binding, a shared list, a shared skill it is attached
    /// to), and any that still lists it. Throws when the store can't be
    /// read: a scope missing a workspace that mirrors the account must never
    /// be confirmed.
    static func workspacesUsing(_ account: Connector) throws -> [Workspace] {
        try workspacesUsing(account) {
            guard let context = account.modelContext else { throw OperationError.storeUnreadable }
            return try context.fetch(FetchDescriptor<Workspace>())
        }
    }

    static func workspacesUsing(
        _ account: Connector,
        fetchingWith fetchWorkspaces: () throws -> [Workspace]
    ) throws -> [Workspace] {
        var seen = Set<UUID>()
        let id = account.id.uuidString
        guard let workspaces = try? fetchWorkspaces(), let modelContext = account.modelContext else {
            throw OperationError.storeUnreadable
        }
        let listing = workspaces.filter { WorkspaceCapabilityActivation.state(of: $0).globalConnectorIDs.contains(id) }
        let mirroring = try WorkspaceConfigManager.workspacesMirroring(accountIDs: [account.id], among: workspaces, modelContext: modelContext)
        return ([account.workspace].compactMap { $0 } + mirroring + listing)
            .filter { !$0.isDeleted && seen.insert($0.id).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Deletes an account everywhere: its bindings go with it, its row is
    /// deleted, and its credentials are cleaned through the durable connector
    /// cleanup outbox once the deletion is saved. The only operation that
    /// clears an account's credentials.
    static func deleteAccount(
        _ account: Connector, modelContext: ModelContext, rewriteMirror: ((Workspace) -> Bool)? = nil
    ) throws {
        // Who lists the account must be known before anything is deleted: a
        // workspace missed here would keep a dangling ID.
        guard let workspaces = try? modelContext.fetch(FetchDescriptor<Workspace>()) else {
            throw OperationError.storeUnreadable
        }
        let id = account.id.uuidString
        let listing = workspaces.filter { WorkspaceCapabilityActivation.state(of: $0).globalConnectorIDs.contains(id) }
        // Every workspace whose mirror names the account, the one the
        // confirmation named, is rewritten once the deletion is saved and
        // before its credentials are cleaned, so recovery can't bring it back.
        let affected = try workspacesUsing(account) { workspaces }
        // rollback() doesn't restore bindings and memberships: every
        // workspace the deletion touches is put back by hand if it fails.
        let snapshots = affected.map { ($0, WorkspaceCapabilityActivation.snapshot($0)) }
        for workspace in listing {
            WorkspaceCapabilityActivation.mutate(workspace) { $0.globalConnectorIDs.removeAll { $0 == id } }
        }
        let cleanup = account.keychainCleanup
        for binding in account.accountBindings where !binding.isDeleted {
            if let activation = binding.activation {
                WorkspaceCapabilityActivation.unbind(account, from: activation)
            }
        }
        modelContext.delete(account)
        let saved = ConnectorCredentialCleanup.deleteThenClean(
            [cleanup], modelContext: modelContext,
            save: { WorkspacePersistenceCoordinator.saveWithoutAutoExport(modelContext: modelContext) },
            beforeSettling: { rewriteMirror.map { rewrite in affected.reduce(true) { rewrite($1) && $0 } }
                ?? WorkspaceConfigManager.exportMirrorsNow(affected, modelContext: modelContext) }
        )
        guard saved else {
            modelContext.rollback()
            snapshots.forEach { WorkspaceCapabilityActivation.restore($1, to: $0) }
            throw OperationError.saveFailed
        }
    }

    // MARK: - Held imports

    /// Discards what a workspace file's activation (or a recovery's) left
    /// waiting for `pluginID` in `workspace` (`RetiredPluginActivation
    /// .pendingImport`): its settings, overrides and accounts are never
    /// restored. The rows it named stay the person's. Saved and mirrored
    /// like every plugin-state save; a failed save puts it back.
    static func discardPendingImport(
        pluginID: String,
        in workspace: Workspace,
        modelContext: ModelContext,
        persist: (Workspace, ModelContext) throws -> Void = persistAndExport
    ) throws {
        guard WorkspaceCapabilityActivation.pendingImport(pluginID: pluginID, in: workspace) != nil else { return }
        let snapshot = WorkspaceCapabilityActivation.snapshot(workspace)
        WorkspaceCapabilityActivation.dropPendingImport(pluginID: pluginID, in: workspace)
        workspace.updatedAt = Date()
        try save(workspace, modelContext: modelContext, restoring: snapshot, persist: persist)
        AppLogger.audit(.capabilityDisabled, category: "Capabilities", fields: [
            "operation": "pending_import_discarded", "package_id": pluginID, "workspace_id": workspace.id.uuidString
        ])
    }

    // MARK: - Private

    private static func save(
        _ workspace: Workspace,
        modelContext: ModelContext,
        restoring snapshot: WorkspaceCapabilityActivation.Snapshot,
        accounts: [Connector] = [],
        persist: (Workspace, ModelContext) throws -> Void = persistAndExport
    ) throws {
        do {
            try persist(workspace, modelContext)
        } catch {
            modelContext.rollback()
            WorkspaceCapabilityActivation.restore(snapshot, to: workspace)
            throw OperationError.saveFailed
        }
        // Every plugin-state save writes the mirrors it changed.
        PluginStateMirrors.exportAfterSave(workspace: workspace, accounts: accounts, modelContext: modelContext)
    }
}

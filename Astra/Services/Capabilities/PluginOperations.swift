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
        case secretReadFailed(key: String)
        case workspaceChanged
        case storeUnreadable
        case saveFailed
        case pendingEdits
        case updateRequired

        var errorDescription: String? {
            switch self {
            case .updateRequired: "Update the plugin before changing its settings or accounts."
            case .notAdded: "Add the plugin to this workspace first."
            case .secretReadFailed(let key): "Couldn't read \(key) from the Keychain. Check credential-storage access before retrying."
            case .secretSaveFailed(let key): "Couldn't save \(key) to the Keychain."
            case .workspaceChanged: "The workspace changed. Reopen its settings before retrying."
            case .storeUnreadable: "Couldn't read the workspaces that use this account."
            case .saveFailed: "Couldn't save the change."
            case .pendingEdits: "Save or discard your pending edits before changing plugin settings or accounts."
            }
        }
    }

    // MARK: - Settings

    /// A plugin skill's setting in this workspace: the activation's value,
    /// else the plugin's default. Secret values are read from the Keychain.
    static func setting(
        _ key: String,
        of skill: PluginSkill,
        in activation: PluginActivation,
        secrets: (any SkillSecretPersisting.Type)? = nil
    ) throws -> String {
        let componentID = CapabilityResourceOrigin.componentID(for: skill)
        if Skill.isSecretEnvironmentKey(key) {
            let skillID = PluginRuntimeProjection.credentialID(of: activation, componentID: componentID)
            switch (secrets ?? SkillSecretSeam.required).readSecretValue(key: key, skillID: skillID, store: KeychainSecretStore()) {
            case .value(let value): return value
            case .missing: return ""
            case .unavailable: throw OperationError.secretReadFailed(key: key)
            }
        }
        if let value = activation.configuration(forComponent: componentID)[key] { return value }
        guard let index = skill.environmentKeys.firstIndex(of: key), index < skill.environmentValues.count else { return "" }
        return skill.environmentValues[index]
    }

    /// Publishes settings with a complete credential generation. Old values
    /// are never overwritten or cleared before the matching domain receipt.
    static func setSetting(
        _ key: String, to value: String, of skill: PluginSkill, package: PluginPackage,
        in workspace: Workspace, modelContext: ModelContext,
        secrets: (any SkillSecretPersisting.Type)? = nil,
        persist: (Workspace, ModelContext) throws -> Void = persistAndExport,
        rewriteMirror: ((Workspace) -> Bool)? = nil
    ) throws {
        guard !modelContext.hasChanges else { throw OperationError.pendingEdits }
        guard workspace.modelContext === modelContext, !workspace.isDeleted else { throw OperationError.workspaceChanged }
        try PluginActivationAdmission.requireCurrent(in: workspace, modelContext: modelContext)
        let pluginID = package.id
        guard let activation = WorkspaceCapabilityActivation.activation(for: pluginID, in: workspace) else {
            throw OperationError.notAdded(pluginID: pluginID)
        }
        guard package.skills.contains(skill), !PluginRuntimeProjection.awaitsUpdate(activation, to: package) else {
            throw OperationError.updateRequired
        }
        let componentID = CapabilityResourceOrigin.componentID(for: skill)
        let settingKey = PluginActivation.settingKey(componentID: componentID, key: key)
        let snapshot = WorkspaceCapabilityActivation.snapshot(workspace)
        let secret = Skill.isSecretEnvironmentKey(key)
        let changesCredentials = secret || activation.secretSettingKeys.contains(settingKey)
        let prepared: PluginCredentialGenerationTransaction?
        if changesCredentials {
            prepared = try PluginCredentialGenerationTransaction.prepare(activation: activation,
                workspaceID: workspace.id, componentID: componentID, key: key,
                replacement: secret && !value.isEmpty ? value : nil, skillName: skill.name,
                modelContext: modelContext, persistence: secrets ?? SkillSecretSeam.required)
        } else { prepared = nil }
        if let prepared { WorkspaceCapabilityActivation.setCredentialNamespaceSeed(prepared.generation, on: activation) }
        if secret {
            WorkspaceCapabilityActivation.setConfigValue(nil, forKey: settingKey, on: activation)
            WorkspaceCapabilityActivation.setSecretRecorded(!value.isEmpty, forKey: settingKey, on: activation)
        } else {
            WorkspaceCapabilityActivation.setSecretRecorded(false, forKey: settingKey, on: activation)
            WorkspaceCapabilityActivation.setConfigValue(value, forKey: settingKey, on: activation)
        }
        workspace.updatedAt = Date()
        do {
            try save(workspace, modelContext: modelContext, restoring: snapshot,
                pluginIDs: [pluginID], rewriteMirror: rewriteMirror, persist: persist)
            prepared?.completed(keeping: Set(PluginRuntimeProjection.secretNamespaces(of: activation, package: nil)))
        } catch {
            // A saved or uncertain cutover must retain both generations and
            // their recovery intents. Only a proved noncommit can discard.
            if !PluginOperationProblem.preventsRollback(error) { prepared?.discard() }
            throw error
        }
    }

    /// Saves the domain state; `save` couples it to a durable operation
    /// receipt and confirms its mirrors through `PluginStateCommit`.
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
        guard !modelContext.hasChanges else { throw OperationError.pendingEdits }
        try PluginActivationAdmission.requireCurrent(in: workspace, modelContext: modelContext)
        guard let activation = WorkspaceCapabilityActivation.activation(for: package.id, in: workspace) else {
            throw OperationError.notAdded(pluginID: package.id)
        }
        guard package.connectors.contains(connector), !PluginRuntimeProjection.awaitsUpdate(activation, to: package) else {
            throw OperationError.updateRequired
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
        // This is a new, empty account, never a legacy credential owner.
        // Publish its private namespace with the row so shared aliases from
        // older accounts cannot supply credentials before the first edit.
        account.credentialNamespaceID = UUID()
        account.notes = connector.notes
        // A setting only a bundled definition may keep plain; any other is
        // a credential field of the account (`PluginConnectorFieldTrust`).
        let stored = PluginConnectorFieldTrust.asStored(connector, in: package)
        account.credentialKeys = stored.credentialHints.map(\.key)
        account.credentialValues = Array(repeating: "", count: account.credentialKeys.count)
        account.configKeys = PluginAccountFieldLayout.configurationKeys(hints: stored.configHints)
        let defaults = PluginAccountFieldLayout.defaults(in: package)
        account.configValues = account.configKeys.map { defaults[$0] ?? "" }
        CapabilityResourceOrigin.stamp(account, package: package, componentID: componentID)
        modelContext.insert(account)
        account.workspace = workspace
        WorkspaceCapabilityActivation.bind(account, toComponent: componentID, of: activation)
        workspace.updatedAt = Date()
        try save(workspace, modelContext: modelContext, restoring: snapshot, accounts: [account], pluginIDs: [package.id], kind: .add)
        return account
    }

    /// Makes `account` the workspace's default for its service.
    static func makeDefault(
        _ account: Connector,
        componentID: String,
        package: PluginPackage,
        in workspace: Workspace,
        modelContext: ModelContext
    ) throws {
        guard !modelContext.hasChanges else { throw OperationError.pendingEdits }
        try PluginActivationAdmission.requireCurrent(in: workspace, modelContext: modelContext)
        guard let activation = WorkspaceCapabilityActivation.activation(for: package.id, in: workspace) else {
            throw OperationError.notAdded(pluginID: package.id)
        }
        guard !PluginRuntimeProjection.awaitsUpdate(activation, to: package) else { throw OperationError.updateRequired }
        guard account.modelContext === modelContext, !account.isDeleted,
              activation.bindings.contains(where: { !$0.isDeleted && $0.account?.id == account.id && $0.componentID == componentID }) else {
            throw OperationError.workspaceChanged
        }
        let snapshot = WorkspaceCapabilityActivation.snapshot(workspace)
        WorkspaceCapabilityActivation.bind(account, toComponent: componentID, of: activation, isDefault: true)
        workspace.updatedAt = Date()
        try save(workspace, modelContext: modelContext, restoring: snapshot, accounts: [account], pluginIDs: [package.id], kind: .accountChange)
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
        guard !modelContext.hasChanges else { throw OperationError.pendingEdits }
        guard account.modelContext === modelContext, !account.isDeleted else { throw OperationError.workspaceChanged }
        // Serialize with credential producers until the deletion and cleanup
        // intent are saved, so its admitted namespace cannot rotate in between.
        let journal = try ConnectorCredentialGenerationJournal(modelContext: modelContext)
        let lease = try journal?.acquireLease()
        defer { withExtendedLifetime(lease) {} }
        _ = try journal?.pending()
        // Who lists the account must be known before anything is deleted: a
        // workspace missed here would keep a dangling ID.
        let workspaces = try PluginAccountDeletionAdmission.currentWorkspaces(for: account, modelContext: modelContext)
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
            PluginSavedStateRollback.finish(in: modelContext)
            throw OperationError.saveFailed
        }
    }

    // MARK: - Private

    private static func save(
        _ workspace: Workspace,
        modelContext: ModelContext,
        restoring snapshot: WorkspaceCapabilityActivation.Snapshot,
        accounts: [Connector] = [],
        pluginIDs: [String] = [],
        kind: PluginOperationReceipt.Kind = .configure,
        rewriteMirror: ((Workspace) -> Bool)? = nil,
        publishesCompleted: Bool = true,
        persist: (Workspace, ModelContext) throws -> Void = persistAndExport
    ) throws {
        switch PluginStateCommit.save(workspace: workspace, accounts: accounts, pluginIDs: pluginIDs,
            kind: kind, modelContext: modelContext, persist: { try persist(workspace, $0) },
            export: rewriteMirror, publishesCompleted: publishesCompleted) {
        case .completed: return
        case .pendingRecovery(let id): throw PluginOperationProblem.savedRecoveryPending(id)
        case .indeterminate(let id, _): throw PluginOperationProblem.commitUncertain(id)
        case .notCommitted:
            modelContext.rollback()
            WorkspaceCapabilityActivation.restore(snapshot, to: workspace)
            PluginSavedStateRollback.finish(in: modelContext)
            throw OperationError.saveFailed
        }
    }
}

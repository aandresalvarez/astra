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
        case storeUnreadable
        case saveFailed

        var errorDescription: String? {
            switch self {
            case .notAdded: "Add the plugin to this workspace first."
            case .secretSaveFailed(let key): "Couldn't save \(key) to the Keychain."
            case .secretDeleteFailed(let key): "Couldn't clear \(key) from the Keychain; the old value is still in use."
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

    /// Sets a plugin skill's setting for this workspace. An empty secret
    /// clears it from the Keychain; a clear the Keychain refuses throws, so
    /// the old credential is never reported gone while still in use. An
    /// emptied non-secret setting is kept as empty.
    static func setSetting(
        _ key: String,
        to value: String,
        of skill: PluginSkill,
        pluginID: String,
        in workspace: Workspace,
        modelContext: ModelContext
    ) throws {
        guard let activation = WorkspaceCapabilityActivation.activation(for: pluginID, in: workspace) else {
            throw OperationError.notAdded(pluginID: pluginID)
        }
        let componentID = CapabilityResourceOrigin.componentID(for: skill)
        let settingKey = PluginActivation.settingKey(componentID: componentID, key: key)
        let snapshot = WorkspaceCapabilityActivation.snapshot(workspace)
        if Skill.isSecretEnvironmentKey(key) {
            let skillID = PluginRuntimeProjection.derivedID(of: activation, componentID: componentID)
            let persistence = SkillSecretSeam.required
            let previous = persistence.loadSecretValue(key: key, skillID: skillID, store: KeychainSecretStore())
            if value.isEmpty {
                guard persistence.deleteSecret(key: key, skillID: skillID) else {
                    throw OperationError.secretDeleteFailed(key: key)
                }
            } else if !persistence.saveSecretValue(value, key: key, skillID: skillID, skillName: skill.name, allowUserInteraction: true) {
                throw OperationError.secretSaveFailed(key: key)
            }
            // Which secrets exist is recorded, so cleanup and Update find them.
            WorkspaceCapabilityActivation.setSecretRecorded(!value.isEmpty, forKey: settingKey, on: activation)
            do {
                try save(workspace, modelContext: modelContext, restoring: snapshot)
            } catch {
                // The record went back to what it was; so does the Keychain.
                if let previous {
                    persistence.saveSecretValue(previous, key: key, skillID: skillID, skillName: skill.name, allowUserInteraction: false)
                } else {
                    persistence.deleteSecret(key: key, skillID: skillID)
                }
                throw error
            }
            return
        }
        WorkspaceCapabilityActivation.setConfigValue(value, forKey: settingKey, on: activation)
        workspace.updatedAt = Date()
        try save(workspace, modelContext: modelContext, restoring: snapshot)
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
        account.credentialKeys = connector.credentialHints.map(\.key)
        account.credentialValues = Array(repeating: "", count: account.credentialKeys.count)
        account.configKeys = connector.configHints.map(\.key)
        account.configValues = Array(repeating: "", count: account.configKeys.count)
        CapabilityResourceOrigin.stamp(account, package: package, componentID: componentID)
        modelContext.insert(account)
        account.workspace = workspace
        WorkspaceCapabilityActivation.bind(account, toComponent: componentID, of: activation)
        workspace.updatedAt = Date()
        try save(workspace, modelContext: modelContext, restoring: snapshot)
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
        try save(workspace, modelContext: modelContext, restoring: snapshot)
    }

    /// Every workspace deleting `account` reaches, for the delete
    /// confirmation to name: its owner, the workspaces whose plugins bind
    /// it, and those that list it as a shared connector. Throws when the
    /// store can't be read: a scope missing the workspaces that only list
    /// the account must never be confirmed.
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
        guard let workspaces = try? fetchWorkspaces() else { throw OperationError.storeUnreadable }
        let listing = workspaces.filter { WorkspaceCapabilityActivation.state(of: $0).globalConnectorIDs.contains(id) }
        let bound = account.accountBindings.filter { !$0.isDeleted }.compactMap { $0.activation?.workspace }
        return ([account.workspace].compactMap { $0 } + bound + listing)
            .filter { !$0.isDeleted && seen.insert($0.id).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Deletes an account everywhere: its bindings go with it, its row is
    /// deleted, and its credentials are cleaned through the durable connector
    /// cleanup outbox once the deletion is saved. The only operation that
    /// clears an account's credentials.
    static func deleteAccount(_ account: Connector, modelContext: ModelContext) throws {
        // Who lists the account must be known before anything is deleted: a
        // workspace missed here would keep a dangling ID.
        guard let workspaces = try? modelContext.fetch(FetchDescriptor<Workspace>()) else {
            throw OperationError.storeUnreadable
        }
        let id = account.id.uuidString
        let listing = workspaces.filter { WorkspaceCapabilityActivation.state(of: $0).globalConnectorIDs.contains(id) }
        // Every workspace whose mirror names the account is exported after
        // the deletion, so recovery can't bring it back.
        var affected = try listing + workspacesUsing(account) { workspaces }
        if let owner = account.workspace { affected.append(owner) }
        // rollback() doesn't restore bindings and memberships: every
        // workspace the deletion touches is put back by hand if it fails.
        var seen = Set<UUID>()
        let snapshots = affected.filter { seen.insert($0.id).inserted }.map { ($0, WorkspaceCapabilityActivation.snapshot($0)) }
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
        let saved = ConnectorCredentialCleanup.deleteThenClean([cleanup], modelContext: modelContext) {
            (try? WorkspacePersistenceCoordinator.saveAndAutoExportOrThrow(workspaces: affected, modelContext: modelContext)) != nil
        }
        guard saved else {
            modelContext.rollback()
            snapshots.forEach { WorkspaceCapabilityActivation.restore($1, to: $0) }
            throw OperationError.saveFailed
        }
    }

    // MARK: - Private

    private static func save(
        _ workspace: Workspace,
        modelContext: ModelContext,
        restoring snapshot: WorkspaceCapabilityActivation.Snapshot
    ) throws {
        do {
            try WorkspacePersistenceCoordinator.saveAndAutoExportOrThrow(workspace: workspace, modelContext: modelContext)
        } catch {
            modelContext.rollback()
            WorkspaceCapabilityActivation.restore(snapshot, to: workspace)
            throw OperationError.saveFailed
        }
    }
}

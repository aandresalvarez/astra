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
        case saveFailed

        var errorDescription: String? {
            switch self {
            case .notAdded: "Add the plugin to this workspace first."
            case .secretSaveFailed(let key): "Couldn't save \(key) to the Keychain."
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
            let skillID = PluginRuntimeProjection.derivedID(activationID: activation.id, componentID: componentID)
            return SkillSecretSeam.required.loadSecretValue(key: key, skillID: skillID, store: KeychainSecretStore()) ?? ""
        }
        if let value = activation.configuration(forComponent: componentID)[key] { return value }
        guard let index = skill.environmentKeys.firstIndex(of: key), index < skill.environmentValues.count else { return "" }
        return skill.environmentValues[index]
    }

    /// Sets a plugin skill's setting for this workspace. An empty secret
    /// clears it from the Keychain.
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
        if Skill.isSecretEnvironmentKey(key) {
            let skillID = PluginRuntimeProjection.derivedID(activationID: activation.id, componentID: componentID)
            let persistence = SkillSecretSeam.required
            if value.isEmpty {
                persistence.deleteSecret(key: key, skillID: skillID)
            } else if !persistence.saveSecretValue(value, key: key, skillID: skillID, skillName: skill.name, allowUserInteraction: true) {
                throw OperationError.secretSaveFailed(key: key)
            }
            return
        }
        let snapshot = WorkspaceCapabilityActivation.snapshot(workspace)
        WorkspaceCapabilityActivation.setConfigValue(value, forKey: "\(componentID).\(key)", on: activation)
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
        let existing = activation.accounts(forComponent: componentID)
        let account = Connector(
            name: uniqueAlias(connector.name, among: existing.map(\.name)),
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

    /// Makes `account` the default for its component in this workspace.
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

    /// The workspaces whose plugins use `account`, for the delete
    /// confirmation to name.
    static func workspacesUsing(_ account: Connector) -> [Workspace] {
        var seen = Set<UUID>()
        return account.accountBindings
            .filter { !$0.isDeleted }
            .compactMap { $0.activation?.workspace }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Deletes an account everywhere: its bindings go with it, its row is
    /// deleted, and its credentials are cleaned through the durable connector
    /// cleanup outbox once the deletion is saved. The only operation that
    /// clears an account's credentials.
    static func deleteAccount(_ account: Connector, modelContext: ModelContext) throws {
        let workspaces = (try? modelContext.fetch(FetchDescriptor<Workspace>())) ?? []
        let id = account.id.uuidString
        let listing = workspaces.filter { WorkspaceCapabilityActivation.state(of: $0).globalConnectorIDs.contains(id) }
        let snapshots = listing.map { ($0, WorkspaceCapabilityActivation.snapshot($0)) }
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
            (try? WorkspacePersistenceCoordinator.saveAndAutoExportOrThrow(workspace: nil, modelContext: modelContext)) != nil
        }
        guard saved else {
            modelContext.rollback()
            snapshots.forEach { WorkspaceCapabilityActivation.restore($1, to: $0) }
            throw OperationError.saveFailed
        }
    }

    // MARK: - Private

    /// "Jira", then "Jira 2", "Jira 3": an account's name is its alias, and
    /// aliases of one component must tell its accounts apart.
    static func uniqueAlias(_ base: String, among names: [String]) -> String {
        let taken = Set(names.map { $0.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var index = 2
        while taken.contains("\(base) \(index)".lowercased()) { index += 1 }
        return "\(base) \(index)"
    }

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

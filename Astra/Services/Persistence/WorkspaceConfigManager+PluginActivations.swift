import Foundation
import SwiftData
import ASTRAModels

/// How `.astra-workspace.json` carries a workspace's plugin activations.
///
/// Besides the plugin ID and version, each entry keeps what the activation
/// owns for the workspace: its non-secret settings, the components the person
/// replaced with an authored row, and which connector rows are the accounts
/// of each connector component. Launch recovery restores all of it; a file
/// the user picks restores it only for components the installed plugin still
/// declares, against the rows the import itself created.
extension WorkspaceConfigManager {
    public struct InstalledPluginRef: Codable, Sendable {
        public init(
            id: String,
            version: String,
            name: String? = nil,
            settings: [String: String]? = nil,
            overriddenComponentIDs: [String]? = nil,
            overridingRowIDs: [String]? = nil,
            accounts: [PluginAccountRef]? = nil,
            activationID: String? = nil
        ) {
            self.id = id
            self.activationID = activationID
            self.version = version
            self.name = name
            self.settings = settings
            self.overriddenComponentIDs = overriddenComponentIDs
            self.overridingRowIDs = overridingRowIDs
            self.accounts = accounts
        }

        public var id: String
        public var version: String
        public var name: String?
        /// Non-secret settings keyed `componentID.KEY`.
        public var settings: [String: String]?
        public var overriddenComponentIDs: [String]?
        public var overridingRowIDs: [String]?
        public var accounts: [PluginAccountRef]?
        /// The activation's own ID, which names its projected components'
        /// Keychain namespaces. Restored only from the workspace's own mirror.
        public var activationID: String?
    }

    public struct PluginAccountRef: Codable, Sendable, Equatable {
        public var componentID: String
        public var connectorID: String
        public var isDefault: Bool

        public init(componentID: String, connectorID: String, isDefault: Bool) {
            self.componentID = componentID
            self.connectorID = connectorID
            self.isDefault = isDefault
        }
    }

    /// Every connector row bound as an account to one of the workspace's
    /// activations, shared ones included, so the mirror can rebind them.
    static func boundAccounts(of workspace: Workspace) -> [Connector] {
        WorkspaceCapabilityActivation.activations(of: workspace)
            .flatMap(\.bindings)
            .filter { !$0.isDeleted }
            .compactMap(\.account)
    }

    static func installedPluginRefs(for workspace: Workspace) -> [InstalledPluginRef] {
        WorkspaceCapabilityActivation.activations(of: workspace).map { activation in
            let accounts = activation.bindings
                .filter { !$0.isDeleted }
                .sorted { $0.createdAt < $1.createdAt }
                .compactMap { binding in
                    binding.account.map {
                        PluginAccountRef(componentID: binding.componentID, connectorID: $0.id.uuidString, isDefault: binding.isDefault)
                    }
                }
            return InstalledPluginRef(
                id: activation.pluginID,
                version: activation.recordedVersion.isEmpty ? "0.0.0" : activation.recordedVersion,
                settings: activation.configuration.isEmpty ? nil : activation.configuration,
                overriddenComponentIDs: activation.overriddenComponentIDs.isEmpty ? nil : activation.overriddenComponentIDs,
                overridingRowIDs: activation.overridingRowIDs.isEmpty ? nil : activation.overridingRowIDs,
                accounts: accounts.isEmpty ? nil : accounts,
                activationID: activation.id.uuidString
            )
        }
    }

    /// Restores each imported activation's settings, overrides and account
    /// bindings once `apply` has created the activations. Row IDs from the
    /// file resolve through the maps the import built, so a validated import
    /// (fresh row IDs) binds the rows it created, never an unrelated one.
    @MainActor
    static func restoreActivationDetails(
        from config: WorkspaceConfig,
        into workspace: Workspace,
        connectorsByID: [String: Connector],
        skillsByID: [String: Skill],
        toolsByID: [String: LocalTool],
        trust: CapabilityImportTrustPolicy
    ) {
        for ref in config.installedPlugins ?? [] {
            guard let activation = WorkspaceCapabilityActivation.activation(for: ref.id, in: workspace) else { continue }
            let declared: Set<String>?
            if case .validate(let verifier) = trust {
                declared = verifier.declaredComponentIDs[ref.id] ?? []
            } else {
                declared = nil
                // The workspace's own mirror keeps the activation's identity,
                // so its secret settings resolve again. A chosen file never
                // does: a copy imported next to its original would share them.
                if let id = ref.activationID.flatMap(UUID.init(uuidString:)),
                   !workspace.pluginActivations.contains(where: { $0.id == id }) {
                    activation.id = id
                }
            }
            func allowed(_ componentID: String) -> Bool { declared?.contains(componentID) ?? true }

            for (key, value) in (ref.settings ?? [:]).sorted(by: { $0.key < $1.key }) {
                guard let dot = key.lastIndex(of: "."), allowed(String(key[..<dot])) else { continue }
                WorkspaceCapabilityActivation.setConfigValue(value, forKey: key, on: activation)
            }
            let overridden = ref.overriddenComponentIDs ?? []
            let rows = ref.overridingRowIDs ?? []
            for (index, componentID) in overridden.enumerated() where allowed(componentID) {
                let fileRowID = index < rows.count ? rows[index] : ""
                // The workspace's own mirror may name a shared row it did not
                // export (an override for a plugin that is off): it is still
                // in this store under the same ID.
                let row = skillsByID[fileRowID]?.id ?? toolsByID[fileRowID]?.id
                    ?? (declared == nil ? UUID(uuidString: fileRowID) : nil)
                WorkspaceCapabilityActivation.setOverridden(true, componentID: componentID, rowID: row, on: activation)
            }
            for account in ref.accounts ?? [] where allowed(account.componentID) {
                guard let connector = connectorsByID[account.connectorID] else { continue }
                WorkspaceCapabilityActivation.bind(
                    connector,
                    toComponent: account.componentID,
                    of: activation,
                    isDefault: account.isDefault
                )
            }
        }
    }
}

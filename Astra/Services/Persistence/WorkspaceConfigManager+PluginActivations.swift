import Foundation
import SwiftData
import ASTRAModels

/// How `.astra-workspace.json` carries a workspace's plugin activations.
///
/// Besides the plugin ID and version, each entry keeps what the activation
/// owns for the workspace: its non-secret settings, the components the person
/// replaced with an authored row, which connector rows are the accounts of
/// each connector component, the components of the definition it was last
/// reconciled against, and which secret settings it stored. Launch recovery restores all of it; a file
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
            activationID: String? = nil,
            knownComponentIDs: [String]? = nil,
            secretSettingKeys: [String]? = nil,
            namespaceSeed: String? = nil,
            digest: String? = nil,
            templateDigests: [String]? = nil,
            awaitingUpdate: Bool? = nil
        ) {
            self.id = id
            self.activationID = activationID
            self.version = version
            self.name = name
            self.settings = settings
            self.overriddenComponentIDs = overriddenComponentIDs
            self.overridingRowIDs = overridingRowIDs
            self.accounts = accounts
            self.knownComponentIDs = knownComponentIDs
            self.secretSettingKeys = secretSettingKeys
            self.namespaceSeed = namespaceSeed
            self.digest = digest
            self.templateDigests = templateDigests
            self.awaitingUpdate = awaitingUpdate
        }

        public var id: String
        public var version: String
        public var name: String?
        /// Non-secret settings keyed `componentID#KEY`.
        public var settings: [String: String]?
        public var overriddenComponentIDs: [String]?
        public var overridingRowIDs: [String]?
        public var accounts: [PluginAccountRef]?
        /// The activation's own ID. Restored only from the workspace's own
        /// mirror.
        public var activationID: String?
        /// The components of the definition the activation was last
        /// reconciled against, so an Update after recovery still knows which
        /// ones it drops.
        public var knownComponentIDs: [String]?
        /// The secret settings (`componentID#KEY`) the activation stored in
        /// the Keychain. The values themselves are never in the file.
        public var secretSettingKeys: [String]?
        /// The activation's namespace seed; restored only from the
        /// workspace's own mirror.
        public var namespaceSeed: String?
        /// The approval digest of the definition the workspace accepted. A
        /// chosen file's activation stays off, with none of its details,
        /// unless this matches the installed copy (`CapabilityImportVerifier`).
        public var digest: String?
        /// The template rows' content digests (`componentID#digest`). Restored
        /// only from the workspace's own mirror, whose rows keep their stamps.
        public var templateDigests: [String]?
        /// Whether an automatic reconcile held the activation back from its
        /// library definition; restored only from the workspace's own mirror.
        public var awaitingUpdate: Bool?
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

    /// Shared rows an activation names as a component's override, so the
    /// mirror carries them even when nothing else enables them (an edited
    /// shared row kept while its plugin was off).
    static func overridingRows<Row: PersistentModel>(of workspace: Workspace, among rows: [Row]) -> [Row] where Row.ID == UUID {
        let ids = Set(WorkspaceCapabilityActivation.activations(of: workspace)
            .flatMap(\.overridingRowIDs)
            .compactMap(UUID.init(uuidString:)))
        guard !ids.isEmpty else { return [] }
        return rows.filter { ids.contains($0.id) }
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
                activationID: activation.id.uuidString,
                knownComponentIDs: activation.knownComponentIDs.isEmpty ? nil : activation.knownComponentIDs,
                secretSettingKeys: activation.secretSettingKeys.isEmpty ? nil : activation.secretSettingKeys,
                namespaceSeed: activation.namespaceSeed.isEmpty ? nil : activation.namespaceSeed,
                digest: activation.recordedDigest.isEmpty ? nil : activation.recordedDigest,
                templateDigests: activation.templateDigests.isEmpty ? nil : activation.templateDigests,
                awaitingUpdate: activation.awaitingUpdate ? true : nil
            )
        }
    }

    /// Restores each imported activation's settings, overrides and account
    /// bindings once `apply` has created the activations. Row IDs from the
    /// file resolve through the maps the import built, so a validated import
    /// (fresh row IDs) binds the rows it created, never an unrelated one.
    ///
    /// Returns the projected-skill IDs a validated import re-minted (file ID
    /// → new ID), for the templates and schedules the file names them in.
    /// `fileWorkspaceID` is the workspace the file's IDs were derived from,
    /// which a Duplicate does not keep.
    @MainActor
    @discardableResult
    static func restoreActivationDetails(
        from config: WorkspaceConfig,
        into workspace: Workspace,
        connectorsByID: [String: Connector],
        skillsByID: [String: Skill],
        toolsByID: [String: LocalTool],
        trust: CapabilityImportTrustPolicy,
        fileWorkspaceID: UUID? = nil
    ) -> [String: String] {
        var projectedIDs: [String: String] = [:]
        for ref in config.installedPlugins ?? [] {
            guard let activation = WorkspaceCapabilityActivation.activation(for: ref.id, in: workspace) else { continue }
            // A chosen file may keep the workspace's ID, so every activation
            // it brings, accepted or not, gets its own namespaces: one left
            // off and later added never reads the secrets of the workspace
            // the file replaced.
            if case .validate = trust {
                WorkspaceCapabilityActivation.setNamespaceSeed(UUID().uuidString, on: activation)
            }
            // A chosen file's activation for another copy of the plugin than
            // the one installed here (or for an unrecorded one) restores
            // nothing: `reconcile` already left it off.
            guard isAcceptedCopy(ref, trust: trust) else { continue }
            if let digest = ref.digest, !digest.isEmpty {
                WorkspaceCapabilityActivation.recordAccepted(
                    pluginID: ref.id, version: activation.recordedVersion, digest: digest, in: workspace
                )
            }
            let declared: Set<String>?
            if case .validate(let verifier) = trust {
                declared = verifier.declaredComponentIDs[ref.id] ?? []
                // The file's projected IDs (its workspace, its seed) name the
                // same components under the fresh seed.
                for componentID in declared ?? [] {
                    let old = PluginActivation.projectedID(
                        workspaceID: fileWorkspaceID ?? workspace.id, pluginID: ref.id,
                        componentID: componentID, seed: ref.namespaceSeed ?? ""
                    )
                    let new = PluginActivation.projectedID(
                        workspaceID: workspace.id, pluginID: ref.id, componentID: componentID, seed: activation.namespaceSeed
                    )
                    projectedIDs[old.uuidString] = new.uuidString
                }
            } else {
                if let seed = ref.namespaceSeed, !seed.isEmpty {
                    WorkspaceCapabilityActivation.setNamespaceSeed(seed, on: activation)
                }
                WorkspaceCapabilityActivation.setTemplateDigests(entries: ref.templateDigests ?? [], on: activation)
                WorkspaceCapabilityActivation.setAwaitingUpdate(ref.awaitingUpdate ?? false, on: activation)
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

            func allowedSetting(_ key: String) -> Bool {
                PluginActivation.componentID(ofSettingKey: key).map(allowed) ?? false
            }
            for (key, value) in (ref.settings ?? [:]).sorted(by: { $0.key < $1.key }) where allowedSetting(key) {
                WorkspaceCapabilityActivation.setConfigValue(value, forKey: key, on: activation)
            }
            // A chosen file's activation has fresh namespaces: no secret is
            // carried over, so none is recorded.
            for key in declared == nil ? ref.secretSettingKeys ?? [] : [] {
                WorkspaceCapabilityActivation.setSecretRecorded(true, forKey: key, on: activation)
            }
            // A chosen file's history is limited to what the installed
            // definition declares; a missing one is seeded at launch from the
            // library (`PluginActivationMigration`).
            let known = (ref.knownComponentIDs ?? []).filter(allowed)
            if !known.isEmpty {
                WorkspaceCapabilityActivation.setKnownComponents(activation.knownComponentIDs + known, on: activation)
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
                // A chosen file binds only a row it created, for the
                // component's own service.
                if case .validate(let verifier) = trust,
                   !verifier.acceptsAccount(connector, componentID: account.componentID, pluginID: ref.id) { continue }
                WorkspaceCapabilityActivation.bind(
                    connector,
                    toComponent: account.componentID,
                    of: activation,
                    isDefault: account.isDefault
                )
            }
        }
        return projectedIDs
    }
}

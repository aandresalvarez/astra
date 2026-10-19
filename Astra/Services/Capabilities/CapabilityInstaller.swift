import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

@MainActor
struct CapabilityInstaller {
    enum InstallationError: Error, Equatable, LocalizedError {
        case blocked([String])
        case persistenceFailed(packageID: String)
        case credentialSaveFailed(packageID: String, key: String)
        /// The value was refused before it reached the Keychain — retrying
        /// the same value cannot help, so this must not say "Try again".
        case credentialRejected(packageID: String, key: String, verdict: ConnectorCredentialAdmissionVerdict)
        /// The install failed *and* could not put back what it overwrote, so a
        /// credential the user had working is gone. Distinct from the two
        /// above because the remedy is different: nothing about this install
        /// can recover it, and they have to re-enter the value.
        case credentialRestoreFailed(packageID: String, keys: [String])
        /// An earlier Remove's secrets are still waiting to be cleared from
        /// the Keychain; a new activation would derive the same namespaces.
        case secretCleanupPending(packageID: String)

        var errorDescription: String? {
            switch self {
            case .blocked(let messages):
                return messages.joined(separator: "\n")
            case .persistenceFailed(let id):
                return "Enabling \(id) could not be saved. Try again."
            case .credentialSaveFailed(let id, let key):
                return "Enabling \(id) could not save the \(key) credential. Try again."
            case .credentialRejected(let id, let key, let verdict):
                let reason = verdict.message(forKey: key)
                    ?? "\(key) is not a valid credential for this connector."
                return "Enabling \(id) was stopped: \(reason)"
            case .secretCleanupPending(let id):
                return "\(id) can't be added yet: the secrets it had here before haven't been cleared from the Keychain. Try again."
            case .credentialRestoreFailed(let id, let keys):
                let names = keys.joined(separator: ", ")
                return """
                    Enabling \(id) failed, and the previous \(names) \
                    credential could not be put back. Re-enter it in Connectors.
                    """
            }
        }
    }

    struct InstallationResult: Equatable {
        var packageID: String
        var skillIDs: [UUID]
        var connectorIDs: [UUID]
        var localToolIDs: [UUID]
        var templateIDs: [UUID]
    }

    let library: CapabilityLibrary
    let appVersion: SemanticVersion
    /// Where skill secret settings are stored; nil reads the registered
    /// seam when used, so building an installer never needs it.
    private let skillSecretsOverride: (any SkillSecretPersisting.Type)?
    /// What the Keychain holds for an account's key; nil reads the
    /// account's own namespaces (`Connector.currentCredentialValue`).
    private let heldCredentialOverride: ((Connector, String) -> String?)?

    init(
        library: CapabilityLibrary = CapabilityLibrary(),
        appVersion: SemanticVersion = SemanticVersion(string: AppBuildInfo.current.version) ?? SemanticVersion(0, 0, 0),
        skillSecrets: (any SkillSecretPersisting.Type)? = nil,
        heldCredential: ((Connector, String) -> String?)? = nil
    ) {
        self.library = library
        self.appVersion = appVersion
        self.skillSecretsOverride = skillSecrets
        self.heldCredentialOverride = heldCredential
    }

    @discardableResult
    func install(
        _ package: PluginPackage,
        into workspace: Workspace,
        modelContext: ModelContext,
        credentialInputs: [String: String] = [:],
        configInputs: [String: String] = [:],
        baseURLOverrides: [String: String] = [:],
        allowCredentialUserInteraction: Bool = false,
        policyContext: CapabilityCatalogPolicyContext? = nil,
        traceID: String? = nil,
        announceCatalogMutation: Bool = true
    ) throws -> InstallationResult {
        let effectivePolicyContext = policyContext ?? defaultPolicyContext(for: workspace)
        let blockers = uniqueMessages(
            policyBlockerMessages(for: package, context: effectivePolicyContext)
                + installBlockerMessages(for: package, in: workspace, baseURLOverrides: baseURLOverrides)
        )
        guard blockers.isEmpty else {
            var fields = capabilityFields(for: package, workspace: workspace, source: "install")
            if let traceID { fields["trace_id"] = traceID }
            fields["result"] = "blocked"
            fields["blocker_count"] = String(blockers.count)
            AppLogger.audit(.capabilityEnableFailed, category: "Capabilities", fields: fields, level: .warning)
            throw InstallationError.blocked(blockers)
        }
        // A stored skill row the catalog lists as a package is not a
        // library entry: it is only turned on.
        if Self.syntheticSkillRowID(of: package) != nil {
            return try enable(
                package,
                in: workspace,
                modelContext: modelContext,
                policyContext: effectivePolicyContext,
                auditSource: "install",
                traceID: traceID
            )
        }
        // Snapshot the pre-install library state so a failed enable can be
        // compensated instead of leaving an orphaned or overwritten file.
        let packageStorageSnapshot = library.makePackageStorageSnapshot(for: package.id)
        do {
            try library.install(package)
        } catch {
            var fields = capabilityFields(for: package, workspace: workspace, source: "install")
            if let traceID { fields["trace_id"] = traceID }
            fields["result"] = "library_install_failed"
            fields["error_type"] = String(describing: type(of: error))
            AppLogger.audit(.capabilityEnableFailed, category: "Capabilities", fields: fields, level: .error)
            throw error
        }
        let result: InstallationResult
        do {
            result = try enable(
                package,
                in: workspace,
                modelContext: modelContext,
                credentialInputs: credentialInputs,
                configInputs: configInputs,
                baseURLOverrides: baseURLOverrides,
                allowCredentialUserInteraction: allowCredentialUserInteraction,
                policyContext: effectivePolicyContext,
                auditSource: "install",
                traceID: traceID
            )
        } catch {
            library.restorePackageStorage(packageStorageSnapshot)
            var fields = capabilityFields(for: package, workspace: workspace, source: "install")
            if let traceID { fields["trace_id"] = traceID }
            fields["result"] = "enable_failed_library_rolled_back"
            fields["restored_previous_file"] = packageStorageSnapshot.snapshotURL == nil ? "false" : "true"
            AppLogger.audit(.capabilityEnableFailed, category: "Capabilities", fields: fields, level: .error)
            throw error
        }
        library.discardPackageStorageSnapshot(packageStorageSnapshot)
        var installedFields = [
            "package_id": package.id,
            "package_name": package.name,
            "package_version": package.version,
            "workspace_id": workspace.id.uuidString
        ]
        installedFields.merge(CapabilityAudit.governanceFields(package.governance), uniquingKeysWith: { _, new in new })
        if let traceID { installedFields["trace_id"] = traceID }
        AppLogger.audit(.capabilityInstalled, category: "Capabilities", fields: installedFields)
        // Installing changes the process-wide package library, so every open
        // catalog must reload even when the workspace enable was initiated by
        // a lifecycle path that has no catalog view (for example onboarding).
        // Keep this at the complete mutation boundary so callers cannot omit
        // it and failed/rolled-back installs never publish a stale change.
        if announceCatalogMutation {
            CapabilityCatalogPersistenceEvents.post(.global)
        }
        return result
    }

    @discardableResult
    func enable(
        _ package: PluginPackage,
        in workspace: Workspace,
        modelContext: ModelContext,
        credentialInputs: [String: String] = [:],
        configInputs: [String: String] = [:],
        baseURLOverrides: [String: String] = [:],
        allowCredentialUserInteraction: Bool = false,
        policyContext: CapabilityCatalogPolicyContext? = nil,
        auditSource: String = "enable",
        traceID: String? = nil,
        persist: @MainActor (Workspace?, ModelContext) -> Bool = CapabilityPersistence.defaultPersist,
        exportMirror: (@MainActor (Workspace) -> Void)? = nil,
        rewriteMirror: (@MainActor (Workspace) -> Bool)? = nil
    ) throws -> InstallationResult {
        var startFields = capabilityFields(for: package, workspace: workspace, source: auditSource)
        if let traceID { startFields["trace_id"] = traceID }
        startFields["credential_input_count"] = String(credentialInputs.count)
        startFields["config_input_count"] = String(configInputs.count)
        startFields["base_url_override_count"] = String(baseURLOverrides.count)
        AppLogger.audit(.capabilityEnableStarted, category: "Capabilities", fields: startFields)

        let effectivePolicyContext = policyContext ?? defaultPolicyContext(for: workspace)
        let blockers = uniqueMessages(policyBlockerMessages(for: package, context: effectivePolicyContext))
        guard blockers.isEmpty else {
            var fields = capabilityFields(for: package, workspace: workspace, source: auditSource)
            if let traceID { fields["trace_id"] = traceID }
            fields["result"] = "enable_blocked"
            fields["blocker_count"] = String(blockers.count)
            AppLogger.audit(.capabilityEnableFailed, category: "Capabilities", fields: fields, level: .warning)
            throw InstallationError.blocked(blockers)
        }

        // A skill the catalog lists as its own package is a stored row: Add
        // turns that row on, keeping its ID and its Keychain secrets.
        if let skillID = Self.syntheticSkillRowID(of: package) {
            return try enableSkillRow(skillID, package: package, workspace: workspace, modelContext: modelContext, persist: persist)
        }

        // A new activation derives the namespaces a Remove may not have
        // finished clearing: settle them first, and wait while one is pending.
        if WorkspaceCapabilityActivation.activation(for: package.id, in: workspace) == nil,
           !PluginSecretCleanupOutbox.settleBeforeAdding(package, to: workspace, modelContext: modelContext) {
            throw InstallationError.secretCleanupPending(packageID: package.id)
        }
        let membershipSnapshot = WorkspaceCapabilityActivation.snapshot(workspace)
        // The library holds one definition for every workspace: each other
        // one whose activation kept rows while it was missing gets them as
        // overrides in the same save, so none projects a second copy.
        let pendingElsewhere = ((try? modelContext.fetch(FetchDescriptor<Workspace>())) ?? []).filter { other in
            other.id != workspace.id
                && WorkspaceCapabilityActivation.pendingOverridePluginIDs(of: other).contains(package.id)
                && WorkspaceCapabilityActivation.activation(for: package.id, in: other) != nil
        }
        let pendingSnapshots = pendingElsewhere.map { ($0, WorkspaceCapabilityActivation.snapshot($0)) }
        var savedSkillSecrets: [SavedSkillSecret] = []
        var renamedSecrets: [PluginUpdateService.CopiedSecret] = []
        var restoreReconciled: () -> Void = {}
        // Everything from here through persist() is one transaction: staging a
        // skill/connector/tool can throw (credential save denied, activation
        // swap failure, ...) partway through the loops below, after earlier
        // iterations already inserted records and mutated the workspace's
        // membership arrays. Without a shared catch, only a persist() failure
        // rolled back — any other mid-loop throw left those partial inserts
        // and membership mutations in place for a later unrelated save to
        // persist as orphaned, credential-less resources.
        do {
            var skillIDs: [UUID] = []
            var connectorIDs: [UUID] = []
            var localToolIDs: [UUID] = []
            var templateIDs: [UUID] = []

            // The activation owns everything this workspace keeps for the
            // plugin. Skills and tools are not stored: the runtime projects
            // them from the library entry and this record.
            WorkspaceCapabilityActivation.mutate(workspace) {
                $0.enableCapability(package.id)
                $0.recordInstalledPlugin(id: package.id, version: package.version)
            }
            guard let activation = WorkspaceCapabilityActivation.activation(for: package.id, in: workspace) else {
                throw InstallationError.persistenceFailed(packageID: package.id)
            }
            // Added back after a Remove: the same projected IDs (templates
            // and schedules name them) and the person's overrides again,
            // before reconciling derives anything from them, the rows the
            // migration kept while it was missing included.
            let componentIDs = PluginRuntimeProjection.componentIDs(of: package)
            // The accounts its components created here before a Remove come
            // back bound, stamped again, rather than as duplicates.
            let retainedAccounts = WorkspaceCapabilityActivation.retainedAccounts(of: package.id, in: workspace)
            WorkspaceCapabilityActivation.reinstateRetired(on: activation, declaring: componentIDs, in: workspace)
            for retained in retainedAccounts
            where componentIDs.contains(retained.componentID) && activation.accounts(forComponent: retained.componentID).isEmpty {
                CapabilityResourceOrigin.stamp(retained.account, package: package, componentID: retained.componentID)
                WorkspaceCapabilityActivation.bind(
                    retained.account, toComponent: retained.componentID, of: activation, isDefault: retained.isDefault
                )
            }
            for (other, _) in pendingSnapshots {
                guard let otherActivation = WorkspaceCapabilityActivation.activation(for: package.id, in: other) else { continue }
                WorkspaceCapabilityActivation.adoptPendingOverrides(on: otherActivation, declaring: componentIDs, in: other)
            }
            // Adding a version this workspace had at another one is an Update
            // for it: renamed components keep their state, dropped ones
            // release theirs, and the version and digest are recorded.
            // rollback() and the activation snapshot don't cover templates,
            // schedules and the synced account fields reconciling writes.
            restoreReconciled = PluginUpdateService.captureState(of: [workspace])
            let reconciliation = try PluginUpdateService.reconcile(
                activation,
                in: workspace,
                to: package,
                mode: .release,
                copied: &renamedSecrets
            )
            let releasedSkillIDs = reconciliation.released

            let skillConfigInputs = package.connectors.isEmpty ? configInputs : [:]
            // A skill setting an account carries as a plain setting, unless a
            // connector of this plugin stores that key as a credential.
            let movedSettings = Set(package.connectors.flatMap { PluginConnectorFieldTrust.settingsStoredAsCredentials(of: $0, in: package) })
            let packageEnvironmentKeys = package.skills.flatMap(\.environmentKeys).filter { !movedSettings.contains($0) }

            for pluginSkill in package.skills {
                let componentID = CapabilityResourceOrigin.componentID(for: pluginSkill)
                let projectedID = PluginRuntimeProjection.derivedID(of: activation, componentID: componentID)
                try saveSkillSettings(
                    pluginSkill,
                    componentID: componentID,
                    projectedID: projectedID,
                    activation: activation,
                    configInputs: skillConfigInputs,
                    packageID: package.id,
                    modelContext: modelContext,
                    savedSecrets: &savedSkillSecrets
                )
                appendUnique(projectedID, to: &skillIDs)
            }

            for pluginConnector in package.connectors {
                let componentID = CapabilityResourceOrigin.componentID(for: pluginConnector)
                // This component's own inputs over the shared ones: two
                // connectors with one name or field key never trade values.
                let ownConfigInputs = PluginSetupInputs.view(configInputs, component: componentID)
                let fields = StoredConnectorFields(
                    pluginConnector, in: package,
                    credentialInputs: PluginSetupInputs.view(credentialInputs, component: componentID),
                    configInputs: ownConfigInputs
                )
                let configKeys = connectorConfigKeys(
                    hints: fields.connector.configHints,
                    extraConfigKeys: packageEnvironmentKeys,
                    configInputs: ownConfigInputs
                )
                let overriddenBaseURL = PluginSetupInputs.baseURL(in: baseURLOverrides, for: pluginConnector)
                let baseURL = overriddenBaseURL ?? pluginConnector.baseURL
                let hasScopedInputs = connectorHasScopedInputs(
                    fields.connector,
                    configKeys: configKeys,
                    credentialInputs: fields.credentialInputs,
                    configInputs: ownConfigInputs,
                    baseURLOverridden: overriddenBaseURL != nil
                )
                let bound = activation.accounts(forComponent: componentID).first
                // The account replacing this component's default takes its
                // place as the workspace's default for the service.
                let inheritsDefault = activation.bindings.contains {
                    !$0.isDeleted && $0.componentID == componentID && $0.isDefault
                }
                // And its age, which elects the next default.
                let boundAge = activation.bindings.first {
                    !$0.isDeleted && $0.componentID == componentID && $0.account?.id == bound?.id
                }?.createdAt
                let account: Connector
                if let bound, !hasScopedInputs {
                    // Adding again keeps the account the workspace chose.
                    account = bound
                } else {
                    // A new account, or new settings for this workspace's own
                    // one, is owned by this workspace; a shared account the
                    // inputs would change is replaced here, not edited for
                    // every workspace that uses it.
                    account = try upsertWorkspaceConnector(
                        fields,
                        package: package,
                        workspace: workspace,
                        existing: bound.flatMap { $0.isGlobal ? nil : $0 },
                        modelContext: modelContext,
                        configInputs: ownConfigInputs,
                        extraConfigKeys: packageEnvironmentKeys,
                        baseURL: baseURL,
                        allowCredentialUserInteraction: allowCredentialUserInteraction
                    )
                    if let bound, bound.id != account.id, bound.isGlobal {
                        // Only this component moves to the new account; the
                        // shared one stays bound wherever else it serves.
                        WorkspaceCapabilityActivation.unbind(bound, from: activation, componentID: componentID)
                    }
                }
                WorkspaceCapabilityActivation.bind(account, toComponent: componentID, of: activation, isDefault: inheritsDefault, createdAt: boundAge)
                appendUnique(account.id, to: &connectorIDs)
            }

            for pluginTool in package.localTools {
                let componentID = CapabilityResourceOrigin.componentID(for: pluginTool)
                appendUnique(
                    PluginRuntimeProjection.derivedID(of: activation, componentID: componentID),
                    to: &localToolIDs
                )
            }

            for template in PluginTemplateSync.sync(package, in: workspace, modelContext: modelContext) {
                appendUnique(template.id, to: &templateIDs)
            }

            workspace.updatedAt = Date()
            // The secret settings written above settle with the save: the
            // activation records them now.
            let journaledSecrets = savedSkillSecrets.map { PluginUpdateService.StaleSecret(key: $0.key, skillID: $0.skillID) }
            // Every mirror the save changed is written before anything it
            // released is cleaned, as Update does: this workspace's, the
            // others whose pending rows became overrides, and each carrying
            // an account the reconcile changed. One that can't be written
            // keeps the cleanup for launch.
            let mirrored = [workspace] + pendingSnapshots.map(\.0) + WorkspaceConfigManager.workspacesMirroring(
                accountIDs: reconciliation.changedAccountIDs,
                among: (try? modelContext.fetch(FetchDescriptor<Workspace>())) ?? [], modelContext: modelContext
            )
            let rewrite = rewriteMirror ?? { WorkspaceConfigManager.exportMirrorNow(workspace: $0, modelContext: modelContext) }
            guard PluginSecretCleanupOutbox.deleteThenClean(
                releasedSkillIDs, keys: reconciliation.staleSecrets + journaledSecrets, modelContext: modelContext,
                save: { persist(workspace, modelContext) },
                beforeSettling: {
                    var seen = Set<UUID>()
                    return mirrored.filter { seen.insert($0.id).inserted }.reduce(true) { rewrite($1) && $0 }
                }
            ) else {
                throw InstallationError.persistenceFailed(packageID: package.id)
            }
            // `persist` exports the clicked workspace; the others whose
            // pending rows became overrides in the same save are exported
            // here, or their mirrors would restore the rows as before.
            for (other, _) in pendingSnapshots {
                if let exportMirror {
                    exportMirror(other)
                } else if !WorkspacePersistenceCoordinator.shouldSkipAutoExport() {
                    WorkspaceConfigManager.autoExport(workspace: other, modelContext: modelContext)
                }
            }
            var enabledFields = [
                "package_id": package.id,
                "package_name": package.name,
                "package_version": package.version,
                "workspace_id": workspace.id.uuidString,
                "skills_count": String(skillIDs.count),
                "connectors_count": String(connectorIDs.count),
                "tools_count": String(localToolIDs.count),
                "templates_count": String(templateIDs.count),
                "enabled_capability_ids": CapabilityAudit.compactNames(workspace.enabledCapabilityIDs)
            ]
            enabledFields.merge(CapabilityAudit.governanceFields(package.governance), uniquingKeysWith: { _, new in new })
            if let traceID { enabledFields["trace_id"] = traceID }
            AppLogger.audit(.capabilityEnabled, category: "Capabilities", fields: enabledFields)

            return InstallationResult(
                packageID: package.id,
                skillIDs: skillIDs,
                connectorIDs: connectorIDs,
                localToolIDs: localToolIDs,
                templateIDs: templateIDs
            )
        } catch {
            // Reporting success (or even a clean failure) while leaving a
            // partial stage in place would strand the library file and any
            // saved keychain credentials against unsaved/orphaned records.
            // rollback() drops the inserted resources; restore() undoes the
            // membership-array mutations it does not revert.
            modelContext.rollback()
            restoreReconciled()
            WorkspaceCapabilityActivation.restore(membershipSnapshot, to: workspace)
            for (other, snapshot) in pendingSnapshots { WorkspaceCapabilityActivation.restore(snapshot, to: other) }
            let unrestored = restoreSkillSecrets(savedSkillSecrets)
                + PluginUpdateService.undo(renamedSecrets)
            PluginSecretSettingWriter.forgetJournaled(
                savedSkillSecrets.map { PluginUpdateService.StaleSecret(key: $0.key, skillID: $0.skillID) }, modelContext: modelContext
            )
            var fields = capabilityFields(for: package, workspace: workspace, source: auditSource)
            if let traceID { fields["trace_id"] = traceID }
            fields["result"] = "enable_failed_rolled_back"
            fields["error_type"] = String(describing: type(of: error))
            if !unrestored.isEmpty { fields["unrestored_secret_count"] = String(unrestored.count) }
            AppLogger.audit(.capabilityEnableFailed, category: "Capabilities", fields: fields, level: .error)
            // A secret setting the rollback could not put back is reported
            // ahead of the failure that caused it, as a connector credential's
            // is (`saveConnectorCredentials`): the activation is restored, the
            // Keychain is not.
            if !unrestored.isEmpty {
                var keys = Set(unrestored)
                if case .credentialRestoreFailed(_, let others)? = error as? InstallationError { keys.formUnion(others) }
                throw InstallationError.credentialRestoreFailed(packageID: package.id, keys: keys.sorted())
            }
            throw error
        }
    }

    /// Compensation for a failed enable after the library file was written:
    /// restore the pre-install bytes, or remove the file if this was a fresh
    /// install, so the catalog never shows an installed-but-never-enabled
    /// package.
    static func restoreLibraryFile(previousData: Data?, fileExistedBefore: Bool, at url: URL) {
        if let previousData {
            try? previousData.write(to: url, options: [.atomic])
        } else if !fileExistedBefore {
            // Only a genuinely fresh install removes the file. A nil snapshot
            // of a file that DID exist means the pre-install read failed —
            // deleting then would destroy the user's previous package.
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func capabilityFields(
        for package: PluginPackage,
        workspace: Workspace,
        source: String
    ) -> [String: String] {
        CapabilityAudit.packageFields(
            packageID: package.id,
            packageName: package.name,
            packageVersion: package.version,
            workspace: workspace,
            source: source,
            skillsCount: package.skills.count,
            connectorsCount: package.connectors.count,
            toolsCount: package.localTools.count,
            templatesCount: package.templates.count,
            governance: package.governance
        )
    }

    /// A secret skill setting written to the Keychain by this enable, with
    /// the value it replaced, so a failed enable can put it back.
    /// The stored skill row a catalog-synthesized `skill.<uuid>` package
    /// stands for (`CapabilityCatalogInventory`), nil for a real plugin.
    static func syntheticSkillRowID(of package: PluginPackage) -> UUID? {
        let kind = package.sourceMetadata?.kind
        guard package.id.hasPrefix("skill."), kind == "workspace" || kind == "shared" else { return nil }
        return UUID(uuidString: String(package.id.dropFirst("skill.".count)))
    }

    /// Turns on the stored skill row a synthetic package names: a shared row
    /// and its shared connectors and tools join the workspace; a workspace
    /// row is already on. No activation is created, so nothing projects a
    /// second copy under another ID.
    private func enableSkillRow(
        _ skillID: UUID,
        package: PluginPackage,
        workspace: Workspace,
        modelContext: ModelContext,
        persist: @MainActor (Workspace?, ModelContext) -> Bool
    ) throws -> InstallationResult {
        var descriptor = FetchDescriptor<Skill>(predicate: #Predicate { $0.id == skillID })
        descriptor.fetchLimit = 1
        guard let skill = try? modelContext.fetch(descriptor).first, !skill.isDeleted else {
            throw InstallationError.persistenceFailed(packageID: package.id)
        }
        let snapshot = WorkspaceCapabilityActivation.snapshot(workspace)
        if skill.isGlobal {
            WorkspaceCapabilityActivation.mutate(workspace) { state in
                state.enableGlobalSkill(skill.id.uuidString)
                for connector in skill.connectors where connector.isGlobal {
                    state.enableGlobalConnector(connector.id.uuidString)
                }
                for tool in skill.localTools where tool.isGlobal {
                    state.enableGlobalTool(tool.id.uuidString)
                }
            }
            workspace.updatedAt = Date()
        }
        guard persist(workspace, modelContext) else {
            modelContext.rollback()
            WorkspaceCapabilityActivation.restore(snapshot, to: workspace)
            throw InstallationError.persistenceFailed(packageID: package.id)
        }
        AppLogger.audit(.capabilityEnabled, category: "Capabilities", fields: [
            "package_id": package.id,
            "workspace_id": workspace.id.uuidString,
            "result": "skill_row_enabled"
        ])
        return InstallationResult(
            packageID: package.id,
            skillIDs: [skill.id],
            connectorIDs: skill.connectors.map(\.id),
            localToolIDs: skill.localTools.map(\.id),
            templateIDs: []
        )
    }

    private struct SavedSkillSecret {
        let key: String
        let skillID: UUID
        let previousValue: String?
    }

    /// Stores a skill's configured settings on the activation: non-secret
    /// values under `componentID.KEY`, secret ones in the Keychain under the
    /// projected skill's ID.
    private func saveSkillSettings(
        _ pluginSkill: PluginSkill,
        componentID: String,
        projectedID: UUID,
        activation: PluginActivation,
        configInputs: [String: String],
        packageID: String,
        modelContext: ModelContext,
        savedSecrets: inout [SavedSkillSecret]
    ) throws {
        for key in pluginSkill.environmentKeys {
            guard let value = configInputs[key] else { continue }
            let settingKey = PluginActivation.settingKey(componentID: componentID, key: key)
            guard Skill.isSecretEnvironmentKey(key) else {
                // A blank field at Add keeps the plugin's default.
                WorkspaceCapabilityActivation.setConfigValue(value.isEmpty ? nil : value, forKey: settingKey, on: activation)
                continue
            }
            guard !value.isEmpty else { continue }
            let persistence = skillSecrets
            let previous = persistence.loadSecretValue(key: key, skillID: projectedID, store: KeychainSecretStore())
            // Journaled before the write, settled with the Add's save: a quit
            // between them leaves a value launch cleans, never one unrecorded.
            let written = try PluginSecretSettingWriter.writeJournaled(
                value, key: key, skillName: pluginSkill.name, skillID: projectedID,
                modelContext: modelContext, persistence: persistence
            )
            guard written else {
                throw InstallationError.credentialSaveFailed(packageID: packageID, key: key)
            }
            savedSecrets.append(SavedSkillSecret(key: key, skillID: projectedID, previousValue: previous))
            WorkspaceCapabilityActivation.setSecretRecorded(true, forKey: settingKey, on: activation)
        }
    }

    private var skillSecrets: any SkillSecretPersisting.Type {
        skillSecretsOverride ?? SkillSecretSeam.required
    }

    /// Puts back what a failed enable overwrote, returning the keys whose
    /// previous state (a value, or no value) it could not restore.
    private func restoreSkillSecrets(_ saved: [SavedSkillSecret]) -> [String] {
        let persistence = skillSecrets
        var unrestored: [String] = []
        for secret in saved.reversed() {
            let restored: Bool
            if let previous = secret.previousValue {
                restored = persistence.saveSecretValue(
                    previous,
                    key: secret.key,
                    skillID: secret.skillID,
                    skillName: "",
                    allowUserInteraction: false
                )
            } else {
                restored = persistence.deleteSecret(key: secret.key, skillID: secret.skillID)
            }
            if !restored { unrestored.append(secret.key) }
        }
        return unrestored
    }

    /// A connector component's fields as its account stores them
    /// (`PluginConnectorFieldTrust.asStored`), with the credential inputs
    /// that fill them: a setting stored as a credential takes its value from
    /// either input, whichever the caller filled.
    struct StoredConnectorFields {
        let connector: PluginConnector
        let movedSettings: Set<String>
        let credentialInputs: [String: String]

        init(_ declared: PluginConnector, in package: PluginPackage, credentialInputs: [String: String], configInputs: [String: String]) {
            connector = PluginConnectorFieldTrust.asStored(declared, in: package)
            movedSettings = PluginConnectorFieldTrust.settingsStoredAsCredentials(of: declared, in: package)
            var inputs = credentialInputs
            for key in movedSettings where (inputs[key] ?? "").isEmpty {
                if let value = configInputs[key], !value.isEmpty { inputs[key] = value }
            }
            self.credentialInputs = inputs
        }
    }

    private func upsertWorkspaceConnector(
        _ fields: StoredConnectorFields,
        package: PluginPackage,
        workspace: Workspace,
        existing: Connector?,
        modelContext: ModelContext,
        configInputs: [String: String],
        extraConfigKeys: [String],
        baseURL: String,
        allowCredentialUserInteraction: Bool
    ) throws -> Connector {
        let pluginConnector = fields.connector
        let connector = existing ?? existingWorkspaceConnector(
            for: pluginConnector,
            package: package,
            workspace: workspace
        ) ?? Connector(
            name: pluginConnector.name,
            serviceType: pluginConnector.serviceType,
            icon: pluginConnector.icon,
            connectorDescription: pluginConnector.description,
            baseURL: baseURL,
            authMethod: pluginConnector.authMethod
        )
        if connector.modelContext == nil {
            modelContext.insert(connector)
        }
        // A row from before its plugin's settings were credentials can hold
        // one as plain text: it moves to the Keychain with this save. One
        // the Keychain already holds a different value for is not: the
        // Keychain's is kept, and the row's stays on it as a setting for the
        // person to settle, as `Connector.moveSettingsToKeychain` leaves it.
        var credentialInputs = fields.credentialInputs
        var unsettled: [(key: String, value: String)] = []
        for key in fields.movedSettings where (credentialInputs[key] ?? "").isEmpty && !connector.configValue(key).isEmpty {
            let plain = connector.configValue(key)
            let held = heldCredentialOverride.map { $0(connector, key) } ?? connector.currentCredentialValue(forKey: key)
            if let held, !held.isEmpty, held != plain {
                unsettled.append((key, plain))
            } else {
                credentialInputs[key] = plain
            }
        }
        connector.name = pluginConnector.name
        connector.serviceType = pluginConnector.serviceType
        connector.icon = pluginConnector.icon
        connector.connectorDescription = pluginConnector.description
        connector.baseURL = baseURL
        connector.authMethod = pluginConnector.authMethod
        connector.notes = pluginConnector.notes
        connector.credentialKeys = pluginConnector.credentialHints.map(\.key)
        connector.credentialValues = Array(repeating: "", count: connector.credentialKeys.count)
        connector.configKeys = connectorConfigKeys(
            hints: pluginConnector.configHints,
            extraConfigKeys: extraConfigKeys,
            configInputs: configInputs
        )
        connector.configValues = connector.configKeys.map { configInputs[$0] ?? "" }
        for (key, value) in unsettled {
            if let index = connector.credentialKeys.firstIndex(where: { ConnectorCredentialKey.same($0, key) }) {
                connector.credentialKeys.remove(at: index)
                connector.credentialValues.remove(at: index)
            }
            if !connector.configKeys.contains(key) {
                connector.configKeys.append(key)
                connector.configValues.append(value)
            }
        }
        connector.isGlobal = false
        connector.workspace = workspace
        connector.skill = nil
        CapabilityResourceOrigin.stamp(
            connector,
            package: package,
            componentID: CapabilityResourceOrigin.componentID(for: pluginConnector)
        )
        connector.updatedAt = Date()
        if connector.isStanfordOutlookMail {
            connector.applyStanfordOutlookDefaults()
        }
        try saveConnectorCredentials(
            connector,
            hints: pluginConnector.credentialHints,
            credentialInputs: credentialInputs,
            allowCredentialUserInteraction: allowCredentialUserInteraction,
            packageID: package.id
        )
        return connector
    }

    /// Saves each hinted credential in order, and on a mid-batch failure
    /// undoes only what this call itself changed: `enable()`'s catch only
    /// calls `modelContext.rollback()`, which reverts the connector's
    /// `credentialKeys` array but never touches Keychain, so without this,
    /// an earlier hint's successful Keychain write survives a later hint's
    /// failure. A hint that had no saved value before this call gets its
    /// Keychain entry deleted (it would otherwise be orphaned under a
    /// connector the user can no longer see or manage). A hint that
    /// already had a value — e.g. re-enabling an existing connector — gets
    /// that prior value restored instead of deleted, since rollback leaves
    /// the connector's `credentialKeys` still listing it as configured;
    /// deleting it there would silently break an unrelated, previously
    /// working credential. A restore that cannot land is reported rather than
    /// swallowed: see `InstallationError.credentialRestoreFailed`.
    ///
    /// Looks up each hint's prior value with `currentCredentialValue(forKey:)`
    /// right before overwriting it, rather than snapshotting `connector
    /// .credentials` once up front: the caller resets `credentialKeys` to
    /// the package's declared hint spelling just before this runs, which
    /// isn't necessarily uppercase, while every saved credential is stored
    /// under its uppercased key — a bulk snapshot keyed off that
    /// just-reset array would silently miss existing secrets for
    /// non-uppercase hint keys.
    private func saveConnectorCredentials(
        _ connector: Connector,
        hints: [PluginConnector.CredentialHint],
        credentialInputs: [String: String],
        allowCredentialUserInteraction: Bool,
        packageID: String
    ) throws {
        var savedThisCall: [(key: String, previousValue: String?)] = []
        for hint in hints {
            guard let value = credentialInputs[hint.key], !value.isEmpty else { continue }
            let previousValue = connector.currentCredentialValue(forKey: hint.key)
            let outcome = connector.saveCredentialChecked(
                key: hint.key,
                value: value,
                allowUserInteraction: allowCredentialUserInteraction,
                declaredFormat: hint.format
            )
            guard outcome.isSaved else {
                // The compensating rollback runs for a rejection too: an
                // earlier hint in this batch may already have overwritten a
                // working credential.
                //
                // Restoration deliberately does not go back through admission.
                // It used to, and that made the rollback able to fail for the
                // same reason the install did — a package that tightened a
                // format since the value was stored, or a reuse scan that now
                // sees it on a sibling connector — leaving this call reporting
                // a failed install while the connector kept the failed
                // install's credential and the user's working one was gone. A
                // value already in the Keychain has been admitted once; the
                // question at rollback is only whether the write lands.
                var unrestored: [String] = []
                for saved in savedThisCall {
                    if let previousValue = saved.previousValue {
                        let restored = connector.restorePreviouslyStoredCredential(
                            key: saved.key,
                            value: previousValue,
                            allowUserInteraction: allowCredentialUserInteraction
                        )
                        if !restored { unrestored.append(saved.key) }
                    } else {
                        connector.removeCredential(forKey: saved.key)
                    }
                }
                // Reported ahead of the failure that caused it. Both are true,
                // but only one of them says a credential that was working
                // before this install is not there any more, and no amount of
                // retrying the install will bring it back.
                if !unrestored.isEmpty {
                    throw InstallationError.credentialRestoreFailed(
                        packageID: packageID, keys: unrestored.sorted())
                }
                if let verdict = outcome.rejection {
                    throw InstallationError.credentialRejected(
                        packageID: packageID, key: hint.key, verdict: verdict)
                }
                throw InstallationError.credentialSaveFailed(packageID: packageID, key: hint.key)
            }
            savedThisCall.append((key: hint.key, previousValue: previousValue))
        }
    }

    private func connectorConfigKeys(
        hints: [PluginConnector.ConfigHint],
        extraConfigKeys: [String],
        configInputs: [String: String]
    ) -> [String] {
        var keys = hints.map(\.key)
        for key in extraConfigKeys where configInputs[key] != nil && !keys.contains(key) {
            keys.append(key)
        }
        return keys
    }

    private func connectorHasScopedInputs(
        _ pluginConnector: PluginConnector,
        configKeys: [String],
        credentialInputs: [String: String],
        configInputs: [String: String],
        baseURLOverridden: Bool
    ) -> Bool {
        if baseURLOverridden {
            return true
        }
        if pluginConnector.credentialHints.contains(where: { hint in
            !(credentialInputs[hint.key] ?? "").isEmpty
        }) {
            return true
        }
        return configKeys.contains { key in
            !(configInputs[key] ?? "").isEmpty
        }
    }

    /// A workspace row this plugin's component created itself: one stamped
    /// by this plugin and stamped with or bound to this component (or one it
    /// `replaces`). A row the person authored is never taken over just
    /// because its name and service match: Add would overwrite its URL, keys
    /// and skill attachment, and a Remove could not put them back. A row of
    /// another component (two same-named connectors with distinct IDs) is
    /// that component's account, and Add makes this one its own. The
    /// activation's own binding comes in as `existing`.
    private func existingWorkspaceConnector(
        for pluginConnector: PluginConnector,
        package: PluginPackage,
        workspace: Workspace
    ) -> Connector? {
        let identities = Set([CapabilityResourceOrigin.componentID(for: pluginConnector)]
            + CapabilityResourceOrigin.replacedComponentIDs(for: pluginConnector))
        return workspace.connectors.first { candidate in
            guard candidate.name == pluginConnector.name,
                  candidate.serviceType == pluginConnector.serviceType,
                  CapabilityResourceOrigin.isOwnedBy(candidate, packageID: package.id)
            else { return false }
            let stamp = candidate.originComponentID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let served = Set(candidate.accountBindings.filter { !$0.isDeleted }.map(\.componentID) + (stamp.isEmpty ? [] : [stamp]))
            return !served.isDisjoint(with: identities)
        }
    }

    private func appendUnique(_ value: UUID, to values: inout [UUID]) {
        guard !values.contains(value) else { return }
        values.append(value)
    }

    private func installBlockerMessages(
        for package: PluginPackage,
        in workspace: Workspace,
        baseURLOverrides: [String: String]
    ) -> [String] {
        let dependencyMessages = package.installBlockers(
            appVersion: appVersion,
            installedPluginIDs: workspace.installedPluginIDSet.union(Set(workspace.enabledCapabilityIDs))
        ).map { blocker in
            switch blocker {
            case .appTooOld(let required, let current):
                return "\(package.name) requires ASTRA \(required) or newer. Current version is \(current)."
            case .missingDependency(let dependency):
                return "\(package.name) requires \(dependency) to be installed first."
            case .conflictsWith(let conflict):
                return "\(package.name) conflicts with \(conflict)."
            }
        }
        return dependencyMessages
            + unsafeLocalToolMessages(for: package)
            + unsafeConnectorMessages(for: package, baseURLOverrides: baseURLOverrides)
            + unsafeMCPServerMessages(for: package)
    }

    private func policyBlockerMessages(
        for package: PluginPackage,
        context: CapabilityCatalogPolicyContext
    ) -> [String] {
        let decision = CapabilityCatalogPolicy.decision(for: package, context: context)
        guard !decision.canEnable else { return [] }
        return decision.blockerMessages
    }

    private func defaultPolicyContext(for workspace: Workspace) -> CapabilityCatalogPolicyContext {
        CapabilityCatalogPolicyContext.workspaceUser(
            workspace: workspace,
            currentAppVersion: appVersion,
            approvalRecords: CapabilityApprovalStore().records()
        )
    }

    private func unsafeLocalToolMessages(for package: PluginPackage) -> [String] {
        package.localTools.compactMap { tool in
            let command = tool.command.trimmingCharacters(in: .whitespacesAndNewlines)
            if let reason = LocalToolSecurityPolicy.unsafeInvocationReason(command: command, arguments: tool.arguments) {
                return "\(package.name) defines local tool \(tool.name) with an unsafe command or default arguments: \(reason). Put flags or shell syntax in reviewed documentation, not in package defaults."
            }
            return nil
        }
    }

    private func unsafeConnectorMessages(
        for package: PluginPackage,
        baseURLOverrides: [String: String]
    ) -> [String] {
        package.connectors.compactMap { connector in
            let baseURL = PluginSetupInputs.baseURL(in: baseURLOverrides, for: connector) ?? connector.baseURL
            guard let violation = PluginConnectorFieldTrust.credentialTransportViolation(
                of: connector, in: package, baseURL: baseURL
            ) else {
                return nil
            }
            return "\(package.name) defines connector \(connector.name) with an unsafe credential transport. \(violation)"
        }
    }

    private func unsafeMCPServerMessages(for package: PluginPackage) -> [String] {
        package.mcpServers.compactMap { server in
            switch server.transport {
            case .stdio:
                let command = (server.command ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if let reason = LocalToolSecurityPolicy.unsafeInvocationReason(
                    command: command,
                    arguments: server.arguments.joined(separator: " ")
                ) {
                    return "\(package.name) defines MCP server \(server.displayName) with an unsafe command or default arguments: \(reason)."
                }
            case .http, .sse:
                guard let url = server.url,
                      let scheme = url.scheme?.lowercased() else {
                    return "\(package.name) defines MCP server \(server.displayName) with a missing or invalid remote URL."
                }
                if scheme == "https" || (scheme == "http" && isLoopbackHost(url.host)) {
                    return nil
                }
                return "\(package.name) defines MCP server \(server.displayName) with an unsafe remote URL. Remote MCP URLs must use HTTPS, except loopback HTTP for local development."
            }
            return nil
        }
    }

    private func isLoopbackHost(_ host: String?) -> Bool {
        guard let host = host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !host.isEmpty else {
            return false
        }
        return host == "localhost"
            || host.hasSuffix(".localhost")
            || host == "127.0.0.1"
            || host == "::1"
    }

    private func uniqueMessages(_ messages: [String]) -> [String] {
        var seen = Set<String>()
        return messages.filter { seen.insert($0).inserted }
    }
}

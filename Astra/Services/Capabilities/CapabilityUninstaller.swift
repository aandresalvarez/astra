import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

@MainActor
struct CapabilityUninstaller {
    enum UninstallError: Error, Equatable, LocalizedError {
        case saveFailed(packageID: String)

        var errorDescription: String? {
            switch self {
            case .saveFailed(let id):
                return "Removing \(id) could not be saved. No resources were deleted; try again."
            }
        }
    }

    struct RemovalResult: Equatable {
        var packageID: String
        var disabledWorkspaceIDs: [UUID] = []
        var removedSkillIDs: [UUID] = []
        var removedConnectorIDs: [UUID] = []
        var removedToolIDs: [UUID] = []
        var removedTemplateIDs: [UUID] = []
    }

    let library: CapabilityLibrary

    init(library: CapabilityLibrary = CapabilityLibrary()) {
        self.library = library
    }

    @discardableResult
    func remove(
        _ requestedPackage: PluginPackage,
        modelContext: ModelContext,
        persist: @MainActor (Workspace?, ModelContext) -> Bool = CapabilityPersistence.defaultPersist,
        connectorCleanupStore: ConnectorCredentialCleanupStore? = nil
    ) throws -> RemovalResult {
        let installedPackages = library.installedPackages()
        guard var package = installedPackages.first(where: { $0.id == requestedPackage.id }) else {
            throw CapabilityLibrary.RemovalError.notInstalled(requestedPackage.id)
        }
        if package.sourceMetadata == nil {
            package.sourceMetadata = .localLibrary()
        }
        if package.sourceMetadata?.kind == "built-in" {
            throw CapabilityLibrary.RemovalError.builtInPackage(package.name)
        }

        let remainingPackages = installedPackages.filter { $0.id != package.id }
        // A fetch failure must abort the uninstall rather than degrade to
        // "nothing matched": proceeding with empty arrays would remove the
        // package file while leaving its resources behind in every workspace.
        let workspaces = try modelContext.fetch(FetchDescriptor<Workspace>())
        let globalSkills = try modelContext.fetch(FetchDescriptor<Skill>(
            predicate: #Predicate { $0.isGlobal == true }
        ))
        let globalConnectors = try modelContext.fetch(FetchDescriptor<Connector>(
            predicate: #Predicate { $0.isGlobal == true }
        ))
        let globalTools = try modelContext.fetch(FetchDescriptor<LocalTool>(
            predicate: #Predicate { $0.isGlobal == true }
        ))
        let packageID = package.id
        let stampedAccounts = try modelContext.fetch(FetchDescriptor<Connector>(
            predicate: #Predicate { $0.originPackageID == packageID }
        ))

        let packageTemplateNames = Set(package.templates.map(\.name))

        let matchedGlobalSkills = ownedOrLegacyMatches(
            globalSkills,
            packageID: package.id,
            hasOrigin: CapabilityResourceOrigin.hasOrigin,
            isOwned: CapabilityResourceOrigin.isOwnedBy(_:packageID:),
            // Plugin skills, tools and connectors are no longer rows: only a
            // leftover stamped row is the plugin's. A same-named row without a
            // stamp is the person's (an authored skill, or an edited plugin
            // skill the migration kept), never the plugin's to delete.
            legacyMatches: { _ in false }
        )
        let matchedGlobalConnectors = ownedOrLegacyMatches(
            globalConnectors,
            packageID: package.id,
            hasOrigin: CapabilityResourceOrigin.hasOrigin,
            isOwned: CapabilityResourceOrigin.isOwnedBy(_:packageID:),
            legacyMatches: { _ in false }
        )
        let matchedGlobalTools = ownedOrLegacyMatches(
            globalTools,
            packageID: package.id,
            hasOrigin: CapabilityResourceOrigin.hasOrigin,
            isOwned: CapabilityResourceOrigin.isOwnedBy(_:packageID:),
            legacyMatches: { _ in false }
        )

        var result = RemovalResult(packageID: package.id)
        // Membership arrays are mutated per workspace below; rollback does not
        // revert them, so snapshot for the save-failure path.
        let membershipSnapshots = workspaces.map { ($0, WorkspaceCapabilityActivation.snapshot($0)) }
        // Wiped only after the SwiftData deletes are saved — see below.
        var pendingKeychainCleanups: [() -> Void] = []
        // Remove never deletes a connector, so no connector namespace is
        // released here.
        let pendingConnectorCleanups: [ConnectorKeychainCleanup] = []
        var activationSecretSkillIDs: [UUID] = []

        for workspace in workspaces {
            let remainingWorkspacePackages = remainingPackages.filter {
                workspace.enabledCapabilityIDs.contains($0.id) ||
                workspace.installedPluginIDSet.contains($0.id)
            }
            let removableGlobalSkillIDs = Set(matchedGlobalSkills
                .filter { skill in !remainingWorkspacePackages.contains(where: { claims(skill, package: $0) }) }
                .map { $0.id.uuidString })
            let removableGlobalConnectorIDs = Set(matchedGlobalConnectors
                .filter { connector in !remainingWorkspacePackages.contains(where: { claims(connector, package: $0) }) }
                .map { $0.id.uuidString })
            let removableGlobalToolIDs = Set(matchedGlobalTools
                .filter { tool in !remainingWorkspacePackages.contains(where: { claims(tool, package: $0) }) }
                .map { $0.id.uuidString })

            let wasPackageEnabled = workspace.enabledCapabilityIDs.contains(package.id)
            let wasPackageRecorded = workspace.installedPluginIDSet.contains(package.id)
            let hadPackageGlobals =
                workspace.enabledGlobalSkillIDs.contains { removableGlobalSkillIDs.contains($0) } ||
                workspace.enabledGlobalConnectorIDs.contains { removableGlobalConnectorIDs.contains($0) } ||
                workspace.enabledGlobalToolIDs.contains { removableGlobalToolIDs.contains($0) }

            // The activation's secret settings live under its projected
            // skills' IDs, which nothing names once the activation is gone:
            // they are recorded before the save and cleaned after it, every
            // component it ever knew included.
            if let activation = WorkspaceCapabilityActivation.activation(for: package.id, in: workspace) {
                activationSecretSkillIDs += PluginRuntimeProjection.secretNamespaces(of: activation, package: package)
            }
            WorkspaceCapabilityActivation.mutate(workspace) {
                $0.capabilityIDs.removeAll { $0 == package.id }
                $0.globalSkillIDs.removeAll { removableGlobalSkillIDs.contains($0) }
                $0.globalConnectorIDs.removeAll { removableGlobalConnectorIDs.contains($0) }
                $0.globalToolIDs.removeAll { removableGlobalToolIDs.contains($0) }
                $0.removeInstalledPlugin(id: package.id)
            }

            // Connectors are accounts: removing a plugin deletes its
            // activations (and with them the bindings), never the accounts or
            // their credentials. Deleting an account is its own action.

            let workspaceTemplates = ownedOrLegacyMatches(
                workspace.templates,
                packageID: package.id,
                hasOrigin: CapabilityResourceOrigin.hasOrigin,
                isOwned: CapabilityResourceOrigin.isOwnedBy(_:packageID:),
                legacyMatches: { packageTemplateNames.contains($0.name) }
            )
            .filter { template in
                !remainingWorkspacePackages.contains(where: { claims(template, package: $0) })
            }
            for template in workspaceTemplates {
                result.removedTemplateIDs.append(template.id)
                modelContext.delete(template)
            }

            if wasPackageEnabled || wasPackageRecorded || hadPackageGlobals || !workspaceTemplates.isEmpty {
                workspace.updatedAt = Date()
                result.disabledWorkspaceIDs.append(workspace.id)
            }
        }

        // The accounts stay with their credentials, but no longer as this
        // plugin's: a later install of the same file has no activation yet,
        // and a stamped account would make the plugin look on.
        for account in stampedAccounts {
            releaseProvenance(of: account, packageID: package.id)
        }

        for tool in matchedGlobalTools where !remainingPackages.contains(where: { claims(tool, package: $0) }) {
            result.removedToolIDs.append(tool.id)
            modelContext.delete(tool)
        }

        for skill in matchedGlobalSkills where !remainingPackages.contains(where: { claims(skill, package: $0) }) {
            pendingKeychainCleanups.append { skill.cleanupKeychain() }
            result.removedSkillIDs.append(skill.id)
            modelContext.delete(skill)
        }

        // The connectors' cleanups are recorded before the save and run, read
        // after it, so a connector sharing a namespace with one removed here
        // keeps its credentials; any that don't clear are retried at launch.
        guard ConnectorCredentialCleanup.deleteThenClean(
            pendingConnectorCleanups, modelContext: modelContext, store: connectorCleanupStore,
            save: {
                PluginSecretCleanupOutbox.deleteThenClean(activationSecretSkillIDs, modelContext: modelContext) {
                    persist(nil, modelContext)
                }
            }
        ) else {
            // Abort before touching the keychain or the library file: the
            // deletes were not persisted, so removing either would strand
            // resources (file gone) or credentials (records still present).
            modelContext.rollback()
            membershipSnapshots.forEach { WorkspaceCapabilityActivation.restore($1, to: $0) }
            throw UninstallError.saveFailed(packageID: package.id)
        }
        pendingKeychainCleanups.forEach { $0() }
        for workspace in workspaces where result.disabledWorkspaceIDs.contains(workspace.id) {
            WorkspaceConfigManager.autoExport(workspace: workspace, modelContext: modelContext)
        }

        // File removal is the last step and deliberately non-throwing: the
        // deletes are committed and the keychain is wiped, so the package is
        // already functionally uninstalled. A failure here leaves an inert
        // library file that self-heals on the next uninstall/sync (which
        // finds no resources to delete and just clears it). Throwing would
        // make the caller report a failed uninstall that actually succeeded.
        do {
            _ = try library.removePackage(id: package.id)
        } catch {
            AppLogger.audit(.capabilityDisabled, category: "Capabilities", fields: [
                "source": "package_uninstall",
                "package_id": package.id,
                "result": "library_file_removal_failed_resources_already_removed",
                "error_type": String(describing: type(of: error))
            ], level: .error)
        }

        AppLogger.audit(.capabilityDisabled, category: "Capabilities", fields: [
            "source": "package_uninstall",
            "package_id": package.id,
            "disabled_workspace_count": String(result.disabledWorkspaceIDs.count),
            "removed_skills_count": String(result.removedSkillIDs.count),
            "removed_connectors_count": String(result.removedConnectorIDs.count),
            "removed_tools_count": String(result.removedToolIDs.count),
            "removed_templates_count": String(result.removedTemplateIDs.count)
        ])

        CapabilityCatalogPersistenceEvents.post(.global)
        return result
    }

    /// Clears the plugin's origin stamp from an account it leaves behind.
    /// The stamp also names a shared Keychain namespace, so credentials only
    /// there are first copied into the row's own (which loads first); one
    /// the copy can't reach keeps the stamp rather than be stranded.
    private func releaseProvenance(of account: Connector, packageID: String) {
        KeychainService.synchronizeConnectorCredentialNamespaces(connector: account)
        let stranded = account.credentialKeys.contains { key in
            KeychainService.load(key: key, connectorID: account.id) == nil
                && KeychainService.load(key: key, connector: account) != nil
        }
        guard !stranded else {
            AppLogger.audit(.capabilityDisabled, category: "Capabilities", fields: [
                "source": "package_uninstall",
                "package_id": packageID,
                "result": "account_provenance_kept_credentials_not_copied"
            ], level: .warning)
            return
        }
        account.originPackageID = nil
        account.originPackageVersion = nil
        account.originComponentID = nil
        account.originComponentKind = nil
        account.originSourceKind = nil
        account.updatedAt = Date()
    }

    private func matches(_ connector: Connector, pluginConnector: PluginConnector) -> Bool {
        connector.name == pluginConnector.name &&
        connector.serviceType == pluginConnector.serviceType
    }

    private func matches(_ tool: LocalTool, pluginTool: PluginLocalTool) -> Bool {
        tool.name == pluginTool.name &&
        tool.toolType == pluginTool.toolType &&
        tool.command == pluginTool.command
    }

    private func claims(_ skill: Skill, package: PluginPackage) -> Bool {
        if CapabilityResourceOrigin.isOwnedBy(skill, packageID: package.id) {
            return true
        }
        return package.skills.contains { $0.name == skill.name }
    }

    private func claims(_ connector: Connector, package: PluginPackage) -> Bool {
        if CapabilityResourceOrigin.isOwnedBy(connector, packageID: package.id) {
            return true
        }
        return package.connectors.contains { matches(connector, pluginConnector: $0) }
    }

    private func claims(_ tool: LocalTool, package: PluginPackage) -> Bool {
        if CapabilityResourceOrigin.isOwnedBy(tool, packageID: package.id) {
            return true
        }
        return package.localTools.contains { matches(tool, pluginTool: $0) }
    }

    private func claims(_ template: TaskTemplate, package: PluginPackage) -> Bool {
        if CapabilityResourceOrigin.isOwnedBy(template, packageID: package.id) {
            return true
        }
        return package.templates.contains { $0.name == template.name }
    }

    private func ownedOrLegacyMatches<Resource>(
        _ resources: [Resource],
        packageID: String,
        hasOrigin: (Resource) -> Bool,
        isOwned: (Resource, String) -> Bool,
        legacyMatches: (Resource) -> Bool
    ) -> [Resource] {
        let owned = resources.filter { isOwned($0, packageID) }
        if !owned.isEmpty {
            return owned
        }
        return resources.filter { !hasOrigin($0) && legacyMatches($0) }
    }
}

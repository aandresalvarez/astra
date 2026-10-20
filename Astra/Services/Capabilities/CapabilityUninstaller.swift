import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

@MainActor
struct CapabilityUninstaller {
    enum UninstallError: Error, Equatable, LocalizedError {
        case saveFailed(packageID: String)
        /// Installed plugins that `requires` this one: removing it would
        /// leave each with a missing dependency in every workspace.
        case requiredBy(packageID: String, dependents: [String])

        var errorDescription: String? {
            switch self {
            case .saveFailed(let id):
                return "Removing \(id) could not be saved. No resources were deleted; try again."
            case .requiredBy(let id, let dependents):
                return "\(id) can't be removed while \(dependents.joined(separator: ", ")) \(dependents.count == 1 ? "needs" : "need") it. Remove \(dependents.count == 1 ? "that plugin" : "those plugins") first."
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
    /// Provenance is read before the correlated removal commits its forget.
    let sourceStore: PluginSourceStore

    init(library: CapabilityLibrary = CapabilityLibrary(), sourceStore: PluginSourceStore = PluginSourceStore()) {
        self.library = library
        self.sourceStore = sourceStore
    }

    /// Forgets a plugin the library no longer has a readable entry for
    /// (deleted, unreadable, never obtainable again) through the normal
    /// Remove: its intent journaled, its activations retired with their
    /// settings released, every secret namespace they name journaled and
    /// cleaned, its accounts kept and released, every mirror carrying them
    /// rewritten. A plugin still installed takes the normal Remove; a
    /// bundled one is never forgotten (the built-in sync brings it back).
    @discardableResult
    func forgetMissing(
        pluginID: String,
        modelContext: ModelContext,
        persist: @MainActor (Workspace?, ModelContext) -> Bool = Self.persistRemoval,
        removeJournal: PluginRemoveJournal? = nil,
        skillSecrets: (any SkillSecretPersisting.Type)? = nil,
        operation: PluginFileOperationContext? = nil
    ) throws -> RemovalResult {
        if let installed = library.installedPackages().first(where: { $0.id == pluginID }) {
            return try remove(installed, modelContext: modelContext, persist: persist, removeJournal: removeJournal, skillSecrets: skillSecrets, operation: operation)
        }
        guard !CapabilityLibrary.trustedBuiltInPackageIDs.contains(pluginID) else {
            throw CapabilityLibrary.RemovalError.builtInPackage(pluginID)
        }
        // What is left of the definition is its ID: the activations name
        // their components, settings and secrets themselves.
        let missing = PluginPackage(
            id: pluginID, name: pluginID, icon: "puzzlepiece", description: "", author: "", category: "",
            tags: [], version: "", skills: [], connectors: [], localTools: [], templates: [], sourceMetadata: .localLibrary()
        )
        return try remove(
            missing, modelContext: modelContext, persist: persist, removeJournal: removeJournal,
            skillSecrets: skillSecrets, definitionMissing: true, operation: operation
        )
    }

    @discardableResult
    func remove(
        _ requestedPackage: PluginPackage,
        modelContext: ModelContext,
        persist: @MainActor (Workspace?, ModelContext) -> Bool = Self.persistRemoval,
        connectorCleanupStore _: ConnectorCredentialCleanupStore? = nil,
        removeJournal: PluginRemoveJournal? = nil,
        skillSecrets: (any SkillSecretPersisting.Type)? = nil,
        definitionMissing: Bool = false,
        secretCleanupOutbox: PluginSecretCleanupOutbox? = nil,
        exportMirror: (@MainActor (Workspace) -> Bool)? = nil,
        operation: PluginFileOperationContext? = nil
    ) throws -> RemovalResult {
        try PluginRemovalTransaction.recover(library: library, modelContext: modelContext, operation: operation)
        let installedPackages = library.installedPackages()
        guard var package = installedPackages.first(where: { $0.id == requestedPackage.id })
            ?? (definitionMissing ? requestedPackage : nil) else {
            throw CapabilityLibrary.RemovalError.notInstalled(requestedPackage.id)
        }
        if package.sourceMetadata == nil {
            package.sourceMetadata = .localLibrary()
        }
        if CapabilityLibrary.trustedBuiltInPackageIDs.contains(package.id) || package.sourceMetadata?.kind == "built-in" {
            throw CapabilityLibrary.RemovalError.builtInPackage(package.name)
        }

        let remainingPackages = installedPackages.filter { $0.id != package.id }
        // Refused while another installed plugin requires it, before
        // anything changes. Forgetting a missing one changes nothing for
        // them: they already lack it.
        let dependents = remainingPackages.filter { ($0.requires ?? []).contains(package.id) }.map(\.name).sorted()
        guard dependents.isEmpty || definitionMissing else {
            throw UninstallError.requiredBy(packageID: package.name, dependents: dependents)
        }
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

        // Read old intents for compatibility, but new removals have a
        // UUID-bound file manifest and receipt instead of inferring a save.
        let removeJournal = removeJournal ?? PluginRemoveJournal(for: modelContext)
        let legacyIntents = try removeJournal?.intents() ?? []
        let legacyWorkspaceIDs = legacyIntents.first { $0.pluginID == package.id }
            .map { $0.workspaceIDs ?? workspaces.map(\.id) } ?? []
        let transaction = try PluginRemovalTransaction.prepare(pluginID: package.id, missing: definitionMissing,
            library: library, modelContext: modelContext, operation: operation)
        let restore = PluginUpdateService.captureState(of: workspaces)
        var result = RemovalResult(packageID: package.id)
        var activationSecretSkillIDs: [UUID] = []
        let removedSource = definitionMissing
            ? sourceStore.provenance()[package.id].map { "\(PluginSource.metadataKind):\($0.sourceID)" }
            : sourceStore.installedCopy(of: installedPackages.first { $0.id == package.id }).source

        do {
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
                // component it ever knew included. Its seed and the person's
                // override rows are retired, not lost: those rows stay out of
                // the workspace's scope until the plugin is added back.
                let activation = WorkspaceCapabilityActivation.activation(for: package.id, in: workspace)
                if let activation {
                    activationSecretSkillIDs += PluginRuntimeProjection.secretNamespaces(of: activation, package: package)
                    WorkspaceCapabilityActivation.retire(activation, in: workspace, source: removedSource)
                }
                let hadPendingImport = WorkspaceCapabilityActivation.pendingImport(pluginID: package.id, in: workspace) != nil
                WorkspaceCapabilityActivation.dropPendingImport(pluginID: package.id, in: workspace)
                // Read before the activation goes: they tell a template the
                // person edited from the plugin's own.
                var templateDigests: [String: String] = [:]
                for row in PluginTemplateSync.stamped(package.id, in: workspace) {
                    guard let componentID = row.originComponentID else { continue }
                    templateDigests[componentID] = activation?.templateDigest(forComponent: componentID)
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
                // The IDs of the stamped templates deleted here are kept, so the
                // next Add writes each component's template under its old ID and
                // a schedule naming it resolves again.
                var deletedTemplateIDs: [String: UUID] = [:]
                for template in workspaceTemplates {
                    // A plugin template the person edited is theirs: it stays,
                    // no longer the plugin's, as Update would leave it.
                    if CapabilityResourceOrigin.isOwnedBy(template, packageID: package.id),
                       PluginTemplateSync.isEdited(template, of: package, recorded: templateDigests[template.originComponentID ?? ""]) {
                        PluginTemplateSync.unstamp(template)
                        continue
                    }
                    if CapabilityResourceOrigin.isOwnedBy(template, packageID: package.id),
                       let componentID = template.originComponentID, !componentID.isEmpty {
                        deletedTemplateIDs[componentID] = template.id
                    }
                    result.removedTemplateIDs.append(template.id)
                    modelContext.delete(template)
                }
                WorkspaceCapabilityActivation.retainTemplateIDs(deletedTemplateIDs, pluginID: package.id, in: workspace, source: removedSource)

                if wasPackageEnabled || wasPackageRecorded || hadPackageGlobals || hadPendingImport || !workspaceTemplates.isEmpty {
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
                activationSecretSkillIDs.append(skill.id)
                result.removedSkillIDs.append(skill.id)
                modelContext.delete(skill)
            }

            // Recorded with the workspaces whose mirrors it changes: those it
            // disabled, and each one carrying an account whose provenance it
            // released (another plugin's binding, a shared list). They are
            // rewritten before any secret is cleaned or the intent is cleared.
            // Unreadable shared rows abort before anything is deleted: a
            // mirror left out would restore the plugin without its secrets.
            let affected = result.disabledWorkspaceIDs + (try WorkspaceConfigManager.workspacesMirroring(
                accountIDs: Set(stampedAccounts.map(\.id)), among: workspaces, modelContext: modelContext
            )).map(\.id).filter { !result.disabledWorkspaceIDs.contains($0) } + legacyWorkspaceIDs
            try transaction.commit(workspaceIDs: affected, secretIDs: activationSecretSkillIDs,
                modelContext: modelContext, outbox: secretCleanupOutbox, secrets: skillSecrets,
                persist: { persist(nil, $0) }, export: exportMirror)
            removeJournal?.finish(package.id)
        } catch {
            if PluginOperationProblem.preventsRollback(error) {
                CapabilityCatalogPersistenceEvents.post(.global)
                throw error
            }
            modelContext.rollback()
            restore()
            guard transaction.rollBackFiles(modelContext: modelContext) else {
                throw PluginOperationProblem.commitUncertain(transaction.prepared.id)
            }
            throw error
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

    /// Mirrors are explicit recovery work, never a detached write from the
    /// context that is still deciding whether this removal was committed.
    static let persistRemoval: @MainActor (Workspace?, ModelContext) -> Bool = { _, context in
        WorkspacePersistenceCoordinator.saveWithoutAutoExport(modelContext: context)
    }

    /// Clears the plugin's origin stamp from an account it leaves behind
    /// (`CapabilityResourceOrigin.releaseProvenance`).
    private func releaseProvenance(of account: Connector, packageID: String) {
        guard !CapabilityResourceOrigin.releaseProvenance(of: account) else { return }
        AppLogger.audit(.capabilityDisabled, category: "Capabilities", fields: [
            "source": "package_uninstall",
            "package_id": packageID,
            "result": "account_provenance_kept_credentials_not_copied"
        ], level: .warning)
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

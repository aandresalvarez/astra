import Foundation
import SwiftData
import ASTRACore

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
        modelContext: ModelContext
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

        let packageSkillNames = Set(package.skills.map(\.name))
        let packageConnectorNames = Set(package.connectors.map(\.name))
        let packageTemplateNames = Set(package.templates.map(\.name))

        let matchedGlobalSkills = ownedOrLegacyMatches(
            globalSkills,
            packageID: package.id,
            hasOrigin: CapabilityResourceOrigin.hasOrigin,
            isOwned: CapabilityResourceOrigin.isOwnedBy(_:packageID:),
            legacyMatches: { packageSkillNames.contains($0.name) }
        )
        let matchedGlobalConnectors = ownedOrLegacyMatches(
            globalConnectors,
            packageID: package.id,
            hasOrigin: CapabilityResourceOrigin.hasOrigin,
            isOwned: CapabilityResourceOrigin.isOwnedBy(_:packageID:),
            legacyMatches: { connector in
                package.connectors.contains { matches(connector, pluginConnector: $0) }
            }
        )
        let matchedGlobalTools = ownedOrLegacyMatches(
            globalTools,
            packageID: package.id,
            hasOrigin: CapabilityResourceOrigin.hasOrigin,
            isOwned: CapabilityResourceOrigin.isOwnedBy(_:packageID:),
            legacyMatches: { tool in
                package.localTools.contains { matches(tool, pluginTool: $0) }
            }
        )

        var result = RemovalResult(packageID: package.id)
        // Wiped only after the SwiftData deletes are saved — see below.
        var pendingKeychainCleanups: [() -> Void] = []

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

            workspace.enabledCapabilityIDs.removeAll { $0 == package.id }
            workspace.enabledGlobalSkillIDs.removeAll { removableGlobalSkillIDs.contains($0) }
            workspace.enabledGlobalConnectorIDs.removeAll { removableGlobalConnectorIDs.contains($0) }
            workspace.enabledGlobalToolIDs.removeAll { removableGlobalToolIDs.contains($0) }
            removeInstalledPackageRecord(package.id, from: workspace)

            let workspaceConnectors = ownedOrLegacyMatches(
                workspace.connectors,
                packageID: package.id,
                hasOrigin: CapabilityResourceOrigin.hasOrigin,
                isOwned: CapabilityResourceOrigin.isOwnedBy(_:packageID:),
                legacyMatches: { packageConnectorNames.contains($0.name) }
            )
            .filter { connector in
                !remainingWorkspacePackages.contains(where: { claims(connector, package: $0) })
            }
            for connector in workspaceConnectors {
                pendingKeychainCleanups.append { connector.cleanupKeychain() }
                result.removedConnectorIDs.append(connector.id)
                modelContext.delete(connector)
            }

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

            if wasPackageEnabled || wasPackageRecorded || hadPackageGlobals || !workspaceConnectors.isEmpty || !workspaceTemplates.isEmpty {
                workspace.updatedAt = Date()
                result.disabledWorkspaceIDs.append(workspace.id)
            }
        }

        for connector in matchedGlobalConnectors where !remainingPackages.contains(where: { claims(connector, package: $0) }) {
            pendingKeychainCleanups.append { connector.cleanupKeychain() }
            result.removedConnectorIDs.append(connector.id)
            modelContext.delete(connector)
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

        guard WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: nil, modelContext: modelContext) else {
            // Abort before touching the keychain or the library file: the
            // deletes were not persisted, so removing either would strand
            // resources (file gone) or credentials (records still present).
            throw UninstallError.saveFailed(packageID: package.id)
        }
        pendingKeychainCleanups.forEach { $0() }
        for workspace in workspaces where result.disabledWorkspaceIDs.contains(workspace.id) {
            WorkspaceConfigManager.autoExport(workspace: workspace, modelContext: modelContext)
        }

        _ = try library.removePackage(id: package.id)

        AppLogger.audit(.capabilityDisabled, category: "Capabilities", fields: [
            "source": "package_uninstall",
            "package_id": package.id,
            "disabled_workspace_count": String(result.disabledWorkspaceIDs.count),
            "removed_skills_count": String(result.removedSkillIDs.count),
            "removed_connectors_count": String(result.removedConnectorIDs.count),
            "removed_tools_count": String(result.removedToolIDs.count),
            "removed_templates_count": String(result.removedTemplateIDs.count)
        ])

        return result
    }

    private func removeInstalledPackageRecord(_ packageID: String, from workspace: Workspace) {
        while let index = workspace.installedPluginIDs.firstIndex(of: packageID) {
            workspace.installedPluginIDs.remove(at: index)
            if index < workspace.installedPluginVersions.count {
                workspace.installedPluginVersions.remove(at: index)
            }
        }
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

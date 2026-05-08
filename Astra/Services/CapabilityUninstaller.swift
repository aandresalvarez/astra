import Foundation
import SwiftData
import ASTRACore

@MainActor
struct CapabilityUninstaller {
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
        let workspaces = (try? modelContext.fetch(FetchDescriptor<Workspace>())) ?? []
        let globalSkills = (try? modelContext.fetch(FetchDescriptor<Skill>(
            predicate: #Predicate { $0.isGlobal == true }
        ))) ?? []
        let globalConnectors = (try? modelContext.fetch(FetchDescriptor<Connector>(
            predicate: #Predicate { $0.isGlobal == true }
        ))) ?? []
        let globalTools = (try? modelContext.fetch(FetchDescriptor<LocalTool>(
            predicate: #Predicate { $0.isGlobal == true }
        ))) ?? []

        let packageSkillNames = Set(package.skills.map(\.name))
        let packageConnectorNames = Set(package.connectors.map(\.name))
        let packageTemplateNames = Set(package.templates.map(\.name))

        let matchedGlobalSkills = globalSkills.filter { packageSkillNames.contains($0.name) }
        let matchedGlobalConnectors = globalConnectors.filter { connector in
            package.connectors.contains { matches(connector, pluginConnector: $0) }
        }
        let matchedGlobalTools = globalTools.filter { tool in
            package.localTools.contains { matches(tool, pluginTool: $0) }
        }

        var result = RemovalResult(packageID: package.id)

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

            let workspaceConnectors = workspace.connectors.filter { connector in
                packageConnectorNames.contains(connector.name) &&
                !remainingWorkspacePackages.contains(where: { claims(connector, package: $0) })
            }
            for connector in workspaceConnectors {
                connector.cleanupKeychain()
                result.removedConnectorIDs.append(connector.id)
                modelContext.delete(connector)
            }

            let workspaceTemplates = workspace.templates.filter { template in
                packageTemplateNames.contains(template.name) &&
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
            connector.cleanupKeychain()
            result.removedConnectorIDs.append(connector.id)
            modelContext.delete(connector)
        }

        for tool in matchedGlobalTools where !remainingPackages.contains(where: { claims(tool, package: $0) }) {
            result.removedToolIDs.append(tool.id)
            modelContext.delete(tool)
        }

        for skill in matchedGlobalSkills where !remainingPackages.contains(where: { claims(skill, package: $0) }) {
            skill.cleanupKeychain()
            result.removedSkillIDs.append(skill.id)
            modelContext.delete(skill)
        }

        _ = WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: nil, modelContext: modelContext)
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
        package.skills.contains { $0.name == skill.name }
    }

    private func claims(_ connector: Connector, package: PluginPackage) -> Bool {
        package.connectors.contains { matches(connector, pluginConnector: $0) }
    }

    private func claims(_ tool: LocalTool, package: PluginPackage) -> Bool {
        package.localTools.contains { matches(tool, pluginTool: $0) }
    }

    private func claims(_ template: TaskTemplate, package: PluginPackage) -> Bool {
        package.templates.contains { $0.name == template.name }
    }
}

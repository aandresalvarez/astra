import Foundation
import SwiftData
import ASTRACore

@MainActor
struct CapabilityActivationDisabler {
    struct Result: Equatable {
        var packageID: String
        var disabledSkillIDs: [UUID] = []
        var disabledConnectorIDs: [UUID] = []
        var disabledToolIDs: [UUID] = []
        var removedWorkspaceSkillIDs: [UUID] = []
        var removedWorkspaceConnectorIDs: [UUID] = []
    }

    @discardableResult
    func disable(
        _ package: PluginPackage,
        in workspace: Workspace,
        capabilities: WorkspaceCapabilities,
        modelContext: ModelContext,
        availablePackages: [PluginPackage] = CapabilityRuntimeResourceMatcher.packageDefinitions()
    ) -> Result {
        let state = CapabilityPackageState(
            package: package,
            workspace: workspace,
            capabilities: capabilities
        )
        let remainingPackages = remainingEnabledPackages(
            excluding: package,
            workspace: workspace,
            capabilities: capabilities,
            availablePackages: availablePackages
        )
        var result = Result(packageID: package.id)

        workspace.enabledCapabilityIDs.removeAll { $0 == package.id }

        let removableGlobalSkillIDs = Set(state.linkedSkills
            .filter { skill in
                skill.isGlobal && !remainingPackages.contains { remaining in
                    claims(skill, package: remaining)
                }
            }
            .map { $0.id.uuidString })
        result.disabledSkillIDs = removableGlobalSkillIDs.compactMap(UUID.init(uuidString:))
        workspace.enabledGlobalSkillIDs.removeAll { id in
            removableGlobalSkillIDs.contains(id)
        }

        let removableGlobalConnectorIDs = Set(state.linkedConnectors
            .filter { connector in
                connector.isGlobal && !remainingPackages.contains { remaining in
                    claims(connector, package: remaining)
                }
            }
            .map { $0.id.uuidString })
        result.disabledConnectorIDs = removableGlobalConnectorIDs.compactMap(UUID.init(uuidString:))
        workspace.enabledGlobalConnectorIDs.removeAll { id in
            removableGlobalConnectorIDs.contains(id)
        }

        let removableGlobalToolIDs = Set(state.linkedTools
            .filter { tool in
                tool.isGlobal && !remainingPackages.contains { remaining in
                    claims(tool, package: remaining)
                }
            }
            .map { $0.id.uuidString })
        result.disabledToolIDs = removableGlobalToolIDs.compactMap(UUID.init(uuidString:))
        workspace.enabledGlobalToolIDs.removeAll { id in
            removableGlobalToolIDs.contains(id)
        }

        for connector in state.linkedConnectors where !connector.isGlobal {
            guard !remainingPackages.contains(where: { claims(connector, package: $0) }) else { continue }
            connector.cleanupKeychain()
            result.removedWorkspaceConnectorIDs.append(connector.id)
            modelContext.delete(connector)
        }

        let remainingExplicitPackages = remainingPackages.filter { !$0.isSyntheticWorkspaceSkillPackage }
        for skill in state.linkedSkills where !skill.isGlobal {
            guard !remainingExplicitPackages.contains(where: { claims(skill, package: $0) }) else { continue }
            skill.cleanupKeychain()
            result.removedWorkspaceSkillIDs.append(skill.id)
            modelContext.delete(skill)
        }

        workspace.updatedAt = Date()
        return result
    }

    private func remainingEnabledPackages(
        excluding package: PluginPackage,
        workspace: Workspace,
        capabilities: WorkspaceCapabilities,
        availablePackages: [PluginPackage]
    ) -> [PluginPackage] {
        let enabledIDs = Set(workspace.enabledCapabilityIDs).subtracting([package.id])
        let enabledCatalogPackages = availablePackages.filter { enabledIDs.contains($0.id) }
        let syntheticPackages = CapabilityCatalogInventory.configuredPackages(
            catalogPackages: [],
            capabilities: capabilities,
            workspace: workspace
        )
        .filter { $0.id != package.id }
        return uniquePackages(enabledCatalogPackages + syntheticPackages)
    }

    private func claims(_ skill: Skill, package: PluginPackage) -> Bool {
        package.skills.contains {
            CapabilityRuntimeResourceMatcher.skillMatches($0, skill: skill)
        }
    }

    private func claims(_ connector: Connector, package: PluginPackage) -> Bool {
        package.connectors.contains {
            CapabilityRuntimeResourceMatcher.connectorMatches($0, connector: connector)
        }
    }

    private func claims(_ tool: LocalTool, package: PluginPackage) -> Bool {
        package.localTools.contains {
            CapabilityRuntimeResourceMatcher.toolMatches($0, tool: tool)
        }
    }

    private func uniquePackages(_ packages: [PluginPackage]) -> [PluginPackage] {
        var seen = Set<String>()
        return packages.filter { seen.insert($0.id).inserted }
    }
}

private extension PluginPackage {
    var isSyntheticWorkspaceSkillPackage: Bool {
        id.hasPrefix("skill.") && sourceMetadata?.kind == "workspace"
    }
}

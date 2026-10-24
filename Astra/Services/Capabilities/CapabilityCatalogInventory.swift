import Foundation
import ASTRACore
import ASTRAModels

struct CapabilityCatalogInventory {
    static func packages(
        catalogPackages: [PluginPackage],
        capabilities: WorkspaceCapabilities,
        policyContext: CapabilityCatalogPolicyContext? = nil
    ) -> [PluginPackage] {
        let workspace = capabilities.workspace
        let state = WorkspaceCapabilityActivation.state(of: workspace)
        let overrides = WorkspaceCapabilityActivation.overridingRowIDs(of: workspace)
        let shared = Set(state.globalSkillIDs)
        let ownedPluginIDs = Set(state.pluginIDs)
            .union(WorkspaceCapabilityActivation.pendingLegacyInstallations(in: workspace).map(\.id))
        let represented = ownedPluginIDs.intersection(catalogPackages.map(\.id))
        let standaloneSkillPackages = uniqueSkills(capabilities.workspaceSkills + capabilities.availableGlobalSkills)
            .filter { skill in
                guard !overrides.contains(skill.id) else { return false }
                let origin = skill.originPackageID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let independentSharedChoice = skill.isGlobal && shared.contains(skill.id.uuidString)
                return !represented.contains(origin) || independentSharedChoice
            }
            .map(makePackage)

        return uniquePackages(catalogPackages + standaloneSkillPackages)
            .filter { package in
                guard let policyContext else { return true }
                return CapabilityCatalogPolicy.decision(for: package, context: policyContext).isVisible
            }
            .sorted { lhs, rhs in
                if lhs.category != rhs.category { return lhs.category < rhs.category }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    static func configuredPackages(
        catalogPackages: [PluginPackage],
        capabilities: WorkspaceCapabilities,
        workspace: Workspace,
        policyContext: CapabilityCatalogPolicyContext? = nil
    ) -> [PluginPackage] {
        packages(
            catalogPackages: catalogPackages,
            capabilities: capabilities,
            policyContext: policyContext
        )
            .filter { package in
                CapabilityPackageState(
                    package: package,
                    workspace: workspace,
                    capabilities: capabilities
                ).isEnabled
            }
    }

    private static func makePackage(for skill: Skill) -> PluginPackage {
        let name = skill.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Untitled Capability"
            : skill.name
        let category = skill.isGlobal ? "Shared" : "Workspace"
        let source = CapabilitySourceMetadata(
            id: skill.isGlobal ? "shared-skills" : "workspace",
            displayName: skill.isGlobal ? "Shared Capability" : "Workspace Capability",
            kind: skill.isGlobal ? "shared" : "workspace",
            trustLevel: skill.isGlobal ? "shared" : "workspace"
        )

        return PluginPackage(
            id: "skill.\(skill.id.uuidString.lowercased())",
            name: name,
            icon: skill.icon,
            description: skill.skillDescription,
            author: skill.isGlobal ? "Shared Library" : "Workspace",
            category: category,
            tags: [category.lowercased()],
            version: "1.0.0",
            skills: [
                PluginSkill(
                    name: name,
                    icon: skill.icon,
                    description: skill.skillDescription,
                    allowedTools: skill.allowedTools,
                    disallowedTools: skill.disallowedTools,
                    customTools: skill.customTools,
                    behaviorInstructions: skill.behaviorInstructions,
                    environmentKeys: skill.environmentKeys,
                    environmentValues: skill.exportableEnvironmentValues
                )
            ],
            connectors: skill.connectors.map(CapabilityPackageFactory.makeConnector),
            localTools: skill.localTools.map(CapabilityPackageFactory.makeLocalTool),
            templates: [],
            sourceMetadata: source
        )
    }

    private static func uniqueSkills(_ skills: [Skill]) -> [Skill] {
        var seen = Set<UUID>()
        return skills.filter { seen.insert($0.id).inserted }
    }

    private static func uniquePackages(_ packages: [PluginPackage]) -> [PluginPackage] {
        var seen = Set<String>()
        return packages.filter { seen.insert($0.id).inserted }
    }

}

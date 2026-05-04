import Foundation
import ASTRACore

struct CapabilityCatalogInventory {
    static func packages(
        catalogPackages: [PluginPackage],
        capabilities: WorkspaceCapabilities
    ) -> [PluginPackage] {
        let packagedSkillNames = Set(catalogPackages.flatMap { package in
            package.skills.map { normalizedName($0.name) } + [normalizedName(package.name)]
        })

        let standaloneSkillPackages = uniqueSkills(capabilities.workspaceSkills + capabilities.availableGlobalSkills)
            .filter { !packagedSkillNames.contains(normalizedName($0.name)) }
            .map(makePackage)

        return uniquePackages(catalogPackages + standaloneSkillPackages)
            .sorted { lhs, rhs in
                if lhs.category != rhs.category { return lhs.category < rhs.category }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    static func configuredPackages(
        catalogPackages: [PluginPackage],
        capabilities: WorkspaceCapabilities,
        workspace: Workspace
    ) -> [PluginPackage] {
        packages(catalogPackages: catalogPackages, capabilities: capabilities)
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

    private static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

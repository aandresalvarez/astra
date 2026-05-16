import Foundation
import ASTRACore

struct CapabilityGalleryInventory {
    static func packages(catalogPackages: [PluginPackage]) -> [PluginPackage] {
        uniquePackages(catalogPackages)
            .filter { !$0.isProjectedResourceCapability }
            .sorted(by: sortPackages)
    }

    static func managementPackages(
        catalogPackages: [PluginPackage],
        capabilities: WorkspaceCapabilities,
        workspace: Workspace
    ) -> [PluginPackage] {
        let libraryPackages = packages(catalogPackages: catalogPackages)
        let activeWorkspacePackages = CapabilityCatalogInventory.configuredPackages(
            catalogPackages: libraryPackages,
            capabilities: capabilities,
            workspace: workspace
        )
        .filter(\.isProjectedResourceCapability)

        return uniquePackages(libraryPackages + activeWorkspacePackages)
            .sorted(by: sortPackages)
    }

    private static func uniquePackages(_ packages: [PluginPackage]) -> [PluginPackage] {
        var seen = Set<String>()
        return packages.filter { seen.insert($0.id).inserted }
    }

    private static func sortPackages(_ lhs: PluginPackage, _ rhs: PluginPackage) -> Bool {
        if lhs.category != rhs.category { return lhs.category < rhs.category }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}

private extension PluginPackage {
    var isProjectedResourceCapability: Bool {
        id.hasPrefix("skill.") && (sourceMetadata?.kind == "workspace" || sourceMetadata?.kind == "shared")
    }
}

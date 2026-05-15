import Foundation
import ASTRACore

struct CapabilityGalleryInventory {
    static func packages(catalogPackages: [PluginPackage]) -> [PluginPackage] {
        uniquePackages(catalogPackages)
            .filter { !$0.isProjectedResourceCapability }
            .sorted { lhs, rhs in
                if lhs.category != rhs.category { return lhs.category < rhs.category }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private static func uniquePackages(_ packages: [PluginPackage]) -> [PluginPackage] {
        var seen = Set<String>()
        return packages.filter { seen.insert($0.id).inserted }
    }
}

private extension PluginPackage {
    var isProjectedResourceCapability: Bool {
        id.hasPrefix("skill.") && (sourceMetadata?.kind == "workspace" || sourceMetadata?.kind == "shared")
    }
}

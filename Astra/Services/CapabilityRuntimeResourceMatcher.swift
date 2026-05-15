import Foundation
import ASTRACore

enum CapabilityRuntimeResourceMatcher {
    static func packageDefinitions(library: CapabilityLibrary = CapabilityLibrary()) -> [PluginPackage] {
        uniquePackages(library.installedPackages() + ApprovedCapabilityBundle.packages())
    }

    static func enabledPackages(
        for workspace: Workspace?,
        library: CapabilityLibrary = CapabilityLibrary()
    ) -> [PluginPackage] {
        guard let workspace else { return [] }
        let enabledIDs = Set(workspace.enabledCapabilityIDs)
        guard !enabledIDs.isEmpty else { return [] }
        return packageDefinitions(library: library).filter { enabledIDs.contains($0.id) }
    }

    static func skillMatches(_ pluginSkill: PluginSkill, skill: Skill) -> Bool {
        normalizedName(pluginSkill.name) == normalizedName(skill.name)
    }

    static func connectorMatches(_ pluginConnector: PluginConnector, connector: Connector) -> Bool {
        if normalizedName(pluginConnector.name) == normalizedName(connector.name) {
            return true
        }

        let packageServiceType = normalizedServiceType(pluginConnector.serviceType)
        guard !packageServiceType.isEmpty, packageServiceType != "custom" else {
            return false
        }
        return packageServiceType == normalizedServiceType(connector.serviceType)
    }

    static func toolMatches(_ pluginTool: PluginLocalTool, tool: LocalTool) -> Bool {
        if normalizedName(pluginTool.name) == normalizedName(tool.name) {
            return true
        }
        return normalizedName(pluginTool.toolType) == normalizedName(tool.toolType)
            && normalizedName(pluginTool.command) == normalizedName(tool.command)
            && normalizedName(pluginTool.arguments) == normalizedName(tool.arguments)
    }

    static func normalizedServiceType(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func normalizedName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func uniquePackages(_ packages: [PluginPackage]) -> [PluginPackage] {
        var seen = Set<String>()
        return packages.filter { seen.insert($0.id).inserted }
    }
}

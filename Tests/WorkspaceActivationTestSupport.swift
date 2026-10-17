import Foundation
import ASTRAModels

/// Test-only setters for the plugin enablement that `Workspace` now derives
/// from its `PluginActivation`s. Each write goes through the owner, exactly
/// as the old stored arrays' writes would have been reconciled.
extension Workspace {
    var testEnabledCapabilityIDs: [String] {
        get { enabledCapabilityIDs }
        set { WorkspaceCapabilityActivation.mutate(self) { $0.capabilityIDs = newValue } }
    }

    var testInstalledPluginIDs: [String] {
        get { installedPluginIDs }
        set { WorkspaceCapabilityActivation.mutate(self) { $0.pluginIDs = newValue } }
    }

    var testInstalledPluginVersions: [String] {
        get { installedPluginVersions }
        set { WorkspaceCapabilityActivation.mutate(self) { $0.pluginVersions = newValue } }
    }
}

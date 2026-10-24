import Foundation
import ASTRACore
import ASTRAModels
@testable import ASTRA

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

    /// Binds `account` as the account of the connector component of
    /// `pluginID`'s activation here that serves its service (or `spec`), as
    /// an Add or the migration would. False when there is no such
    /// activation or component.
    @MainActor
    func testBind(_ account: Connector, toPlugin pluginID: String, component spec: PluginConnector? = nil) -> Bool {
        guard let activation = WorkspaceCapabilityActivation.activation(for: pluginID, in: self) else { return false }
        let componentSpec = spec ?? PluginCatalog.builtInPackages.first { $0.id == pluginID }?.connectors.first {
            CapabilityRuntimeResourceMatcher.connectorMatches($0, connector: account)
        }
        guard let componentSpec else { return false }
        WorkspaceCapabilityActivation.bind(account, toComponent: CapabilityResourceOrigin.componentID(for: componentSpec), of: activation)
        return true
    }
}

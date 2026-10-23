import Foundation
import ASTRACore
import ASTRAModels

/// Adopts original V20 account choices at the domain migration boundary.
/// New bindings own aliases and defaults; legacy rows remain unchanged so a
/// shared account's display name in another workspace is never rewritten.
@MainActor
enum PluginV20AccountChoices {
    static func bind(_ account: Connector, componentID: String, to activation: PluginActivation, in workspace: Workspace) {
        let service = CapabilityRuntimeResourceMatcher.normalizedServiceType(account.serviceType)
        let selectedID = zip(workspace.defaultAccountServiceTypes, workspace.defaultAccountConnectorIDs)
            .first { CapabilityRuntimeResourceMatcher.normalizedServiceType($0.0) == service }?.1
        let alias = account.accountAlias.flatMap(AccountDisplayName.sanitized).map {
            WorkspaceCapabilityActivation.uniqueAlias($0, serviceType: account.serviceType, in: workspace, excluding: account.id)
        }
        WorkspaceCapabilityActivation.bind(
            account, toComponent: componentID, of: activation,
            isDefault: selectedID.flatMap(UUID.init(uuidString:)) == account.id,
            alias: alias
        )
    }
}

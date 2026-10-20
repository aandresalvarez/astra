import SwiftData
import ASTRAModels

/// Faults the plugin/account relationships touched by a reversible deletion.
/// SwiftData must snapshot real arrays, including empty ones, before cascade
/// deletion changes an inverse. This reads the affected relationship closure;
/// it never edits domain state or scans task histories.
@MainActor
public enum SwiftDataPluginRelationshipPreparation {
    public static func prepare(_ workspace: Workspace, additionalAccounts: [Connector] = []) {
        prepare(activations: workspace.pluginActivations, accounts: workspace.connectors + additionalAccounts)
    }

    public static func prepare(_ account: Connector) {
        prepare(activations: [], accounts: [account])
    }

    private static func prepare(activations: [PluginActivation], accounts: [Connector]) {
        var activations = activations
        var accounts = accounts
        var seenActivations: Set<ObjectIdentifier> = []
        var seenAccounts: Set<ObjectIdentifier> = []
        while !activations.isEmpty || !accounts.isEmpty {
            if let activation = activations.popLast(), !activation.isDeleted,
               seenActivations.insert(ObjectIdentifier(activation)).inserted {
                if let workspace = activation.workspace {
                    for related in workspace.pluginActivations { _ = related.id }
                }
                for binding in activation.bindings {
                    _ = (binding.id, binding.activation?.id)
                    if let account = binding.account { accounts.append(account) }
                }
            }
            if let account = accounts.popLast(), !account.isDeleted,
               seenAccounts.insert(ObjectIdentifier(account)).inserted {
                for binding in account.accountBindings {
                    _ = (binding.id, binding.account?.id)
                    if let activation = binding.activation { activations.append(activation) }
                }
            }
        }
    }
}

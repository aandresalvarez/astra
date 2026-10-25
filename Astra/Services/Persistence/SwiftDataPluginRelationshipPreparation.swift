import SwiftData
import ASTRAModels

/// Resolves relationship arrays before a reversible plugin graph mutation.
/// SwiftData snapshots the owning workspace's arrays together, including ones
/// the operation does not edit. An unresolved empty array can otherwise return
/// as a snapshot future after rollback. This reads IDs, never task histories.
@MainActor
public enum SwiftDataPluginRelationshipPreparation {
    public static func prepare(_ workspace: Workspace, additionalAccounts: [Connector] = []) {
        for task in workspace.tasks { _ = task.id }
        for skill in workspace.skills { _ = skill.id }
        for connector in workspace.connectors { _ = connector.id }
        for tool in workspace.localTools { _ = tool.id }
        for template in workspace.templates { _ = template.id }
        for schedule in workspace.schedules { _ = schedule.id }
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

import Foundation
import ASTRAModels

extension TaskExecutionLaunchSnapshotApplicator {
    nonisolated static func accountInventory(for task: AgentTask) -> TaskAccountInventorySnapshot {
        TaskAccountInventorySnapshot(connectors: TaskCapabilityResolver(task: task).resourceInventory.connectors,
                                     workspace: task.workspace)
    }

    /// Rebuild account references from the inventory accepted by submission.
    /// This applies only to an unmanaged launch graph. Legacy policies without
    /// this field keep their previous account projection contract.
    static func applyAccountInventory(
        _ inventory: TaskAccountInventorySnapshot?, to workspace: Workspace,
        skillsByID: [UUID: Skill]
    ) {
        guard let inventory, workspace.modelContext == nil else { return }
        let skills = Dictionary((Array(skillsByID.values) + workspace.skills).map { ($0.id, $0) },
                                uniquingKeysWith: { _, last in last })
        let existing = Dictionary((workspace.connectors + skills.values.flatMap(\.connectors)).map { ($0.id, $0) },
                                  uniquingKeysWith: { first, _ in first })
        // Detach live relationships before wiring the accepted roles. Neither
        // late membership nor an edited parent may turn an attachment into a
        // standalone account (or remove a previously standalone account).
        for skill in skills.values { skill.connectors = [] }
        workspace.connectors = []
        for entry in inventory.entries {
            let parent = entry.skillID.flatMap { skills[$0] }
            // A projected plugin parent is reconstructed by its frozen
            // activation, rather than promoted into an authored standalone row.
            guard entry.skillID == nil || parent != nil || entry.account.isGlobal else { continue }
            let copy = existing[entry.account.id] ?? entry.account.makeAccount()
            entry.account.apply(to: copy)
            copy.skill = parent
            if let parent, !parent.connectors.contains(where: { $0.id == copy.id }) { parent.connectors.append(copy) }
            workspace.connectors.append(copy)
        }
        WorkspaceCapabilityActivation.mutate(workspace) { state in
            state.globalConnectorIDs = inventory.sharedConnectorIDs
        }
    }
}

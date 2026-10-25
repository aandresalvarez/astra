import Foundation
import SwiftData
import ASTRAModels

/// Read-only launch admission. Receipts remain the commit/completion owner;
/// prepared file work is a library-wide barrier until recovery decides it.
/// This runs at execution preflight, never from a view render or a timer.
@MainActor
enum PluginOperationRuntimeAdmission {
    static func issues(
        in workspace: Workspace, pluginIDs: Set<String>, names: [String: String], modelContext: ModelContext
    ) -> [CapabilityRuntimeIntegrityIssue] {
        guard !pluginIDs.isEmpty else { return [] }
        var blocked = Set<String>()
        do {
            let files = PluginFileOperationJournal(library: CapabilityLibrary(), approvals: CapabilityApprovalStore())
            if !((try files.pendingIDs()).isEmpty) { return problems(pluginIDs, names: names) }
            let pending = try PluginPendingOperations.capture(modelContext: modelContext)
            var workspaceIDs = Set([workspace.id])
            workspaceIDs.formUnion(WorkspaceCapabilityActivation.activations(of: workspace).compactMap(\.launchWorkspaceID))
            for entry in pending {
                let receipt = entry.snapshot
                // A definition/approval file operation affects the shared
                // library, including workspaces not named by its domain save.
                guard receipt.manifestDigest != nil || receipt.workspaceIDs.isEmpty
                    || !workspaceIDs.isDisjoint(with: receipt.workspaceIDs) else { continue }
                blocked.formUnion(receipt.pluginIDs.isEmpty ? pluginIDs : pluginIDs.intersection(receipt.pluginIDs))
            }
        } catch {
            // Unreadable proof cannot grant permission to run a possibly
            // half-published definition or credential generation.
            blocked = pluginIDs
        }
        return problems(blocked, names: names)
    }

    private static func problems(_ pluginIDs: Set<String>, names: [String: String]) -> [CapabilityRuntimeIntegrityIssue] {
        pluginIDs.sorted().map { id in
            CapabilityRuntimeIntegrityIssue(packageID: id, packageName: names[id] ?? id, source: .enabledPackage,
                resourceKind: .policy, resourceName: id,
                message: "This plugin has an unfinished change or its saved result cannot be verified. Open Plugins to finish recovery, then retry.")
        }
    }
}

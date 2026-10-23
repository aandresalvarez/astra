import Foundation
import ASTRAModels

extension PluginsSurfacePresentation {
    /// Missing definitions remain manageable through their persisted owners.
    @MainActor
    static func missingInputs(in workspace: Workspace, libraryIDs: Set<String>, listedIDs: Set<String>) -> [Input] {
        let activations = WorkspaceCapabilityActivation.activations(of: workspace)
        let ids = activations.map(\.pluginID)
            + WorkspaceCapabilityActivation.pendingLegacyInstallations(in: workspace).map(\.id)
        let enabled = Set(WorkspaceCapabilityActivation.enabledPluginIDs(of: workspace))
        var seen = libraryIDs.union(listedIDs)
        return ids.compactMap { id in
            guard seen.insert(id).inserted else { return nil }
            return missingInput(pluginID: id, isEnabled: enabled.contains(id))
        }
    }
}

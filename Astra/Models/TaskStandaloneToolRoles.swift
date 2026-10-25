import Foundation

/// Immutable acceptance evidence, derived from the existing workspace owner.
public enum TaskStandaloneToolRoles {
    /// On detached graphs only; absence of a baseline in an old request must
    /// not turn into fresh acceptance when a continuation recaptures it.
    public enum LaunchEvidence: Sendable {
        case legacy
        case accepted([UUID])
    }

    public static func capture(for task: AgentTask) -> [UUID]? {
        guard let workspace = task.workspace else { return nil }
        if let evidence = workspace.launchStandaloneToolRoles {
            switch evidence {
            case .legacy: return nil
            case .accepted(let ids): return ids
            }
        }
        let overrides = WorkspaceCapabilityActivation.overridingRowIDs(of: workspace)
        return workspace.localTools.filter {
            !$0.isDeleted && !$0.isGlobal && $0.skill == nil && !overrides.contains($0.id)
                && !WorkspaceCapabilityActivation.isPluginOriginDisabled($0.originPackageID, in: workspace)
        }.map(\.id)
    }
}

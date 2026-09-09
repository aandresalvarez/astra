import Foundation
import ASTRACore
import ASTRAModels

struct TaskRuntimeRequirementSet: Equatable, Sendable {
    /// What this turn cannot proceed without. Every consequence that can cost
    /// the run something — rerouting to another runtime, aborting the launch,
    /// withdrawing native shell — reads this list and only this list.
    let hostControlTools: [String]
    /// What to attach when the transport can carry it: everything the user
    /// explicitly enabled, so a capability stays callable through a turn that
    /// does not happen to name it. Always a superset of `hostControlTools`, and
    /// never on its own a reason to fail, reroute, or restrict a run.
    let offeredHostControlTools: [String]
    let requiresDockerWorkspaceShell: Bool
    let requiresBrowserControl: Bool

    init(
        hostControlTools: [String],
        offeredHostControlTools: [String]? = nil,
        requiresDockerWorkspaceShell: Bool,
        requiresBrowserControl: Bool
    ) {
        let required = Self.normalizedHostControlTools(hostControlTools)
        self.hostControlTools = required
        self.offeredHostControlTools = Self.normalizedHostControlTools(
            required + (offeredHostControlTools ?? [])
        )
        self.requiresDockerWorkspaceShell = requiresDockerWorkspaceShell
        self.requiresBrowserControl = requiresBrowserControl
    }

    var requiresHostControlPlane: Bool {
        !hostControlTools.isEmpty
    }

    /// True when there is anything worth standing the broker up for, whether or
    /// not the turn depends on it.
    var offersHostControlPlane: Bool {
        !offeredHostControlTools.isEmpty
    }

    var isEmpty: Bool {
        !requiresHostControlPlane && !requiresDockerWorkspaceShell && !requiresBrowserControl
    }

    var missingCapabilityNames: [String] {
        var names: [String] = []
        if requiresHostControlPlane {
            names.append("ASTRA host tools for \(hostControlTools.joined(separator: ", "))")
        }
        if requiresDockerWorkspaceShell {
            names.append("Docker workspace shell MCP")
        }
        if requiresBrowserControl {
            names.append("browser control transport")
        }
        return names
    }

    static func derive(
        task: AgentTask,
        capabilityResolutionSnapshot: TaskCapabilityResolutionSnapshot,
        executionEnvironment: WorkspaceExecutionEnvironment,
        browserBridgeAttached: Bool
    ) -> TaskRuntimeRequirementSet {
        // Docker mode grants the host-control MCP server all 5 tools
        // unconditionally (HostControlPlaneMCPProjection.enabledToolNames) —
        // requiredToolNames alone only covers the capability-scope-derived
        // subset, so it must be skipped in Docker mode or this requirement
        // set silently disagrees with the actual launch-time tool grant.
        let isDocker = HostControlPlaneMCPProjection.isEnabled(for: executionEnvironment)
        let hostControlTools = isDocker
            ? HostControlPlaneMCPProjection.toolNames
            : HostControlPlaneMCPProjection.requiredToolNames(
                capabilityScope: capabilityResolutionSnapshot.providerLaunch
            )
        let offeredHostControlTools = isDocker
            ? HostControlPlaneMCPProjection.toolNames
            : HostControlPlaneMCPProjection.offeredToolNames(
                capabilityScope: capabilityResolutionSnapshot.providerLaunch
            )
        return TaskRuntimeRequirementSet(
            hostControlTools: hostControlTools,
            offeredHostControlTools: offeredHostControlTools,
            requiresDockerWorkspaceShell: DockerWorkspaceMCPProjection.isEnabled(for: executionEnvironment),
            requiresBrowserControl: browserBridgeAttached
        )
    }

    private static func normalizedHostControlTools(_ tools: [String]) -> [String] {
        var seen: Set<String> = []
        return tools.compactMap { tool in
            let normalized = tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }
}

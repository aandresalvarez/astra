import Foundation
import ASTRACore
import ASTRAModels

struct TaskRuntimeRequirementSet: Equatable, Sendable {
    let hostControlTools: [String]
    let requiresDockerWorkspaceShell: Bool
    let requiresBrowserControl: Bool

    init(
        hostControlTools: [String],
        requiresDockerWorkspaceShell: Bool,
        requiresBrowserControl: Bool
    ) {
        self.hostControlTools = Self.normalizedHostControlTools(hostControlTools)
        self.requiresDockerWorkspaceShell = requiresDockerWorkspaceShell
        self.requiresBrowserControl = requiresBrowserControl
    }

    var requiresHostControlPlane: Bool {
        !hostControlTools.isEmpty
    }

    var isEmpty: Bool {
        !requiresHostControlPlane && !requiresDockerWorkspaceShell && !requiresBrowserControl
    }

    var missingCapabilityNames: [String] {
        var names: [String] = []
        if requiresHostControlPlane {
            names.append("host-control MCP server for \(hostControlTools.joined(separator: ", "))")
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
        let hostControlTools = HostControlPlaneMCPProjection.isEnabled(for: executionEnvironment)
            ? HostControlPlaneMCPProjection.toolNames
            : HostControlPlaneMCPProjection.requiredToolNames(
                capabilityScope: capabilityResolutionSnapshot.providerLaunch
            )
        return TaskRuntimeRequirementSet(
            hostControlTools: hostControlTools,
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

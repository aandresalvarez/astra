import Foundation
import ASTRACore
import ASTRAModels

enum TaskRuntimeIncompatibility: Equatable, Sendable {
    case runtimeUnavailable
    case missingHostControlPlane(requiredTools: [String])
    case missingDockerWorkspaceShell
    case missingBrowserControlTransport

    var userFacingName: String {
        switch self {
        case .runtimeUnavailable:
            return "runtime executable"
        case .missingHostControlPlane(let tools):
            return "host-control MCP server for \(tools.joined(separator: ", "))"
        case .missingDockerWorkspaceShell:
            return "Docker workspace shell MCP"
        case .missingBrowserControlTransport:
            return "browser control transport"
        }
    }
}

struct TaskRuntimeCompatibilityLaunchBlock: Equatable, Sendable {
    var stopReason: String
    var title: String
    var message: String
    var remediation: String
    var missingCapabilities: [String]
    /// The first candidate runtime that WOULD satisfy every requirement, when
    /// one exists — computed even though `respectExplicitRuntimeChoice`
    /// suppressed the automatic reroute to it. Powers a one-click "Switch to
    /// <runtime>" action instead of leaving the user to guess.
    var suggestedRuntime: AgentRuntimeID?
}

struct TaskRuntimeCompatibilityResolution: Equatable, Sendable {
    var requestedRuntime: AgentRuntimeID
    var selectedRuntime: AgentRuntimeID
    var reroutedFrom: AgentRuntimeID?
    var requirements: TaskRuntimeRequirementSet
    var incompatibilities: [AgentRuntimeID: [TaskRuntimeIncompatibility]]
    var launchBlock: TaskRuntimeCompatibilityLaunchBlock?
}

enum TaskRuntimeCompatibilityService {
    static let runtimeCapabilityIncompatibleReason = TaskRunStopReason.runtimeCapabilityIncompatible.rawValue

    static func resolve(
        requestedRuntime: AgentRuntimeID,
        defaultRuntime: AgentRuntimeID,
        requirements: TaskRuntimeRequirementSet,
        candidateRuntimes: [AgentRuntimeID] = AgentRuntimeAdapterRegistry.runtimeIDs,
        // When true, an incompatible *requested* runtime is never silently
        // rerouted to a fallback — it goes straight to `launchBlock` instead,
        // as if no fallback existed. This is for runtimes the user explicitly
        // picked (AgentTask.runtimeExplicitlySelected): overriding that choice
        // without telling them is worse than a clear, actionable block. A
        // runtime that reaches this resolver as a *default* (not explicitly
        // chosen) keeps today's silent-reroute behavior.
        respectExplicitRuntimeChoice: Bool = false,
        profile: (AgentRuntimeID) -> AgentRuntimeCapabilityProfile,
        isRuntimeUsable: (AgentRuntimeID) -> Bool
    ) -> TaskRuntimeCompatibilityResolution {
        guard !requirements.isEmpty else {
            return TaskRuntimeCompatibilityResolution(
                requestedRuntime: requestedRuntime,
                selectedRuntime: requestedRuntime,
                reroutedFrom: nil,
                requirements: requirements,
                incompatibilities: [:],
                launchBlock: nil
            )
        }

        var incompatibilities: [AgentRuntimeID: [TaskRuntimeIncompatibility]] = [:]
        if recordCompatibility(
            runtime: requestedRuntime,
            requirements: requirements,
            profile: profile(requestedRuntime),
            isRuntimeUsable: isRuntimeUsable(requestedRuntime),
            incompatibilities: &incompatibilities
        ) {
            return TaskRuntimeCompatibilityResolution(
                requestedRuntime: requestedRuntime,
                selectedRuntime: requestedRuntime,
                reroutedFrom: nil,
                requirements: requirements,
                incompatibilities: incompatibilities,
                launchBlock: nil
            )
        }

        // Always find the first compatible fallback (if any) so a block can
        // still suggest it, even when respectExplicitRuntimeChoice suppresses
        // the automatic switch.
        var firstCompatibleFallback: AgentRuntimeID?
        for runtime in orderedFallbackRuntimes(
            requestedRuntime: requestedRuntime,
            defaultRuntime: defaultRuntime,
            candidateRuntimes: candidateRuntimes
        ) {
            if recordCompatibility(
                runtime: runtime,
                requirements: requirements,
                profile: profile(runtime),
                isRuntimeUsable: isRuntimeUsable(runtime),
                incompatibilities: &incompatibilities
            ) {
                firstCompatibleFallback = runtime
                break
            }
        }

        if let fallback = firstCompatibleFallback, !respectExplicitRuntimeChoice {
            return TaskRuntimeCompatibilityResolution(
                requestedRuntime: requestedRuntime,
                selectedRuntime: fallback,
                reroutedFrom: requestedRuntime,
                requirements: requirements,
                incompatibilities: incompatibilities,
                launchBlock: nil
            )
        }

        return TaskRuntimeCompatibilityResolution(
            requestedRuntime: requestedRuntime,
            selectedRuntime: requestedRuntime,
            reroutedFrom: nil,
            requirements: requirements,
            incompatibilities: incompatibilities,
            launchBlock: launchBlock(
                for: requestedRuntime,
                requirements: requirements,
                incompatibilities: incompatibilities[requestedRuntime] ?? [],
                suggestedRuntime: firstCompatibleFallback
            )
        )
    }

    static func incompatibilities(
        runtime: AgentRuntimeID,
        requirements: TaskRuntimeRequirementSet,
        profile: AgentRuntimeCapabilityProfile,
        isRuntimeUsable: Bool
    ) -> [TaskRuntimeIncompatibility] {
        var missing: [TaskRuntimeIncompatibility] = []
        if !isRuntimeUsable {
            missing.append(.runtimeUnavailable)
        }
        if requirements.requiresHostControlPlane && !profile.canDeliverHostControlPlaneMCP {
            missing.append(.missingHostControlPlane(requiredTools: requirements.hostControlTools))
        }
        if requirements.requiresDockerWorkspaceShell && !profile.canDeliverDockerWorkspaceShellMCP {
            missing.append(.missingDockerWorkspaceShell)
        }
        if requirements.requiresBrowserControl && !profile.canUseBrowserBridgeTransport {
            missing.append(.missingBrowserControlTransport)
        }
        return missing
    }

    static func launchBlock(
        for runtime: AgentRuntimeID,
        requirements: TaskRuntimeRequirementSet,
        incompatibilities: [TaskRuntimeIncompatibility],
        suggestedRuntime: AgentRuntimeID? = nil
    ) -> TaskRuntimeCompatibilityLaunchBlock {
        let missing = missingCapabilityNames(
            requirements: requirements,
            incompatibilities: incompatibilities
        )
        let remediation = suggestedRuntime.map { "Switch to \($0.displayName)." }
            ?? "Switch to a compatible runtime such as Codex CLI, Claude Code, or a Copilot CLI build with task-scoped MCP config support."
        return TaskRuntimeCompatibilityLaunchBlock(
            stopReason: runtimeCapabilityIncompatibleReason,
            title: "Selected runtime is incompatible with required ASTRA capabilities",
            message: "\(runtime.displayName) cannot satisfy: \(missing.joined(separator: ", ")).",
            remediation: remediation,
            missingCapabilities: missing,
            suggestedRuntime: suggestedRuntime
        )
    }

    private static func recordCompatibility(
        runtime: AgentRuntimeID,
        requirements: TaskRuntimeRequirementSet,
        profile: AgentRuntimeCapabilityProfile,
        isRuntimeUsable: Bool,
        incompatibilities: inout [AgentRuntimeID: [TaskRuntimeIncompatibility]]
    ) -> Bool {
        let missing = self.incompatibilities(
            runtime: runtime,
            requirements: requirements,
            profile: profile,
            isRuntimeUsable: isRuntimeUsable
        )
        incompatibilities[runtime] = missing
        return missing.isEmpty
    }

    private static func orderedFallbackRuntimes(
        requestedRuntime: AgentRuntimeID,
        defaultRuntime: AgentRuntimeID,
        candidateRuntimes: [AgentRuntimeID]
    ) -> [AgentRuntimeID] {
        var seen: Set<AgentRuntimeID> = [requestedRuntime]
        var ordered: [AgentRuntimeID] = []
        for runtime in [defaultRuntime, .codexCLI, .claudeCode, .copilotCLI] + candidateRuntimes {
            guard seen.insert(runtime).inserted else { continue }
            ordered.append(runtime)
        }
        return ordered
    }

    private static func missingCapabilityNames(
        requirements: TaskRuntimeRequirementSet,
        incompatibilities: [TaskRuntimeIncompatibility]
    ) -> [String] {
        let capabilityNames = incompatibilities.map(\.userFacingName)
        if !capabilityNames.isEmpty {
            return capabilityNames
        }
        return requirements.missingCapabilityNames
    }
}

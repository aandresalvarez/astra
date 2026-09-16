import Foundation
import ASTRACore
import ASTRAModels

enum TaskRuntimeIncompatibility: Equatable, Sendable {
    case runtimeUnavailable
    case missingHostControlPlane(requiredTools: [String])
    case hostControlBrokerUnavailable
    case missingDockerWorkspaceShell
    case missingBrowserControlTransport
    /// The provider itself refuses to run MCP servers, so every ASTRA
    /// capability that rides on one is unreachable no matter what ASTRA
    /// renders into the launch manifest.
    case providerMCPServersDisabled(policyName: String?)
    case policyBlocked(reason: String)
    case invalidLaunchResourceContract(reason: String)

    var userFacingName: String {
        switch self {
        case .runtimeUnavailable:
            return "runtime executable"
        case .missingHostControlPlane(let tools):
            return "ASTRA host tools for \(tools.joined(separator: ", "))"
        case .hostControlBrokerUnavailable:
            return "ASTRA host-control helper"
        case .missingDockerWorkspaceShell:
            return "Docker workspace shell MCP"
        case .missingBrowserControlTransport:
            return "browser control transport"
        case .providerMCPServersDisabled(let policyName):
            return policyName.map { "ASTRA connectors (blocked by Codex policy \"\($0)\")" }
                ?? "ASTRA connectors (blocked by your organization's Codex policy)"
        case .policyBlocked(let reason), .invalidLaunchResourceContract(let reason):
            return reason
        }
    }

    /// Plain-language wording for a block whose real cause is outside ASTRA.
    /// The generic "cannot satisfy: <capability list>" phrasing reads as if
    /// ASTRA were missing a feature, which sends the user looking in the wrong
    /// place; this says who refused and what to do instead. Returns nil for
    /// every incompatibility the generic phrasing already describes correctly.
    func launchBlockPhrasing(
        runtime: AgentRuntimeID,
        suggestedRuntime: AgentRuntimeID?
    ) -> (message: String, remediation: String)? {
        guard case .providerMCPServersDisabled(let policyName) = self else { return nil }
        let policy = policyName.map { "your organization's Codex policy (\"\($0)\")" }
            ?? "your organization's Codex policy"
        let ask = "ask your Codex administrator to allow ASTRA's MCP server"
        return (
            message: "\(runtime.displayName) cannot use ASTRA's connectors: \(policy) disables all MCP servers.",
            remediation: suggestedRuntime.map { "Run this task on \($0.displayName), or \(ask)." }
                ?? "\(ask.prefix(1).uppercased())\(ask.dropFirst())."
        )
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
        isRuntimeUsable: Bool,
        isHostControlBrokerAvailable: Bool = true
    ) -> [TaskRuntimeIncompatibility] {
        var missing: [TaskRuntimeIncompatibility] = []
        if !isRuntimeUsable {
            missing.append(.runtimeUnavailable)
        }
        if let refusal = providerMCPRefusal(requirements: requirements, profile: profile) {
            // Report the cause, not its symptoms. Listing "ASTRA host tools for
            // jira" and "Docker workspace shell MCP" separately would describe
            // two ASTRA gaps when there is one provider refusal, and would send
            // the reader looking for a fix inside ASTRA.
            missing.append(refusal)
            return missing
        }
        if requirements.requiresHostControlPlane && !profile.canDeliverHostControlPlane {
            missing.append(.missingHostControlPlane(requiredTools: requirements.hostControlTools))
        }
        if requirements.requiresHostControlPlane,
           profile.canDeliverHostControlPlane,
           !isHostControlBrokerAvailable {
            missing.append(.hostControlBrokerUnavailable)
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
        let phrasing = incompatibilities.compactMap {
            $0.launchBlockPhrasing(runtime: runtime, suggestedRuntime: suggestedRuntime)
        }.first
        let remediation = phrasing?.remediation
            ?? suggestedRuntime.map { "Switch to \($0.displayName)." }
            ?? "Switch to a runtime that can attach ASTRA host tools."
        return TaskRuntimeCompatibilityLaunchBlock(
            stopReason: stopReason(for: runtime, incompatibilities: incompatibilities),
            title: "Selected runtime is incompatible with required ASTRA capabilities",
            message: phrasing?.message
                ?? "\(runtime.displayName) cannot satisfy: \(missing.joined(separator: ", ")).",
            remediation: remediation,
            missingCapabilities: missing,
            suggestedRuntime: suggestedRuntime
        )
    }

    static func stopReason(
        for runtime: AgentRuntimeID,
        incompatibilities: [TaskRuntimeIncompatibility]
    ) -> String {
        guard incompatibilities == [.runtimeUnavailable] else {
            return runtimeCapabilityIncompatibleReason
        }
        return AgentRuntimeAdapterRegistry.adapter(for: runtime)
            .missingExecutableStopReason()
            ?? runtimeCapabilityIncompatibleReason
    }

    /// The provider refuses MCP servers *and* this turn needs one. Both halves
    /// matter: a refusal only blocks a launch when a required capability has no
    /// other route, so a turn that never asked for a connector still runs, and
    /// a runtime that carries host control over a CLI relay is unaffected.
    /// Browser control is deliberately absent — it has a shell transport.
    private static func providerMCPRefusal(
        requirements: TaskRuntimeRequirementSet,
        profile: AgentRuntimeCapabilityProfile
    ) -> TaskRuntimeIncompatibility? {
        guard profile.providerMCPPolicy.refusesServers,
              profile.hasTaskScopedMCPDeliveryMechanism else { return nil }
        let needsMCP = (requirements.requiresHostControlPlane && !profile.supportsHostControlCLIRelay)
            || requirements.requiresDockerWorkspaceShell
        guard needsMCP else { return nil }
        return .providerMCPServersDisabled(policyName: profile.providerMCPPolicy.policyName)
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

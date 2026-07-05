import Foundation
import ASTRACore

enum AgentRuntimeCapabilityCompatibilityPolicy {
    enum Requirement: Equatable {
        case hostControlPlane(requiredTools: [String])
    }

    struct LaunchBlock: Equatable {
        let stopReason: TaskRunStopReason
        let title: String
        let message: String
        let remediation: String
        let requiredTools: [String]

        var eventPayload: String {
            """
            Selected runtime is incompatible with required ASTRA capabilities.
            - \(title): \(message) Remediation: \(remediation)
            """
        }
    }

    struct LaunchRuntimeResolution: Equatable {
        let requestedRuntime: AgentRuntimeID
        let runtime: AgentRuntimeID
        let requiredTools: [String]

        var rerouted: Bool {
            runtime != requestedRuntime
        }
    }

    static func launchBlock(
        runtime: AgentRuntimeID,
        task: AgentTask,
        capabilityResolutionSnapshot: TaskCapabilityResolutionSnapshot
    ) -> LaunchBlock? {
        for requirement in requirements(
            task: task,
            capabilityResolutionSnapshot: capabilityResolutionSnapshot
        ) {
            if let block = launchBlock(runtime: runtime, requirement: requirement) {
                return block
            }
        }
        return nil
    }

    static func requirements(
        task: AgentTask,
        capabilityResolutionSnapshot: TaskCapabilityResolutionSnapshot
    ) -> [Requirement] {
        let executionEnvironment = DockerExecutionPlanner.resolveEnvironment(for: task)
        let requiredTools = HostControlPlaneMCPProjection.enabledToolNames(
            task: task,
            environment: executionEnvironment,
            capabilityScope: capabilityResolutionSnapshot.providerLaunch
        )
        guard !requiredTools.isEmpty else {
            return []
        }
        return [.hostControlPlane(requiredTools: requiredTools)]
    }

    static func resolveLaunchRuntime(
        requestedRuntime: AgentRuntimeID,
        defaultRuntime: AgentRuntimeID,
        task: AgentTask,
        capabilityResolutionSnapshot: TaskCapabilityResolutionSnapshot,
        candidateRuntimes: [AgentRuntimeID] = AgentRuntimeAdapterRegistry.runtimeIDs,
        isRuntimeUsable: (AgentRuntimeID) -> Bool = { _ in true }
    ) -> LaunchRuntimeResolution {
        let requirements = requirements(
            task: task,
            capabilityResolutionSnapshot: capabilityResolutionSnapshot
        )
        let requiredTools = requirements.flatMap { requirement -> [String] in
            switch requirement {
            case .hostControlPlane(let tools):
                return tools
            }
        }
        guard !requirements.isEmpty,
              !isRuntimeCompatible(requestedRuntime, requirements: requirements) else {
            return LaunchRuntimeResolution(
                requestedRuntime: requestedRuntime,
                runtime: requestedRuntime,
                requiredTools: requiredTools
            )
        }

        let fallback = orderedFallbackRuntimes(
            requestedRuntime: requestedRuntime,
            defaultRuntime: defaultRuntime,
            candidateRuntimes: candidateRuntimes
        )
        .first { runtime in
            isRuntimeUsable(runtime) && isRuntimeCompatible(runtime, requirements: requirements)
        }

        return LaunchRuntimeResolution(
            requestedRuntime: requestedRuntime,
            runtime: fallback ?? requestedRuntime,
            requiredTools: requiredTools
        )
    }

    private static func launchBlock(
        runtime: AgentRuntimeID,
        requirement: Requirement
    ) -> LaunchBlock? {
        switch requirement {
        case .hostControlPlane(let requiredTools):
            return hostControlPlaneLaunchBlock(runtime: runtime, requiredTools: requiredTools)
        }
    }

    private static func isRuntimeCompatible(
        _ runtime: AgentRuntimeID,
        requirements: [Requirement]
    ) -> Bool {
        requirements.allSatisfy { launchBlock(runtime: runtime, requirement: $0) == nil }
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

    private static func hostControlPlaneLaunchBlock(
        runtime: AgentRuntimeID,
        requiredTools: [String]
    ) -> LaunchBlock? {
        guard !HostControlPlaneMCPProjection.supportsHostControlPlane(runtime: runtime),
              let stopReason = TaskRunStopReason.custom(HostControlPlaneRuntimeLaunchGuard.missingHostControlMCPReason) else {
            return nil
        }
        return LaunchBlock(
            stopReason: stopReason,
            title: "Host control-plane route is unavailable",
            message: HostControlPlaneRuntimeLaunchGuard.unsupportedRuntimeDetail(
                runtime: runtime,
                requiredTools: requiredTools
            ),
            remediation: HostControlPlaneRuntimeLaunchGuard.unsupportedRuntimeRemediation(
                requiredTools: requiredTools
            ),
            requiredTools: requiredTools
        )
    }
}

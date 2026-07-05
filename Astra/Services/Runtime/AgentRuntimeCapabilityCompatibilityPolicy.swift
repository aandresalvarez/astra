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

    static func launchBlock(
        runtime: AgentRuntimeID,
        capabilityResolutionSnapshot: TaskCapabilityResolutionSnapshot
    ) -> LaunchBlock? {
        for requirement in requirements(capabilityResolutionSnapshot: capabilityResolutionSnapshot) {
            if let block = launchBlock(runtime: runtime, requirement: requirement) {
                return block
            }
        }
        return nil
    }

    static func requirements(
        capabilityResolutionSnapshot: TaskCapabilityResolutionSnapshot
    ) -> [Requirement] {
        let requiredTools = HostControlPlaneMCPProjection.requiredToolNames(
            capabilityScope: capabilityResolutionSnapshot.providerLaunch
        )
        guard !requiredTools.isEmpty else {
            return []
        }
        return [.hostControlPlane(requiredTools: requiredTools)]
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

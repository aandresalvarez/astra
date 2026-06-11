import Foundation
import ASTRACore

/// Honest, per-(runtime, policy) statement of how much of the "Ask" promise
/// ASTRA can actually keep — so the UI never implies parity the code can't
/// deliver. Two facts decide it: whether ASTRA owns live per-action approvals
/// for this runtime (the stdio control channel — Claude only today), and
/// whether a kernel Seatbelt floor backstops the run.
struct AskCoverageBadge: Equatable {
    enum Tier: String, Equatable {
        /// ASTRA live approvals + kernel floor.
        case guaranteed
        /// ASTRA live approvals, no kernel floor.
        case bestEffort
        /// No ASTRA live approvals — the provider decides asks; ASTRA gates at
        /// run boundaries and (when the floor is active) the kernel backstops.
        case providerManaged
    }

    let tier: Tier
    let hasLiveApprovals: Bool
    let hasKernelFloor: Bool

    var label: String {
        switch tier {
        case .guaranteed: "Guaranteed"
        case .bestEffort: "Best-effort"
        case .providerManaged: "Provider-managed"
        }
    }

    var symbolName: String {
        switch tier {
        case .guaranteed: "checkmark.shield.fill"
        case .bestEffort: "shield.lefthalf.filled"
        case .providerManaged: "shield"
        }
    }

    /// One-line, plain-language explanation for a tooltip / detail row.
    var detail: String {
        switch tier {
        case .guaranteed:
            "ASTRA asks you before each risky action, and the macOS sandbox confines file writes if anything slips past."
        case .bestEffort:
            "ASTRA asks you before each risky action, but the macOS sandbox floor is off, so a bypass isn't kernel-confined."
        case .providerManaged:
            hasKernelFloor
                ? "This runtime decides its own permission prompts; ASTRA gates between steps and the macOS sandbox confines file writes."
                : "This runtime decides its own permission prompts and ASTRA's sandbox floor is off; only run-boundary gating applies."
        }
    }

    static func resolve(
        runtime: AgentRuntimeID,
        permissionPolicy: PermissionPolicy,
        sandboxSettings: ExecutionSandboxSettings
    ) -> AskCoverageBadge {
        let liveApprovals = PlanCheckpointPolicy.tier(for: runtime) == .liveApprovals
            && permissionPolicy != .autonomous
        let kernelFloor = sandboxSettings.shouldWrap(runtime: runtime)

        let tier: Tier
        switch (liveApprovals, kernelFloor) {
        case (true, true): tier = .guaranteed
        case (true, false): tier = .bestEffort
        case (false, _): tier = .providerManaged
        }
        return AskCoverageBadge(tier: tier, hasLiveApprovals: liveApprovals, hasKernelFloor: kernelFloor)
    }

    @MainActor
    static func resolve(for task: AgentTask, permissionPolicy: PermissionPolicy) -> AskCoverageBadge {
        resolve(
            runtime: AgentRuntimeAdapterRegistry.registeredRuntime(rawValue: task.runtimeID),
            permissionPolicy: permissionPolicy,
            sandboxSettings: ExecutionSandboxSettings.current(permissionPolicy: permissionPolicy)
        )
    }
}

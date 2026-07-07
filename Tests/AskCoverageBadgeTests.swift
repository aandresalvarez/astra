import Foundation
import Testing
@testable import ASTRA
import ASTRACore

@Suite("Ask coverage badge")
struct AskCoverageBadgeTests {
    private func settings(wrapping runtimes: Set<AgentRuntimeID>) -> ExecutionSandboxSettings {
        ExecutionSandboxSettings(enforcement: .strict, wrappedRuntimes: runtimes, allowNetwork: true)
    }

    @Test("Claude in Ask with the floor on is Guaranteed")
    func claudeAskWithFloorGuaranteed() {
        let badge = AskCoverageBadge.resolve(
            runtime: .claudeCode,
            permissionPolicy: .restricted,
            sandboxSettings: settings(wrapping: [.claudeCode])
        )
        #expect(badge.tier == .guaranteed)
        #expect(badge.hasLiveApprovals)
        #expect(badge.hasKernelFloor)
    }

    @Test("Claude in Ask with the floor off is Best-effort")
    func claudeAskNoFloorBestEffort() {
        let badge = AskCoverageBadge.resolve(
            runtime: .claudeCode,
            permissionPolicy: .restricted,
            sandboxSettings: settings(wrapping: [])
        )
        #expect(badge.tier == .bestEffort)
        #expect(badge.hasLiveApprovals)
        #expect(!badge.hasKernelFloor)
    }

    @Test("Non-live runtime is Provider-managed; floor flips only the detail")
    func nonLiveProviderManaged() {
        let withFloor = AskCoverageBadge.resolve(
            runtime: .codexCLI,
            permissionPolicy: .restricted,
            sandboxSettings: settings(wrapping: [.codexCLI])
        )
        #expect(withFloor.tier == .providerManaged)
        #expect(withFloor.hasKernelFloor)
        #expect(withFloor.detail.contains("confines file writes"))

        let withoutFloor = AskCoverageBadge.resolve(
            runtime: .codexCLI,
            permissionPolicy: .restricted,
            sandboxSettings: settings(wrapping: [])
        )
        #expect(withoutFloor.tier == .providerManaged)
        #expect(!withoutFloor.hasKernelFloor)
        #expect(withoutFloor.detail.contains("only run-boundary gating"))
    }

    @Test("Auto mode is never live approvals (channel isn't opened)")
    func autoModeNotLive() {
        // Even Claude: autonomous uses --dangerously-skip-permissions, so there
        // is no live ask channel — the badge must not claim live approvals.
        let badge = AskCoverageBadge.resolve(
            runtime: .claudeCode,
            permissionPolicy: .autonomous,
            sandboxSettings: settings(wrapping: [.claudeCode])
        )
        #expect(!badge.hasLiveApprovals)
        #expect(badge.tier == .providerManaged)
        // Autonomous escalates ANY non-strict enforcement (including a user-set
        // .off) to strict, so the strict kernel floor always holds for Auto runs.
        #expect(badge.hasKernelFloor)
    }

    @Test("Best-effort enforcement is not a guaranteed floor (it can silently fall back)")
    func bestEffortEnforcementNoGuaranteedFloor() {
        // shouldWrap(claudeCode) is true, but enforcement is best-effort: the
        // Seatbelt wrap can fall back to an unconfined run when it can't apply, so
        // the badge must not claim a floor or the Guaranteed tier — only strict
        // enforcement is a hard kernel guarantee.
        let bestEffort = ExecutionSandboxSettings(
            enforcement: .bestEffort, wrappedRuntimes: [.claudeCode], allowNetwork: true
        )
        let badge = AskCoverageBadge.resolve(
            runtime: .claudeCode,
            permissionPolicy: .restricted,
            sandboxSettings: bestEffort
        )
        #expect(badge.hasLiveApprovals)
        #expect(!badge.hasKernelFloor)
        #expect(badge.tier == .bestEffort)
    }

    @Test("Every tier has a non-empty label, symbol, and detail")
    func presentationComplete() {
        for policy in [PermissionPolicy.restricted, .interactive, .autonomous] {
            for runtime in [AgentRuntimeID.claudeCode, .codexCLI, .copilotCLI] {
                let badge = AskCoverageBadge.resolve(
                    runtime: runtime,
                    permissionPolicy: policy,
                    sandboxSettings: settings(wrapping: [runtime])
                )
                #expect(!badge.label.isEmpty)
                #expect(!badge.symbolName.isEmpty)
                #expect(!badge.detail.isEmpty)
            }
        }
    }
}

import Foundation
import Testing
import ASTRAModels
import ASTRACore
@testable import ASTRA

/// Which runtimes ASTRA's Seatbelt wraps by default. Antigravity's own
/// `--sandbox` restricts only its terminal, so unlike Codex and Cursor it needs
/// ASTRA's wrap at every level for a write outside the workspace to be denied.
@Suite("Execution sandbox: Antigravity wrap")
struct ExecutionSandboxAntigravityWrapTests {
    @Test("Antigravity is wrapped at every level by default")
    func wrappedAtEveryLevel() {
        let defaults = InMemoryDefaults()

        for policy in [PermissionPolicy.restricted, .interactive, .autonomous] {
            let resolved = ExecutionSandboxSettings.current(permissionPolicy: policy, defaults: defaults)
            #expect(resolved.shouldWrap(runtime: .antigravityCLI), "Antigravity \(policy)")
        }
    }

    @Test("Codex and Cursor stay unwrapped below Auto because their sandboxes confine file writes")
    func codexAndCursorStayUnwrappedBelowAuto() {
        let defaults = InMemoryDefaults()

        let ask = ExecutionSandboxSettings.current(permissionPolicy: .restricted, defaults: defaults)
        #expect(!ask.shouldWrap(runtime: .codexCLI))
        #expect(!ask.shouldWrap(runtime: .cursorCLI))
    }

    @Test("The user's explicit Off still disables the wrap")
    func explicitOffStillWins() {
        let defaults = InMemoryDefaults()
        defaults.set(ExecutionSandboxEnforcement.off.rawValue, forKey: AppStorageKeys.sandboxEnforcement)

        let off = ExecutionSandboxSettings.current(permissionPolicy: .restricted, defaults: defaults)
        #expect(!off.shouldWrap(runtime: .antigravityCLI))
    }

    // MARK: - When the sandbox cannot be applied

    @Test("Below Auto, Antigravity is blocked rather than run unconfined when the sandbox cannot apply")
    func blockedBelowAutoWhenTheSandboxCannotApply() {
        let defaults = InMemoryDefaults()

        for policy in [PermissionPolicy.restricted, .interactive] {
            let settings = ExecutionSandboxSettings.current(permissionPolicy: policy, defaults: defaults)
            let decision = decide(runtime: .antigravityCLI, workspace: "/", settings: settings)
            #expect(decision == .failClosed(reason: "unsafe_execution_path"), "Antigravity \(policy)")
        }
    }

    @Test("In Auto the fallback still proceeds, as before")
    func autoStillFallsBack() {
        let defaults = InMemoryDefaults()
        let settings = ExecutionSandboxSettings.current(permissionPolicy: .autonomous, defaults: defaults)

        let decision = decide(runtime: .antigravityCLI, workspace: "/", settings: settings)

        #expect(decision == .fallback(reason: "unsafe_execution_path"))
    }

    @Test("Other wrapped runtimes keep falling back below Auto")
    func otherRuntimesKeepFallingBack() {
        let defaults = InMemoryDefaults()
        let settings = ExecutionSandboxSettings.current(permissionPolicy: .restricted, defaults: defaults)

        for runtime in [AgentRuntimeID.claudeCode, .copilotCLI, .openCodeCLI] {
            let decision = decide(runtime: runtime, workspace: "/", settings: settings)
            #expect(decision == .fallback(reason: "unsafe_execution_path"), "\(runtime.rawValue)")
        }
    }

    @Test("The queue admission snapshot keeps the block when it changes the enforcement")
    func admissionSnapshotKeepsTheBlock() {
        let defaults = InMemoryDefaults()
        defaults.set(ExecutionSandboxEnforcement.off.rawValue, forKey: AppStorageKeys.sandboxEnforcement)
        let stored = ExecutionSandboxSettings.current(permissionPolicy: .restricted, defaults: defaults)

        let admitted = stored.applyingAdmissionSnapshot(.bestEffort, permissionPolicy: .restricted)

        #expect(decide(runtime: .antigravityCLI, workspace: "/", settings: admitted)
            == .failClosed(reason: "unsafe_execution_path"))
    }

    // MARK: - What the user is told

    @Test("The Ask badge counts the wrap as a kernel floor for Antigravity even under best-effort")
    func askBadgeCountsTheFailClosedWrap() {
        let defaults = InMemoryDefaults()
        let ask = ExecutionSandboxSettings.current(permissionPolicy: .restricted, defaults: defaults)

        let antigravity = AskCoverageBadge.resolve(
            runtime: .antigravityCLI, permissionPolicy: .restricted, sandboxSettings: ask
        )
        #expect(antigravity.hasKernelFloor)

        // A wrapped runtime that still falls back has no guaranteed floor under best-effort.
        let claude = AskCoverageBadge.resolve(
            runtime: .claudeCode, permissionPolicy: .restricted, sandboxSettings: ask
        )
        #expect(!claude.hasKernelFloor)

        // Auto drops the block, so there is no guarantee to claim.
        let auto = ExecutionSandboxSettings.current(permissionPolicy: .autonomous, defaults: defaults)
        let autoAntigravity = AskCoverageBadge.resolve(
            runtime: .antigravityCLI, permissionPolicy: .autonomous, sandboxSettings: auto
        )
        #expect(!autoAntigravity.hasKernelFloor)
    }

    @Test("A strict block points at the sandbox setting, since switching to Auto would not unblock it")
    func strictBlockPointsAtTheSetting() {
        let message = blockedMessage(enforcement: .strict)

        #expect(message?.contains("strict") == true)
        #expect(message?.contains("Auto") == false)
        #expect(message?.contains("sandbox enforcement") == true)
    }

    @Test("A best-effort block offers a narrower workspace or Auto, and does not claim strict is on")
    func bestEffortBlockOffersAutoOrANarrowerWorkspace() {
        let message = blockedMessage(enforcement: .bestEffort)

        #expect(message?.contains("strict") == false)
        #expect(message?.contains("narrower workspace") == true)
        #expect(message?.contains("Auto") == true)
    }

    @Test("A utility block never offers Auto, since utility runs use a fixed restricted policy")
    func utilityBlockDoesNotOfferAuto() {
        let bestEffort = blockedMessage(enforcement: .bestEffort, isUtility: true)
        #expect(bestEffort?.contains("Auto") == false)
        #expect(bestEffort?.contains("narrower workspace") == true)

        let strict = blockedMessage(enforcement: .strict, isUtility: true)
        #expect(strict?.contains("Auto") == false)
        #expect(strict?.contains("sandbox enforcement") == true)
    }

    @Test("A missing sandbox-exec is not fixed by a narrower workspace; the message says what is")
    func missingSandboxExecGetsAMatchingRecovery() {
        for (enforcement, isUtility) in [
            (ExecutionSandboxEnforcement.bestEffort, false),
            (.bestEffort, true),
            (.strict, false)
        ] {
            let message = blockedMessage(enforcement: enforcement, isUtility: isUtility, reason: "sandbox_exec_missing")
            #expect(message?.contains("narrower workspace") == false, "\(enforcement) utility=\(isUtility)")
            #expect(message?.contains("sandbox-exec") == true, "\(enforcement) utility=\(isUtility)")
        }

        // Below strict the user can also turn the sandbox off; Auto only for non-utility runs.
        let bestEffort = blockedMessage(enforcement: .bestEffort, reason: "sandbox_exec_missing")
        #expect(bestEffort?.contains("turn the execution sandbox off") == true)
        #expect(bestEffort?.contains("Auto") == true)
        let utility = blockedMessage(enforcement: .bestEffort, isUtility: true, reason: "sandbox_exec_missing")
        #expect(utility?.contains("turn the execution sandbox off") == true)
        #expect(utility?.contains("Auto") == false)
    }

    @Test("A path-related block still offers a narrower workspace and, below strict, turning the sandbox off")
    func pathBlockOffersANarrowerWorkspace() {
        let message = blockedMessage(enforcement: .bestEffort, reason: "no_execution_path")

        #expect(message?.contains("narrower workspace") == true)
        #expect(message?.contains("turn the execution sandbox off") == true)
    }

    @Test("The Best effort help text names the Antigravity exception to its unconfined fallback")
    func bestEffortHelpTextMentionsTheException() {
        let text = ExecutionSandboxEnforcement.bestEffort.helpText

        #expect(text.contains("Antigravity"))
        #expect(text.contains("blocked"))
    }

    private func makePlan(runtime: AgentRuntimeID, workspace: String) -> AgentRuntimeProcessLaunchPlan {
        AgentRuntimeProcessLaunchPlan(
            runtime: runtime,
            executablePath: "/usr/bin/true",
            arguments: [],
            currentDirectory: workspace,
            environment: ["HOME": "/tmp/astra-home"],
            browserShimDirectory: nil,
            providerVersion: nil,
            parsesJSONLines: false,
            directoriesToCreate: [],
            sandboxReadablePaths: [],
            sandboxProtectedWriteDenyPaths: [],
            providerDetectedFields: [:],
            commandPlannedFields: [:],
            pathMapper: nil,
            executionEnvironment: .host
        )
    }

    private func decide(
        runtime: AgentRuntimeID,
        workspace: String,
        settings: ExecutionSandboxSettings
    ) -> ExecutionSandboxDecision {
        ExecutionSandbox.decide(
            plan: makePlan(runtime: runtime, workspace: workspace),
            providerHomeDirectory: "",
            settings: settings
        )
    }

    private func blockedMessage(
        enforcement: ExecutionSandboxEnforcement,
        isUtility: Bool = false,
        reason: String = "unsafe_execution_path"
    ) -> String? {
        let outcome = AgentRuntimeProcessRunner.sandboxOutcome(
            for: .failClosed(reason: reason),
            originalPlan: makePlan(runtime: .antigravityCLI, workspace: "/"),
            enforcement: enforcement,
            isUtility: isUtility
        )
        guard case .blocked(let result) = outcome else { return nil }
        return result.runtimeStopMessage
    }
}

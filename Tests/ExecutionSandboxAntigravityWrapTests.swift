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

    private func decide(
        runtime: AgentRuntimeID,
        workspace: String,
        settings: ExecutionSandboxSettings
    ) -> ExecutionSandboxDecision {
        let plan = AgentRuntimeProcessLaunchPlan(
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
        return ExecutionSandbox.decide(plan: plan, providerHomeDirectory: "", settings: settings)
    }
}

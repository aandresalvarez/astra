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
}

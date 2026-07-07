import ASTRACore
import AstraTestSeamBootstrap
import Testing
@testable import ASTRA

/// Process-wide seam registration for the ASTRATests bundle, called from the
/// load-time constructor in `Tests/AstraTestSeamBootstrap` — dyld runs it
/// when it loads the test bundle, before either XCTest or Swift Testing
/// schedules a suite, while the process is still single-threaded.
///
/// This replaces the per-suite guard pattern (a stored `Void` property whose
/// initializer called `RuntimeSeamRegistration.registerAll()`), which was a
/// scheduling roulette under Swift Testing's parallel execution: far more
/// suites transitively read a seam (Connector credential paths, Skill
/// environment variables, `TaskRoleProfile.runtime`, task fork/output
/// discovery, `WorkspaceConfigManager.importWorkspace`, ...) than ever
/// carried the guard, so whether an unguarded suite crashed the whole test
/// process depended on which suite the scheduler happened to run first. A
/// load-time constructor cannot lose that race.
///
/// The architecture-fitness test "Runtime seam registration stays wired
/// through the load-time test bootstrap" pins this file, the C target, and
/// the Package.swift wiring to each other, and keeps per-suite registration
/// from creeping back.
@_cdecl("astra_test_register_runtime_seams")
public func astraTestRegisterRuntimeSeams() {
    // Force-links the C archive member that carries the constructor — see
    // astra_test_seam_bootstrap_force_link's doc comment.
    astra_test_seam_bootstrap_force_link()
    RuntimeSeamRegistration.registerAll()
}

@Suite("Runtime seam test bootstrap")
struct RuntimeSeamTestBootstrapTests {
    @Test("Seams are registered by the load-time bootstrap, not by suites")
    func seamsRegisteredBeforeAnySuite() {
        // No suite in this target calls RuntimeSeamRegistration.registerAll()
        // (fitness-enforced), so a registered seam here proves the C
        // constructor ran when the bundle loaded.
        #expect(AgentRuntimeRegistrySeam.currentIfRegistered != nil)
    }
}

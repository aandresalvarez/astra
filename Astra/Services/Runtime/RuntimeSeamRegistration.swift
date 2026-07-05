import ASTRACore

/// Wires the `ExecutionPathSafety`/`AgentRuntimeRegistrySeam` seams declared
/// in `ASTRACore/RuntimeSeams.swift` to their real, Runtime-owned
/// implementations (`ExecutionSandbox`, `AgentRuntimeAdapterRegistry`).
///
/// Swift has no module-load hook (no ObjC-style `+load`, and a library
/// target's top-level/static declarations are not run eagerly just by being
/// linked in — verified before choosing this design), so this must be called
/// explicitly, once, before either seam is read:
///  - Production: `ASTRAApp.init()` calls it.
///  - Tests: any test that constructs a `WorkspaceExecutionEnvironment` with a
///    non-empty `credentialProjections` list, or reads
///    `TaskRoleProfile.runtime`, calls it at the top of the test (or suite
///    `init`). Both seam accessors trap with a clear message if read before
///    registration, so a future test that hits either path without calling
///    this fails loudly instead of silently misbehaving.
///
/// Idempotent — safe to call more than once (e.g. once per test file).
enum RuntimeSeamRegistration {
    static func registerAll() {
        ExecutionPathSafety.checker = ExecutionSandbox.self
        AgentRuntimeRegistrySeam.lookup = AgentRuntimeAdapterRegistry.self
    }
}

extension ExecutionSandbox: ExecutionPathSafetyChecking {}

extension AgentRuntimeAdapterRegistry: AgentRuntimeRegistryLookup {}

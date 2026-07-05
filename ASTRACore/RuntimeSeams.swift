import Foundation

// MARK: - Runtime↔Models cycle break (Track A2)
//
// Two value types that moved here from the app target as part of breaking the
// Models↔Runtime cycle (`WorkspaceExecutionEnvironment`'s credential-projection
// sanitizer, `TaskRoleProfile.runtime`) need small pieces of behavior that only
// the app target's `Astra/Services/Runtime/*.swift` can provide: (1) whether a
// filesystem path is safe to trust as a credential source (the sandbox's
// broad-root/canonicalization policy), and (2) resolving a raw runtime-ID
// string against the live set of registered provider adapters. Both are
// backed by substantial, genuinely Runtime-specific state (a ~1,070-line
// sandbox-exec policy engine; a 6-provider adapter catalog) that must not be
// duplicated or relocated here — so ASTRACore declares the seam only, and the
// app target's `ExecutionSandbox` / `AgentRuntimeAdapterRegistry` conform.
//
// Swift has no module-load hook (no ObjC-style `+load`, no guaranteed
// eager top-level initializers in a library target — verified empirically
// before choosing this design), so registration is **explicit, not
// automatic**: `Astra/Services/Runtime/RuntimeSeamRegistration.swift` exposes
// `RuntimeSeamRegistration.registerAll()`, called from `ASTRAApp.init()` for
// the shipping app. Test targets that exercise the gated paths call it too
// (see the call sites next to `@testable import ASTRA` in
// `ExecutionEnvironmentTests.swift`, `AgentPolicyTests.swift`,
// `AgentRuntimeAdapterTests.swift`, `RealProviderSmokeTests.swift`,
// `TaskLaunchResourcePlanTests.swift`, `ProcessMonitorTests.swift`).
// Accessing either seam before registration is a programmer error, not a
// silently-degraded security check: both trap with `preconditionFailure`
// rather than failing open or returning a guessed answer.
public enum ExecutionPathSafety {
    /// Set once by `RuntimeSeamRegistration.registerAll()`.
    public static var checker: (any ExecutionPathSafetyChecking.Type)?

    /// Fail-fast accessor. Traps if `registerAll()` has not run yet — this
    /// path is only reached when constructing a `WorkspaceExecutionEnvironment`
    /// with a non-empty `credentialProjections` list, never during plain JSON
    /// decode/encode (`Codable` is synthesized; the sanitizer only runs from
    /// the memberwise `init`/`setCredentialProjections`).
    public static var required: any ExecutionPathSafetyChecking.Type {
        guard let checker else {
            preconditionFailure(
                "ExecutionPathSafety.checker read before RuntimeSeamRegistration.registerAll() ran. " +
                "Call it in ASTRAApp.init() (already done) or at the top of the test that hit this path."
            )
        }
        return checker
    }
}

/// Whether a filesystem path is safe to trust as a mounted-credential source
/// (e.g. GCP Application Default Credentials). Backed by
/// `ExecutionSandbox`'s broad-root denylist and path canonicalization.
public protocol ExecutionPathSafetyChecking {
    static func canonicalize(_ rawPath: String) -> String?
    static func isForbiddenReadableRoot(_ canonicalRoot: String) -> Bool
    static func isForbiddenWritableRoot(_ canonicalRoot: String) -> Bool
    static func isOverlyBroadRoot(_ canonicalRoot: String) -> Bool
}

public enum AgentRuntimeRegistrySeam {
    /// Set once by `RuntimeSeamRegistration.registerAll()`.
    public static var lookup: (any AgentRuntimeRegistryLookup.Type)?

    /// Fail-fast accessor. Traps if `registerAll()` has not run yet.
    public static var required: any AgentRuntimeRegistryLookup.Type {
        guard let lookup else {
            preconditionFailure(
                "AgentRuntimeRegistrySeam.lookup read before RuntimeSeamRegistration.registerAll() ran. " +
                "Call it in ASTRAApp.init() (already done) or at the top of the test that hit this path."
            )
        }
        return lookup
    }
}

/// Resolves a raw runtime-ID string against the live set of registered
/// provider adapters, matching `AgentRuntimeAdapterRegistry.registeredRuntime`.
public protocol AgentRuntimeRegistryLookup {
    static func registeredRuntime(rawValue: String?, fallback: AgentRuntimeID) -> AgentRuntimeID
}

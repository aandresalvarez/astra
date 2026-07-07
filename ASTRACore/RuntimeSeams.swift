import Foundation
import os

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
// the shipping app. The ASTRATests bundle borrows C's load-time hook
// instead: a `__attribute__((constructor))` in the test-only
// `AstraTestSeamBootstrap` target calls `registerAll()` when dyld loads the
// bundle, before either test framework schedules a suite (see
// `Tests/RuntimeSeamTestBootstrap.swift`; individual suites must not
// register — fitness-enforced).
// Accessing either seam before registration is a programmer error, not a
// silently-degraded security check: both trap with `preconditionFailure`
// rather than failing open or returning a guessed answer.
//
// Swift Testing runs suite initializers concurrently on different GCD worker
// threads by default (no implicit `.serialized`). Before the load-time test
// bootstrap existed, suites registered these seams from stored-property
// initializers in parallel, and a plain `static var` here made
// `registerAll()` a data race — confirmed empirically with
// `swift test --sanitize=thread` before this locking was added. Test
// registration is single-threaded now (a dyld image initializer), but reads
// still race each other and the production `registerAll()`, so both seams
// keep their backing value behind an `OSAllocatedUnfairLock` rather than a
// bare Optional static.
public enum ExecutionPathSafety {
    private static let storage = OSAllocatedUnfairLock<(any ExecutionPathSafetyChecking.Type)?>(initialState: nil)

    /// Set once by `RuntimeSeamRegistration.registerAll()`. Safe to call
    /// concurrently from multiple threads (e.g. parallel Swift Testing suite
    /// initializers) — later writes with the same value are idempotent, and
    /// this module has exactly one real implementation (`ExecutionSandbox`),
    /// so there is no meaningful "which writer won" ambiguity.
    public static func register(_ checker: any ExecutionPathSafetyChecking.Type) {
        storage.withLock { $0 = checker }
    }

    /// Fail-fast accessor. Traps if `registerAll()` has not run yet — this
    /// path is only reached when constructing a `WorkspaceExecutionEnvironment`
    /// with a non-empty `credentialProjections` list, never during plain JSON
    /// decode/encode (`Codable` is synthesized; the sanitizer only runs from
    /// the memberwise `init`/`setCredentialProjections`).
    public static var required: any ExecutionPathSafetyChecking.Type {
        guard let checker = storage.withLock({ $0 }) else {
            preconditionFailure(
                "ExecutionPathSafety checker read before RuntimeSeamRegistration.registerAll() ran. " +
                "Production registers it in ASTRAApp.init(); tests register it via the load-time bootstrap in Tests/AstraTestSeamBootstrap - a trap here in a test means that bootstrap wiring broke."
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
    private static let storage = OSAllocatedUnfairLock<(any AgentRuntimeRegistryLookup.Type)?>(initialState: nil)

    /// Set once by `RuntimeSeamRegistration.registerAll()`. Safe to call
    /// concurrently — see `ExecutionPathSafety.register(_:)`.
    public static func register(_ lookup: any AgentRuntimeRegistryLookup.Type) {
        storage.withLock { $0 = lookup }
    }

    /// Fail-fast accessor. Traps if `registerAll()` has not run yet.
    public static var required: any AgentRuntimeRegistryLookup.Type {
        guard let lookup = storage.withLock({ $0 }) else {
            preconditionFailure(
                "AgentRuntimeRegistrySeam lookup read before RuntimeSeamRegistration.registerAll() ran. " +
                "Production registers it in ASTRAApp.init(); tests register it via the load-time bootstrap in Tests/AstraTestSeamBootstrap - a trap here in a test means that bootstrap wiring broke."
            )
        }
        return lookup
    }

    /// Best-effort accessor for low-stakes callers (e.g.
    /// `TaskExecutionDefaults.model`) that must not crash a whole test
    /// process just because they happened to run before any suite called
    /// `registerAll()`. Returns `nil` instead of trapping; unlike
    /// `registeredRuntime(rawValue:fallback:)` (a real runtime-selection
    /// decision), a default suggested model has a safe, verifiable
    /// hardcoded fallback.
    public static var currentIfRegistered: (any AgentRuntimeRegistryLookup.Type)? {
        storage.withLock { $0 }
    }
}

/// Resolves a raw runtime-ID string against the live set of registered
/// provider adapters, matching `AgentRuntimeAdapterRegistry.registeredRuntime`.
///
/// `defaultModel(for:)` was added in Track A2.2 (finishing A2's Models
/// cycle-break) so `TaskExecutionDefaults.model` (moved to
/// `ASTRACore/TaskExecutionDefaults.swift`) can resolve a runtime's default
/// model without depending on the concrete `AgentRuntimeAdapterRegistry`.
/// `AgentRuntimeAdapterRegistry` already declares a matching
/// `static func defaultModel(for:) -> String`, so its existing
/// `AgentRuntimeRegistryLookup` conformance picks this up with no changes
/// there.
public protocol AgentRuntimeRegistryLookup {
    static func registeredRuntime(rawValue: String?, fallback: AgentRuntimeID) -> AgentRuntimeID
    static func defaultModel(for runtime: AgentRuntimeID) -> String
}

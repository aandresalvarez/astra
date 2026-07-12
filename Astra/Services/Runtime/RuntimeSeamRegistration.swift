import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// Wires the `ExecutionPathSafety`/`AgentRuntimeRegistrySeam` seams declared
/// in `ASTRACore/RuntimeSeams.swift` to their real, Runtime-owned
/// implementations (`ExecutionSandbox`, `AgentRuntimeAdapterRegistry`).
///
/// Swift has no module-load hook (no ObjC-style `+load`, and a library
/// target's top-level/static declarations are not run eagerly just by being
/// linked in — verified before choosing this design), so this must be called
/// explicitly, once, before either seam is read:
///  - Production: `ASTRAApp.init()` calls it.
///  - Tests: the test-only `AstraTestSeamBootstrap` C target gives the
///    ASTRATests bundle the load-time hook Swift lacks — its
///    `__attribute__((constructor))` calls this (through the `@_cdecl` entry
///    point in `Tests/RuntimeSeamTestBootstrap.swift`) when dyld loads the
///    bundle, before any suite is scheduled. Individual suites must NOT call
///    this themselves (fitness-enforced): per-suite registration was a
///    scheduling roulette under Swift Testing's parallel execution, crashing
///    whenever an unguarded seam-reading suite happened to run first.
///
/// The seam accessors trap with a clear message if read before registration,
/// so a production path that runs before `ASTRAApp.init()` — or a broken
/// test-bootstrap wiring — fails loudly instead of silently misbehaving.
///
/// Idempotent and thread-safe — safe to call more than once and safe to call
/// concurrently from multiple threads (both seams are backed by an
/// `OSAllocatedUnfairLock`, not a bare static var).
enum RuntimeSeamRegistration {
    static func registerAll() {
        ExecutionPathSafety.register(ExecutionSandbox.self)
        AgentRuntimeRegistrySeam.register(AgentRuntimeAdapterRegistry.self)
        AuditLoggingSeam.register(AppLogger.self)
        SkillSecretSeam.register(SkillSecretPersistence.self)
        ConnectorSecretSeam.register(ConnectorSecretPersistence.self)
        OutlookMailConnectionSeam.register(OutlookMailConnectionAdapter.self)
        ConnectorEnvironmentProjectionSeam.register(ConnectorEnvironmentProjectionAdapter.self)
        TaskForkStateInitializingSeam.register(TaskStateTransitionSeamAdapter.self)
        TaskSessionStateApplyingSeam.register(TaskStateTransitionSeamAdapter.self)
        TaskFolderResolvingSeam.register(TaskFolderResolvingAdapter.self)
        TaskForkManifestWritingSeam.register(TaskForkManifestWritingAdapter.self)
        SecretStoreSeam.register { KeychainSecretStore() }
        TaskPlanReconstructionSeam.register(TaskPlanService.self)
        TaskForkSourcePointerSeam.register(TaskForkManifestService.self)
        TaskGeneratedFileQuerySeam.register(TaskGeneratedFiles.self)
    }
}

extension ExecutionSandbox: ExecutionPathSafetyChecking {}

extension AgentRuntimeAdapterRegistry: AgentRuntimeRegistryLookup {}

extension AppLogger: AuditLogging {}

extension TaskPlanService: TaskPlanReconstructing {}

extension TaskForkManifestService: TaskForkSourcePointerProviding {}

extension TaskGeneratedFiles: TaskGeneratedFileQuerying {}

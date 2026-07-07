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
///  - Tests: any test that constructs a `WorkspaceExecutionEnvironment` with a
///    non-empty `credentialProjections` list, or reads
///    `TaskRoleProfile.runtime`, calls it at the top of the test (or suite
///    `init`). Both seam accessors trap with a clear message if read before
///    registration, so a future test that hits either path without calling
///    this fails loudly instead of silently misbehaving.
///
/// Idempotent and thread-safe — safe to call more than once (e.g. once per
/// test file) and safe to call concurrently from multiple threads (Swift
/// Testing runs suite initializers in parallel by default; both seams are
/// backed by an `OSAllocatedUnfairLock`, not a bare static var).
enum RuntimeSeamRegistration {
    static func registerAll() {
        ExecutionPathSafety.register(ExecutionSandbox.self)
        AgentRuntimeRegistrySeam.register(AgentRuntimeAdapterRegistry.self)
        AuditLoggingSeam.register(AppLogger.self)
        SkillSecretSeam.register(SkillSecretPersistence.self)
        ConnectorSecretSeam.register(ConnectorSecretPersistence.self)
        OutlookMailConnectionSeam.register(OutlookMailConnectionAdapter.self)
        ConnectorEnvironmentProjectionSeam.register(ConnectorEnvironmentProjectionAdapter.self)
        TaskForkStateInitializingSeam.register(TaskStateMachine.self)
        TaskSessionStateApplyingSeam.register(TaskStateMachine.self)
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

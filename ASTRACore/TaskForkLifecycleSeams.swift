import Foundation
import os

// Added as part of Track A2.6 (finishing A2's Models cycle-break) so
// `Astra/Models/AgentTaskForkService.swift` (moved into `ASTRAModels` in A3)
// can call the three app-side services it depends on (`TaskStateMachine`,
// `TaskForkManifestService`, `TaskWorkspaceAccess`) without importing them.

// MARK: - Fork state initialization

// `initializeForkAsCompleted` has exactly one call site in the whole app:
// `AgentTaskForkService.fork()`, always called with a freshly constructed
// (`.draft`) task and the default `savePolicy: .none` (no persistence side
// effect - `TaskStateMachine.persistIfNeeded` only calls
// `WorkspacePersistenceCoordinator` when `savePolicy == .save`). Its only
// real, callable-observable effects are: the draft/completed -> completed
// guard, a status/updatedAt mutation, and an audit log line. Per the plan's
// option (a), the seam returns the values to set rather than mutating a live
// `AgentTask` (which `ASTRACore` can never reference) - `AgentTaskForkService`
// applies them to `forked` directly, keeping `fork(...)`'s single-call
// contract intact for its own callers/tests.
public struct TaskForkStateInitializationResult: Sendable {
    public let statusRawValue: String
    public let updatedAt: Date?
    public let applied: Bool

    public init(statusRawValue: String, updatedAt: Date?, applied: Bool) {
        self.statusRawValue = statusRawValue
        self.updatedAt = updatedAt
        self.applied = applied
    }
}

public protocol TaskForkStateInitializing: Sendable {
    /// `statusRawValue` is `forked.status.rawValue` at the point of the call
    /// (always `.draft` in practice, since `forked` was just constructed).
    /// An unrecognized raw value is treated the same as an illegal
    /// transition (`applied: false`) - it should never happen in practice,
    /// but this boundary is a `String`, not the enum, so it's handled
    /// explicitly rather than force-unwrapped.
    static func initializeForkAsCompleted(taskID: UUID, statusRawValue: String, at date: Date) -> TaskForkStateInitializationResult
}

public enum TaskForkStateInitializingSeam {
    private static let storage = OSAllocatedUnfairLock<(any TaskForkStateInitializing.Type)?>(initialState: nil)

    public static func register(_ initializing: any TaskForkStateInitializing.Type) {
        storage.withLock { $0 = initializing }
    }

    public static var required: any TaskForkStateInitializing.Type {
        guard let initializing = storage.withLock({ $0 }) else {
            preconditionFailure(
                "TaskForkStateInitializingSeam read before RuntimeSeamRegistration.registerAll() ran. " +
                "Production registers it in ASTRAApp.init(); tests register it via the load-time bootstrap in Tests/AstraTestSeamBootstrap - a trap here in a test means that bootstrap wiring broke."
            )
        }
        return initializing
    }
}

// MARK: - Session-recovery / import status transitions

// Added as part of Track A4 (ASTRAPersistence extraction) so
// `Astra/Services/Persistence/SessionScanner.swift`/`WorkspaceConfigManager.swift`
// can apply `TaskStateMachine.completeFromSessionRecovery`/
// `.restoreImportedStatus` without depending on `TaskStateMachine`. Both
// source methods use `allowedFrom: Set(TaskStatus.allCases)` - the
// transition can never be rejected - so unlike `TaskForkStateInitializing`
// there's no `applied`/`rejection` outcome to report; the seam's only real
// job is performing the audit-log side effect and returning the
// business-rule-derived values (`completedAt`'s backfill, `updatedAt`) for
// the caller to apply to the live `AgentTask` directly. Both source call
// sites always pass the default `savePolicy: .none`, so persistence
// (`TaskStateMachine.persistIfNeeded`) is a no-op in both cases - not
// carried across the seam.
public struct TaskSessionRecoveryCompletionResult: Sendable {
    public let completedAt: Date
    public let updatedAt: Date

    public init(completedAt: Date, updatedAt: Date) {
        self.completedAt = completedAt
        self.updatedAt = updatedAt
    }
}

public struct TaskImportedStatusRestorationResult: Sendable {
    public let updatedAt: Date

    public init(updatedAt: Date) {
        self.updatedAt = updatedAt
    }
}

public protocol TaskSessionStateApplying: Sendable {
    /// Mirrors `TaskStateMachine.completeFromSessionRecovery`'s
    /// `completedAt: .set(task.completedAt ?? date)` rule: preserves an
    /// already-set completion date, else backfills `date`.
    static func completeFromSessionRecovery(
        taskID: UUID,
        currentStatusRawValue: String,
        existingCompletedAt: Date?,
        at date: Date
    ) -> TaskSessionRecoveryCompletionResult

    static func restoreImportedStatus(
        taskID: UUID,
        currentStatusRawValue: String,
        targetStatusRawValue: String,
        at date: Date
    ) -> TaskImportedStatusRestorationResult
}

public enum TaskSessionStateApplyingSeam {
    private static let storage = OSAllocatedUnfairLock<(any TaskSessionStateApplying.Type)?>(initialState: nil)

    public static func register(_ applying: any TaskSessionStateApplying.Type) {
        storage.withLock { $0 = applying }
    }

    public static var required: any TaskSessionStateApplying.Type {
        guard let applying = storage.withLock({ $0 }) else {
            preconditionFailure(
                "TaskSessionStateApplyingSeam read before RuntimeSeamRegistration.registerAll() ran. " +
                "Production registers it in ASTRAApp.init(); tests register it via the load-time bootstrap in Tests/AstraTestSeamBootstrap - a trap here in a test means that bootstrap wiring broke."
            )
        }
        return applying
    }
}

// MARK: - Task folder resolution

// Mirrors `Astra/Services/Persistence/TaskWorkspaceAccess.swift`'s
// `taskFolder`/`ensureTaskFolder()` - the only two members of that struct
// `AgentTaskForkService` (directly) and `TaskForkManifestService.writeManifest`
// (internally, unaffected by this seam - it stays app-side) use. Both were
// already effectively primitive under the hood (`effectiveWorkspacePath`
// resolves to `task.workspace?.primaryPath ?? ""`, plus `task.id`) - no
// scratch-object reconstruction needed here, unlike the manifest-writing seam
// below.
public protocol TaskFolderResolving: Sendable {
    static func taskFolder(workspacePath: String, taskID: UUID) -> String
    static func ensureTaskFolder(workspacePath: String, taskID: UUID) throws -> String
}

public enum TaskFolderResolvingSeam {
    private static let storage = OSAllocatedUnfairLock<(any TaskFolderResolving.Type)?>(initialState: nil)

    public static func register(_ resolving: any TaskFolderResolving.Type) {
        storage.withLock { $0 = resolving }
    }

    public static var required: any TaskFolderResolving.Type {
        guard let resolving = storage.withLock({ $0 }) else {
            preconditionFailure(
                "TaskFolderResolvingSeam read before RuntimeSeamRegistration.registerAll() ran. " +
                "Production registers it in ASTRAApp.init(); tests register it via the load-time bootstrap in Tests/AstraTestSeamBootstrap - a trap here in a test means that bootstrap wiring broke."
            )
        }
        return resolving
    }
}

// MARK: - Fork manifest writing

// `TaskForkManifestService.writeManifest(source:forked:targetRun:...)` (real
// file I/O against the task folder, reads `source.artifacts`) is far too
// deep to hand-translate into primitives - it stays entirely app-side,
// unchanged. Instead, this seam's registered adapter reconstructs scratch,
// never-persisted `AgentTask`/`TaskRun`/`Artifact`/`Workspace` instances from
// `TaskForkManifestRequest` and calls the *existing* `writeManifest`
// unchanged on them - same "reconstruct, don't re-derive" reasoning as
// `OutlookMailConnectionSeam`/`ConnectorEnvironmentProjectionSeam` (Track
// A2.5). Verified empirically (not assumed) that a standalone `@Model`
// instance never inserted into a `ModelContext` behaves as a plain Swift
// object for relationship-array reads - see this seam's introducing PR.
public struct TaskForkArtifactFacts: Sendable {
    public let createdAt: Date
    public let path: String

    public init(createdAt: Date, path: String) {
        self.createdAt = createdAt
        self.path = path
    }
}

public struct TaskForkManifestRequest: Sendable {
    public let sourceTaskID: UUID
    public let sourceWorkspacePath: String
    public let sourceArtifacts: [TaskForkArtifactFacts]
    public let forkedTaskID: UUID
    public let forkedWorkspacePath: String
    public let checkpointRunID: UUID
    public let checkpointRunStartedAt: Date
    public let checkpointRunCompletedAt: Date?
    public let checkpointRunIndex: Int
    public let copiedRunIDs: [UUID]

    public init(
        sourceTaskID: UUID,
        sourceWorkspacePath: String,
        sourceArtifacts: [TaskForkArtifactFacts],
        forkedTaskID: UUID,
        forkedWorkspacePath: String,
        checkpointRunID: UUID,
        checkpointRunStartedAt: Date,
        checkpointRunCompletedAt: Date?,
        checkpointRunIndex: Int,
        copiedRunIDs: [UUID]
    ) {
        self.sourceTaskID = sourceTaskID
        self.sourceWorkspacePath = sourceWorkspacePath
        self.sourceArtifacts = sourceArtifacts
        self.forkedTaskID = forkedTaskID
        self.forkedWorkspacePath = forkedWorkspacePath
        self.checkpointRunID = checkpointRunID
        self.checkpointRunStartedAt = checkpointRunStartedAt
        self.checkpointRunCompletedAt = checkpointRunCompletedAt
        self.checkpointRunIndex = checkpointRunIndex
        self.copiedRunIDs = copiedRunIDs
    }
}

public struct TaskForkManifestSummary: Sendable {
    public let sourceTaskID: UUID
    public let checkpointRunID: UUID
    public let checkpointRunIndex: Int

    public init(sourceTaskID: UUID, checkpointRunID: UUID, checkpointRunIndex: Int) {
        self.sourceTaskID = sourceTaskID
        self.checkpointRunID = checkpointRunID
        self.checkpointRunIndex = checkpointRunIndex
    }
}

public protocol TaskForkManifestWriting: Sendable {
    static func writeManifest(_ request: TaskForkManifestRequest) throws -> TaskForkManifestSummary
    /// Matches `TaskForkManifestService.manifestPath(taskFolder:)`, already
    /// primitive (`String`-only) in its real form.
    static func manifestPath(taskFolder: String) -> String
}

public enum TaskForkManifestWritingSeam {
    private static let storage = OSAllocatedUnfairLock<(any TaskForkManifestWriting.Type)?>(initialState: nil)

    public static func register(_ writing: any TaskForkManifestWriting.Type) {
        storage.withLock { $0 = writing }
    }

    public static var required: any TaskForkManifestWriting.Type {
        guard let writing = storage.withLock({ $0 }) else {
            preconditionFailure(
                "TaskForkManifestWritingSeam read before RuntimeSeamRegistration.registerAll() ran. " +
                "Production registers it in ASTRAApp.init(); tests register it via the load-time bootstrap in Tests/AstraTestSeamBootstrap - a trap here in a test means that bootstrap wiring broke."
            )
        }
        return writing
    }
}

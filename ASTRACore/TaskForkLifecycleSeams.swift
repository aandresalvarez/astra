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

public protocol TaskForkStateInitializing {
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
                "Call it in ASTRAApp.init() (already done) or at the top of the test that hit this path."
            )
        }
        return initializing
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
public protocol TaskFolderResolving {
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
                "Call it in ASTRAApp.init() (already done) or at the top of the test that hit this path."
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

public protocol TaskForkManifestWriting {
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
                "Call it in ASTRAApp.init() (already done) or at the top of the test that hit this path."
            )
        }
        return writing
    }
}

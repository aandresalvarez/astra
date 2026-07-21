import Foundation
import SwiftData

/// The durable reason an execution request exists.
public enum TaskExecutionRequestKind: String, Codable, CaseIterable, Sendable {
    case initial
    case followUp = "follow_up"
    case retry
    case scheduled
    case planStep = "plan_step"
}

/// A typed, versioned snapshot of launch policy that must not change while a
/// request waits for admission. Runtime, model, and budget remain separate
/// queryable columns on `TaskTurnRequest`.
public struct TaskExecutionPolicySnapshotV1: Codable, Equatable, Sendable {
    public let version: Int
    public let runtimeExplicitlySelected: Bool
    public let maxTurns: Int
    public let isolationStrategyRawValue: String
    public let validationStrategyRawValue: String
    public let testCommand: String
    public let useAgentTeam: Bool
    public let teamSize: Int
    public let teamInstructions: String
    public let executionRootPath: String?
    public let executionEnvironmentSnapshotJSON: String?
    public let templateHooksJSON: String
    public let skillSnapshotsJSON: String
    public let runtimePermissionGrantsJSON: String?

    public init(task: AgentTask) {
        version = 1
        runtimeExplicitlySelected = task.runtimeExplicitlySelected
        maxTurns = task.maxTurns
        isolationStrategyRawValue = task.isolationStrategy.rawValue
        validationStrategyRawValue = task.validationStrategy.rawValue
        testCommand = task.testCommand
        useAgentTeam = task.useAgentTeam
        teamSize = task.teamSize
        teamInstructions = task.teamInstructions
        executionRootPath = task.executionRootPath
        executionEnvironmentSnapshotJSON = task.executionEnvironmentSnapshotJSON
        templateHooksJSON = task.templateHooksJSON
        skillSnapshotsJSON = task.skillSnapshotsJSON
        runtimePermissionGrantsJSON = task.runtimePermissionGrantsJSON
    }
}

public enum TaskExecutionResourceKind: String, Codable, CaseIterable, Sendable {
    case workspace
    case gitCommonDirectory = "git_common_directory"
    case browserSession = "browser_session"
    case docker
    case remoteDirectory = "remote_directory"
    case accountSession = "account_session"
}

public enum TaskExecutionResourceAccess: String, Codable, CaseIterable, Sendable {
    case shared
    case exclusive
}

/// An immutable admission claim. Multiple claims allow the scheduler to admit
/// unrelated work instead of collapsing all safety decisions into one
/// workspace-wide write lock.
public struct TaskExecutionResourceClaim: Codable, Equatable, Hashable, Sendable {
    public let kind: TaskExecutionResourceKind
    public let key: String
    public let access: TaskExecutionResourceAccess

    public init(kind: TaskExecutionResourceKind, key: String, access: TaskExecutionResourceAccess) {
        self.kind = kind
        self.key = key
        self.access = access
    }
}

/// Durable admission state for one execution request.
///
/// The source intent remains an append-only `TaskEvent`. This record owns only
/// the execution/admission lifecycle so initial runs, follow-ups, retries,
/// scheduled runs, and plan steps remain visible and recoverable while waiting.
public enum TaskTurnRequestState: String, Codable, CaseIterable, Sendable {
    case waitingForWorker = "waiting_for_worker"
    case waitingForResource = "waiting_for_resource"
    case admitted
    case running
    case completed
    case failed
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            true
        case .waitingForWorker, .waitingForResource, .admitted, .running:
            false
        }
    }

    public var isActive: Bool { !isTerminal }
}

/// A bounded, Sendable projection suitable for queue and presentation code.
/// Consumers should reload the model before attempting a state transition.
public struct TaskTurnRequestSnapshot: Equatable, Sendable {
    public let id: UUID
    public let taskID: UUID
    public let messageEventID: UUID
    public let runID: UUID?
    public let sequence: Int
    public let state: TaskTurnRequestState
    public let submittedAt: Date
    public let admittedAt: Date?
    public let startedAt: Date?
    public let terminalAt: Date?
    public let terminalReason: String?
    public let blockingTaskID: UUID?
    public let blockerSummary: String?
    public let kind: TaskExecutionRequestKind
    public let runtimeIDSnapshot: String?
    public let modelSnapshot: String?
    public let tokenBudgetSnapshot: Int?
    public let executionPolicySnapshotJSON: String?
    public let resourceClaimsJSON: String
}

@Model
public final class TaskTurnRequest {
    public var id: UUID
    /// The owning task, stored as a scalar id rather than a SwiftData
    /// relationship. A to-one relationship to `AgentTask` would force SwiftData
    /// to synthesize an inverse on `AgentTask`, mutating the shipped V14 task
    /// entity and breaking the V14→V15 lightweight migration of populated
    /// stores (a hard CoreData abort). The scalar keeps V15 a genuinely
    /// additive new-entity migration — the invariant this record's repository
    /// comment already promised. Mirrors `TaskExternalOperation.taskID`.
    public var taskID: UUID
    /// Stable reference to the append-only source event. V15 supported only a
    /// `user.message`; V16 retains the column while allowing any typed event.
    public var messageEventID: UUID
    /// Set by queue admission. The run remains owned by `AgentTask.runs`.
    public var runID: UUID?
    /// Strictly increasing per task, assigned at durable submission time.
    public var sequence: Int
    public var stateRawValue: String
    public var submittedAt: Date
    public var admittedAt: Date?
    public var startedAt: Date?
    public var terminalAt: Date?
    public var terminalReason: String?
    /// Local diagnostic metadata. Never use this field as a lock authority.
    public var blockingTaskID: UUID?
    public var blockerSummary: String?
    /// Defaults to follow-up so canonical V15 rows migrate without inventing a
    /// new initial/scheduled/retry origin they never recorded.
    public var kindRawValue: String = TaskExecutionRequestKind.followUp.rawValue
    /// Nil is reserved for rows migrated from V15, whose launch configuration
    /// was not captured at submission time. Every V16 submission initializes
    /// these immutable snapshots; `runtimeIDSnapshot` stores the RESOLVED
    /// runtime raw value (`AgentTask.resolvedRuntimeID`), never the task's
    /// raw optional `runtimeID`, so a legacy task with a nil or unrecognized
    /// runtime still records the provider that would actually launch instead
    /// of persisting a nil that is indistinguishable from a migrated row.
    public var runtimeIDSnapshot: String?
    public var modelSnapshot: String?
    public var tokenBudgetSnapshot: Int?
    public var executionPolicySnapshotJSON: String?
    public var resourceClaimsJSON: String = "[]"

    public init(
        task: AgentTask,
        messageEventID: UUID,
        sequence: Int,
        kind: TaskExecutionRequestKind = .followUp,
        resourceClaims: [TaskExecutionResourceClaim] = [],
        state: TaskTurnRequestState = .waitingForWorker,
        submittedAt: Date = Date()
    ) {
        self.id = UUID()
        self.taskID = task.id
        self.messageEventID = messageEventID
        self.runID = nil
        self.sequence = sequence
        self.stateRawValue = state.rawValue
        self.submittedAt = submittedAt
        self.admittedAt = nil
        self.startedAt = nil
        self.terminalAt = nil
        self.terminalReason = nil
        self.blockingTaskID = nil
        self.blockerSummary = nil
        self.kindRawValue = kind.rawValue
        self.runtimeIDSnapshot = task.resolvedRuntimeID.rawValue
        self.modelSnapshot = task.model
        self.tokenBudgetSnapshot = task.tokenBudget
        self.executionPolicySnapshotJSON = Self.encode(TaskExecutionPolicySnapshotV1(task: task))
        self.resourceClaimsJSON = Self.encode(resourceClaims) ?? "[]"
    }

    public var state: TaskTurnRequestState {
        get { TaskTurnRequestState(rawValue: stateRawValue) ?? .failed }
        set { stateRawValue = newValue.rawValue }
    }

    public var kind: TaskExecutionRequestKind {
        get { TaskExecutionRequestKind(rawValue: kindRawValue) ?? .followUp }
        set { kindRawValue = newValue.rawValue }
    }

    /// Compatibility alias: V15 named this scalar after its only supported
    /// source event (`user.message`). V16 allows any typed TaskEvent to own the
    /// request while retaining the on-disk column for lightweight migration.
    public var sourceEventID: UUID { messageEventID }

    public var executionPolicySnapshot: TaskExecutionPolicySnapshotV1? {
        Self.decode(TaskExecutionPolicySnapshotV1.self, from: executionPolicySnapshotJSON)
    }

    /// Restores the owning task's mutable launch-input fields from this
    /// request's immutable submission snapshots. Queue admission calls this
    /// immediately before launch so the request executes with the runtime,
    /// model, budget, and policy advertised at submission — not whatever the
    /// still-editable composer wrote to the task while the request waited.
    /// Nil top-level snapshots mark rows migrated from V15, whose launch
    /// configuration was never captured; those keep the launch-from-task
    /// fallback untouched. A present policy snapshot is applied whole:
    /// captured nils (e.g. `executionRootPath`) are meaningful and restored.
    /// Returns true when any task field actually changed.
    @discardableResult
    public func applyLaunchInputSnapshots(to task: AgentTask) -> Bool {
        guard task.id == taskID else { return false }
        var changed = false
        func write<Value: Equatable>(_ value: Value, _ keyPath: ReferenceWritableKeyPath<AgentTask, Value>) {
            guard task[keyPath: keyPath] != value else { return }
            task[keyPath: keyPath] = value
            changed = true
        }
        if let runtimeIDSnapshot {
            write(runtimeIDSnapshot as String?, \.runtimeID)
        }
        if let modelSnapshot {
            write(modelSnapshot, \.model)
        }
        if let tokenBudgetSnapshot {
            write(tokenBudgetSnapshot, \.tokenBudget)
        }
        if let policy = executionPolicySnapshot {
            write(policy.runtimeExplicitlySelected, \.runtimeExplicitlySelected)
            write(policy.maxTurns, \.maxTurns)
            if let isolation = IsolationStrategy(rawValue: policy.isolationStrategyRawValue) {
                write(isolation, \.isolationStrategy)
            }
            if let validation = ValidationStrategy(rawValue: policy.validationStrategyRawValue) {
                write(validation, \.validationStrategy)
            }
            write(policy.testCommand, \.testCommand)
            write(policy.useAgentTeam, \.useAgentTeam)
            write(policy.teamSize, \.teamSize)
            write(policy.teamInstructions, \.teamInstructions)
            write(policy.executionRootPath, \.executionRootPath)
            write(policy.executionEnvironmentSnapshotJSON, \.executionEnvironmentSnapshotJSON)
            write(policy.templateHooksJSON, \.templateHooksJSON)
            write(policy.skillSnapshotsJSON, \.skillSnapshotsJSON)
            write(policy.runtimePermissionGrantsJSON, \.runtimePermissionGrantsJSON)
        }
        if changed {
            task.updatedAt = Date()
        }
        return changed
    }

    public var resourceClaims: [TaskExecutionResourceClaim] {
        Self.decode([TaskExecutionResourceClaim].self, from: resourceClaimsJSON) ?? []
    }

    public var snapshot: TaskTurnRequestSnapshot {
        TaskTurnRequestSnapshot(
            id: id,
            taskID: taskID,
            messageEventID: messageEventID,
            runID: runID,
            sequence: sequence,
            state: state,
            submittedAt: submittedAt,
            admittedAt: admittedAt,
            startedAt: startedAt,
            terminalAt: terminalAt,
            terminalReason: terminalReason,
            blockingTaskID: blockingTaskID,
            blockerSummary: blockerSummary,
            kind: kind,
            runtimeIDSnapshot: runtimeIDSnapshot,
            modelSnapshot: modelSnapshot,
            tokenBudgetSnapshot: tokenBudgetSnapshot,
            executionPolicySnapshotJSON: executionPolicySnapshotJSON,
            resourceClaimsJSON: resourceClaimsJSON
        )
    }

    private static func encode<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from json: String?) -> T? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

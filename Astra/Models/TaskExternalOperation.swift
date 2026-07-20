import Foundation
import SwiftData

/// ASTRA's durable, task-owned control-plane projection of an external job.
///
/// The execution backend remains authoritative for commands, process identity,
/// logs, and raw execution status. This model stores only the bounded identity,
/// scheduling, observation, and notification state needed to resume monitoring
/// after ASTRA restarts. `taskID` is deliberately a scalar rather than a
/// SwiftData relationship so adding this entity does not mutate AgentTask's
/// historical V14 schema fingerprint.
@Model
public final class TaskExternalOperation {
    public var id: UUID
    public var taskID: UUID
    @Attribute(.unique) public var externalIdentity: String
    public var originatingRunID: UUID
    public var backendKindRaw: String
    public var backendJobID: String
    public var originatingContextRevision: String?
    public var executionStateRaw: String
    public var observationHealthRaw: String
    public var monitoringStateRaw: String
    public var nextCheckAt: Date?
    public var generation: Int
    public var leaseOwner: String?
    public var leaseExpiresAt: Date?
    public var lastObservedAt: Date?
    public var terminalObservedAt: Date?
    public var lastNotificationKey: String?
    public var lastWakeKey: String?
    public var consecutiveObservationFailures: Int
    /// The resource-lock key of the execution root the detached job mounted at
    /// LAUNCH. Recomputing exclusion from the task/workspace's current paths is
    /// wrong once the user retargets the workspace default mid-job: the holder
    /// would drift to the new path while the original root loses protection.
    /// Optional so pre-existing rows lightweight-migrate; holders fall back to
    /// recomputation when nil.
    public var launchResourceKey: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        taskID: UUID,
        externalIdentity: String,
        originatingRunID: UUID,
        backendKindRaw: String,
        backendJobID: String,
        originatingContextRevision: String? = nil,
        executionState: TaskExternalOperationExecutionState = .registered,
        observationHealth: TaskExternalOperationObservationHealth = .unknown,
        monitoringState: TaskExternalOperationMonitoringState = .active,
        nextCheckAt: Date? = nil,
        generation: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = UUID()
        self.taskID = taskID
        self.externalIdentity = externalIdentity
        self.originatingRunID = originatingRunID
        self.backendKindRaw = backendKindRaw
        self.backendJobID = backendJobID
        self.originatingContextRevision = originatingContextRevision
        self.executionStateRaw = executionState.rawValue
        self.observationHealthRaw = observationHealth.rawValue
        self.monitoringStateRaw = monitoringState.rawValue
        self.nextCheckAt = nextCheckAt
        self.generation = generation
        self.leaseOwner = nil
        self.leaseExpiresAt = nil
        self.lastObservedAt = nil
        self.terminalObservedAt = nil
        self.lastNotificationKey = nil
        self.lastWakeKey = nil
        self.consecutiveObservationFailures = 0
        self.launchResourceKey = nil
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    public var executionState: TaskExternalOperationExecutionState {
        get { TaskExternalOperationExecutionState(rawValue: executionStateRaw) ?? .unknown }
        set { executionStateRaw = newValue.rawValue }
    }

    public var observationHealth: TaskExternalOperationObservationHealth {
        get { TaskExternalOperationObservationHealth(rawValue: observationHealthRaw) ?? .unknown }
        set { observationHealthRaw = newValue.rawValue }
    }

    public var monitoringState: TaskExternalOperationMonitoringState {
        get { TaskExternalOperationMonitoringState(rawValue: monitoringStateRaw) ?? .stopped }
        set { monitoringStateRaw = newValue.rawValue }
    }
}

public enum TaskExternalOperationExecutionState: String, Codable, CaseIterable, Sendable {
    case registered
    case queued
    case running
    case processCompleted = "process_completed"
    case interrupted
    case failed
    case cancelled
    case timedOut = "timed_out"
    case unknown

    public var isTerminalObservation: Bool {
        switch self {
        case .processCompleted, .interrupted, .failed, .cancelled, .timedOut:
            true
        case .registered, .queued, .running, .unknown:
            false
        }
    }
}

public enum TaskExternalOperationObservationHealth: String, Codable, CaseIterable, Sendable {
    case unknown
    case healthy
    case unreachable
    case malformed
    case quarantined
}

public enum TaskExternalOperationMonitoringState: String, Codable, CaseIterable, Sendable {
    case active
    case stopped
    case quarantined
    case validating
    case completed
}

public struct TaskExternalOperationObservation: Equatable, Sendable {
    public let executionState: TaskExternalOperationExecutionState
    public let health: TaskExternalOperationObservationHealth

    public init(
        executionState: TaskExternalOperationExecutionState,
        health: TaskExternalOperationObservationHealth
    ) {
        self.executionState = executionState
        self.health = health
    }
}

public enum TaskExternalOperationWakeIntent: String, Equatable, Sendable {
    case ambiguousObservation = "ambiguous_observation"
    case completionValidation = "completion_validation"
    case userFacingReasoning = "user_facing_reasoning"
}

/// Single owner of the wake-intent/semantic-key derivation, shared by the
/// monitor's dedupe, the resource-holder provider, the worker's isolation
/// retention, and the import/export mirror — "is this operation's terminal
/// wake still pending?" must mean the same thing everywhere or exclusion,
/// cleanup, delivery, and import silently disagree.
public enum TaskExternalOperationWakeKeyDerivation {
    public static func intent(
        for observation: TaskExternalOperationObservation
    ) -> TaskExternalOperationWakeIntent? {
        if observation.health == .malformed ||
            (observation.health == .healthy && observation.executionState == .unknown) {
            return .ambiguousObservation
        }
        switch observation.executionState {
        case .processCompleted:
            return .completionValidation
        case .interrupted, .failed, .cancelled, .timedOut:
            return .userFacingReasoning
        case .registered, .queued, .running, .unknown:
            return nil
        }
    }

    public static func semanticKey(for observation: TaskExternalOperationObservation) -> String {
        "v1|\(observation.executionState.rawValue)|\(observation.health.rawValue)"
    }

    public static func wakeKey(for observation: TaskExternalOperationObservation) -> String? {
        guard let intent = intent(for: observation) else { return nil }
        return "\(semanticKey(for: observation))|\(intent.rawValue)"
    }

    /// Whether a terminal operation's validation/reasoning wake has NOT yet
    /// been acknowledged. `lastWakeKey == nil` is insufficient: a previously
    /// acknowledged ambiguity/malformed wake leaves a non-nil, DIFFERENT key
    /// when the next observation transitions straight to a terminal state —
    /// any key other than the current terminal wake key means pending.
    public static func hasPendingTerminalWake(_ operation: TaskExternalOperation) -> Bool {
        guard operation.executionState.isTerminalObservation else { return false }
        switch operation.monitoringState {
        case .validating:
            return true
        case .completed:
            let observation = TaskExternalOperationObservation(
                executionState: operation.executionState,
                health: operation.observationHealth
            )
            guard let currentKey = wakeKey(for: observation) else { return false }
            return operation.lastWakeKey != currentKey
        case .active, .stopped, .quarantined:
            return false
        }
    }
}

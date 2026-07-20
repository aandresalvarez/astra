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

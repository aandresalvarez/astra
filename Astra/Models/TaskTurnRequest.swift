import Foundation
import SwiftData

/// Durable admission state for one user-authored task turn.
///
/// The user message remains an append-only `TaskEvent`. This record owns only
/// the work-admission lifecycle so a turn remains visible and recoverable
/// while it waits for a worker or an exclusive workspace resource.
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
}

@Model
public final class TaskTurnRequest {
    public var id: UUID
    public var task: AgentTask?
    /// Stable reference to the append-only `user.message` event. This avoids a
    /// second mutable owner for user-authored content.
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

    public init(
        task: AgentTask,
        messageEventID: UUID,
        sequence: Int,
        state: TaskTurnRequestState = .waitingForWorker,
        submittedAt: Date = Date()
    ) {
        self.id = UUID()
        self.task = task
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
    }

    public var state: TaskTurnRequestState {
        get { TaskTurnRequestState(rawValue: stateRawValue) ?? .failed }
        set { stateRawValue = newValue.rawValue }
    }

    public var snapshot: TaskTurnRequestSnapshot? {
        guard let taskID = task?.id else { return nil }
        return TaskTurnRequestSnapshot(
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
            blockerSummary: blockerSummary
        )
    }
}

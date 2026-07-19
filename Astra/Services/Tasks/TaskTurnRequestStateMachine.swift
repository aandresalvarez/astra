import Foundation
import SwiftData
import ASTRAModels

/// The sole mutator for durable turn-admission state. Queue and recovery code
/// must use this boundary rather than assigning `stateRawValue` directly.
@MainActor
enum TaskTurnRequestStateMachine {
    enum Rejection: Equatable {
        case illegalTransition(from: TaskTurnRequestState, to: TaskTurnRequestState)
    }

    struct TransitionResult: Equatable {
        let from: TaskTurnRequestState
        let to: TaskTurnRequestState
        let changed: Bool
        let rejection: Rejection?
    }

    @discardableResult
    static func transition(
        _ request: TaskTurnRequest,
        to next: TaskTurnRequestState,
        runID: UUID? = nil,
        blockingTaskID: UUID? = nil,
        blockerSummary: String? = nil,
        terminalReason: String? = nil,
        at date: Date = Date()
    ) -> TransitionResult {
        let current = request.state
        guard current != next else {
            let previousRunID = request.runID
            let previousBlockerID = request.blockingTaskID
            let previousBlockerSummary = request.blockerSummary
            if let runID { request.runID = runID }
            if blockingTaskID != nil || blockerSummary != nil {
                request.blockingTaskID = blockingTaskID
                request.blockerSummary = blockerSummary
            }
            let changed = previousRunID != request.runID
                || previousBlockerID != request.blockingTaskID
                || previousBlockerSummary != request.blockerSummary
            if changed {
                TaskThreadChangeNotifier.post(taskID: request.taskID, source: "turn_request_\(next.rawValue)")
            }
            return TransitionResult(from: current, to: next, changed: changed, rejection: nil)
        }
        guard allowedTransitions[current, default: []].contains(next) else {
            return TransitionResult(
                from: current,
                to: next,
                changed: false,
                rejection: .illegalTransition(from: current, to: next)
            )
        }

        request.state = next
        if let runID { request.runID = runID }
        request.blockingTaskID = blockingTaskID
        request.blockerSummary = blockerSummary
        if next == .admitted, request.admittedAt == nil {
            request.admittedAt = date
        }
        if next == .running, request.startedAt == nil {
            request.startedAt = date
        }
        if next.isTerminal {
            request.terminalAt = date
            request.terminalReason = terminalReason
        } else if current.isTerminal {
            // Retrying a failed or cancelled submission reuses the same
            // durable intent. The linked TaskRun history remains the record
            // of prior attempts; the request is once again actionable. Clear
            // the prior attempt's admission fields too — a stale runID would
            // otherwise let restart recovery mirror the OLD run's terminal
            // status onto a retried-but-not-yet-rerun request, and stale
            // admitted/started timestamps skew the turn timeline.
            request.terminalAt = nil
            request.terminalReason = nil
            if runID == nil { request.runID = nil }
            request.admittedAt = nil
            request.startedAt = nil
        }
        TaskThreadChangeNotifier.post(taskID: request.taskID, source: "turn_request_\(next.rawValue)")
        return TransitionResult(from: current, to: next, changed: true, rejection: nil)
    }

    private static let allowedTransitions: [TaskTurnRequestState: Set<TaskTurnRequestState>] = [
        .waitingForWorker: [.waitingForResource, .admitted, .failed, .cancelled],
        .waitingForResource: [.waitingForWorker, .admitted, .failed, .cancelled],
        .admitted: [.waitingForWorker, .running, .failed, .cancelled],
        .running: [.completed, .failed, .cancelled],
        .completed: [],
        .failed: [.waitingForWorker],
        .cancelled: [.waitingForWorker]
    ]
}

/// Query boundary for the scalar `taskID` back-reference. Keeping the
/// collection off `AgentTask` (no relationship, no synthesized inverse)
/// preserves the shipped V14 task entity so V15 is a genuinely additive
/// lightweight migration.
@MainActor
enum TaskTurnRequestRepository {
    static func requests(for task: AgentTask, in modelContext: ModelContext) throws -> [TaskTurnRequest] {
        let taskID = task.id
        let descriptor = FetchDescriptor<TaskTurnRequest>(
            predicate: #Predicate { $0.taskID == taskID },
            sortBy: [SortDescriptor(\.sequence), SortDescriptor(\.submittedAt)]
        )
        return try modelContext.fetch(descriptor)
    }

    static func activeRequests(for task: AgentTask, in modelContext: ModelContext) throws -> [TaskTurnRequest] {
        try requests(for: task, in: modelContext).filter { $0.state.isActive }
    }

    static func request(id: UUID, in modelContext: ModelContext) throws -> TaskTurnRequest? {
        let descriptor = FetchDescriptor<TaskTurnRequest>(
            predicate: #Predicate { $0.id == id }
        )
        return try modelContext.fetch(descriptor).first
    }

    static func nextSequence(for task: AgentTask, in modelContext: ModelContext) throws -> Int {
        (try requests(for: task, in: modelContext).last?.sequence ?? 0) + 1
    }
}

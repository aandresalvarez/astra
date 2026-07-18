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
            return TransitionResult(from: current, to: next, changed: false, rejection: nil)
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
        }
        request.task?.updatedAt = date
        if let taskID = request.task?.id {
            TaskThreadChangeNotifier.post(taskID: taskID, source: "turn_request_\(next.rawValue)")
        }
        return TransitionResult(from: current, to: next, changed: true, rejection: nil)
    }

    private static let allowedTransitions: [TaskTurnRequestState: Set<TaskTurnRequestState>] = [
        .waitingForWorker: [.waitingForResource, .admitted, .failed, .cancelled],
        .waitingForResource: [.waitingForWorker, .admitted, .failed, .cancelled],
        .admitted: [.waitingForWorker, .running, .failed, .cancelled],
        .running: [.completed, .failed, .cancelled],
        .completed: [],
        .failed: [],
        .cancelled: []
    ]
}

/// Query boundary for the new one-way request relationship. Keeping the
/// collection off `AgentTask` preserves the shipped V14 task schema so V15 is
/// a genuinely additive lightweight migration.
@MainActor
enum TaskTurnRequestRepository {
    static func requests(for task: AgentTask, in modelContext: ModelContext) throws -> [TaskTurnRequest] {
        let taskID = task.id
        let descriptor = FetchDescriptor<TaskTurnRequest>(
            predicate: #Predicate { $0.task?.id == taskID },
            sortBy: [SortDescriptor(\.sequence), SortDescriptor(\.submittedAt)]
        )
        return try modelContext.fetch(descriptor)
    }

    static func activeRequests(for task: AgentTask, in modelContext: ModelContext) throws -> [TaskTurnRequest] {
        try requests(for: task, in: modelContext).filter { $0.state.isActive }
    }

    static func nextSequence(for task: AgentTask, in modelContext: ModelContext) throws -> Int {
        (try requests(for: task, in: modelContext).last?.sequence ?? 0) + 1
    }
}

import Foundation
import ASTRAModels

enum PendingTaskDismissalReason: Equatable {
    case noUsableResult
    case policyBlocked
    case missingRequiredArtifact
}

struct PendingTaskReviewState: Equatable {
    let isDismissed: Bool
    let dismissalReason: PendingTaskDismissalReason?

    static let none = PendingTaskReviewState(isDismissed: false, dismissalReason: nil)
}

struct PendingTaskReviewRunSnapshot: Equatable, Sendable {
    let id: UUID
    let status: RunStatus
    let startedAt: Date
    let completedAt: Date?
    let stopReason: String
}

struct PendingTaskReviewEventSnapshot: Equatable, Sendable {
    let runID: UUID?
    let type: String
    let timestamp: Date
}

/// Value-only input for SwiftUI presentation. It deliberately contains no
/// SwiftData model references so evaluating a decision dock never faults a
/// `TaskRun` merely to sort it by `startedAt`.
struct PendingTaskReviewSnapshotInput: Equatable, Sendable {
    let taskStatus: TaskStatus
    let isTaskDone: Bool
    let requiresDeliverableArtifact: Bool
    let latestRun: PendingTaskReviewRunSnapshot?
    let runs: [PendingTaskReviewRunSnapshot]
    let events: [PendingTaskReviewEventSnapshot]
    let latestRunHasScopedArtifact: Bool
}

enum PendingTaskReviewPolicy {
    static func requiresScopedArtifactEvidence(
        taskStatus: TaskStatus,
        isTaskDone: Bool,
        requiresDeliverableArtifact: Bool,
        latestRun: PendingTaskReviewRunSnapshot?,
        runs: [PendingTaskReviewRunSnapshot],
        events: [PendingTaskReviewEventSnapshot]
    ) -> Bool {
        guard requiresDeliverableArtifact, let latestRun else { return false }

        if taskStatus == .completed {
            return !isTaskDone && latestRun.status == .completed
        }

        guard taskStatus == .pendingUser else { return false }
        let dismissed = events.contains { event in
            event.type == "task.dismissed" &&
                (event.runID == latestRun.id || legacyDismissal(event, appliesTo: latestRun, runs: runs))
        }
        guard !dismissed else { return false }

        let stopReason = TaskRunStopReason(rawValue: latestRun.stopReason)
        guard !stopReasonIsPolicyBlocked(stopReason) else { return false }
        return stopReason == .noUsableResult || latestRun.status == .completed
    }

    static func dismissalReason(for task: AgentTask, latestRun: TaskRun?) -> PendingTaskDismissalReason? {
        reviewState(for: task, latestRun: latestRun).dismissalReason
    }

    static func isDismissed(task: AgentTask, latestRun: TaskRun?) -> Bool {
        reviewState(for: task, latestRun: latestRun).isDismissed
    }

    static func completedTaskNeedsArtifactAttention(task: AgentTask, latestRun: TaskRun?) -> Bool {
        guard task.status == .completed,
              !task.isDone,
              let latestRun,
              latestRun.status == .completed else {
            return false
        }

        return TaskDeliverableExpectation.requiresDeliverableArtifact(task) &&
            !TaskDeliverableExpectation.hasRunScopedArtifact(for: task, run: latestRun)
    }

    static func completedTaskNeedsArtifactAttention(_ input: PendingTaskReviewSnapshotInput) -> Bool {
        guard input.taskStatus == .completed,
              !input.isTaskDone,
              let latestRun = input.latestRun,
              latestRun.status == .completed else {
            return false
        }
        return input.requiresDeliverableArtifact && !input.latestRunHasScopedArtifact
    }

    static func reviewState(for task: AgentTask, latestRun: TaskRun?) -> PendingTaskReviewState {
        guard task.status == .pendingUser, let latestRun else { return .none }

        let dismissed = task.events.contains { event in
            event.type == "task.dismissed" &&
                (event.run?.id == latestRun.id || legacyDismissal(event, appliesTo: latestRun, task: task))
        }
        guard !dismissed else {
            return PendingTaskReviewState(isDismissed: true, dismissalReason: nil)
        }

        return PendingTaskReviewState(
            isDismissed: false,
            dismissalReason: unresolvedDismissalReason(for: task, latestRun: latestRun)
        )
    }

    static func reviewState(for input: PendingTaskReviewSnapshotInput) -> PendingTaskReviewState {
        guard input.taskStatus == .pendingUser, let latestRun = input.latestRun else { return .none }

        let dismissed = input.events.contains { event in
            event.type == "task.dismissed" &&
                (event.runID == latestRun.id || legacyDismissal(event, appliesTo: latestRun, runs: input.runs))
        }
        guard !dismissed else {
            return PendingTaskReviewState(isDismissed: true, dismissalReason: nil)
        }

        return PendingTaskReviewState(
            isDismissed: false,
            dismissalReason: unresolvedDismissalReason(
                for: latestRun,
                requiresDeliverableArtifact: input.requiresDeliverableArtifact,
                hasScopedArtifact: input.latestRunHasScopedArtifact
            )
        )
    }

    private static func unresolvedDismissalReason(for task: AgentTask, latestRun: TaskRun) -> PendingTaskDismissalReason? {
        if latestRun.typedStopReason == .noUsableResult {
            if TaskDeliverableExpectation.requiresDeliverableArtifact(task),
               !TaskDeliverableExpectation.hasRunScopedArtifact(for: task, run: latestRun) {
                return .noUsableResult
            }
            return nil
        }

        if stopReasonIsPolicyBlocked(latestRun.typedStopReason) {
            return .policyBlocked
        }

        guard latestRun.status == .completed else {
            return nil
        }

        if TaskDeliverableExpectation.requiresDeliverableArtifact(task),
           !TaskDeliverableExpectation.hasRunScopedArtifact(for: task, run: latestRun) {
            return .missingRequiredArtifact
        }

        return nil
    }

    private static func unresolvedDismissalReason(
        for latestRun: PendingTaskReviewRunSnapshot,
        requiresDeliverableArtifact: Bool,
        hasScopedArtifact: Bool
    ) -> PendingTaskDismissalReason? {
        let typedStopReason = TaskRunStopReason(rawValue: latestRun.stopReason)
        if typedStopReason == .noUsableResult {
            return requiresDeliverableArtifact && !hasScopedArtifact ? .noUsableResult : nil
        }
        if stopReasonIsPolicyBlocked(typedStopReason) {
            return .policyBlocked
        }
        guard latestRun.status == .completed else { return nil }
        return requiresDeliverableArtifact && !hasScopedArtifact ? .missingRequiredArtifact : nil
    }

    private static func legacyDismissal(_ event: TaskEvent, appliesTo run: TaskRun, task: AgentTask) -> Bool {
        guard event.run == nil, event.timestamp >= run.startedAt else { return false }

        let nextRunStartedAt = task.runs
            .filter { $0.id != run.id && $0.startedAt > run.startedAt }
            .map(\.startedAt)
            .min()

        if let nextRunStartedAt {
            return event.timestamp < nextRunStartedAt
        }

        return true
    }

    private static func legacyDismissal(
        _ event: PendingTaskReviewEventSnapshot,
        appliesTo run: PendingTaskReviewRunSnapshot,
        runs: [PendingTaskReviewRunSnapshot]
    ) -> Bool {
        guard event.runID == nil, event.timestamp >= run.startedAt else { return false }
        let nextRunStartedAt = runs
            .filter { $0.id != run.id && $0.startedAt > run.startedAt }
            .map(\.startedAt)
            .min()
        return nextRunStartedAt.map { event.timestamp < $0 } ?? true
    }

    static func stopReasonIsPolicyBlocked(_ stopReason: String) -> Bool {
        TaskRunStopReason(rawValue: stopReason)?.isPolicyBlocked ?? false
    }

    static func stopReasonIsPolicyBlocked(_ stopReason: TaskRunStopReason?) -> Bool {
        stopReason?.isPolicyBlocked ?? false
    }
}

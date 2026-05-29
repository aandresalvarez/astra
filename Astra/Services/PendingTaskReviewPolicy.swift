import Foundation

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

enum PendingTaskReviewPolicy {
    static func dismissalReason(for task: AgentTask, latestRun: TaskRun?) -> PendingTaskDismissalReason? {
        reviewState(for: task, latestRun: latestRun).dismissalReason
    }

    static func isDismissed(task: AgentTask, latestRun: TaskRun?) -> Bool {
        reviewState(for: task, latestRun: latestRun).isDismissed
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

    private static func unresolvedDismissalReason(for task: AgentTask, latestRun: TaskRun) -> PendingTaskDismissalReason? {
        if latestRun.stopReason == "no_usable_result" {
            if TaskDeliverableExpectation.requiresStandaloneArtifact(task),
               !TaskDeliverableExpectation.hasArtifact(for: task, run: latestRun) {
                return .noUsableResult
            }
            return nil
        }

        if stopReasonIsPolicyBlocked(latestRun.stopReason) {
            return .policyBlocked
        }

        guard latestRun.status == .completed else {
            return nil
        }

        if TaskDeliverableExpectation.requiresStandaloneArtifact(task),
           !TaskDeliverableExpectation.hasArtifact(for: task, run: latestRun) {
            return .missingRequiredArtifact
        }

        return nil
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

    static func stopReasonIsPolicyBlocked(_ stopReason: String) -> Bool {
        stopReason.lowercased().contains("policy")
    }
}

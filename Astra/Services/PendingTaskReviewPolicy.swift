import Foundation

enum PendingTaskDismissalReason: Equatable {
    case noUsableResult
    case policyBlocked
    case missingRequiredArtifact
}

enum PendingTaskReviewPolicy {
    static func dismissalReason(for task: AgentTask, latestRun: TaskRun?) -> PendingTaskDismissalReason? {
        guard task.status == .pendingUser, let latestRun else { return nil }

        if latestRun.stopReason == "no_usable_result" {
            return .noUsableResult
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

    static func stopReasonIsPolicyBlocked(_ stopReason: String) -> Bool {
        stopReason.lowercased().contains("policy")
    }
}

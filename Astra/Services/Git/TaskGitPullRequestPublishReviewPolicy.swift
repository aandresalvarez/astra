import ASTRAModels

/// UI visibility for a required typed publication outcome. Provider authority
/// is intentionally absent from this decision: Auto may perform publication,
/// but it may not turn an unresolved durable requirement into generic result
/// approval without a verified receipt.
enum TaskGitPullRequestPublishReviewPolicy {
    static func shouldOffer(
        taskStatus: TaskStatus,
        latestRunStopReason: TaskRunStopReason?,
        hasPendingPublication: Bool
    ) -> Bool {
        taskStatus == .pendingUser
            && latestRunStopReason == .externalOutcomePending
            && hasPendingPublication
    }
}

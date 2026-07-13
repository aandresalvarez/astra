import SwiftData
import ASTRAModels

/// Applies task/run state transitions when the provider has finished local work
/// but ASTRA must retain control of either an approval or completion gate.
enum TaskRuntimeOutcomeTransition {
    @MainActor
    static func applyPolicyApproval(
        task: AgentTask,
        run: TaskRun,
        approvalMessage: String?,
        modelContext: ModelContext
    ) {
        let message = approvalMessage ?? "The provider needs a runtime permission before it can continue."
        if let publicationFailure = TaskExternalOutcomeFailureClassifier.failureForGitHubPullRequestEvidence(
            task: task,
            run: run,
            evidence: message
        ) {
            applyPendingExternalOutcome(
                task: task,
                run: run,
                failure: publicationFailure,
                modelContext: modelContext
            )
            return
        }

        run.recordPermissionApprovalRequired()
        TaskStateMachine.pauseForRuntimePermission(task, modelContext: modelContext)
        TaskRuntimePermissionOpenRequestStore.recordOpenRequest(payload: message, task: task)
        modelContext.insert(TaskEvent(
            task: task,
            eventType: TaskEventTypes.Tool.permissionApprovalRequested,
            payload: message,
            run: run
        ))
    }

    @MainActor
    static func applyCompletionBlock(
        _ decision: TaskCompletionPolicyDecision,
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext
    ) {
        if decision.gate == .requiredExternalOutcome {
            let failure = TaskExternalOutcomeFailureClassifier.pendingGitHubPullRequestFailure(
                task: task,
                run: run
            )
            applyPendingExternalOutcome(
                task: task,
                run: run,
                failure: failure,
                modelContext: modelContext
            )
        } else {
            run.recordCompletionBlocked(
                stopReason: decision.typedStopReason ?? TaskRunStopReason.custom(decision.gate.rawValue)
            )
            TaskStateMachine.pauseForValidationReview(task, modelContext: modelContext)
        }
        modelContext.insert(TaskEvent(
            task: task,
            eventType: TaskEventTypes.System.error,
            payload: decision.userVisibleMessage ?? "Task completion blocked by \(decision.gate.rawValue).",
            run: run
        ))
    }

    @MainActor
    private static func applyPendingExternalOutcome(
        task: AgentTask,
        run: TaskRun,
        failure: TaskRequiredExternalOutcomeFailure?,
        modelContext: ModelContext
    ) {
        run.recordExternalOutcomePending()
        TaskStateMachine.pauseForExternalOutcome(task, modelContext: modelContext)
        guard let failure else { return }
        modelContext.insert(TaskEvent.structuredPayloadEvent(
            task: task,
            type: TaskExternalOutcomeEventTypes.publicationFailed,
            payload: failure,
            run: run
        ))
    }
}

import SwiftData
import ASTRAModels

/// Applies task/run state transitions when the provider has finished local work
/// but ASTRA must retain control of either an approval or completion gate.
enum TaskRuntimeOutcomeTransition {
    /// Records a future typed publication gate without changing the current
    /// completion blocker. Artifact review may have to happen first, but the
    /// durable request ensures a later manual approval re-evaluates the PR
    /// outcome instead of completing the task directly.
    @MainActor
    @discardableResult
    static func queueGitHubPullRequestIfNeeded(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext
    ) -> Bool {
        guard let request = TaskExternalOutcomeRequirementResolver.makeGitHubPullRequest(
            task: task,
            run: run
        ) else { return false }
        let alreadyRequested = task.events.contains {
            $0.run?.id == run.id && $0.type == TaskExternalOutcomeEventTypes.publicationRequested
        }
        guard !alreadyRequested else { return false }
        modelContext.insert(TaskEvent.structuredPayloadEvent(
            task: task,
            type: TaskExternalOutcomeEventTypes.publicationRequested,
            payload: request,
            run: run
        ))
        return true
    }

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
        ), let publicationRequest = TaskExternalOutcomeRequirementResolver.makeGitHubPullRequest(
            task: task,
            run: run,
            message: publicationFailure.message
        ) {
            applyPendingExternalOutcome(
                task: task,
                run: run,
                request: publicationRequest,
                legacyFailure: publicationFailure,
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
            let legacyFailure = TaskExternalOutcomeFailureClassifier.pendingGitHubPullRequestFailure(
                task: task,
                run: run
            )
            let request = TaskExternalOutcomeRequirementResolver.pendingGitHubPullRequest(
                task: task,
                run: run
            ) ?? TaskExternalOutcomeRequirementResolver.makeGitHubPullRequest(task: task, run: run)
            if let request {
                applyPendingExternalOutcome(
                    task: task,
                    run: run,
                    request: request,
                    legacyFailure: legacyFailure,
                    modelContext: modelContext
                )
            } else {
                run.recordCompletionBlocked(stopReason: .externalOutcomePending)
                TaskStateMachine.pauseForExternalOutcome(task, modelContext: modelContext)
            }
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
        request: TaskRequiredExternalOutcomeRequest,
        legacyFailure: TaskRequiredExternalOutcomeFailure? = nil,
        modelContext: ModelContext
    ) {
        run.recordExternalOutcomePending()
        TaskStateMachine.pauseForExternalOutcome(task, modelContext: modelContext)
        let alreadyRequested = task.events.contains {
            $0.run?.id == run.id && $0.type == TaskExternalOutcomeEventTypes.publicationRequested
        }
        if !alreadyRequested {
            modelContext.insert(TaskEvent.structuredPayloadEvent(
                task: task,
                type: TaskExternalOutcomeEventTypes.publicationRequested,
                payload: request,
                run: run
            ))
        }
        let alreadyFailed = task.events.contains {
            $0.run?.id == run.id && $0.type == TaskExternalOutcomeEventTypes.publicationFailed
        }
        if let legacyFailure, !alreadyFailed {
            modelContext.insert(TaskEvent.structuredPayloadEvent(
                task: task,
                type: TaskExternalOutcomeEventTypes.publicationFailed,
                payload: legacyFailure,
                run: run
            ))
        }
    }
}

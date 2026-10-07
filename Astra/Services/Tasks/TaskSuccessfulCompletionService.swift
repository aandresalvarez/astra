import Foundation
import SwiftData
import ASTRAModels

/// Owns the deterministic transition from successful provider work to either
/// task completion or a typed ASTRA review gate.
enum TaskSuccessfulCompletionService {
    @MainActor
    static func apply(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        successPayload: String,
        permissionPolicy: PermissionPolicy,
        reviewOriginURL: @escaping (String) async -> String? = { path in
            await GitService.shared.getRemoteOriginURL(at: path)
        },
        reviewPublicationService: GitHubReviewPublicationService? = nil
    ) async -> Bool {
        do {
            if try TaskPermissionContinuation.applyBlockingOutcomeIfNeeded(task: task, run: run, modelContext: modelContext) {
                return false
            }
        } catch { return false }
        await GitHubReviewPublicationRequirement.bindOriginTargetIfNeeded(
            task: task,
            run: run,
            modelContext: modelContext,
            originURL: reviewOriginURL
        )
        await GitHubReviewAutoPost.postIfAuto(
            task: task,
            run: run,
            policyLevel: permissionPolicy.agentPolicyLevel,
            modelContext: modelContext,
            service: reviewPublicationService
                ?? GitHubReviewPublicationService(modelContext: modelContext, originURL: reviewOriginURL)
        )
        if ExternalActionPolicy.asksUser(for: .gitPullRequestPublication, level: permissionPolicy.agentPolicyLevel) {
            TaskRuntimeOutcomeTransition.queueGitHubPullRequestIfNeeded(
                task: task,
                run: run,
                modelContext: modelContext
            )
        }
        let decision = TaskCompletionPolicy.decideSuccessfulCompletion(
            task: task,
            run: run,
            permissionPolicy: permissionPolicy
        )
        if decision.shouldBlockCompletion {
            TaskRuntimeOutcomeTransition.applyCompletionBlock(
                decision,
                task: task,
                run: run,
                modelContext: modelContext
            )
            return false
        }

        TaskStateMachine.completeFromRuntime(task, modelContext: modelContext)
        modelContext.insert(TaskEvent(
            task: task,
            eventType: TaskEventTypes.Task.completed,
            payload: successPayload,
            run: run
        ))
        return true
    }

    /// Re-runs every remaining completion gate after a durable external
    /// outcome receipt. A PR receipt cannot bypass a pending review receipt,
    /// and a review receipt cannot bypass a pending PR publication.
    @MainActor
    static func applyAfterRequiredExternalOutcome(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        reviewOriginURL: (String) async -> String? = { path in
            await GitService.shared.getRemoteOriginURL(at: path)
        }
    ) async -> Bool {
        if let reason = run.typedStopReason, reason != .externalOutcomePending {
            return false
        }
        await GitHubReviewPublicationRequirement.bindOriginTargetIfNeeded(
            task: task,
            run: run,
            modelContext: modelContext,
            originURL: reviewOriginURL
        )
        let decision = TaskCompletionPolicy.decideSuccessfulCompletion(
            task: task,
            run: run
        )
        if decision.shouldBlockCompletion {
            TaskRuntimeOutcomeTransition.applyCompletionBlock(
                decision,
                task: task,
                run: run,
                modelContext: modelContext
            )
            return false
        }
        guard run.typedStopReason == .externalOutcomePending else { return false }

        let completedAt = Date()
        run.recordExternalOutcomeCompleted(at: completedAt)
        TaskStateMachine.completeFromUserApproval(
            task,
            modelContext: modelContext,
            at: completedAt
        )
        return true
    }
}

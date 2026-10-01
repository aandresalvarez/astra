import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

@MainActor
enum ApprovedPlanRuntimeSettlement {
    /// Returns false when the run was rejected (checkpoint, provider blocker,
    /// or contract) so the caller can terminalize the durable turn as failed
    /// instead of completed. A pause that only awaits the NEXT step's approval
    /// is an accepted outcome — that step's work really did land.
    @MainActor
    static func finalizeApprovedPlanStep(
        _ step: TaskPlanPayloadStep,
        plan: TaskPlanPayload,
        task: AgentTask,
        workspacePath: String? = nil,
        sandboxEnforcementSnapshot: ExecutionSandboxEnforcement? = nil,
        modelContext: ModelContext,
        verifierRuntime: AgentUtilityRuntimeConfiguration
    ) async -> Bool {
        let stateAfterRun = TaskPlanService.reconstruct(for: task)
        let currentStepStatus = stateAfterRun.plan?.steps.first(where: { $0.id == step.id })?.status
        let lastRun = task.runs.sorted { $0.startedAt < $1.startedAt }.last

        // Checkpoint: a finished process is a claim, not evidence. Resolve the
        // step's declared required outputs before recording it done — even a
        // provider-emitted completion marker doesn't outrank a missing output.
        // Provider-skipped steps are exempt (their outputs legitimately don't
        // exist), and a provider-reported blocker takes priority below so its
        // actionable detail isn't shadowed by a generic checkpoint message.
        let checkpoint = PlanStepCheckpointVerifier.verify(
            step: step,
            plan: plan,
            task: task,
            workspacePath: workspacePath
        )
        let latestBlockIsCheckpointImposed = PlanStepCheckpointVerifier.latestBlockIsCheckpointImposed(
            task: task,
            stepID: step.id
        )
        let providerReportedBlock = currentStepStatus == .blocked && !latestBlockIsCheckpointImposed
        if currentStepStatus != .skipped, !providerReportedBlock, !checkpoint.missingRequiredPaths.isEmpty {
            let message = PlanStepCheckpointVerifier.recordCheckpointBlock(
                step: step,
                missing: checkpoint.missingRequiredPaths,
                plan: plan,
                task: task,
                run: lastRun,
                modelContext: modelContext
            )
            pauseApprovedPlanForUser(task: task, modelContext: modelContext, message: message, run: lastRun)
            return false
        }

        let shouldFallbackComplete: Bool = {
            switch currentStepStatus {
            case .done, .skipped:
                return false
            case .blocked:
                // Only ASTRA's own checkpoint blocks are liftable by evidence:
                // a retried step whose required outputs now exist completes.
                // Provider-reported blockers carry meaning the filesystem
                // can't refute and still need an explicit completion marker.
                return latestBlockIsCheckpointImposed
                    && checkpoint.isVerified
                    && !checkpoint.verifiedPaths.isEmpty
            case .pending, .running, nil:
                return true
            }
        }()
        if shouldFallbackComplete {
            TaskPlanService.recordStepProgress(
                type: TaskPlanEventTypes.stepCompleted,
                planID: plan.planID,
                stepID: step.id,
                status: .done,
                task: task,
                modelContext: modelContext,
                run: lastRun,
                title: step.title,
                summary: "Completed approved step: \(step.title).\(checkpoint.completionEvidence)"
            )
        } else if currentStepStatus == .done, !checkpoint.verifiedPaths.isEmpty {
            // The provider's own completion marker recorded the step; keep the
            // checkpoint's evidence in the log alongside it.
            modelContext.insert(TaskEvent(
                task: task,
                eventType: TaskEventTypes.System.info,
                payload: "Step checkpoint verified for \"\(step.title)\":\(checkpoint.completionEvidence)",
                run: lastRun
            ))
        }

        let refreshedPlan = TaskPlanService.reconstruct(for: task).plan ?? plan
        if let blockedStep = refreshedPlan.steps.first(where: { $0.id == step.id && $0.status == .blocked }) {
            pauseApprovedPlanForUser(
                task: task,
                modelContext: modelContext,
                message: blockedStep.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Plan step blocked. Fix the blocker, then approve this step again to retry."
                    : "Plan step blocked: \(blockedStep.detail)",
                run: task.runs.sorted { $0.startedAt < $1.startedAt }.last
            )
            return false
        }

        if TaskPlanService.hasRemainingExecutableSteps(in: refreshedPlan) {
            pauseApprovedPlanForUser(
                task: task,
                modelContext: modelContext,
                message: "Plan step complete. Review the next step, then approve it when you're ready.",
                run: task.runs.sorted { $0.startedAt < $1.startedAt }.last
            )
        } else {
            guard await validateApprovedPlanContractForFinalCompletion(
                task: task,
                plan: refreshedPlan,
                workspacePath: workspacePath,
                sandboxEnforcementSnapshot: sandboxEnforcementSnapshot,
                modelContext: modelContext, verifierRuntime: verifierRuntime
            ) else {
                return false
            }
            TaskPlanService.recordExecutionCompleted(planID: plan.planID, task: task, modelContext: modelContext)
        }
        return true
    }

    /// Returns false when the plan was rejected after the run; see
    /// `finalizeApprovedPlanStep`.
    @MainActor
    static func finalizeApprovedFullPlan(
        _ plan: TaskPlanPayload,
        task: AgentTask,
        workspacePath: String? = nil,
        sandboxEnforcementSnapshot: ExecutionSandboxEnforcement? = nil,
        modelContext: ModelContext,
        verifierRuntime: AgentUtilityRuntimeConfiguration
    ) async -> Bool {
        let refreshedPlan = TaskPlanService.reconstruct(for: task).plan ?? plan
        if let blockedStep = refreshedPlan.steps.first(where: { $0.status == .blocked }) {
            pauseApprovedPlanForUser(
                task: task,
                modelContext: modelContext,
                message: blockedStep.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Plan blocked. Fix the blocker, then approve the plan again to retry."
                    : "Plan blocked at \(blockedStep.title): \(blockedStep.detail)",
                run: task.runs.sorted { $0.startedAt < $1.startedAt }.last
            )
            return false
        }

        // Single-run plans have no intermediate run boundaries, so the output
        // checkpoint for every step lands here instead.
        let lastRun = task.runs.sorted(by: { $0.startedAt < $1.startedAt }).last
        if let message = PlanStepCheckpointVerifier.recordFullPlanCheckpointBlocks(
            plan: refreshedPlan,
            task: task,
            run: lastRun,
            workspacePath: workspacePath,
            modelContext: modelContext
        ) {
            pauseApprovedPlanForUser(task: task, modelContext: modelContext, message: message, run: lastRun)
            return false
        }

        guard await validateApprovedPlanContractForFinalCompletion(
            task: task,
            plan: refreshedPlan,
            workspacePath: workspacePath,
            sandboxEnforcementSnapshot: sandboxEnforcementSnapshot,
            modelContext: modelContext, verifierRuntime: verifierRuntime
        ) else {
            return false
        }
        TaskPlanService.recordExecutionCompleted(planID: plan.planID, task: task, modelContext: modelContext)
        return true
    }

    @MainActor
    static func validateApprovedPlanContractForFinalCompletion(
        task: AgentTask,
        plan: TaskPlanPayload,
        workspacePath: String? = nil,
        sandboxEnforcementSnapshot: ExecutionSandboxEnforcement? = nil,
        modelContext: ModelContext,
        verifierRuntime: AgentUtilityRuntimeConfiguration
    ) async -> Bool {
        let contractEvaluation = await ValidationService.runContract(
            task: task,
            plan: plan,
            run: task.runs.sorted { $0.startedAt < $1.startedAt }.last,
            modelContext: modelContext,
            workspacePath: workspacePath,
            verifierRuntime: verifierRuntime,
            commandRunner: ShellValidationCommandRunner(
                sandboxEnforcementSnapshot: sandboxEnforcementSnapshot
            )
        )
        let decision = TaskCompletionPolicy.decide(validationContract: contractEvaluation)
        guard decision.canComplete else {
            let run = task.runs.sorted { $0.startedAt < $1.startedAt }.last
            run?.status = .failed
            run?.typedStopReason = decision.typedStopReason ?? TaskRunStopReason.custom(TaskCompletionPolicyGate.validationContract.rawValue)
            pauseApprovedPlanForUser(
                task: task,
                modelContext: modelContext,
                message: decision.userVisibleMessage ?? contractEvaluation.summary,
                run: run
            )
            return false
        }
        return true
    }

    @MainActor
    static func pauseApprovedPlanForUser(
        task: AgentTask,
        modelContext: ModelContext,
        message: String,
        run: TaskRun?
    ) {
        let notice = TaskEvent(
            task: task,
            eventType: TaskEventTypes.System.info,
            payload: message,
            run: run
        )
        modelContext.insert(notice)
        TaskStateMachine.pauseForValidationReview(task, modelContext: modelContext)
    }
}

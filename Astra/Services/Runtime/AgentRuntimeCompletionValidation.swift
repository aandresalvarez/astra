import SwiftData
import ASTRACore
import ASTRAModels

@MainActor
enum AgentRuntimeCompletionValidation {
    /// Every reason a process that exited cleanly still must not be filed as a
    /// completed run, in the order they take precedence. The agent's own
    /// verdict comes first: if the provider said the turn failed, there is
    /// nothing for deliverable verification to grade.
    static func applyCompletionBlocksIfNeeded(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        workspacePath: String,
        agentReportedError: Bool
    ) async -> Bool {
        if applyAgentReportedErrorIfNeeded(
            task: task,
            run: run,
            modelContext: modelContext,
            agentReportedError: agentReportedError
        ) {
            return true
        }
        return await applyDeliverableVerificationFailureIfNeeded(
            task: task,
            run: run,
            modelContext: modelContext,
            workspacePath: workspacePath
        )
    }

    /// The provider's stream reported that the turn failed. Codex reports this
    /// and then exits 0, so `exitCode == 0` is not evidence the work happened —
    /// prod task 484A69A5 spent 685,203 tokens, logged four
    /// `task.failed reason=agent_reported_error` events, and still finished
    /// `run_status=completed task_status=completed`, with the disagreement
    /// visible only as `error_event_count=4` in the persistence summary.
    ///
    /// The agent's message was already written to the transcript by
    /// `AgentEventRecorder`, so this changes the outcome without adding a
    /// second copy of the explanation.
    @discardableResult
    static func applyAgentReportedErrorIfNeeded(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        agentReportedError: Bool
    ) -> Bool {
        guard agentReportedError else { return false }
        run.recordAgentReportedFailure()
        TaskStateMachine.failFromRuntime(task, modelContext: modelContext)
        AppLogger.audit(.taskFailed, category: "Worker", taskID: task.id, fields: [
            "run_id": run.id.uuidString,
            "reason": "agent_reported_error",
            "source": "run_outcome",
            "exit_code": run.exitCode.map(String.init) ?? "none"
        ], level: .warning)
        return true
    }

    static func applyDeliverableVerificationFailureIfNeeded(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        workspacePath: String
    ) async -> Bool {
        let result = await TaskDeliverableVerificationService.evaluate(
            task: task,
            run: run,
            modelContext: modelContext,
            workspacePath: workspacePath
        )
        guard let eventType = TaskDeliverableVerificationService.eventType(for: result) else {
            return false
        }

        modelContext.insert(TaskEvent(
            task: task,
            type: eventType,
            payload: TaskDeliverableVerificationService.encode(result),
            run: run
        ))

        let auditEvent: AuditEvent = switch result.status {
        case "passed":
            .deliverableVerificationPassed
        case "review_needed":
            .deliverableVerificationReviewNeeded
        default:
            .deliverableVerificationFailed
        }
        AppLogger.audit(auditEvent, category: "Validation", taskID: task.id, fields: [
            "run_id": run.id.uuidString,
            "profile": result.profile.rawValue,
            "level": result.level.rawValue,
            "status": result.status,
            "can_complete": String(result.canComplete),
            "requires_human_review": String(result.requiresHumanReview),
            "check_count": String(result.checks.count),
            "evidence_count": String(result.evidencePaths.count)
        ], level: result.shouldBlockCompletion ? .warning : .info)

        let decision = TaskCompletionPolicy.decide(deliverableVerification: result)
        guard decision.shouldBlockCompletion else {
            return false
        }

        TaskRuntimeOutcomeTransition.applyCompletionBlock(
            decision,
            task: task,
            run: run,
            modelContext: modelContext
        )
        return true
    }

    static func applyAutomaticBaselineVerificationIfNeeded(
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        workspacePath: String,
        sandboxEnforcementSnapshot: ExecutionSandboxEnforcement?
    ) async {
        let result = await TaskInferredValidationService.runAutomaticBaselineIfNeeded(
            task: task,
            modelContext: modelContext,
            workspacePath: workspacePath,
            commandRunner: ShellValidationCommandRunner(
                sandboxEnforcementSnapshot: sandboxEnforcementSnapshot
            )
        )
        guard result.didRun else { return }

        AppLogger.audit(
            result.canComplete ? .validationContractPassed : .validationContractFailed,
            category: "Validation",
            taskID: task.id,
            fields: [
                "run_id": run.id.uuidString,
                "source": "automatic_inferred_baseline",
                "can_complete": String(result.canComplete),
                "failed_required_assertion_count": String(result.failedRequiredAssertionIDs.count)
            ],
            level: result.canComplete ? .info : .warning
        )

        let decision = TaskCompletionPolicy.decide(inferredValidation: result)
        guard !decision.canComplete else { return }
        TaskRuntimeOutcomeTransition.applyCompletionBlock(
            decision,
            task: task,
            run: run,
            modelContext: modelContext
        )
    }
}

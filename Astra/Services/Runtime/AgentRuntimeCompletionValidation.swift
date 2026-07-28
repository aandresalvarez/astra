import SwiftData
import ASTRACore
import ASTRAModels

@MainActor
enum AgentRuntimeCompletionValidation {
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

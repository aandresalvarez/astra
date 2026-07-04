import Foundation
import SwiftData
import ASTRACore

struct AgentRuntimeBudgetSnapshot: Equatable, Sendable {
    let effectiveTokenBudget: Int
    let tokensUsed: Int

    init(effectiveTokenBudget: Int, tokensUsed: Int) {
        self.effectiveTokenBudget = effectiveTokenBudget
        self.tokensUsed = tokensUsed
    }

    @MainActor
    init(task: AgentTask) {
        self.init(
            effectiveTokenBudget: AgentRuntimeProcessRunner.effectiveTokenBudget(for: task),
            tokensUsed: task.tokensUsed
        )
    }

    var hasReportedTokensAboveBudget: Bool {
        hasEnabledBudget && tokensUsed > effectiveTokenBudget
    }

    var hasEnabledBudget: Bool {
        effectiveTokenBudget != Int.max
    }
}

enum AgentRuntimeBudgetPolicy {
    @MainActor
    static func enforcePromptBudgetIfNeeded(
        prompt: String,
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        phase: RunPhase,
        runtime: AgentRuntimeID,
        budgetEnforcementMode: BudgetEnforcementMode
    ) -> Bool {
        let tokenBudget = AgentRuntimeProcessRunner.effectiveTokenBudget(for: task)
        guard tokenBudget != Int.max else { return true }

        let promptTokens = AgentProcessMonitor.estimatedTokenCount(for: prompt)
        let launchOverhead = AgentRuntimeProcessRunner.launchOverheadTokens(for: runtime)
        let estimatedInputTokens = promptTokens + launchOverhead
        guard estimatedInputTokens > tokenBudget else { return true }

        // The launch overhead models the provider's fixed billed runtime context
        // (e.g. Claude Code's system prompt + tool schemas), not task work the user
        // can trim. When the prompt itself fits the budget and only the fixed floor
        // pushes the estimate over, an advisory Warning-mode notice would fire on
        // essentially every task with no actionable remedy — so we suppress the
        // user-facing warning and keep only a debug breadcrumb. Hard-stop still
        // blocks below: a budget under the provider's fixed floor cannot complete.
        let isLaunchOverheadFloor = tokenBudget <= launchOverhead && promptTokens <= tokenBudget

        let fields = [
            "phase": phase.rawValue,
            "reason": "prompt_budget_estimate_exceeded",
            "estimated_input_tokens": String(estimatedInputTokens),
            "prompt_estimate_tokens": String(promptTokens),
            "launch_overhead_tokens": String(launchOverhead),
            "launch_overhead_floor": String(isLaunchOverheadFloor),
            "runtime": runtime.rawValue,
            "token_budget": String(tokenBudget),
            "configured_task_budget": String(task.tokenBudget),
            "enforcement": budgetEnforcementMode.rawValue
        ]

        if budgetEnforcementMode == .warning && isLaunchOverheadFloor {
            AppLogger.audit(.workerBudgetExceeded, category: "Worker", taskID: task.id, fields: fields, level: .debug)
            return true
        }

        if budgetEnforcementMode == .warning {
            let message = "Launch estimate exceeds the task budget before launch (\(estimatedInputTokens)/\(tokenBudget)). ASTRA started the provider because Budget Enforcement is set to Warning Only."
            modelContext.insert(TaskEvent(
                task: task,
                eventType: TaskEventTypes.Budget.warning,
                payload: message,
                run: run
            ))
            AppLogger.audit(.workerBudgetExceeded, category: "Worker", taskID: task.id, fields: fields, level: .warning)
            return true
        }

        run.status = .budgetExceeded
        run.completedAt = Date()
        run.typedStopReason = .maxBudgetReached
        TaskStateMachine.exceedBudgetFromRuntime(task, modelContext: modelContext, at: run.completedAt ?? Date())
        let message = "Launch estimate exceeds the task budget before launch (\(estimatedInputTokens)/\(tokenBudget)). Provider was not started."
        modelContext.insert(TaskEvent(
            task: task,
            eventType: TaskEventTypes.Budget.exceeded,
            payload: message,
            run: run
        ))
        AppLogger.audit(.workerBudgetExceeded, category: "Worker", taskID: task.id, fields: fields, level: .error)
        WorkspacePersistenceCoordinator.saveAndAutoExport(
            workspace: task.workspace,
            modelContext: modelContext,
            taskID: task.id,
            auditFields: ["operation": "prompt_budget_exceeded_stop"]
        )
        return false
    }

    static func shouldTreatAsBudgetExceeded(
        result: AgentProcessResult,
        budget: AgentRuntimeBudgetSnapshot,
        budgetEnforcementMode: BudgetEnforcementMode
    ) -> Bool {
        guard budget.hasEnabledBudget else { return false }
        return result.budgetExceeded ||
            (budgetEnforcementMode == .hardStop && hasReportedTokensAboveBudget(budget: budget))
    }

    @MainActor
    static func shouldTreatAsBudgetExceeded(
        result: AgentProcessResult,
        task: AgentTask,
        budgetEnforcementMode: BudgetEnforcementMode
    ) -> Bool {
        shouldTreatAsBudgetExceeded(
            result: result,
            budget: AgentRuntimeBudgetSnapshot(task: task),
            budgetEnforcementMode: budgetEnforcementMode
        )
    }

    @MainActor
    static func recordFinalBudgetWarningIfNeeded(
        result: AgentProcessResult,
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        phase: RunPhase,
        budgetEnforcementMode: BudgetEnforcementMode
    ) {
        guard AgentRuntimeBudgetSnapshot(task: task).hasEnabledBudget else { return }

        let reportedBudgetWarning = budgetEnforcementMode == .warning && hasReportedTokensAboveBudget(task: task)
        guard result.budgetWarning || result.finalReportedBudgetExceededAfterCompletion || reportedBudgetWarning else {
            return
        }
        let message: String
        let reason: String
        if result.budgetWarning || reportedBudgetWarning {
            message = "Budget exceeded in warning mode (\(task.tokensUsed)/\(task.tokenBudget)). ASTRA kept the provider running because Budget Enforcement is set to Warning Only."
            reason = "budget_exceeded_warning_mode"
        } else {
            message = "Completed after exceeding the reported provider token budget (\(task.tokensUsed)/\(task.tokenBudget)). The completion marker was emitted before the final usage report, so ASTRA recorded this as a warning instead of a budget kill."
            reason = "final_reported_budget_exceeded_after_completion"
        }
        modelContext.insert(TaskEvent(
            task: task,
            eventType: TaskEventTypes.Budget.warning,
            payload: message,
            run: run
        ))
        AppLogger.audit(.workerBudgetExceeded, category: "Worker", taskID: task.id, fields: [
            "phase": phase.rawValue,
            "reason": reason,
            "tokens_used": String(task.tokensUsed),
            "token_budget": String(task.tokenBudget)
        ], level: .warning)
    }

    static func hasReportedTokensAboveBudget(budget: AgentRuntimeBudgetSnapshot) -> Bool {
        budget.hasReportedTokensAboveBudget
    }

    @MainActor
    static func hasReportedTokensAboveBudget(task: AgentTask) -> Bool {
        hasReportedTokensAboveBudget(budget: AgentRuntimeBudgetSnapshot(task: task))
    }
}

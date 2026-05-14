import Foundation
import SwiftData
import ASTRACore

@MainActor
enum AgentRuntimeBudgetPolicy {
    static func enforcePromptBudgetIfNeeded(
        prompt: String,
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        phase: String,
        runtime: AgentRuntimeID,
        budgetEnforcementMode: BudgetEnforcementMode
    ) -> Bool {
        let tokenBudget = AgentRuntimeProcessRunner.effectiveTokenBudget(for: task)
        guard tokenBudget != Int.max else { return true }

        let estimatedInputTokens = AgentRuntimeProcessRunner.estimatedLaunchInputTokens(prompt: prompt, runtime: runtime)
        guard estimatedInputTokens > tokenBudget else { return true }

        let fields = [
            "phase": phase,
            "reason": "prompt_budget_estimate_exceeded",
            "estimated_input_tokens": String(estimatedInputTokens),
            "launch_overhead_tokens": String(AgentRuntimeProcessRunner.launchOverheadTokens(for: runtime)),
            "runtime": runtime.rawValue,
            "token_budget": String(tokenBudget),
            "configured_task_budget": String(task.tokenBudget),
            "enforcement": budgetEnforcementMode.rawValue
        ]

        if budgetEnforcementMode == .warning {
            let message = "Launch estimate exceeds the task budget before launch (\(estimatedInputTokens)/\(tokenBudget)). ASTRA started the provider because Budget Enforcement is set to Warning Only."
            modelContext.insert(TaskEvent(task: task, type: "budget.warning", payload: message, run: run))
            AppLogger.audit(.workerBudgetExceeded, category: "Worker", taskID: task.id, fields: fields, level: .warning)
            return true
        }

        run.status = .budgetExceeded
        run.completedAt = Date()
        run.stopReason = "max_budget_reached"
        task.status = .budgetExceeded
        task.updatedAt = Date()
        task.markUnreadForCurrentStatus(at: task.updatedAt)
        let message = "Launch estimate exceeds the task budget before launch (\(estimatedInputTokens)/\(tokenBudget)). Provider was not started."
        modelContext.insert(TaskEvent(task: task, type: "budget.exceeded", payload: message, run: run))
        AppLogger.audit(.workerBudgetExceeded, category: "Worker", taskID: task.id, fields: fields, level: .error)
        try? modelContext.save()
        return false
    }

    static func shouldTreatAsBudgetExceeded(
        result: AgentProcessResult,
        task: AgentTask,
        budgetEnforcementMode: BudgetEnforcementMode
    ) -> Bool {
        result.budgetExceeded ||
            (budgetEnforcementMode == .hardStop && hasReportedTokensAboveBudget(task: task))
    }

    static func recordFinalBudgetWarningIfNeeded(
        result: AgentProcessResult,
        task: AgentTask,
        run: TaskRun,
        modelContext: ModelContext,
        phase: String,
        budgetEnforcementMode: BudgetEnforcementMode
    ) {
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
            type: "budget.warning",
            payload: message,
            run: run
        ))
        AppLogger.audit(.workerBudgetExceeded, category: "Worker", taskID: task.id, fields: [
            "phase": phase,
            "reason": reason,
            "tokens_used": String(task.tokensUsed),
            "token_budget": String(task.tokenBudget)
        ], level: .warning)
    }

    static func hasReportedTokensAboveBudget(task: AgentTask) -> Bool {
        let tokenBudget = AgentRuntimeProcessRunner.effectiveTokenBudget(for: task)
        return tokenBudget != Int.max && task.tokensUsed > tokenBudget
    }
}

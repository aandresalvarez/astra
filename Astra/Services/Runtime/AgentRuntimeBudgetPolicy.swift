import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

struct AgentRuntimeBudgetSnapshot: Equatable, Sendable {
    let effectiveTokenBudget: Int
    let tokensUsed: Int
    /// Whether the user actually chose this budget.
    ///
    /// An unset budget used to resolve to `Int.max`, which let one value mean
    /// two different things: "no ceiling exists" and "do not show the user
    /// budget messages". Now that an unset budget resolves to a finite runaway
    /// ceiling, those have to be tracked separately — the ceiling is real and
    /// should stop a run, but the messages quote `task.tokenBudget`, which is
    /// still 0.
    let isUserConfigured: Bool

    init(effectiveTokenBudget: Int, tokensUsed: Int, isUserConfigured: Bool? = nil) {
        self.effectiveTokenBudget = effectiveTokenBudget
        self.tokensUsed = tokensUsed
        self.isUserConfigured = isUserConfigured ?? (effectiveTokenBudget != Int.max)
    }

    @MainActor
    init(task: AgentTask) {
        self.init(
            effectiveTokenBudget: AgentRuntimeProcessRunner.effectiveTokenBudget(for: task),
            tokensUsed: task.tokensUsed,
            isUserConfigured: task.tokenBudget != 0
        )
    }

    var hasReportedTokensAboveBudget: Bool {
        hasEnforceableBudget && tokensUsed > effectiveTokenBudget
    }

    /// Whether any ceiling applies — the user's budget or the implicit runaway
    /// default. Gates enforcement.
    var hasEnforceableBudget: Bool {
        effectiveTokenBudget != Int.max
    }

    /// Whether budget reporting is meaningful to the user. Gates the warning
    /// event, whose text quotes a budget the user never set.
    var hasEnabledBudget: Bool {
        isUserConfigured
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

        // The third of three places this distinction has to be made, and the
        // one that was missed. `effectiveTokenBudget(for:)` substitutes ASTRA's
        // runaway ceiling when the user set no budget, so `tokenBudget` is
        // finite here either way and the branches below could not tell the two
        // apart. Warning Only is a preference about *your* number; the ceiling
        // is ASTRA's, and a prompt that clears it before the provider has read
        // a single token is exactly the runaway this pre-launch check exists to
        // catch. Same rule as `AgentProcessMonitor.effectiveBudgetEnforcementMode`
        // mid-stream and `shouldTreatAsBudgetExceeded` after exit.
        let isUserConfiguredBudget = task.tokenBudget != 0
        let effectiveMode: BudgetEnforcementMode = isUserConfiguredBudget ? budgetEnforcementMode : .hardStop

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
            "budget_source": isUserConfiguredBudget ? "task" : "runaway_ceiling",
            // The mode that decided this, not the one that was asked for. They
            // differ exactly when the ceiling overrode Warning Only, and a log
            // reading `enforcement=warning` next to a stopped run would be the
            // one line that makes the stop look like a bug.
            "enforcement": effectiveMode.rawValue,
            "configured_enforcement": budgetEnforcementMode.rawValue
        ]

        if effectiveMode == .warning && isLaunchOverheadFloor {
            AppLogger.audit(.workerBudgetExceeded, category: "Worker", taskID: task.id, fields: fields, level: .debug)
            return true
        }

        if effectiveMode == .warning {
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
        // Two wordings, for the same reason the budget-exceeded event in
        // `AgentRuntimeWorker` has two: "the task budget" names a number the
        // user can go and change, and when the ceiling is what fired there is
        // no such number — `task.tokenBudget` is 0. Telling someone to raise a
        // budget they never set sends them looking for a setting that would not
        // have prevented this.
        let message = isUserConfiguredBudget
            ? "Launch estimate exceeds the task budget before launch (\(estimatedInputTokens)/\(tokenBudget)). Provider was not started."
            : "Launch estimate exceeds ASTRA's runaway safety ceiling before launch (\(estimatedInputTokens)/\(tokenBudget) tokens). No token budget was set for this task, so this ceiling applied. Provider was not started."
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
        // Enforcement, not reporting: a run that blows through the implicit
        // runaway ceiling still has to be stopped and labelled, even though the
        // user never set a budget of their own.
        guard budget.hasEnforceableBudget else { return false }
        // `.warning` is a preference about the user's own budget — go past the
        // number you chose and ASTRA tells you rather than stopping you. It says
        // nothing about the runaway ceiling, which the user never chose, so a
        // ceiling breach is a hard stop in either mode. Matches
        // `AgentProcessMonitor.effectiveBudgetEnforcementMode`, which decides the
        // same question mid-stream; this is the post-hoc half, for the tokens the
        // provider only reports at the end.
        let enforcesReportedOverage = budgetEnforcementMode == .hardStop || !budget.isUserConfigured
        return result.budgetExceeded ||
            (enforcesReportedOverage && hasReportedTokensAboveBudget(budget: budget))
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

import Foundation
import ASTRACore
import ASTRAModels

/// What is left of a run's ceilings for a later attempt of the same run (the empty-turn re-run),
/// whose process monitor starts its counters at zero.
extension AgentRuntimeProcessRunner {
    @MainActor
    static func effectiveTokenBudget(for task: AgentTask) -> Int {
        let baseBudget = task.tokenBudget
        let tokenBudget = effectiveTokenBudget(
            baseBudget: baseBudget,
            usesAgentTeam: task.useAgentTeam,
            teamSize: task.teamSize
        )
        if task.useAgentTeam, baseBudget != 0 {
            AppLogger.audit(.taskStats, category: "Worker", taskID: task.id, fields: [
                "event": "team_budget_scaled",
                "base_budget": String(baseBudget),
                "team_size": String(max(2, task.teamSize)),
                "token_budget": String(tokenBudget)
            ])
        }
        return tokenBudget
    }

    static func effectiveTokenBudget(baseBudget: Int, usesAgentTeam: Bool, teamSize: Int) -> Int {
        // Zero is the persisted sentinel for Disabled. Resolve it before team
        // scaling so an unlimited budget stays unlimited instead of overflowing
        // when multiplied by the number of agents. A negative value is not a
        // sentinel — it is a malformed persisted config (workspace imports
        // assign budgets without normalizing) — so it keeps the pre-existing
        // enforcement behaviour instead of silently becoming unlimited.
        if baseBudget == 0 { return Int.max }
        guard baseBudget > 0 else { return baseBudget }
        return usesAgentTeam ? baseBudget * max(2, teamSize) : baseBudget
    }

    static func estimatedLaunchInputTokens(prompt: String, runtime: AgentRuntimeID) -> Int {
        AgentRuntimeBudgetProfile.profile(for: runtime).estimatedLaunchInputTokens(prompt: prompt)
    }

    static func launchOverheadTokens(for runtime: AgentRuntimeID) -> Int {
        AgentRuntimeBudgetProfile.profile(for: runtime).launchOverheadTokens
    }

    @MainActor
    static func attemptAllowance(task: AgentTask, policy: AgentRuntimeExecutionPolicy) -> (tokens: Int, turns: Int) {
        let tokens = remainingTokenBudget(effectiveTokenBudget(for: task), alreadyUsed: policy.providerTokensAlreadyUsed)
        let configuredTurns = remainingTurns(maxTurns: task.maxTurns, alreadyUsed: policy.providerTurnsAlreadyUsed)
        guard let recovery = policy.recoveryAllowance else { return (tokens, configuredTurns > 0 ? configuredTurns : Int.max) }
        return (min(tokens, recovery.tokensRemaining), min(configuredTurns > 0 ? configuredTurns : Int.max, recovery.turnsRemaining))
    }

    /// The turn ceiling a process monitor should enforce: the task's, less what an earlier attempt of the
    /// same run spent. 0 stays "unlimited"; a limit is never reduced below one turn.
    static func remainingTurns(maxTurns: Int, alreadyUsed: Int) -> Int {
        maxTurns > 0 ? max(1, maxTurns - alreadyUsed) : maxTurns
    }

    /// The token ceiling a monitor should enforce, less what an earlier attempt of the same run spent.
    /// Unlimited (`Int.max`) and malformed (non-positive) budgets are left as they are.
    static func remainingTokenBudget(_ budget: Int, alreadyUsed: Int) -> Int {
        budget == Int.max || budget <= 0 ? budget : max(1, budget - alreadyUsed)
    }
}

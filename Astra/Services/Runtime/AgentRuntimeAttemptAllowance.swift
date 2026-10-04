import Foundation

/// What is left of a run's ceilings for a later attempt of the same run (the empty-turn re-run),
/// whose process monitor starts its counters at zero.
extension AgentRuntimeProcessRunner {
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

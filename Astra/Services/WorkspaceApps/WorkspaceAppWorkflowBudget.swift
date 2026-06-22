import Foundation

// B3: a workflow's whole-run token budget is the sum of the token budgets declared
// by its agent-recommendation gate steps. A run accumulates `consumedTokens` from
// awaited tasks on each resume; the executor blocks the run (status `.blocked`,
// not failed) when consumption exceeds the budget, so it can be reviewed/raised
// rather than silently overrunning. A zero/unset budget means "no cap declared".
enum WorkspaceAppWorkflowBudget {
    static func declaredTokenBudget(
        for manifest: WorkspaceAppManifest,
        pipelineActionID: String
    ) -> Int {
        guard let pipeline = manifest.actions.first(where: { $0.id == pipelineActionID }) else {
            return 0
        }
        let stepIDs = Set(pipeline.steps)
        return manifest.actions
            .filter { stepIDs.contains($0.id) && $0.type == "gate.agentRecommendation" }
            .compactMap(\.agentTokenBudget)
            .reduce(0, +)
    }

    static func exceedsBudget(
        consumed: Int,
        manifest: WorkspaceAppManifest,
        pipelineActionID: String
    ) -> Bool {
        let budget = declaredTokenBudget(for: manifest, pipelineActionID: pipelineActionID)
        return budget > 0 && consumed > budget
    }

    // MARK: - Per-app CUMULATIVE agent-spend ceiling
    //
    // `exceedsBudget` above caps ONE run. This is a separate, app-wide SAFETY ceiling on rolling
    // agent spend: an app's HTML can serially trigger workflow runs over time (one at a time, bounded
    // by the durable concurrency throttle), and on a `preApproved` app each run's agent task spends
    // tokens with no per-action approval — so without a rolling cap the lifetime spend is unbounded.
    // Enforced in the executor BEFORE launching a `task.createAndRun`/`task.fanOut` step: if the app's
    // spend in the trailing window already meets a ceiling, the launch is denied and the run is blocked
    // (held for review), with an audit event. These are coarse safety limits, not normal-usage quotas;
    // they exist to stop runaway automation, so the defaults are generous.
    static let appBudgetWindow: TimeInterval = 24 * 60 * 60
    static let appTokenCeiling = 1_000_000
    static let appAgentRunCeiling = 200

    /// True if launching another agent task would breach the rolling per-app ceiling, given the tokens
    /// the app has already consumed and the count of its agent-launching runs within the window. Pure
    /// (the executor supplies the measured prior spend) so it is directly unit-testable.
    static func exceedsAppAgentBudget(priorTokens: Int, priorAgentRuns: Int) -> Bool {
        priorTokens >= appTokenCeiling || priorAgentRuns >= appAgentRunCeiling
    }
}

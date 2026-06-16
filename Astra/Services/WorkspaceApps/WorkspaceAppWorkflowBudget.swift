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
}

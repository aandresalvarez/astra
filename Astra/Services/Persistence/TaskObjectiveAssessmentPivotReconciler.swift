import Foundation

/// Reconciles a persisted Tier 2 (utility-model) objective assessment against
/// Tier 1's deterministic resolver on every `refresh()`, in two ways:
///
///  1. If Tier 1 now finds a newer explicit objective marker
///     (`activeObjectiveResolution(...).supersedesOriginalGoal`), any
///     persisted `objectiveAssessment` is dropped entirely. An explicit user
///     override always wins over an older, now-stale Tier 2 verdict, and
///     nothing else invalidates a persisted assessment once
///     `ObjectiveAssessmentTrigger.shouldAssess` stops re-running Tier 2 after
///     an explicit marker appears (adversarial finding: an explicit correction
///     must not keep surfacing an earlier drift episode via either the
///     Thread Intent line or the raw "Objective assessment" block).
///  2. Otherwise, a still-valid `superseded` verdict's `currentObjective` is
///     copied into `state.currentObjective` / `state.objective.currentObjective`.
///     Without this, `updateDerivedFields` computes `currentObjective` purely
///     from Tier 1's resolver, which never looks at `objectiveAssessment` at
///     all -- so a Tier 2 pivot (fired for exactly the informal-drift case
///     Tier 1 cannot see) would otherwise leave the stale Tier 1 text in the
///     Thread Intent "Current objective" line while a different, pivoted
///     objective renders separately in the "Objective assessment" block
///     (adversarial findings: stale-Thread-Intent-line /
///     contradictory-current-objective).
///
/// Kept in its own file per the established pattern for extending
/// `TaskContextStateManager` without growing the near-budget owner file --
/// does NOT call the owner file's private helpers (`objectiveState`,
/// `activeObjectiveResolution`'s private callees, etc.); the one piece of
/// public state it reads (`activeObjectiveResolution`) is already `static
/// func` (internal), matching `TaskActiveObjectiveResolver.swift`'s own usage.
extension TaskContextStateManager {
    @MainActor
    static func reconcileActiveObjectiveWithAssessmentPivot(_ state: inout TaskContextState, task: AgentTask) {
        guard let assessment = state.objectiveAssessment else { return }

        let hasNewerExplicitMarker = activeObjectiveResolution(
            for: task,
            planState: TaskPlanService.reconstruct(for: task),
            startingRequest: state.startingRequest,
            approvedGoal: state.approvedGoal
        ).supersedesOriginalGoal
        guard !hasNewerExplicitMarker else {
            state.objectiveAssessment = nil
            return
        }

        guard assessment.verdict == "superseded",
              let pivotObjective = assessment.currentObjective,
              !pivotObjective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        state.currentObjective = pivotObjective
        state.objective.currentObjective = pivotObjective
    }
}

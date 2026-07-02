import Foundation

/// Reconciles a persisted Tier 2 (utility-model) objective assessment against
/// Tier 1's deterministic resolver on every `refresh()`, in three ways:
///
///  1. If Tier 1 now finds a newer, more authoritative signal -- either an
///     explicit objective-override message (`activeObjectiveResolution(...)
///     .hasExplicitOverride`, true regardless of whether the override's
///     resolved text differs from `task.goal` -- a user who explicitly says
///     "go back to the original goal" still just issued a fresh correction,
///     even though `supersedesOriginalGoal` alone would read that as "nothing
///     changed") or an approved/executing/completed plan whose goal has
///     already reconciled to something other than `task.goal`
///     (`activeObjectiveResolution(...).objective != task.goal`, which
///     `hasExplicitOverride`/`supersedesOriginalGoal` do not catch -- both are
///     hardcoded `false` on the plan-reconciliation path even though the
///     resolved objective genuinely changed) -- any persisted
///     `objectiveAssessment` is dropped entirely. A durable Tier 1 signal
///     always wins over an older, now-stale Tier 2 verdict, and nothing else
///     invalidates a persisted assessment once
///     `ObjectiveAssessmentTrigger.shouldAssess` stops re-running Tier 2 after
///     such a signal appears (adversarial findings: an explicit correction --
///     including one that reaffirms the original goal verbatim -- or a plan
///     approved after an earlier drift episode, must not keep surfacing that
///     earlier pivot via either the Thread Intent line or the raw "Objective
///     assessment" block).
///  2. If the opt-in "Objective Drift Detection" setting is off, any
///     persisted assessment is also dropped here -- covering the one-turn
///     gap between the user disabling the setting and
///     `AgentRuntimeRunPersistence.recordSessionTurn`'s own (write-side)
///     cleanup running for a completed turn (adversarial finding: the
///     thread-state refresh must not keep applying a stale pivot for a
///     prompt built while the setting reads as off).
///  3. Otherwise, a still-valid `superseded` verdict's `currentObjective` is
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

        guard UserDefaults.standard.bool(forKey: AppStorageKeys.objectiveDriftDetectionEnabled) else {
            state.objectiveAssessment = nil
            return
        }

        let resolution = activeObjectiveResolution(
            for: task,
            planState: TaskPlanService.reconstruct(for: task),
            startingRequest: state.startingRequest,
            approvedGoal: state.approvedGoal
        )
        let goal = task.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedObjective = resolution.objective.trimmingCharacters(in: .whitespacesAndNewlines)
        let tier1HasMovedPastOriginalGoal = resolution.hasExplicitOverride
            || (!resolvedObjective.isEmpty && resolvedObjective.caseInsensitiveCompare(goal) != .orderedSame)
        guard !tier1HasMovedPastOriginalGoal else {
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

    /// Whether the "Current objective" Thread Intent line would just repeat
    /// text that's already been demoted to background framing earlier in the
    /// SAME follow-up prompt by `FollowUpIntroSectionProvider` (Tier 1
    /// `.delivered`, or Tier 2 `original_satisfied` with no distinct pivot --
    /// `superseded` is excluded because `reconcileActiveObjectiveWithAssessmentPivot`
    /// above already rewrites `currentObjective` to the pivoted text in that
    /// case, so it no longer matches `task.goal`). Scoped to prompt rendering
    /// only: `state.currentObjective` itself is left untouched, so unrelated
    /// consumers (Mission Control, the markdown capsule export) keep showing
    /// the retrospective objective for a finished thread, which is correct
    /// there (adversarial finding: only the live provider prompt must avoid
    /// asserting a demoted goal as still "current").
    @MainActor
    static func shouldSuppressRedundantCurrentObjectiveLine(state: TaskContextState, task: AgentTask) -> Bool {
        let currentObjective = state.objective.currentObjective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentObjective.isEmpty else { return false }
        let goal = task.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard currentObjective.caseInsensitiveCompare(goal) == .orderedSame else { return false }
        return originalGoalDelivery(for: task) == .delivered
            || state.objectiveAssessment?.verdict == "original_satisfied"
    }
}

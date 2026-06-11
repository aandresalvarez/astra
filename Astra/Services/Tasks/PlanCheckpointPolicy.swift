import Foundation
import ASTRACore

/// Decides where ask-mode checkpoints live for an approved plan, per runtime.
///
/// Two tiers exist because providers differ in one capability that ASTRA
/// cannot paper over: whether they can ask ASTRA for approval *before* running
/// a tool. Where that channel exists (Claude's stdio control protocol), a
/// single provider run with live asks is both stronger and far cheaper than
/// run-per-step — the provider keeps its session and ASTRA still vetoes every
/// risky action pre-execution. Where it doesn't, the run boundary is the only
/// enforceable checkpoint ASTRA has, so ask mode executes one approved step
/// per run and gates between them.
enum PlanCheckpointPolicy {
    enum Tier: Equatable {
        /// Provider asks ASTRA live before tool use; one run covers the plan.
        case liveApprovals
        /// No pre-action channel; ASTRA gates at each step's run boundary.
        case runBoundary
    }

    static func tier(for runtime: AgentRuntimeID) -> Tier {
        // Deliberately explicit, not derived from policy-adapter capability
        // flags: the live tier requires the in-flight ask plumbing ASTRA
        // actually implements (the stdio control channel in
        // AgentRuntimeProcessRunner), which today exists only for Claude.
        // A provider advertising its own ask flag (e.g. Copilot
        // --no-ask-user) is NOT bridged to ASTRA's approval UI and must
        // stay run-boundary.
        runtime == .claudeCode ? .liveApprovals : .runBoundary
    }

    static func executionMode(
        runtime: AgentRuntimeID,
        skipPermissions: Bool
    ) -> TaskPlanExecutionMode {
        guard !skipPermissions else { return .fullPlan }
        return tier(for: runtime) == .liveApprovals ? .fullPlan : .nextStep
    }

    /// Resolves the runtime the same way the worker will at launch
    /// (registered-adapter mapping with the default-runtime fallback), so the
    /// mode shown and sent by the UI can't diverge from what executes. Uses
    /// the registry directly: constructing an AgentRuntimeConfiguration here
    /// would run executable path detection on every SwiftUI evaluation.
    @MainActor
    static func executionMode(for task: AgentTask, skipPermissions: Bool) -> TaskPlanExecutionMode {
        executionMode(
            runtime: AgentRuntimeAdapterRegistry.registeredRuntime(rawValue: task.runtimeID),
            skipPermissions: skipPermissions
        )
    }

    static func approveActionTitle(mode: TaskPlanExecutionMode, skipPermissions: Bool) -> String {
        if skipPermissions { return "Run remaining plan" }
        return mode == .fullPlan ? "Run plan with live approvals" : "Approve next step"
    }

    static func modeLabel(mode: TaskPlanExecutionMode, skipPermissions: Bool) -> String {
        if skipPermissions { return "Auto mode runs every remaining step." }
        return mode == .fullPlan
            ? "Ask mode runs the plan in one session; the provider asks before risky actions."
            : "Ask mode runs one approved step, then pauses again."
    }
}

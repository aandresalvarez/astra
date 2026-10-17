import Foundation
import ASTRACore

extension AgentRuntimeProcessRunner {
    /// `sandboxedPlan`, plus Copilot's home check run against the final plan:
    /// the environment Copilot actually gets (a skill may set
    /// COPILOT_PROVIDERS_CONFIG), its working directory, the session it
    /// resumes, and the sandbox boundary really applied. Nothing earlier knows
    /// all four, so a file Copilot would read from outside its home is judged
    /// against the readable roots and read scope it will run under.
    @MainActor
    func guardedSandboxedPlan(
        adapter: any AgentRuntimeProcessLaunchPlanning & AgentRuntimeProcessEventParsing,
        context: AgentRuntimeProcessLaunchContext
    ) -> SandboxedPlanOutcome {
        let outcome = sandboxedPlan(adapter: adapter, context: context)
        guard case .plan(let plan) = outcome,
              let message = Self.copilotHomeBlock(for: plan, resumeSessionID: context.nativeContinuationSessionID) else {
            return outcome
        }
        AppLogger.audit(.workerBlocked, category: "Worker", taskID: context.taskSnapshot.id, fields: [
            "runtime": plan.runtime.rawValue,
            "reason": CopilotHomeAccessCheck.launchStopReason,
            "source": "copilot_home_access"
        ], level: .error)
        return .blocked(AgentProcessResult(
            exitCode: -1,
            error: message,
            runtimeStopReason: CopilotHomeAccessCheck.launchStopReason,
            runtimeStopMessage: message
        ))
    }

    /// The same check for a utility launch (verifier, titles, commit
    /// messages), whose silent exit would otherwise surface as an empty
    /// "Verifier failed to run:".
    @MainActor
    func guardedSandboxedUtilityPlan(_ utilityPlan: AgentUtilityLaunchPlan) -> SandboxedUtilityPlanOutcome {
        let outcome = sandboxedUtilityPlan(utilityPlan)
        guard case .plan(let plan) = outcome,
              let message = Self.copilotHomeBlock(for: plan.process, resumeSessionID: nil) else {
            return outcome
        }
        AppLogger.audit(.workerBlocked, category: "Utility", fields: [
            "runtime": plan.process.runtime.rawValue,
            "reason": CopilotHomeAccessCheck.launchStopReason,
            "source": "copilot_home_access"
        ], level: .error)
        return .blocked(AgentUtilityRunResult(exitCode: -1, output: "", error: message))
    }

    /// The blocker text when Copilot would exit silently on this plan, else nil.
    private static func copilotHomeBlock(
        for plan: AgentRuntimeProcessLaunchPlan,
        resumeSessionID: String?
    ) -> String? {
        guard plan.runtime == .copilotCLI,
              // Inside a container Copilot uses the container's home.
              !plan.executionEnvironment.providerRunsInsideContainer,
              let blocker = CopilotHomeAccessCheck.launchBlocker(
                  resumeSessionID: resumeSessionID,
                  environment: plan.environment,
                  workingDirectory: plan.currentDirectory,
                  sandboxReceipt: plan.executionSandboxBoundaryReceipt
              ),
              let check = blocker.checks.first else {
            return nil
        }
        return "\(check.detail) \(check.remediation ?? "")".trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

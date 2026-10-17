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
              plan.runtime == .copilotCLI,
              // Inside a container Copilot uses the container's home.
              !plan.executionEnvironment.providerRunsInsideContainer,
              let blocker = CopilotHomeAccessCheck.launchBlocker(
                  resumeSessionID: context.nativeContinuationSessionID,
                  environment: plan.environment,
                  workingDirectory: plan.currentDirectory,
                  sandboxReceipt: plan.executionSandboxBoundaryReceipt
              ),
              let check = blocker.checks.first else {
            return outcome
        }
        let message = "\(check.detail) \(check.remediation ?? "")"
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
}

import Foundation
import ASTRACore

extension AgentRuntimeProcessRunner {
    /// Validate the final environment, working directory, native session and
    /// applied sandbox before launching a provider. Only immutable facts leave
    /// the main actor while the filesystem is inspected.
    @MainActor
    func guardedSandboxedPlan(
        adapter: any AgentRuntimeProcessLaunchPlanning & AgentRuntimeProcessEventParsing,
        context: AgentRuntimeProcessLaunchContext
    ) async -> SandboxedPlanOutcome {
        let outcome = sandboxedPlan(adapter: adapter, context: context)
        guard case .plan(let plan) = outcome,
              let message = await Self.providerHomeBlock(for: plan, resumeSessionID: context.nativeContinuationSessionID) else {
            return outcome
        }
        AppLogger.audit(.workerBlocked, category: "Worker", taskID: context.taskSnapshot.id, fields: [
            "runtime": plan.runtime.rawValue,
            "reason": RuntimeHomeAccessService.launchStopReason,
            "source": "provider_home_access"
        ], level: .error)
        return .blocked(AgentProcessResult(
            exitCode: -1,
            error: message,
            runtimeStopReason: RuntimeHomeAccessService.launchStopReason,
            runtimeStopMessage: message
        ))
    }

    /// The same provider check for a utility launch (verifier, titles, commit
    /// messages), whose silent exit would otherwise surface as an empty
    /// "Verifier failed to run:".
    @MainActor
    func guardedSandboxedUtilityPlan(_ utilityPlan: AgentUtilityLaunchPlan) async -> SandboxedUtilityPlanOutcome {
        let outcome = sandboxedUtilityPlan(utilityPlan)
        guard case .plan(let plan) = outcome,
              let message = await Self.providerHomeBlock(for: plan.process, resumeSessionID: nil) else {
            return outcome
        }
        AppLogger.audit(.workerBlocked, category: "Utility", fields: [
            "runtime": plan.process.runtime.rawValue,
            "reason": RuntimeHomeAccessService.launchStopReason,
            "source": "provider_home_access"
        ], level: .error)
        return .blocked(AgentUtilityRunResult(exitCode: -1, output: "", error: message))
    }

    /// Only immutable launch facts cross into the background filesystem probe.
    static func providerHomeBlock(
        for plan: AgentRuntimeProcessLaunchPlan,
        resumeSessionID: String?
    ) async -> String? {
        let request = RuntimeHomeAccessRequest(
            runtime: plan.runtime,
            policy: AgentRuntimeAdapterRegistry.homeAccessPolicy(for: plan.runtime),
            environment: plan.environment, workingDirectory: plan.currentDirectory,
            userHome: plan.environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path,
            resumeSessionID: resumeSessionID, sandboxReceipt: plan.executionSandboxBoundaryReceipt,
            insideContainer: plan.executionEnvironment.providerRunsInsideContainer
        )
        guard let check = await RuntimeHomeAccessService.check(request), check.state == .blocked else { return nil }
        return "\(check.detail) \(check.remediation ?? "")".trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

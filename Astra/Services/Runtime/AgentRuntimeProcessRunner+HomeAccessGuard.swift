import Foundation
import ASTRACore

extension AgentRuntimeProcessRunner {
    /// Validate the final environment, working directory, native session and
    /// applied sandbox before launching a provider. Only immutable facts leave
    /// the main actor while the filesystem is inspected.
    @MainActor
    func guardedSandboxedPlan(
        adapter: any AgentRuntimeProcessLaunchPlanning & AgentRuntimeProcessEventParsing,
        context: AgentRuntimeProcessLaunchContext,
        homeAccessCheck: @MainActor (AgentRuntimeProcessLaunchPlan, String?) async -> String? = { plan, session in
            await AgentRuntimeProcessRunner.providerHomeBlock(for: plan, resumeSessionID: session)
        }
    ) async -> SandboxedPlanOutcome {
        let cancellation = homeAccessCancellation.snapshot()
        func cancelled() -> Bool {
            !homeAccessCancellation.isCurrent(cancellation) || Task.isCancelled || context.task.status == .cancelled
        }
        guard !cancelled() else { return .blocked(Self.cancelledHomeLaunch) }
        if let failure = sharedConfigurationFailure(context) { return .blocked(failure) }
        let outcome = sandboxedPlan(adapter: adapter, context: context)
        guard case .plan(let original) = outcome else { return outcome }
        let plan = await RuntimeHomeAccessContainerPreflight.prepare(original, resumeSessionID: context.nativeContinuationSessionID)
        guard !cancelled() else { return .blocked(Self.cancelledHomeLaunch) }
        let message = await homeAccessCheck(plan, context.nativeContinuationSessionID)
        guard !cancelled() else { return .blocked(Self.cancelledHomeLaunch) }
        if let failure = sharedConfigurationFailure(context) { return .blocked(failure) }
        guard let message else { return .plan(plan) }
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
        let cancellation = homeAccessCancellation.snapshot()
        func cancelled() -> Bool { !homeAccessCancellation.isCurrent(cancellation) || Task.isCancelled }
        let cancelledResult = AgentUtilityRunResult(exitCode: -1, output: "", error: "Utility cancelled before provider launch.")
        guard !cancelled() else { return .blocked(cancelledResult) }
        if let message = sharedUtilityConfigurationFailure(utilityPlan) {
            return .blocked(.init(exitCode: -1, output: "", error: message))
        }
        let outcome = sandboxedUtilityPlan(utilityPlan)
        guard case .plan(var plan) = outcome else { return outcome }
        plan.process = await RuntimeHomeAccessContainerPreflight.prepare(plan.process, resumeSessionID: nil)
        guard !cancelled() else { return .blocked(cancelledResult) }
        let message = await Self.providerHomeBlock(for: plan.process, resumeSessionID: nil)
        guard !cancelled() else { return .blocked(cancelledResult) }
        if let message = sharedUtilityConfigurationFailure(utilityPlan) {
            return .blocked(.init(exitCode: -1, output: "", error: message))
        }
        guard let message else { return .plan(plan) }
        AppLogger.audit(.workerBlocked, category: "Utility", fields: [
            "runtime": plan.process.runtime.rawValue,
            "reason": RuntimeHomeAccessService.launchStopReason,
            "source": "provider_home_access"
        ], level: .error)
        return .blocked(AgentUtilityRunResult(exitCode: -1, output: "", error: message))
    }

    private static var cancelledHomeLaunch: AgentProcessResult {
        AgentProcessResult(exitCode: -1, error: "Run cancelled before provider launch.",
                           runtimeStopReason: "cancelled", runtimeStopMessage: "Run cancelled before provider launch.")
    }

    @MainActor
    private func sharedConfigurationFailure(_ context: AgentRuntimeProcessLaunchContext) -> AgentProcessResult? {
        guard let key = context.sharedStateKey, key.filePath != nil else { return nil }
        do {
            try key.validate(fileURL: AntigravityCLIRuntime.settingsURL(providerHomeDirectory: try context.antigravityLaunchHome()))
            return nil
        } catch {
            return AgentProcessResult(exitCode: -1, error: error.localizedDescription,
                runtimeStopReason: RuntimeProviderResourceRegistry.Block.stopReason, runtimeStopMessage: error.localizedDescription)
        }
    }

    private func sharedUtilityConfigurationFailure(_ plan: AgentUtilityLaunchPlan) -> String? {
        guard let key = plan.sharedStateKey else { return nil }
        do {
            try plan.process.validateSharedConfiguration(key)
            return nil
        } catch { return error.localizedDescription }
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

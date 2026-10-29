import Foundation

extension AgentRuntimeProcessLaunchContext {
    /// The provider's effective home is a pinned launch input, not a permission grant.
    @MainActor
    func antigravityLaunchHome() throws -> String {
        if let sharedStateHome { return sharedStateHome }
        let environment = AgentRuntimeProcessRunner.scopedEnvironmentVariables(for: task,
            capabilityScope: capabilityResolutionSnapshot.providerLaunch, contextText: contextText,
            executionPolicy: executionPolicy, runtimeRequirements: runtimeRequirements)
        return try ProviderSharedStateIdentity.effectiveHome(configured: providerHomeDirectory, environment: environment)
    }
}

extension AgentRuntimeProcessLaunchPlan {
    /// Check the actual child environment at the final synchronous launch boundary.
    func validateSharedConfiguration(_ key: AgentRuntimeSharedStateKey?) throws {
        guard let key, key.filePath != nil else { return }
        guard let home = environment["HOME"], !home.isEmpty else {
            throw ProviderSharedStateIdentity.Failure(detail: "the launch home is unavailable")
        }
        do { try key.validate(fileURL: AntigravityCLIRuntime.settingsURL(providerHomeDirectory: home)) }
        catch let error as ProviderSharedStateIdentity.Failure { throw error }
        catch { throw ProviderSharedStateIdentity.Failure(detail: error.localizedDescription) }
    }
}

extension AgentRuntimeProcessRunner {
    static func sharedConfigurationBlock(_ error: Error) -> AgentProcessResult {
        var result = AgentProcessResult(exitCode: -1, error: error.localizedDescription,
            runtimeStopReason: RuntimeProviderResourceRegistry.Block.stopReason,
            runtimeStopMessage: error.localizedDescription)
        result.executionTurnsSpent = 0
        result.executionTokensSpent = 0
        result.executionSecondsSpent = 0
        return result
    }
}

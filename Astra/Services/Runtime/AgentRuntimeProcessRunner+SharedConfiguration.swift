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
    /// Docker's child environment belongs to its host client. Keep the route
    /// to the settings ASTRA prepared before wrapping it, without resolving
    /// symlinks here: a retarget must still fail final identity validation.
    var sharedConfigurationURLOnHost: URL? {
        guard runtime == .antigravityCLI else { return nil }
        if executionEnvironment.providerRunsInsideContainer { return sharedConfigurationHostURL }
        guard let home = environment["HOME"], !home.isEmpty else { return nil }
        return AntigravityCLIRuntime.settingsURL(providerHomeDirectory: home)
    }

    /// Host providers must still follow their actual child HOME, even if an
    /// earlier plan carries a captured URL. Container providers instead retain
    /// the host configuration ASTRA mutated; their profile projection is separate.
    func validateSharedConfiguration(_ key: AgentRuntimeSharedStateKey?) throws {
        guard let key, key.filePath != nil else { return }
        guard let settingsURL = sharedConfigurationURLOnHost else {
            throw ProviderSharedStateIdentity.Failure(detail: "the launch home is unavailable")
        }
        do { try key.validate(fileURL: settingsURL) }
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

import Foundation
import ASTRACore

struct RuntimeProviderAvailabilityConfiguration: Equatable, Sendable {
    var providerSettings: AgentRuntimeProviderSettings
    var claudeProvider: ClaudeProvider
    var vertexProjectID: String
    var vertexRegion: String
    var vertexOpusModel: String
    var vertexSonnetModel: String
    var vertexHaikuModel: String
    var antigravityAuthMode: AntigravityAuthMode

    init(
        claudePath: String,
        copilotPath: String,
        claudeProvider: ClaudeProvider,
        vertexProjectID: String,
        vertexRegion: String,
        vertexOpusModel: String,
        vertexSonnetModel: String,
        vertexHaikuModel: String,
        antigravityAuthMode: AntigravityAuthMode = .consumer
    ) {
        self.init(
            providerSettings: AgentRuntimeProviderSettings(
                executablePaths: [
                    .claudeCode: claudePath,
                    .copilotCLI: copilotPath
                ],
                homeDirectories: [
                    .copilotCLI: CopilotCLIRuntime.channelHome()
                ]
            ),
            claudeProvider: claudeProvider,
            vertexProjectID: vertexProjectID,
            vertexRegion: vertexRegion,
            vertexOpusModel: vertexOpusModel,
            vertexSonnetModel: vertexSonnetModel,
            vertexHaikuModel: vertexHaikuModel,
            antigravityAuthMode: antigravityAuthMode
        )
    }

    init(
        providerSettings: AgentRuntimeProviderSettings,
        claudeProvider: ClaudeProvider,
        vertexProjectID: String,
        vertexRegion: String,
        vertexOpusModel: String,
        vertexSonnetModel: String,
        vertexHaikuModel: String,
        antigravityAuthMode: AntigravityAuthMode = .consumer
    ) {
        self.providerSettings = providerSettings
        self.claudeProvider = claudeProvider
        self.vertexProjectID = vertexProjectID
        self.vertexRegion = vertexRegion
        self.vertexOpusModel = vertexOpusModel
        self.vertexSonnetModel = vertexSonnetModel
        self.vertexHaikuModel = vertexHaikuModel
        self.antigravityAuthMode = antigravityAuthMode
    }

    func readinessConfiguration(for runtime: AgentRuntimeID) -> RuntimeReadinessConfiguration {
        RuntimeReadinessConfiguration(
            runtime: runtime,
            scope: .availability,
            providerSettings: providerSettings,
            claudeProvider: claudeProvider,
            vertexProjectID: vertexProjectID,
            vertexRegion: vertexRegion,
            vertexOpusModel: vertexOpusModel,
            vertexSonnetModel: vertexSonnetModel,
            vertexHaikuModel: vertexHaikuModel,
            antigravityAuthMode: antigravityAuthMode
        )
    }
}

struct RuntimeProviderAvailabilityService {
    private let readinessService: RuntimeReadinessService

    init(readinessService: RuntimeReadinessService = RuntimeReadinessService()) {
        self.readinessService = readinessService
    }

    /// Readiness younger than this is served from `RuntimeReadinessStateCache`
    /// without re-probing the CLIs, so opening a task shows its provider at
    /// once instead of "Checking provider" until the slowest probe answers.
    static let cacheMaxAge: TimeInterval = 300

    func states(
        configuration: RuntimeProviderAvailabilityConfiguration,
        cache: RuntimeReadinessStateCache? = .shared,
        cacheMaxAge: TimeInterval = RuntimeProviderAvailabilityService.cacheMaxAge
    ) async -> [AgentRuntimeID: RuntimeReadinessState] {
        if let cache, let cached = await cache.states(for: configuration, maxAge: cacheMaxAge) {
            return cached
        }
        let states = await withTaskGroup(of: (AgentRuntimeID, RuntimeReadinessState).self) { group in
            for runtime in AgentRuntimeAdapterRegistry.runtimeIDs {
                group.addTask {
                    let report = await readinessService.check(
                        configuration: configuration.readinessConfiguration(for: runtime)
                    )
                    return (runtime, report.state)
                }
            }

            var states: [AgentRuntimeID: RuntimeReadinessState] = [:]
            for await (runtime, state) in group {
                states[runtime] = state
            }
            return states
        }
        // A cancelled group exits early with fewer entries than runtimes; the
        // caller already discards those, and so must the cache.
        if let cache, states.count == AgentRuntimeAdapterRegistry.runtimeIDs.count {
            await cache.store(states, for: configuration)
        }
        return states
    }

    static func readyRuntimes(
        from states: [AgentRuntimeID: RuntimeReadinessState]
    ) -> [AgentRuntimeID] {
        AgentRuntimeAdapterRegistry.runtimeIDs.filter { states[$0] == .ready }
    }
}

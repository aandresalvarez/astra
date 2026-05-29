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

    init(
        claudePath: String,
        copilotPath: String,
        claudeProvider: ClaudeProvider,
        vertexProjectID: String,
        vertexRegion: String,
        vertexOpusModel: String,
        vertexSonnetModel: String,
        vertexHaikuModel: String
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
            vertexHaikuModel: vertexHaikuModel
        )
    }

    init(
        providerSettings: AgentRuntimeProviderSettings,
        claudeProvider: ClaudeProvider,
        vertexProjectID: String,
        vertexRegion: String,
        vertexOpusModel: String,
        vertexSonnetModel: String,
        vertexHaikuModel: String
    ) {
        self.providerSettings = providerSettings
        self.claudeProvider = claudeProvider
        self.vertexProjectID = vertexProjectID
        self.vertexRegion = vertexRegion
        self.vertexOpusModel = vertexOpusModel
        self.vertexSonnetModel = vertexSonnetModel
        self.vertexHaikuModel = vertexHaikuModel
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
            vertexHaikuModel: vertexHaikuModel
        )
    }
}

struct RuntimeProviderAvailabilityService {
    private let readinessService: RuntimeReadinessService

    init(readinessService: RuntimeReadinessService = RuntimeReadinessService()) {
        self.readinessService = readinessService
    }

    func states(
        configuration: RuntimeProviderAvailabilityConfiguration
    ) async -> [AgentRuntimeID: RuntimeReadinessState] {
        await withTaskGroup(of: (AgentRuntimeID, RuntimeReadinessState).self) { group in
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
    }

    static func readyRuntimes(
        from states: [AgentRuntimeID: RuntimeReadinessState]
    ) -> [AgentRuntimeID] {
        AgentRuntimeAdapterRegistry.runtimeIDs.filter { states[$0] == .ready }
    }
}

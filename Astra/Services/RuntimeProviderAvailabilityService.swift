import Foundation
import ASTRACore

struct RuntimeProviderAvailabilityConfiguration: Equatable, Sendable {
    var claudePath: String
    var copilotPath: String
    var claudeProvider: ClaudeProvider
    var vertexProjectID: String
    var vertexRegion: String
    var vertexOpusModel: String
    var vertexSonnetModel: String
    var vertexHaikuModel: String

    func readinessConfiguration(for runtime: AgentRuntimeID) -> RuntimeReadinessConfiguration {
        RuntimeReadinessConfiguration(
            runtime: runtime,
            claudePath: claudePath,
            copilotPath: copilotPath,
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
        var states: [AgentRuntimeID: RuntimeReadinessState] = [:]
        for runtime in AgentRuntimeID.allCases {
            let report = await readinessService.check(
                configuration: configuration.readinessConfiguration(for: runtime)
            )
            states[runtime] = report.state
        }
        return states
    }

    static func readyRuntimes(
        from states: [AgentRuntimeID: RuntimeReadinessState]
    ) -> [AgentRuntimeID] {
        AgentRuntimeID.allCases.filter { states[$0] == .ready }
    }
}

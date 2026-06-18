import Foundation
@testable import ASTRA

struct LiveProviderTestConfiguration: Sendable, Equatable {
    var environment: [String: String]

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    var claudeModel: String {
        configured("REAL_CLAUDE_MODEL")
            ?? AgentRuntimeAdapterRegistry.defaultModel(for: .claudeCode)
    }

    var claudeArtifactModel: String {
        configured("REAL_CLAUDE_ARTIFACT_MODEL")
            ?? configured("REAL_CLAUDE_MODEL")
            ?? AgentRuntimeAdapterRegistry.defaultModel(for: .claudeCode)
    }

    var copilotModel: String {
        configured("REAL_COPILOT_MODEL")
            ?? AgentRuntimeAdapterRegistry.defaultModel(for: .copilotCLI)
    }

    var copilotArtifactModel: String {
        configured("REAL_COPILOT_ARTIFACT_MODEL")
            ?? configured("REAL_COPILOT_MODEL")
            ?? AgentRuntimeAdapterRegistry.defaultModel(for: .copilotCLI)
    }

    var antigravityModel: String {
        configured("REAL_ANTIGRAVITY_MODEL")
            ?? AgentRuntimeAdapterRegistry.defaultModel(for: .antigravityCLI)
    }

    var cursorModel: String {
        configured("REAL_CURSOR_MODEL")
            ?? AgentRuntimeAdapterRegistry.defaultModel(for: .cursorCLI)
    }

    var openCodeModel: String {
        configured("REAL_OPENCODE_MODEL")
            ?? AgentRuntimeAdapterRegistry.defaultModel(for: .openCodeCLI)
    }

    private func configured(_ key: String) -> String? {
        let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }
}

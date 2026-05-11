import Foundation
import Testing
@testable import ASTRA
import ASTRACore

@Suite("RuntimeModelAvailability")
struct RuntimeModelAvailabilityTests {
    @Test("Copilot falls back to CLI-supported models before account availability is cached")
    func copilotUsesStaticModelsWithoutCache() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(RuntimeModelAvailability.models(for: .copilotCLI, defaults: defaults) == AgentRuntimeID.copilotCLI.defaultModels)
        #expect(RuntimeModelAvailability.defaultModel(for: .copilotCLI, defaults: defaults) == "gpt-5")
    }

    @Test("Cached Copilot account models preserve provider choices")
    func cachedCopilotModelsPreserveProviderChoices() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        RuntimeModelAvailability.persistAvailableModels(
            ["gpt-5", "future-model", "claude-sonnet-4.5", "gpt-5"],
            for: .copilotCLI,
            defaults: defaults,
            checkedAt: Date(timeIntervalSince1970: 10)
        )

        #expect(RuntimeModelAvailability.models(for: .copilotCLI, defaults: defaults) == [
            "gpt-5",
            "future-model",
            "claude-sonnet-4.5"
        ])
        #expect(RuntimeModelAvailability.normalizedModel("claude-sonnet-4", for: .copilotCLI, defaults: defaults) == "gpt-5")
        #expect(RuntimeModelAvailability.normalizedModel("gpt-5", for: .copilotCLI, defaults: defaults) == "gpt-5")
    }

    @Test("Cached Claude and Copilot models stay isolated")
    func runtimeModelCachesStayIsolated() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        RuntimeModelAvailability.persistAvailableModels(["claude-sonnet-4.5"], for: .copilotCLI, defaults: defaults)
        RuntimeModelAvailability.persistAvailableModels(
            ["claude-sonnet-4-6", "claude-opus-future"],
            for: .claudeCode,
            defaults: defaults
        )

        #expect(RuntimeModelAvailability.models(for: .claudeCode, defaults: defaults) == [
            "claude-sonnet-4-6",
            "claude-opus-future"
        ])
        #expect(RuntimeModelAvailability.models(for: .copilotCLI, defaults: defaults) == [
            "claude-sonnet-4.5"
        ])
        #expect(RuntimeModelAvailability.normalizedModel("gpt-5", for: .claudeCode, defaults: defaults) == "claude-sonnet-4-6")
    }

    @Test("Unverified custom model is preserved until provider availability is cached")
    func unverifiedCustomModelIsPreservedWithoutCache() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(RuntimeModelAvailability.normalizedModel("custom-provider-model", for: .claudeCode, defaults: defaults) == "custom-provider-model")
        #expect(RuntimeModelAvailability.normalizedModel("gpt-5", for: .claudeCode, defaults: defaults) == AgentRuntimeID.claudeCode.defaultModel)
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "RuntimeModelAvailabilityTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }
}

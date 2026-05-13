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
        #expect(RuntimeModelAvailability.defaultModel(for: .copilotCLI, defaults: defaults) == "claude-sonnet-4.6")
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
        #expect(RuntimeModelAvailability.normalizedModel("gpt-5", for: .copilotCLI, defaults: defaults) == "gpt-5")
        #expect(RuntimeModelAvailability.normalizedModel("future-provider-model", for: .copilotCLI, defaults: defaults) == "future-provider-model")
        #expect(RuntimeModelAvailability.normalizedModel("claude-sonnet-4", for: .copilotCLI, defaults: defaults) == "claude-sonnet-4")
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
        #expect(RuntimeModelAvailability.normalizedModel("claude-custom-alias", for: .claudeCode, defaults: defaults) == "claude-custom-alias")
        #expect(RuntimeModelAvailability.normalizedModel("gpt-5", for: .claudeCode, defaults: defaults) == "gpt-5")
    }

    @Test("Unverified custom model is preserved until provider availability is cached")
    func unverifiedCustomModelIsPreservedWithoutCache() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(RuntimeModelAvailability.normalizedModel("custom-provider-model", for: .claudeCode, defaults: defaults) == "custom-provider-model")
        #expect(RuntimeModelAvailability.normalizedModel("gpt-5.2", for: .claudeCode, defaults: defaults) == "gpt-5.2")
    }

    @Test("Runtime switches choose a provider suggestion without making normalization provider-specific")
    func runtimeSwitchUsesProviderSuggestion() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        RuntimeModelAvailability.persistAvailableModels(
            ["future-copilot-model", "gpt-5"],
            for: .copilotCLI,
            defaults: defaults
        )
        let cachedCopilot = defaults.string(forKey: AppStorageKeys.copilotAvailableModels) ?? ""

        #expect(RuntimeModelAvailability.modelForRuntimeSwitch(
            currentModel: "custom-claude-alias",
            to: .copilotCLI,
            cachedClaudeModelsJSON: "",
            cachedCopilotModelsJSON: cachedCopilot
        ) == "future-copilot-model")

        #expect(RuntimeModelAvailability.modelForRuntimeSwitch(
            currentModel: "gpt-5",
            to: .copilotCLI,
            cachedClaudeModelsJSON: "",
            cachedCopilotModelsJSON: cachedCopilot
        ) == "gpt-5")
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "RuntimeModelAvailabilityTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }
}

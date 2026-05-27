import Foundation
import SwiftData
import Testing
@testable import ASTRA
import ASTRACore

@Suite("RuntimeModelAvailability")
struct RuntimeModelAvailabilityTests {
    @Test("Copilot falls back to CLI-supported models before account availability is cached")
    func copilotUsesStaticModelsWithoutCache() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(RuntimeModelAvailability.models(for: .copilotCLI, defaults: defaults) == AgentRuntimeAdapterRegistry.defaultModels(for: .copilotCLI))
        #expect(RuntimeModelAvailability.defaultModel(for: .claudeCode, defaults: defaults) == AgentRuntimeAdapterRegistry.defaultModel(for: .claudeCode))
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
        #expect(RuntimeModelAvailability.normalizedModel("future-provider-model", for: .copilotCLI, defaults: defaults) == "gpt-5")
        #expect(RuntimeModelAvailability.normalizedModel("claude-sonnet-4", for: .copilotCLI, defaults: defaults) == "gpt-5")
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
        #expect(RuntimeModelAvailability.normalizedModel("claude-custom-alias", for: .claudeCode, defaults: defaults) == "claude-sonnet-4-6")
        #expect(RuntimeModelAvailability.normalizedModel("gpt-5", for: .claudeCode, defaults: defaults) == "claude-sonnet-4-6")
    }

    @Test("Future runtime model cache uses provider-keyed storage")
    func futureRuntimeModelCacheUsesProviderKeyedStorage() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let futureRuntime = try #require(AgentRuntimeID(rawValue: "future_cli"))

        RuntimeModelAvailability.persistAvailableModels(
            ["future-large", "future-small"],
            for: futureRuntime,
            defaults: defaults,
            checkedAt: Date(timeIntervalSince1970: 77)
        )

        let genericKey = AppStorageKeys.runtimeAvailableModelsKey(for: futureRuntime)
        #expect(defaults.string(forKey: genericKey)?.contains("future-large") == true)
        #expect(defaults.string(forKey: AppStorageKeys.claudeAvailableModels) == nil)
        #expect(defaults.string(forKey: AppStorageKeys.copilotAvailableModels) == nil)
        #expect(defaults.integer(forKey: AppStorageKeys.runtimeModelCacheRevision) == 1)
        #expect(RuntimeModelAvailability.models(for: futureRuntime, defaults: defaults) == [
            "future-large",
            "future-small"
        ])
        #expect(RuntimeModelAvailability.normalizedModel("unknown", for: futureRuntime, defaults: defaults) == "future-large")
        #expect(RuntimeModelAvailability.cacheSummary(for: futureRuntime, defaults: defaults).checkedAt == Date(timeIntervalSince1970: 77))
    }

    @Test("Runtime model availability cache resolves arbitrary runtime snapshots")
    func runtimeModelAvailabilityCacheResolvesArbitraryRuntimeSnapshots() throws {
        let futureRuntime = try #require(AgentRuntimeID(rawValue: "future_cli"))
        let snapshot = RuntimeModelAvailabilitySnapshot(
            runtimeID: futureRuntime.rawValue,
            models: ["future-fast", "future-deep"],
            checkedAt: Date(timeIntervalSince1970: 99)
        )
        let data = try JSONEncoder().encode(snapshot)
        let raw = try #require(String(data: data, encoding: .utf8))
        let cache = RuntimeModelAvailabilityCache(rawSnapshots: [futureRuntime: raw])

        #expect(RuntimeModelAvailability.models(for: futureRuntime, cache: cache) == [
            "future-fast",
            "future-deep"
        ])
        let resolution = RuntimeModelAvailability.resolveModel("missing", for: futureRuntime, cache: cache)
        #expect(resolution.resolvedModel == "future-fast")
        #expect(resolution.source == "cached_provider_models")
        #expect(resolution.reason == "not_in_cached_provider_models")
    }

    @Test("App storage cache includes generic runtime model keys")
    func appStorageCacheIncludesGenericRuntimeModelKeys() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let futureRuntime = try #require(AgentRuntimeID(rawValue: "future_cli"))
        RuntimeModelAvailability.persistAvailableModels(
            ["future-ui-model"],
            for: futureRuntime,
            defaults: defaults
        )

        let cache = RuntimeModelAvailabilityCache.appStorage(
            cachedClaudeModelsJSON: "",
            cachedCopilotModelsJSON: "",
            defaults: defaults,
            runtimes: [.claudeCode, .copilotCLI, futureRuntime]
        )

        #expect(RuntimeModelAvailability.models(for: futureRuntime, cache: cache) == ["future-ui-model"])
    }

    @Test("Unverified custom model is preserved unless it is known to another runtime")
    func unverifiedCustomModelIsPreservedWithoutCache() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(RuntimeModelAvailability.normalizedModel("custom-provider-model", for: .claudeCode, defaults: defaults) == "custom-provider-model")
        #expect(RuntimeModelAvailability.normalizedModel("gpt-5.2", for: .claudeCode, defaults: defaults) == AgentRuntimeAdapterRegistry.defaultModel(for: .claudeCode))
        #expect(RuntimeModelAvailability.normalizedModel("claude-sonnet-4-6", for: .copilotCLI, defaults: defaults) == AgentRuntimeAdapterRegistry.defaultModel(for: .copilotCLI))
    }

    @Test("Runtime switches choose a provider suggestion")
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

    @Test("Same model ID can be valid for multiple providers when each provider advertises it")
    func sameModelIDCanBeProviderScopedToMultipleRuntimes() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        RuntimeModelAvailability.persistAvailableModels(
            ["shared-model", "claude-sonnet-4-6"],
            for: .claudeCode,
            defaults: defaults
        )
        RuntimeModelAvailability.persistAvailableModels(
            ["shared-model", "gpt-5"],
            for: .copilotCLI,
            defaults: defaults
        )

        #expect(RuntimeModelAvailability.normalizedModel("shared-model", for: .claudeCode, defaults: defaults) == "shared-model")
        #expect(RuntimeModelAvailability.normalizedModel("shared-model", for: .copilotCLI, defaults: defaults) == "shared-model")
        #expect(RuntimeModelAvailability.normalizedModel("gpt-5", for: .claudeCode, defaults: defaults) == "claude-sonnet-4-6")
        #expect(RuntimeModelAvailability.normalizedModel("claude-sonnet-4-6", for: .copilotCLI, defaults: defaults) == "shared-model")
    }

    @Test("Model resolution records provenance for diagnostics")
    func modelResolutionRecordsProvenance() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        RuntimeModelAvailability.persistAvailableModels(
            ["gpt-5", "claude-sonnet-4.5"],
            for: .copilotCLI,
            defaults: defaults,
            checkedAt: Date(timeIntervalSince1970: 42)
        )

        let resolution = RuntimeModelAvailability.resolveModel(
            "claude-sonnet-4-6",
            for: .copilotCLI,
            defaults: defaults
        )

        #expect(resolution.resolvedModel == "gpt-5")
        #expect(resolution.changed)
        #expect(resolution.source == "cached_provider_models")
        #expect(resolution.reason == "not_in_cached_provider_models")
        #expect(resolution.availableModelCount == 2)
        #expect(resolution.checkedAt == Date(timeIntervalSince1970: 42))
    }

    @Test("Template task creation normalizes template model for selected runtime")
    @MainActor
    func templateTaskCreationNormalizesTemplateModelForRuntime() throws {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(
            name: "Runtime Model Test",
            primaryPath: "/tmp/astra_runtime_model_\(UUID().uuidString)"
        )
        context.insert(workspace)

        let template = TaskTemplate(name: "Template", mainGoal: "Do it", workspace: workspace)
        template.mainModel = AgentRuntimeAdapterRegistry.defaultModel(for: .claudeCode)
        context.insert(template)

        let creation = WorkspaceCommandService.createTemplateTasks(
            template: template,
            taskTitle: "Run template",
            variables: [:],
            selectedSkills: [],
            defaultModel: AgentRuntimeAdapterRegistry.defaultModel(for: .claudeCode),
            defaultRuntimeID: AgentRuntimeID.copilotCLI.rawValue,
            workspace: workspace,
            modelContext: context,
            source: "test"
        )

        #expect(creation.mainTask.resolvedRuntimeID == .copilotCLI)
        #expect(creation.mainTask.model == AgentRuntimeAdapterRegistry.defaultModel(for: .copilotCLI))
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "RuntimeModelAvailabilityTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }
}

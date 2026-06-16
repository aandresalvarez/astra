import Foundation
import Testing
import SwiftData
@testable import ASTRA
import ASTRACore

@Suite("Task Role Profile Store")
struct TaskRoleProfileStoreTests {
    @MainActor
    @Test("role defaults load from global runtime settings")
    func roleDefaultsLoadFromGlobalRuntimeSettings() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(AgentRuntimeID.copilotCLI.rawValue, forKey: "defaultRuntimeID")
        defaults.set("gpt-5-codex", forKey: "defaultModel")
        defaults.set(25_000, forKey: AppStorageKeys.defaultTokenBudget)
        defaults.set(AgentPolicyLevel.review.rawValue, forKey: AppStorageKeys.defaultAgentPolicyLevel)

        let selection = TaskRoleProfileStore.selection(for: .planner, defaults: defaults)

        #expect(selection.source == "default")
        #expect(selection.profile.role == .planner)
        #expect(selection.profile.runtimeID == AgentRuntimeID.copilotCLI.rawValue)
        #expect(selection.profile.model == "gpt-5-codex")
        #expect(selection.profile.tokenBudget == 25_000)
        #expect(selection.profile.policyLevelRaw == AgentPolicyLevel.review.rawValue)
    }

    @Test("composer policy overrides role default for launch selection")
    func composerPolicyOverridesRoleDefaultForLaunchSelection() {
        let selection = TaskRoleProfileSelection(
            profile: TaskRoleProfile(
                role: .worker,
                runtimeID: AgentRuntimeID.copilotCLI.rawValue,
                model: "claude-sonnet-4.6",
                tokenBudget: 0,
                policyLevelRaw: AgentPolicyLevel.review.rawValue
            ),
            source: "default"
        )

        let updated = TaskComposerPolicySelection.applyingComposerPolicy(
            .autonomous,
            to: selection,
            source: "composer_policy"
        )

        #expect(updated.profile.policyLevelRaw == AgentPolicyLevel.autonomous.rawValue)
        #expect(updated.source == "composer_policy")
    }

    @MainActor
    @Test("task worker profile uses task override without mutating global settings")
    func taskWorkerProfileUsesTaskOverrideWithoutMutatingGlobalSettings() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(AgentRuntimeID.claudeCode.rawValue, forKey: "defaultRuntimeID")
        defaults.set("claude-sonnet-4-6", forKey: "defaultModel")

        let task = AgentTask(
            title: "Worker override",
            goal: "Use task runtime",
            tokenBudget: 10_000,
            model: "gpt-5-codex",
            runtime: .copilotCLI
        )
        let selection = TaskRoleProfileStore.selection(for: .worker, task: task, defaults: defaults)

        #expect(selection.source == "task_override")
        #expect(selection.profile.runtimeID == AgentRuntimeID.copilotCLI.rawValue)
        #expect(selection.profile.model == "gpt-5-codex")
        #expect(defaults.string(forKey: "defaultRuntimeID") == AgentRuntimeID.claudeCode.rawValue)
    }

    @MainActor
    @Test("verifier prefers a different configured runtime when no override exists")
    func verifierPrefersDifferentConfiguredRuntimeWhenNoOverrideExists() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let task = AgentTask(
            title: "Verifier",
            goal: "Check verifier",
            tokenBudget: 10_000,
            model: "claude-sonnet-4-6",
            runtime: .claudeCode
        )
        var settings = AgentRuntimeProviderSettings()
        settings.setExecutablePath("/usr/local/bin/copilot", for: .copilotCLI)

        let selection = TaskRoleProfileStore.selection(
            for: .verifier,
            task: task,
            defaultRuntimeID: AgentRuntimeID.claudeCode.rawValue,
            defaultModel: "claude-sonnet-4-6",
            validationModel: "claude-haiku-4-5-20251001",
            providerSettings: settings,
            defaults: defaults
        )

        #expect(selection.source == "default_independent")
        #expect(selection.profile.runtimeID == AgentRuntimeID.copilotCLI.rawValue)
    }

    @MainActor
    @Test("role selection event is durable")
    func roleSelectionEventIsDurable() throws {
        let container = try ModelContainer(
            for: Workspace.self, AgentTask.self, TaskEvent.self, TaskRun.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let task = AgentTask(title: "Audit", goal: "Record role", tokenBudget: 10_000)
        context.insert(task)
        let selection = TaskRoleProfileSelection(
            profile: TaskRoleProfile(
                role: .verifier,
                runtimeID: AgentRuntimeID.claudeCode.rawValue,
                model: "claude-haiku-4-5-20251001",
                tokenBudget: 10_000,
                policyLevelRaw: AgentPolicyLevel.review.rawValue
            ),
            source: "default"
        )

        TaskRoleProfileStore.recordSelected(selection, task: task, modelContext: context)

        let event = try #require(task.events.first { $0.type == TaskRoleProfileEventTypes.selected })
        #expect(event.category == "lifecycle")
        #expect(event.payload.contains("\"role\":\"verifier\""))
        #expect(event.payload.contains("\"source\":\"default\""))
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "TaskRoleProfileStoreTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }
}

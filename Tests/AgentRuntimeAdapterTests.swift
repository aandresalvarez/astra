import Testing
@testable import ASTRA
import ASTRACore

@Suite("Agent Runtime Adapters")
struct AgentRuntimeAdapterTests {
    @Test("Every runtime has one registered adapter")
    func everyRuntimeHasOneRegisteredAdapter() {
        let registeredIDs = AgentRuntimeAdapterRegistry.runtimeIDs

        #expect(Set(registeredIDs) == Set(AgentRuntimeID.allCases))
        #expect(registeredIDs.count == AgentRuntimeID.allCases.count)

        for runtime in AgentRuntimeID.allCases {
            let adapter = AgentRuntimeAdapterRegistry.adapter(for: runtime)

            #expect(adapter.id == runtime)
            #expect(adapter.descriptor.id == runtime)
            #expect(adapter.readinessCheckID.isEmpty == false)
        }
    }

    @Test("Adapters own model cache storage keys")
    func adaptersOwnModelCacheStorageKeys() {
        let claude = AgentRuntimeAdapterRegistry.adapter(for: .claudeCode)
        let copilot = AgentRuntimeAdapterRegistry.adapter(for: .copilotCLI)

        #expect(claude.availableModelsStorageKey == AppStorageKeys.claudeAvailableModels)
        #expect(claude.modelsCheckedAtStorageKey == AppStorageKeys.claudeModelsCheckedAt)
        #expect(copilot.availableModelsStorageKey == AppStorageKeys.copilotAvailableModels)
        #expect(copilot.modelsCheckedAtStorageKey == AppStorageKeys.copilotModelsCheckedAt)
        #expect(Set(AgentRuntimeAdapterRegistry.allAdapters.map(\.availableModelsStorageKey)).count == AgentRuntimeID.allCases.count)
        #expect(Set(AgentRuntimeAdapterRegistry.allAdapters.map(\.modelsCheckedAtStorageKey)).count == AgentRuntimeID.allCases.count)
    }

    @Test("Adapters select provider scoped cached model JSON")
    func adaptersSelectProviderScopedCachedModelJSON() {
        let claude = AgentRuntimeAdapterRegistry.adapter(for: .claudeCode)
        let copilot = AgentRuntimeAdapterRegistry.adapter(for: .copilotCLI)

        #expect(claude.cachedModelsJSON(
            cachedClaudeModelsJSON: "claude-cache",
            cachedCopilotModelsJSON: "copilot-cache"
        ) == "claude-cache")
        #expect(copilot.cachedModelsJSON(
            cachedClaudeModelsJSON: "claude-cache",
            cachedCopilotModelsJSON: "copilot-cache"
        ) == "copilot-cache")
    }

    @Test("Adapters preserve policy and budget wiring")
    func adaptersPreservePolicyAndBudgetWiring() {
        let claude = AgentRuntimeAdapterRegistry.adapter(for: .claudeCode)
        let copilot = AgentRuntimeAdapterRegistry.adapter(for: .copilotCLI)

        #expect(claude.policyAdapter(copilotCapabilities: .conservative).providerID == .claudeCode)
        #expect(copilot.policyAdapter(copilotCapabilities: .conservative).providerID == .copilotCLI)
        #expect(claude.budgetProfile == AgentRuntimeBudgetProfile.profile(for: .claudeCode))
        #expect(copilot.budgetProfile == AgentRuntimeBudgetProfile.profile(for: .copilotCLI))
        #expect(claude.budgetProfile.launchOverheadTokens == 120_000)
        #expect(copilot.budgetProfile.launchOverheadTokens == 0)
    }

    @Test("Adapter readiness check IDs match service reports")
    func adapterReadinessCheckIDsMatchServiceReports() async {
        let runner = StubBinaryRunner()
        await runner.setResponse(
            forKey: "/opt/claude --version",
            result: RunResult(outcome: .exited(code: 0), stdout: "Claude 1.0\n", stderr: "")
        )
        await runner.setResponse(
            forKey: "/opt/claude auth status",
            result: RunResult(outcome: .exited(code: 0), stdout: #"{"loggedIn":true}"#, stderr: "")
        )
        await runner.setResponse(
            forKey: "/opt/copilot --version",
            result: RunResult(outcome: .exited(code: 0), stdout: "copilot 1.0\n", stderr: "")
        )

        let service = RuntimeReadinessService(
            runner: runner,
            detectExecutable: { binary in
                switch binary {
                case "claude": "/opt/claude"
                case "copilot": "/opt/copilot"
                default: ""
                }
            },
            isExecutable: { !$0.isEmpty }
        )

        for runtime in AgentRuntimeAdapterRegistry.runtimeIDs {
            let report = await service.check(configuration: RuntimeReadinessConfiguration(
                runtime: runtime,
                claudePath: "",
                copilotPath: "",
                claudeProvider: .anthropic,
                vertexProjectID: "",
                vertexRegion: "",
                vertexOpusModel: "",
                vertexSonnetModel: "",
                vertexHaikuModel: ""
            ))

            #expect(report.checks.contains {
                $0.id == AgentRuntimeAdapterRegistry.adapter(for: runtime).readinessCheckID
            })
        }
    }
}

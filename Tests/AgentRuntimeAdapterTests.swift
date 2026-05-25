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

    @Test("Adapters own process command planning")
    @MainActor
    func adaptersOwnProcessCommandPlanning() {
        let workspace = Workspace(name: "Adapter", primaryPath: "/tmp/astra-adapter")
        let claudeTask = AgentTask(
            title: "Claude",
            goal: "Say hi",
            workspace: workspace,
            model: "claude-sonnet-4-6",
            runtime: .claudeCode
        )
        let copilotTask = AgentTask(
            title: "Copilot",
            goal: "Say hi",
            workspace: workspace,
            model: "gpt-5",
            runtime: .copilotCLI
        )

        let claudePlan = AgentRuntimeAdapterRegistry
            .adapter(for: .claudeCode)
            .makeProcessLaunchPlan(context: AgentRuntimeProcessLaunchContext(
                prompt: "hello",
                task: claudeTask,
                workspacePath: workspace.primaryPath,
                executablePath: "/bin/claude",
                copilotHome: "",
                permissionPolicy: .restricted,
                executionPolicy: .default,
                permissionManifest: nil,
                timeoutSeconds: 30
            ))
        let copilotPlan = AgentRuntimeAdapterRegistry
            .adapter(for: .copilotCLI)
            .makeProcessLaunchPlan(context: AgentRuntimeProcessLaunchContext(
                prompt: "hello",
                task: copilotTask,
                workspacePath: workspace.primaryPath,
                executablePath: "/bin/copilot-not-present",
                copilotHome: "/tmp/astra-copilot-home",
                permissionPolicy: .restricted,
                executionPolicy: .default,
                permissionManifest: nil,
                timeoutSeconds: 30
            ))

        #expect(claudePlan.runtime == .claudeCode)
        #expect(claudePlan.executablePath == "/bin/claude")
        #expect(claudePlan.arguments.contains("--output-format"))
        #expect(claudePlan.arguments.contains("stream-json"))
        #expect(claudePlan.parsesJSONLines)
        #expect(claudePlan.providerVersion == nil)

        #expect(copilotPlan.runtime == .copilotCLI)
        #expect(copilotPlan.executablePath == "/bin/copilot-not-present")
        #expect(copilotPlan.arguments.starts(with: ["--prompt", "hello", "--model"]))
        #expect(copilotPlan.directoriesToCreate == ["/tmp/astra-copilot-home"])
        #expect(copilotPlan.providerDetectedFields["runtime"] == AgentRuntimeID.copilotCLI.rawValue)
    }

    @Test("Adapters own provider stream parsing")
    func adaptersOwnProviderStreamParsing() {
        let claude = AgentRuntimeAdapterRegistry.adapter(for: .claudeCode)
        let copilot = AgentRuntimeAdapterRegistry.adapter(for: .copilotCLI)
        let claudeLine = #"{"type":"assistant","message":{"content":[{"type":"text","text":"hello"}]}}"#
        let copilotLine = #"{"type":"agent.message.delta","data":{"text":"hello"}}"#
        let permissionPrompt = "Allow access to these paths? (y/n):"

        #expect(claude.parseProcessEvents(line: claudeLine, parsesJSONLines: true).count == 1)
        #expect(claude.parseWorkerStreamEvents(line: claudeLine, parsesJSONLines: true).parsedEvents.count == 1)
        #expect(copilot.parseProcessEvents(line: copilotLine, parsesJSONLines: true).isEmpty == false)
        #expect(copilot.parseWorkerStreamEvents(line: copilotLine, parsesJSONLines: true).agentEvents.isEmpty == false)
        #expect(claude.blockingProcessPermissionMessage(line: permissionPrompt, parsesJSONLines: false) == nil)
        #expect(copilot.blockingProcessPermissionMessage(line: permissionPrompt, parsesJSONLines: false) != nil)
    }
}

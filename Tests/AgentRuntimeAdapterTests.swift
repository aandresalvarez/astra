import Foundation
import Testing
@testable import ASTRA
import ASTRACore

@Suite("Agent Runtime Adapters")
struct AgentRuntimeAdapterTests {
    @Test("Every runtime has one registered adapter")
    func everyRuntimeHasOneRegisteredAdapter() {
        let registeredIDs = AgentRuntimeAdapterRegistry.runtimeIDs

        #expect(Set(registeredIDs) == Set(AgentRuntimeAdapterRegistry.descriptors.map(\.id)))
        #expect(registeredIDs.count == AgentRuntimeAdapterRegistry.allAdapters.count)
        #expect(AgentRuntimeAdapterRegistry.registrationIssues.isEmpty)

        for runtime in registeredIDs {
            let adapter = AgentRuntimeAdapterRegistry.adapter(for: runtime)

            #expect(adapter.id == runtime)
            #expect(adapter.descriptor.id == runtime)
            #expect(adapter.readinessCheckID.isEmpty == false)
        }
    }

    @Test("Adapter catalogs can be composed without the global provider list")
    func adapterCatalogsCanBeComposedWithoutGlobalProviderList() throws {
        let catalog = AgentRuntimeAdapterCatalog(providers: [
            StaticAgentRuntimeAdapterProvider(
                providerID: "test-copilot-provider",
                runtimeAdapters: [CopilotCLIRuntimeAdapter()]
            )
        ])
        let futureRuntime = try #require(AgentRuntimeID(rawValue: "future_cli"))

        #expect(catalog.runtimeIDs == [.copilotCLI])
        #expect(catalog.registrationIssues.isEmpty)
        #expect(catalog.hasAdapter(for: .copilotCLI))
        #expect(catalog.hasAdapter(for: .claudeCode) == false)
        #expect(catalog.registeredRuntime(rawValue: AgentRuntimeID.claudeCode.rawValue, fallback: .copilotCLI) == .copilotCLI)
        #expect(catalog.descriptor(for: futureRuntime).defaultModel == "default")
        #expect(catalog.descriptor(for: futureRuntime).defaultModels == ["default"])
        #expect(catalog.supportsAstraRunProtocol(for: futureRuntime) == false)
        #expect(catalog.supportsNativeContinuation(for: futureRuntime) == false)
    }

    @Test("Registry exposes typed runtime adapter boundaries")
    @MainActor
    func registryExposesTypedRuntimeAdapterBoundaries() {
        let runtime = AgentRuntimeID.copilotCLI
        let adapter = AgentRuntimeAdapterRegistry.adapter(for: runtime)
        let descriptorReadiness = AgentRuntimeAdapterRegistry.descriptorReadiness(for: runtime)
        let policyRenderer = AgentRuntimeAdapterRegistry.policyRenderer(for: runtime)
        let processLauncher = AgentRuntimeAdapterRegistry.processLauncher(for: runtime)
        let processParser = AgentRuntimeAdapterRegistry.processEventParser(for: runtime)
        let workerRecorder = AgentRuntimeAdapterRegistry.workerEventRecorder(for: runtime)
        let utilityRuntime = AgentRuntimeAdapterRegistry.utilityRuntime(for: runtime)
        let postRunDiagnostics = AgentRuntimeAdapterRegistry.postRunDiagnostics(for: runtime)

        #expect(descriptorReadiness.id == adapter.id)
        #expect(descriptorReadiness.descriptor == adapter.descriptor)
        #expect(policyRenderer.policyAdapter(runtimeCapabilities: .conservative).providerID == runtime)
        #expect(processLauncher.launchSettings(configuration: AgentRuntimeConfiguration()).homeDirectory == CopilotCLIRuntime.channelHome())
        #expect(processParser.parseProcessEvents(line: #"{"type":"agent.message.delta","data":{"text":"hello"}}"#, parsesJSONLines: true).isEmpty == false)
        #expect(workerRecorder.recordsStreamTelemetry == adapter.recordsStreamTelemetry)
        #expect(postRunDiagnostics.manualCompletionPayload(phase: "run") == adapter.manualCompletionPayload(phase: "run"))
        _ = utilityRuntime
    }

    @Test("Adapter catalogs report duplicate provider registrations")
    func adapterCatalogsReportDuplicateProviderRegistrations() {
        let catalog = AgentRuntimeAdapterCatalog(providers: [
            StaticAgentRuntimeAdapterProvider(
                providerID: "primary-claude-provider",
                runtimeAdapters: [ClaudeCodeRuntimeAdapter()]
            ),
            StaticAgentRuntimeAdapterProvider(
                providerID: "duplicate-claude-provider",
                runtimeAdapters: [
                    ClaudeCodeRuntimeAdapter(),
                    CopilotCLIRuntimeAdapter()
                ]
            )
        ])

        #expect(catalog.runtimeIDs == [.claudeCode, .copilotCLI])
        #expect(catalog.registrationIssues == [
            AgentRuntimeAdapterRegistrationIssue(
                runtimeID: .claudeCode,
                providerID: "duplicate-claude-provider",
                message: "Runtime 'claude_code' is already registered by provider 'primary-claude-provider'."
            )
        ])
    }

    @Test("Shared launch state release is awaited before returning")
    func sharedLaunchStateReleaseIsAwaitedBeforeReturning() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let runnerURL = repoRoot
            .appendingPathComponent("Astra")
            .appendingPathComponent("Services")
            .appendingPathComponent("Runtime")
            .appendingPathComponent("AgentRuntimeProcessRunner.swift")
        let source = try String(contentsOf: runnerURL, encoding: .utf8)

        #expect(source.contains("await AgentRuntimeSharedStateGate.shared.release(sharedStateKey)"))
        #expect(!source.contains("Task { await AgentRuntimeSharedStateGate.shared.release(sharedStateKey) }"))
    }

    @Test("Adapters own model cache storage keys")
    func adaptersOwnModelCacheStorageKeys() {
        let claude = AgentRuntimeAdapterRegistry.adapter(for: .claudeCode)
        let copilot = AgentRuntimeAdapterRegistry.adapter(for: .copilotCLI)
        let antigravity = AgentRuntimeAdapterRegistry.adapter(for: .antigravityCLI)
        let codex = AgentRuntimeAdapterRegistry.adapter(for: .codexCLI)
        let cursor = AgentRuntimeAdapterRegistry.adapter(for: .cursorCLI)
        let openCode = AgentRuntimeAdapterRegistry.adapter(for: .openCodeCLI)

        #expect(claude.availableModelsStorageKey == AppStorageKeys.claudeAvailableModels)
        #expect(claude.modelsCheckedAtStorageKey == AppStorageKeys.claudeModelsCheckedAt)
        #expect(copilot.availableModelsStorageKey == AppStorageKeys.copilotAvailableModels)
        #expect(copilot.modelsCheckedAtStorageKey == AppStorageKeys.copilotModelsCheckedAt)
        #expect(antigravity.descriptor.defaultModels.contains("Gemini 3.5 Flash (Low)"))
        #expect(antigravity.descriptor.defaultModel != "default")
        #expect(codex.descriptor.executableName == "codex")
        #expect(codex.descriptor.defaultModels.first == "gpt-5.5")
        #expect(cursor.descriptor.executableName == "cursor-agent")
        #expect(cursor.descriptor.defaultModels.first == "composer-2.5-fast")
        #expect(openCode.descriptor.executableName == "opencode")
        #expect(openCode.descriptor.defaultModels.first == "opencode/big-pickle")
        #expect(Set(AgentRuntimeAdapterRegistry.allAdapters.map(\.availableModelsStorageKey)).count == AgentRuntimeAdapterRegistry.allAdapters.count)
        #expect(Set(AgentRuntimeAdapterRegistry.allAdapters.map(\.modelsCheckedAtStorageKey)).count == AgentRuntimeAdapterRegistry.allAdapters.count)
    }

    @Test("Registry rejects unregistered provider IDs without losing the raw value")
    @MainActor
    func registryRejectsUnregisteredProviderIDsWithoutLosingRawValue() throws {
        let futureRuntime = try #require(AgentRuntimeID(rawValue: "future_cli"))
        let workspace = Workspace(name: "Future", primaryPath: "/tmp/astra-future")
        let task = AgentTask(
            title: "Future",
            goal: "Use future provider",
            workspace: workspace,
            runtime: futureRuntime
        )
        let configuration = AgentRuntimeConfiguration(defaultRuntimeID: .copilotCLI)
        let fallbackDescriptor = AgentRuntimeAdapterRegistry.descriptor(for: futureRuntime)

        #expect(futureRuntime.rawValue == "future_cli")
        #expect(AgentRuntimeAdapterRegistry.adapterIfRegistered(for: futureRuntime) == nil)
        #expect(fallbackDescriptor.id == futureRuntime)
        #expect(fallbackDescriptor.executableName == "future_cli")
        #expect(configuration.selectedRuntime(for: task) == .copilotCLI)
    }

    @Test("Adapters select provider scoped cached model JSON")
    func adaptersSelectProviderScopedCachedModelJSON() {
        let futureRuntime = AgentRuntimeID(rawValue: "future_cli")!
        let cache = RuntimeModelAvailabilityCache(rawSnapshots: [
            .claudeCode: "claude-cache",
            .copilotCLI: "copilot-cache",
            futureRuntime: "future-cache"
        ])

        #expect(cache.rawSnapshot(for: .claudeCode) == "claude-cache")
        #expect(cache.rawSnapshot(for: .copilotCLI) == "copilot-cache")
        #expect(cache.rawSnapshot(for: futureRuntime) == "future-cache")
    }

    @Test("Adapters preserve policy and budget wiring")
    func adaptersPreservePolicyAndBudgetWiring() {
        let claude = AgentRuntimeAdapterRegistry.adapter(for: .claudeCode)
        let copilot = AgentRuntimeAdapterRegistry.adapter(for: .copilotCLI)
        let antigravity = AgentRuntimeAdapterRegistry.adapter(for: .antigravityCLI)
        let codex = AgentRuntimeAdapterRegistry.adapter(for: .codexCLI)
        let cursor = AgentRuntimeAdapterRegistry.adapter(for: .cursorCLI)
        let openCode = AgentRuntimeAdapterRegistry.adapter(for: .openCodeCLI)
        let permissiveCapabilities = AgentRuntimePolicyCapabilities(
            copilotCLI: CopilotCLICapabilities(helpText: "--output-format --no-ask-user --allow-all")
        )
        let copilotPolicyAdapter = copilot.policyAdapter(runtimeCapabilities: permissiveCapabilities) as? CopilotPolicyAdapter

        #expect(claude.policyAdapter(runtimeCapabilities: .conservative).providerID == .claudeCode)
        #expect(copilot.policyAdapter(runtimeCapabilities: .conservative).providerID == .copilotCLI)
        #expect(antigravity.policyAdapter(runtimeCapabilities: .conservative).providerID == .antigravityCLI)
        #expect(codex.policyAdapter(runtimeCapabilities: .conservative).providerID == .codexCLI)
        #expect(cursor.policyAdapter(runtimeCapabilities: .conservative).providerID == .cursorCLI)
        #expect(openCode.policyAdapter(runtimeCapabilities: .conservative).providerID == .openCodeCLI)
        #expect(copilotPolicyAdapter?.capabilities.supportsAllowAll == true)
        #expect(copilotPolicyAdapter?.capabilities.supportsOutputFormatJSON == true)
        #expect(claude.budgetProfile == AgentRuntimeBudgetProfile.profile(for: .claudeCode))
        #expect(copilot.budgetProfile == AgentRuntimeBudgetProfile.profile(for: .copilotCLI))
        #expect(antigravity.budgetProfile == AgentRuntimeBudgetProfile.profile(for: .antigravityCLI))
        #expect(codex.budgetProfile == AgentRuntimeBudgetProfile.profile(for: .codexCLI))
        #expect(cursor.budgetProfile == AgentRuntimeBudgetProfile.profile(for: .cursorCLI))
        #expect(openCode.budgetProfile == AgentRuntimeBudgetProfile.profile(for: .openCodeCLI))
        #expect(claude.budgetProfile.launchOverheadTokens == 120_000)
        #expect(copilot.budgetProfile.launchOverheadTokens == 0)
        #expect(antigravity.budgetProfile.launchOverheadTokens == 0)
        #expect(codex.budgetProfile.launchOverheadTokens == 0)
        #expect(cursor.budgetProfile.launchOverheadTokens == 0)
        #expect(openCode.budgetProfile.launchOverheadTokens == 0)
    }

    @Test("Adapters own CLI install planning")
    func adaptersOwnCLIInstallPlanning() {
        let claudePlan = AgentRuntimeAdapterRegistry
            .adapter(for: .claudeCode)
            .installPlan { binary in binary == "npm" ? "/opt/homebrew/bin/npm" : "" }
        let copilotPlan = AgentRuntimeAdapterRegistry
            .adapter(for: .copilotCLI)
            .installPlan { binary in binary == "brew" ? "/opt/homebrew/bin/brew" : "" }
        let antigravityPlan = AgentRuntimeAdapterRegistry
            .adapter(for: .antigravityCLI)
            .installPlan { binary in binary == "bash" ? "/bin/bash" : "" }

        #expect(claudePlan?.runtime == .claudeCode)
        #expect(claudePlan?.displayCommand == "npm install -g @anthropic-ai/claude-code")
        #expect(copilotPlan?.runtime == .copilotCLI)
        #expect(copilotPlan?.displayCommand == "brew install copilot-cli")
        #expect(antigravityPlan == nil)
        let antigravity = AgentRuntimeAdapterRegistry.descriptor(for: .antigravityCLI)
        #expect(antigravity.installHint.contains("official Google Antigravity CLI setup docs"))
        #expect(antigravity.installHint.contains("curl") == false)
        #expect(antigravity.installHint.contains("| bash") == false)
    }

    @Test("Adapters own session lifecycle policy")
    @MainActor
    func adaptersOwnSessionLifecyclePolicy() {
        let workspace = Workspace(name: "Adapter", primaryPath: "/tmp/astra-adapter")
        let task = AgentTask(
            title: "Lifecycle",
            goal: "Say hi",
            workspace: workspace,
            runtime: .claudeCode
        )
        let configuration = AgentRuntimeConfiguration(
            claudePath: "/tmp/claude",
            copilotPath: "/tmp/copilot",
            copilotHome: "/tmp/copilot-home"
        )
        let claude = AgentRuntimeAdapterRegistry.adapter(for: .claudeCode)
        let copilot = AgentRuntimeAdapterRegistry.adapter(for: .copilotCLI)
        let antigravity = AgentRuntimeAdapterRegistry.adapter(for: .antigravityCLI)
        let cursor = AgentRuntimeAdapterRegistry.adapter(for: .cursorCLI)
        let openCode = AgentRuntimeAdapterRegistry.adapter(for: .openCodeCLI)

        #expect(claude.launchSettings(configuration: configuration).executablePath == "/tmp/claude")
        #expect(copilot.launchSettings(configuration: configuration).homeDirectory == "/tmp/copilot-home")
        #expect(claude.recordsStreamTelemetry == false)
        #expect(copilot.recordsStreamTelemetry)
        #expect(antigravity.recordsStreamTelemetry == false)
        #expect(cursor.recordsStreamTelemetry)
        #expect(openCode.recordsStreamTelemetry)
        #expect(claude.recordsInferredFileChanges == false)
        #expect(copilot.recordsInferredFileChanges)
        #expect(antigravity.recordsInferredFileChanges)
        #expect(cursor.recordsInferredFileChanges)
        #expect(openCode.recordsInferredFileChanges)
        #expect(claude.descriptor.supportsNativeContinuation)
        #expect(AgentRuntimeAdapterRegistry.supportsNativeContinuation(for: .claudeCode))
        #expect(copilot.descriptor.supportsNativeContinuation == false)
        #expect(AgentRuntimeAdapterRegistry.supportsNativeContinuation(for: .copilotCLI) == false)
        #expect(antigravity.descriptor.supportsNativeContinuation == false)
        #expect(AgentRuntimeAdapterRegistry.supportsNativeContinuation(for: .antigravityCLI) == false)
        #expect(cursor.descriptor.supportsNativeContinuation == false)
        #expect(AgentRuntimeAdapterRegistry.supportsNativeContinuation(for: .cursorCLI) == false)
        #expect(openCode.descriptor.supportsNativeContinuation == false)
        #expect(AgentRuntimeAdapterRegistry.supportsNativeContinuation(for: .openCodeCLI) == false)

        #expect(claude.shouldCheckWorkspaceDirectory(phase: "resume") == false)
        #expect(copilot.shouldCheckWorkspaceDirectory(phase: "resume"))
        #expect(antigravity.shouldCheckWorkspaceDirectory(phase: "resume"))
        #expect(cursor.shouldCheckWorkspaceDirectory(phase: "resume"))
        #expect(openCode.shouldCheckWorkspaceDirectory(phase: "resume"))
        #expect(claude.shouldPrepareIsolation(phase: "resume") == false)
        #expect(copilot.shouldPrepareIsolation(phase: "resume"))
        #expect(antigravity.shouldPrepareIsolation(phase: "resume"))
        #expect(cursor.shouldPrepareIsolation(phase: "resume"))
        #expect(openCode.shouldPrepareIsolation(phase: "resume"))
        #expect(claude.shouldValidateSuccessfulRun(phase: "resume") == false)
        #expect(copilot.shouldValidateSuccessfulRun(phase: "resume"))
        #expect(antigravity.shouldValidateSuccessfulRun(phase: "resume"))
        #expect(cursor.shouldValidateSuccessfulRun(phase: "resume"))
        #expect(openCode.shouldValidateSuccessfulRun(phase: "resume"))
        #expect(claude.performsPostRunFollowUps(phase: "run"))
        #expect(copilot.performsPostRunFollowUps(phase: "run") == false)
        #expect(antigravity.performsPostRunFollowUps(phase: "run") == false)
        #expect(cursor.performsPostRunFollowUps(phase: "run") == false)
        #expect(openCode.performsPostRunFollowUps(phase: "run") == false)

        #expect(claude.defaultStartEventPayload(task: task) == "Agent started working on: Say hi")
        #expect(copilot.defaultStartEventPayload(task: task) == "Copilot started working on: Say hi")
        #expect(antigravity.defaultStartEventPayload(task: task) == "Antigravity started working on: Say hi")
        #expect(cursor.defaultStartEventPayload(task: task) == "Cursor started working on: Say hi")
        #expect(openCode.defaultStartEventPayload(task: task) == "OpenCode started working on: Say hi")
        #expect(claude.sessionTurnMessage(
            task: task,
            promptOverride: "prompt",
            startPayload: "start",
            sessionMessage: "message",
            phase: "resume"
        ) == "message")
        #expect(copilot.sessionTurnMessage(
            task: task,
            promptOverride: "prompt",
            startPayload: "start",
            sessionMessage: "message",
            phase: "resume"
        ) == "start")
        #expect(antigravity.sessionTurnMessage(
            task: task,
            promptOverride: "prompt",
            startPayload: "start",
            sessionMessage: "message",
            phase: "resume"
        ) == "start")
        #expect(openCode.sessionTurnMessage(
            task: task,
            promptOverride: "prompt",
            startPayload: "start",
            sessionMessage: "message",
            phase: "resume"
        ) == "start")
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
        await runner.setResponse(
            forKey: "/opt/agy --version",
            result: RunResult(outcome: .exited(code: 0), stdout: "1.0.2\n", stderr: "")
        )
        await runner.setResponse(
            forKey: "/opt/agy --print Reply with ASTRA_READY only. --print-timeout 30s --sandbox",
            result: RunResult(outcome: .exited(code: 0), stdout: "ASTRA_READY\n", stderr: "")
        )
        await runner.setResponse(
            forKey: "/opt/codex --version",
            result: RunResult(outcome: .exited(code: 0), stdout: "codex-cli 1.0\n", stderr: "")
        )
        await runner.setResponse(
            forKey: "/opt/cursor-agent --version",
            result: RunResult(outcome: .exited(code: 0), stdout: "2026.06.04-5fd875e\n", stderr: "")
        )

        let service = RuntimeReadinessService(
            runner: runner,
            detectExecutable: { binary in
                switch binary {
                case "claude": "/opt/claude"
                case "copilot": "/opt/copilot"
                case "agy": "/opt/agy"
                case "codex": "/opt/codex"
                case "cursor-agent": "/opt/cursor-agent"
                case "opencode": "/opt/opencode"
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
        let antigravityTask = AgentTask(
            title: "Antigravity",
            goal: "Say hi",
            workspace: workspace,
            model: "default",
            runtime: .antigravityCLI
        )
        let codexTask = AgentTask(
            title: "Codex",
            goal: "Say hi",
            workspace: workspace,
            model: "gpt-5.5",
            runtime: .codexCLI
        )
        let cursorTask = AgentTask(
            title: "Cursor",
            goal: "Say hi",
            workspace: workspace,
            model: "composer-2.5-fast",
            runtime: .cursorCLI
        )
        let openCodeTask = AgentTask(
            title: "OpenCode",
            goal: "Say hi",
            workspace: workspace,
            model: "opencode/big-pickle",
            runtime: .openCodeCLI
        )

        let claudePlan = AgentRuntimeAdapterRegistry
            .adapter(for: .claudeCode)
            .makeProcessLaunchPlan(context: AgentRuntimeProcessLaunchContext(
                prompt: "hello",
                task: claudeTask,
                workspacePath: workspace.primaryPath,
                executablePath: "/bin/claude",
                providerHomeDirectory: "",
                permissionPolicy: .restricted,
                executionPolicy: .default,
                permissionManifest: nil,
                timeoutSeconds: 30
            ))
        let claudeResumePlan = AgentRuntimeAdapterRegistry
            .adapter(for: .claudeCode)
            .makeProcessLaunchPlan(context: AgentRuntimeProcessLaunchContext(
                prompt: "hello",
                task: claudeTask,
                workspacePath: workspace.primaryPath,
                executablePath: "/bin/claude",
                providerHomeDirectory: "",
                permissionPolicy: .restricted,
                executionPolicy: .default,
                permissionManifest: nil,
                timeoutSeconds: 30,
                phase: "resume",
                nativeContinuationSessionID: "claude-session-1"
            ))
        let copilotPlan = AgentRuntimeAdapterRegistry
            .adapter(for: .copilotCLI)
            .makeProcessLaunchPlan(context: AgentRuntimeProcessLaunchContext(
                prompt: "hello",
                task: copilotTask,
                workspacePath: workspace.primaryPath,
                executablePath: "/bin/copilot-not-present",
                providerHomeDirectory: "/tmp/astra-provider-home",
                permissionPolicy: .restricted,
                executionPolicy: .default,
                permissionManifest: nil,
                timeoutSeconds: 30
            ))
        let antigravityPlan = AgentRuntimeAdapterRegistry
            .adapter(for: .antigravityCLI)
            .makeProcessLaunchPlan(context: AgentRuntimeProcessLaunchContext(
                prompt: "hello",
                task: antigravityTask,
                workspacePath: workspace.primaryPath,
                executablePath: "/bin/agy-not-present",
                providerHomeDirectory: "/tmp/astra-antigravity-home",
                permissionPolicy: .restricted,
                executionPolicy: .default,
                permissionManifest: nil,
                timeoutSeconds: 30
            ))
        let codexPlan = AgentRuntimeAdapterRegistry
            .adapter(for: .codexCLI)
            .makeProcessLaunchPlan(context: AgentRuntimeProcessLaunchContext(
                prompt: "hello",
                task: codexTask,
                workspacePath: workspace.primaryPath,
                executablePath: "/bin/codex-not-present",
                providerHomeDirectory: "/tmp/astra-codex-home",
                permissionPolicy: .restricted,
                executionPolicy: .default,
                permissionManifest: nil,
                timeoutSeconds: 30
            ))
        let cursorPlan = AgentRuntimeAdapterRegistry
            .adapter(for: .cursorCLI)
            .makeProcessLaunchPlan(context: AgentRuntimeProcessLaunchContext(
                prompt: "hello",
                task: cursorTask,
                workspacePath: workspace.primaryPath,
                executablePath: "/bin/cursor-agent-not-present",
                providerHomeDirectory: "",
                permissionPolicy: .restricted,
                executionPolicy: .default,
                permissionManifest: nil,
                timeoutSeconds: 30
            ))
        let openCodePlan = AgentRuntimeAdapterRegistry
            .adapter(for: .openCodeCLI)
            .makeProcessLaunchPlan(context: AgentRuntimeProcessLaunchContext(
                prompt: "hello",
                task: openCodeTask,
                workspacePath: workspace.primaryPath,
                executablePath: "/bin/opencode-not-present",
                providerHomeDirectory: "",
                permissionPolicy: .restricted,
                executionPolicy: .default,
                permissionManifest: nil,
                timeoutSeconds: 30
            ))

        #expect(claudePlan.runtime == .claudeCode)
        #expect(claudePlan.executablePath == "/bin/claude")
        #expect(claudePlan.arguments.contains("--output-format"))
        #expect(claudePlan.arguments.contains("stream-json"))
        #expect(claudePlan.arguments.contains("--include-partial-messages"))
        #expect(claudePlan.arguments.contains("--resume") == false)
        #expect(claudePlan.commandPlannedFields["phase"] == "run")
        #expect(claudePlan.commandPlannedFields["supports_native_continuation"] == "true")
        #expect(claudePlan.commandPlannedFields["uses_native_continuation"] == "false")
        #expect(claudePlan.parsesJSONLines)
        #expect(claudePlan.providerVersion == nil)
        #expect(claudeResumePlan.arguments.starts(with: ["-p", "hello", "--resume", "claude-session-1"]))
        #expect(claudeResumePlan.commandPlannedFields["phase"] == "resume")
        #expect(claudeResumePlan.commandPlannedFields["uses_native_continuation"] == "true")
        #expect(claudeResumePlan.commandPlannedFields["native_session_prefix"] == "claude-s")

        #expect(copilotPlan.runtime == .copilotCLI)
        #expect(copilotPlan.executablePath == "/bin/copilot-not-present")
        #expect(copilotPlan.arguments.starts(with: ["--prompt", "hello", "--model"]))
        #expect(copilotPlan.directoriesToCreate == ["/tmp/astra-provider-home"])
        #expect(copilotPlan.providerDetectedFields["runtime"] == AgentRuntimeID.copilotCLI.rawValue)

        #expect(antigravityPlan.runtime == .antigravityCLI)
        #expect(antigravityPlan.executablePath == "/bin/agy-not-present")
        #expect(antigravityPlan.arguments.starts(with: ["--print", "hello", "--print-timeout", "30s"]))
        #expect(antigravityPlan.arguments.contains("--sandbox"))
        #expect(antigravityPlan.parsesJSONLines == false)
        #expect(antigravityPlan.environment["HOME"] == "/tmp/astra-antigravity-home")
        #expect(antigravityPlan.providerDetectedFields["runtime"] == AgentRuntimeID.antigravityCLI.rawValue)
        #expect(antigravityPlan.providerDetectedFields["provider_home_configured"] == "true")
        #expect(antigravityPlan.commandPlannedFields["model"] == AgentRuntimeAdapterRegistry.defaultModel(for: .antigravityCLI))
        #expect(antigravityPlan.commandPlannedFields["provider_model"] == AgentRuntimeAdapterRegistry.defaultModel(for: .antigravityCLI))
        #expect(antigravityPlan.commandPlannedFields["model_applied"] == "false")

        #expect(codexPlan.runtime == .codexCLI)
        #expect(codexPlan.executablePath == "/bin/codex-not-present")
        #expect(codexPlan.arguments.starts(with: ["exec", "--json", "--color", "never"]))
        #expect(codexPlan.arguments.contains("--model"))
        #expect(codexPlan.arguments.contains("gpt-5.5"))
        #expect(codexPlan.arguments.contains("--cd"))
        #expect(codexPlan.arguments.contains(workspace.primaryPath))
        #expect(codexPlan.arguments.contains("--sandbox"))
        #expect(codexPlan.arguments.contains("workspace-write"))
        #expect(codexPlan.arguments.contains("--ask-for-approval") == false)
        #expect(codexPlan.arguments.last == "hello")
        #expect(codexPlan.parsesJSONLines)
        #expect(codexPlan.environment["CODEX_HOME"] == "/tmp/astra-codex-home")
        #expect(codexPlan.directoriesToCreate == ["/tmp/astra-codex-home"])
        #expect(codexPlan.providerDetectedFields["runtime"] == AgentRuntimeID.codexCLI.rawValue)
        #expect(codexPlan.providerDetectedFields["provider_home_configured"] == "true")
        #expect(codexPlan.commandPlannedFields["permission_policy"] == PermissionPolicy.restricted.rawValue)

        #expect(cursorPlan.runtime == .cursorCLI)
        #expect(cursorPlan.executablePath == "/bin/cursor-agent-not-present")
        #expect(cursorPlan.arguments.starts(with: ["--print", "--output-format", "stream-json"]))
        #expect(cursorPlan.arguments.contains("--stream-partial-output") == false)
        #expect(cursorPlan.arguments.contains("--trust"))
        #expect(cursorPlan.arguments.contains("--workspace"))
        #expect(cursorPlan.arguments.contains(workspace.primaryPath))
        #expect(cursorPlan.arguments.contains("--model"))
        #expect(cursorPlan.arguments.contains("composer-2.5-fast"))
        #expect(cursorPlan.arguments.contains("--sandbox"))
        #expect(cursorPlan.arguments.contains("enabled"))
        #expect(cursorPlan.arguments.last == "hello")
        #expect(cursorPlan.parsesJSONLines)
        #expect(cursorPlan.directoriesToCreate == [])
        #expect(cursorPlan.providerDetectedFields["runtime"] == AgentRuntimeID.cursorCLI.rawValue)
        #expect(cursorPlan.commandPlannedFields["permission_policy"] == PermissionPolicy.restricted.rawValue)

        #expect(openCodePlan.runtime == .openCodeCLI)
        #expect(openCodePlan.executablePath == "/bin/opencode-not-present")
        #expect(openCodePlan.arguments.starts(with: ["run", "--format", "json"]))
        #expect(openCodePlan.arguments.contains("--dir"))
        #expect(openCodePlan.arguments.contains(workspace.primaryPath))
        #expect(openCodePlan.arguments.contains("--model"))
        #expect(openCodePlan.arguments.contains("opencode/big-pickle"))
        #expect(openCodePlan.arguments.contains("--dangerously-skip-permissions") == false)
        #expect(openCodePlan.arguments.last == "hello")
        #expect(openCodePlan.parsesJSONLines)
        #expect(openCodePlan.directoriesToCreate == [])
        #expect(openCodePlan.providerDetectedFields["runtime"] == AgentRuntimeID.openCodeCLI.rawValue)
        #expect(openCodePlan.commandPlannedFields["permission_policy"] == PermissionPolicy.restricted.rawValue)
    }

    @Test("Codex launch allows external read-only SSH config access for SSH workspaces")
    @MainActor
    func codexLaunchAllowsExternalReadOnlySSHConfigAccess() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-codex-ssh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let workspace = Workspace(name: "SSH", primaryPath: root.path)
        SSHConnectionManager.save([
            SSHConnection(
                name: "deid-jsn-workbench",
                host: "deid-as-service-jsn",
                user: "alvaro1_stanford_edu",
                keyPath: "~/.ssh/google_compute_engine",
                configAlias: "deid-jsn-workbench"
            )
        ], workspacePath: root.path)
        let task = AgentTask(
            title: "SSH task",
            goal: "Check the remote server",
            workspace: workspace,
            model: "gpt-5.5",
            runtime: .codexCLI
        )

        let plan = AgentRuntimeAdapterRegistry
            .adapter(for: .codexCLI)
            .makeProcessLaunchPlan(context: AgentRuntimeProcessLaunchContext(
                prompt: "ssh deid-jsn-workbench 'echo OK'",
                task: task,
                workspacePath: workspace.primaryPath,
                executablePath: "/bin/codex-not-present",
                providerHomeDirectory: "/tmp/astra-codex-home",
                permissionPolicy: .restricted,
                executionPolicy: .default,
                permissionManifest: nil,
                timeoutSeconds: 30
            ))

        #expect(plan.arguments.contains("--config"))
        #expect(plan.arguments.contains("sandbox_permissions=[\"disk-full-read-access\"]"))
    }

    @Test("Copilot launch audit separates task and runtime support tools")
    @MainActor
    func copilotLaunchAuditSeparatesTaskAndRuntimeSupportTools() {
        let workspace = Workspace(name: "Copilot Support", primaryPath: "/tmp/astra-copilot-support")
        let task = AgentTask(
            title: "Copilot",
            goal: "Who are you?",
            workspace: workspace,
            model: "gpt-5",
            runtime: .copilotCLI
        )
        let supportTools = CopilotPolicyAdapter().runtimeSupportTools
        let providerRender = ProviderPolicyRender(
            providerID: .copilotCLI,
            adapterVersion: 1,
            policyLevel: .review,
            configOwnership: .generated,
            permissionMode: PermissionPolicy.restricted.rawValue,
            allowedTools: ["read"],
            runtimeSupportTools: supportTools,
            askFirstTools: [],
            deniedTools: [],
            allowedShellPatterns: [],
            askFirstShellPatterns: [],
            deniedShellPatterns: [],
            allowedURLPatterns: [],
            deniedURLPatterns: [],
            cliArgumentsSummary: [],
            settingsSummary: "test",
            generatedConfigPreview: "",
            enforcementTiers: [.providerNative, .astraBrokered],
            diagnostics: [],
            usesBroadProviderPermissions: false
        )
        let manifest = RunPermissionManifest(
            taskID: task.id,
            runID: UUID(),
            phase: "test",
            providerID: .copilotCLI,
            providerVersion: nil,
            model: "gpt-5",
            policyLevel: .review,
            policyScope: .builtInDefault,
            providerRender: providerRender,
            workspacePath: workspace.primaryPath,
            additionalPaths: [],
            environmentKeyNames: [],
            credentialLabels: [],
            approvalsGranted: [],
            approvalGrants: []
        )

        let plan = AgentRuntimeAdapterRegistry
            .adapter(for: .copilotCLI)
            .makeProcessLaunchPlan(context: AgentRuntimeProcessLaunchContext(
                prompt: "hello",
                task: task,
                workspacePath: workspace.primaryPath,
                executablePath: "/bin/copilot-not-present",
                providerHomeDirectory: "/tmp/astra-provider-home",
                permissionPolicy: .restricted,
                executionPolicy: .approvedPlan(runtime: .copilotCLI, currentPermissionPolicy: .restricted, allowedTools: ["read"]),
                permissionManifest: manifest,
                timeoutSeconds: 30
            ))

        #expect(plan.commandPlannedFields["allowed_tools_count"] == "1")
        #expect(plan.commandPlannedFields["runtime_support_tool_count"] == "2")
        #expect(plan.commandPlannedFields["runtime_support_tool_names"] == "fetch_copilot_cli_documentation,report_intent")
        #expect(plan.arguments.contains("view"))
        #expect(plan.arguments.contains("grep"))
        #expect(plan.arguments.contains("glob"))
        #expect(plan.arguments.contains("fetch_copilot_cli_documentation"))
        #expect(plan.arguments.contains("report_intent"))
    }

    @Test("Artifact bootstrap policy adds minimal write only for artifact tasks")
    @MainActor
    func artifactBootstrapPolicyAddsMinimalWriteOnlyForArtifactTasks() {
        let workspace = Workspace(name: "Artifact Bootstrap", primaryPath: "/tmp/astra-artifact-bootstrap")
        let artifactTask = AgentTask(
            title: "Create Masterball puzzle web solver",
            goal: "createa web page wit a masterball (similar to rubicks cube but as aball ) with a solver in javascript",
            workspace: workspace,
            runtime: .copilotCLI
        )
        let informationalTask = AgentTask(
            title: "Explain",
            goal: "explain who you are",
            workspace: workspace,
            runtime: .copilotCLI
        )

        #expect(ProviderArtifactBootstrapPolicy.launchTools(
            task: artifactTask,
            permissionPolicy: .restricted,
            providerAllowedTools: ["Read", "Glob", "Grep"],
            askFirstTools: ["Write", "Edit", "Bash"]
        ) == ["Write"])
        #expect(ProviderArtifactBootstrapPolicy.launchTools(
            task: artifactTask,
            permissionPolicy: .restricted,
            providerAllowedTools: ["Read", "Write"],
            askFirstTools: ["Write", "Edit", "Bash"]
        ).isEmpty)
        #expect(ProviderArtifactBootstrapPolicy.launchTools(
            task: artifactTask,
            permissionPolicy: .autonomous,
            providerAllowedTools: ["Read"],
            askFirstTools: ["Write", "Edit", "Bash"]
        ).isEmpty)
        #expect(ProviderArtifactBootstrapPolicy.launchTools(
            task: informationalTask,
            permissionPolicy: .restricted,
            providerAllowedTools: ["Read", "Glob", "Grep"],
            askFirstTools: ["Write", "Edit", "Bash"]
        ).isEmpty)
    }

    @Test("Copilot artifact launch grants bootstrap write without counting it as a task tool")
    @MainActor
    func copilotArtifactLaunchGrantsBootstrapWriteWithoutCountingAsTaskTool() throws {
        let workspaceURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-copilot-artifact-bootstrap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspaceURL) }
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let copilotPath = try Self.writeFakeCopilotExecutable(in: workspaceURL)

        let workspace = Workspace(name: "Copilot Artifact", primaryPath: workspaceURL.path)
        let task = AgentTask(
            title: "Create Masterball puzzle web solver",
            goal: "createa web page wit a masterball (similar to rubicks cube but as aball ) with a solver in javascript",
            workspace: workspace,
            model: "gpt-5.3-codex",
            runtime: .copilotCLI
        )
        let manifest = Self.copilotManifest(
            task: task,
            workspacePath: workspace.primaryPath,
            allowedTools: ["read"],
            askFirstTools: ["Write", "Edit", "MultiEdit", "Bash"]
        )

        let plan = AgentRuntimeAdapterRegistry
            .adapter(for: .copilotCLI)
            .makeProcessLaunchPlan(context: AgentRuntimeProcessLaunchContext(
                prompt: "hello",
                task: task,
                workspacePath: workspace.primaryPath,
                executablePath: copilotPath,
                providerHomeDirectory: workspaceURL.appendingPathComponent("copilot-home", isDirectory: true).path,
                permissionPolicy: .restricted,
                executionPolicy: .approvedPlan(runtime: .copilotCLI, currentPermissionPolicy: .restricted, allowedTools: ["read"]),
                permissionManifest: manifest,
                timeoutSeconds: 30
            ))

        let allowedEntries = Set(Self.argumentValues(after: "--allow-tool", in: plan.arguments))
        let availableEntries = Set(Self.argumentValues(after: "--available-tools", in: plan.arguments))

        #expect(plan.commandPlannedFields["allowed_tools_count"] == "1")
        #expect(plan.commandPlannedFields["provider_launch_allowed_tool_count"] == "2")
        #expect(plan.commandPlannedFields["artifact_bootstrap_profile"] == "true")
        #expect(plan.commandPlannedFields["artifact_bootstrap_tool_count"] == "1")
        #expect(plan.commandPlannedFields["artifact_bootstrap_tool_names"] == "Write")
        #expect(allowedEntries.contains("view"))
        #expect(allowedEntries.contains("grep"))
        #expect(allowedEntries.contains("glob"))
        #expect(allowedEntries.contains("write"))
        #expect(!allowedEntries.contains("create"))
        #expect(!allowedEntries.contains("edit"))
        #expect(availableEntries.contains("apply_patch"))
        #expect(availableEntries.contains("create"))
        #expect(availableEntries.contains("edit"))
        #expect(availableEntries.contains("rg"))
    }

    @Test("Copilot informational launch does not get artifact bootstrap write")
    @MainActor
    func copilotInformationalLaunchDoesNotGetArtifactBootstrapWrite() throws {
        let workspaceURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-copilot-info-bootstrap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspaceURL) }
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let copilotPath = try Self.writeFakeCopilotExecutable(in: workspaceURL)

        let workspace = Workspace(name: "Copilot Info", primaryPath: workspaceURL.path)
        let task = AgentTask(
            title: "Explain",
            goal: "explain who you are",
            workspace: workspace,
            model: "gpt-5.3-codex",
            runtime: .copilotCLI
        )
        let manifest = Self.copilotManifest(
            task: task,
            workspacePath: workspace.primaryPath,
            allowedTools: ["read"],
            askFirstTools: ["Write", "Edit", "MultiEdit", "Bash"]
        )

        let plan = AgentRuntimeAdapterRegistry
            .adapter(for: .copilotCLI)
            .makeProcessLaunchPlan(context: AgentRuntimeProcessLaunchContext(
                prompt: "hello",
                task: task,
                workspacePath: workspace.primaryPath,
                executablePath: copilotPath,
                providerHomeDirectory: workspaceURL.appendingPathComponent("copilot-home", isDirectory: true).path,
                permissionPolicy: .restricted,
                executionPolicy: .approvedPlan(runtime: .copilotCLI, currentPermissionPolicy: .restricted, allowedTools: ["read"]),
                permissionManifest: manifest,
                timeoutSeconds: 30
            ))

        let allowedEntries = Set(Self.argumentValues(after: "--allow-tool", in: plan.arguments))
        let availableEntries = Set(Self.argumentValues(after: "--available-tools", in: plan.arguments))

        #expect(plan.commandPlannedFields["allowed_tools_count"] == "1")
        #expect(plan.commandPlannedFields["provider_launch_allowed_tool_count"] == "1")
        #expect(plan.commandPlannedFields["artifact_bootstrap_profile"] == "false")
        #expect(plan.commandPlannedFields["artifact_bootstrap_tool_count"] == "0")
        #expect(!allowedEntries.contains("write"))
        #expect(availableEntries.contains("apply_patch"))
        #expect(availableEntries.contains("create"))
        #expect(availableEntries.contains("edit"))
        #expect(availableEntries.contains("rg"))
    }

    @Test("Claude launch surfaces ask-first tools without counting them as allowed task tools")
    @MainActor
    func claudeLaunchSurfacesAskFirstToolsWithoutCountingThemAsAllowedTaskTools() throws {
        let workspaceURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-claude-ask-first-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspaceURL) }
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)

        let workspace = Workspace(name: "Claude Ask First", primaryPath: workspaceURL.path)
        let task = AgentTask(
            title: "Claude",
            goal: "Create index.html",
            workspace: workspace,
            model: "claude-sonnet-4-6",
            runtime: .claudeCode
        )
        let providerRender = ProviderPolicyRender(
            providerID: .claudeCode,
            adapterVersion: 1,
            policyLevel: .review,
            configOwnership: .generated,
            permissionMode: PermissionPolicy.restricted.rawValue,
            allowedTools: ["Read"],
            runtimeSupportTools: [],
            askFirstTools: ["Write", "Edit", "Bash"],
            deniedTools: [],
            allowedShellPatterns: [],
            askFirstShellPatterns: [],
            deniedShellPatterns: [],
            allowedURLPatterns: [],
            deniedURLPatterns: [],
            cliArgumentsSummary: [],
            settingsSummary: "test",
            generatedConfigPreview: "",
            enforcementTiers: [.providerNative, .astraBrokered],
            diagnostics: [],
            usesBroadProviderPermissions: false
        )
        let manifest = RunPermissionManifest(
            taskID: task.id,
            runID: UUID(),
            phase: "test",
            providerID: .claudeCode,
            providerVersion: nil,
            model: "claude-sonnet-4-6",
            policyLevel: .review,
            policyScope: .builtInDefault,
            providerRender: providerRender,
            workspacePath: workspace.primaryPath,
            additionalPaths: [],
            environmentKeyNames: [],
            credentialLabels: [],
            approvalsGranted: [],
            approvalGrants: []
        )

        let plan = AgentRuntimeAdapterRegistry
            .adapter(for: .claudeCode)
            .makeProcessLaunchPlan(context: AgentRuntimeProcessLaunchContext(
                prompt: "hello",
                task: task,
                workspacePath: workspace.primaryPath,
                executablePath: "/bin/claude",
                providerHomeDirectory: "",
                permissionPolicy: .restricted,
                executionPolicy: .approvedPlan(runtime: .claudeCode, currentPermissionPolicy: .restricted, allowedTools: ["Read"]),
                permissionManifest: manifest,
                timeoutSeconds: 30
            ))

        #expect(plan.commandPlannedFields["allowed_tools_count"] == "1")
        #expect(plan.commandPlannedFields["ask_first_tool_count"] == "3")
        #expect(plan.commandPlannedFields["ask_first_tool_names"] == "Bash,Edit,Write")
        #expect(plan.commandPlannedFields["uses_visible_tools_filter"] == "true")
        #expect(plan.commandPlannedFields["visible_tools_count"] == "4")
        #expect(plan.commandPlannedFields["visible_tool_names"] == "Bash,Edit,Read,Write")
        #expect(plan.commandPlannedFields["artifact_bootstrap_profile"] == "true")
        #expect(plan.commandPlannedFields["artifact_bootstrap_tool_count"] == "1")
        #expect(plan.commandPlannedFields["artifact_bootstrap_tool_names"] == "Write")
        #expect(plan.commandPlannedFields["provider_launch_allowed_tool_count"] == "4")
        #expect(plan.commandPlannedFields["launch_effort"] == "low")
        let effortFlagIndex = try #require(plan.arguments.firstIndex(of: "--effort"))
        #expect(plan.arguments[effortFlagIndex + 1] == "low")
        let toolsFlagIndex = try #require(plan.arguments.firstIndex(of: "--tools"))
        #expect(plan.arguments[toolsFlagIndex + 1] == "Bash,Edit,Read,Write")
        #expect(!plan.arguments[toolsFlagIndex + 1].contains("TaskCreate"))
        #expect(plan.arguments.contains("--allowedTools"))
        #expect(plan.arguments.contains("Read"))
        #expect(plan.arguments.contains("Write"))
        #expect(plan.arguments.contains("Edit"))
        #expect(plan.arguments.contains("Bash"))

        let settingsURL = workspaceURL
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.local.json")
        let data = try Data(contentsOf: settingsURL)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let permissions = try #require(json["permissions"] as? [String: Any])
        let allow = try #require(permissions["allow"] as? [String])
        #expect(allow.contains("Read(*)"))
        #expect(allow.contains("Write(*)"))
        #expect(allow.contains("Edit(*)"))
        #expect(allow.contains("Bash(*)"))

        task.useAgentTeam = true
        let teamPlan = AgentRuntimeAdapterRegistry
            .adapter(for: .claudeCode)
            .makeProcessLaunchPlan(context: AgentRuntimeProcessLaunchContext(
                prompt: "hello",
                task: task,
                workspacePath: workspace.primaryPath,
                executablePath: "/bin/claude",
                providerHomeDirectory: "",
                permissionPolicy: .restricted,
                executionPolicy: .approvedPlan(runtime: .claudeCode, currentPermissionPolicy: .restricted, allowedTools: ["Read"]),
                permissionManifest: manifest,
                timeoutSeconds: 30
            ))
        let teamToolsFlagIndex = try #require(teamPlan.arguments.firstIndex(of: "--tools"))
        let teamTools = teamPlan.arguments[teamToolsFlagIndex + 1]
        #expect(teamTools.contains("TeamCreate"))
        #expect(teamTools.contains("TaskOutput"))
        #expect(teamPlan.commandPlannedFields["visible_tool_names"]?.contains("TeamCreate") == true)
    }

    @Test("Claude launch keeps informational tasks on default effort")
    @MainActor
    func claudeLaunchKeepsInformationalTasksOnDefaultEffort() throws {
        let workspaceURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-claude-default-effort-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspaceURL) }
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)

        let workspace = Workspace(name: "Claude Default Effort", primaryPath: workspaceURL.path)
        let task = AgentTask(
            title: "Explain",
            goal: "explain who you are",
            workspace: workspace,
            model: "claude-sonnet-4-6",
            runtime: .claudeCode
        )
        let providerRender = ProviderPolicyRender(
            providerID: .claudeCode,
            adapterVersion: 1,
            policyLevel: .review,
            configOwnership: .generated,
            permissionMode: PermissionPolicy.restricted.rawValue,
            allowedTools: ["Read"],
            runtimeSupportTools: [],
            askFirstTools: ["Write", "Edit", "Bash"],
            deniedTools: [],
            allowedShellPatterns: [],
            askFirstShellPatterns: [],
            deniedShellPatterns: [],
            allowedURLPatterns: [],
            deniedURLPatterns: [],
            cliArgumentsSummary: [],
            settingsSummary: "test",
            generatedConfigPreview: "",
            enforcementTiers: [.providerNative, .astraBrokered],
            diagnostics: [],
            usesBroadProviderPermissions: false
        )
        let manifest = RunPermissionManifest(
            taskID: task.id,
            runID: UUID(),
            phase: "test",
            providerID: .claudeCode,
            providerVersion: nil,
            model: "claude-sonnet-4-6",
            policyLevel: .review,
            policyScope: .builtInDefault,
            providerRender: providerRender,
            workspacePath: workspace.primaryPath,
            additionalPaths: [],
            environmentKeyNames: [],
            credentialLabels: [],
            approvalsGranted: [],
            approvalGrants: []
        )

        let plan = AgentRuntimeAdapterRegistry
            .adapter(for: .claudeCode)
            .makeProcessLaunchPlan(context: AgentRuntimeProcessLaunchContext(
                prompt: "hello",
                task: task,
                workspacePath: workspace.primaryPath,
                executablePath: "/bin/claude",
                providerHomeDirectory: "",
                permissionPolicy: .restricted,
                executionPolicy: .approvedPlan(runtime: .claudeCode, currentPermissionPolicy: .restricted, allowedTools: ["Read"]),
                permissionManifest: manifest,
                timeoutSeconds: 30
            ))

        #expect(plan.commandPlannedFields["artifact_bootstrap_profile"] == "false")
        #expect(plan.commandPlannedFields["launch_effort"] == "default")
        #expect(!plan.arguments.contains("--effort"))
    }

    @Test("Antigravity declares shared launch state and suggestion-only model availability")
    func antigravityDeclaresSharedLaunchStateAndSuggestionModelAvailability() {
        let adapter = AgentRuntimeAdapterRegistry.adapter(for: .antigravityCLI)
        let workspace = Workspace(name: "Provider State", primaryPath: "/tmp/astra-provider-state")
        let task = AgentTask(
            title: "Antigravity",
            goal: "Say hi",
            workspace: workspace,
            model: "Gemini 3.5 Flash",
            runtime: .antigravityCLI
        )
        let context = AgentRuntimeProcessLaunchContext(
            prompt: "hello",
            task: task,
            workspacePath: workspace.primaryPath,
            executablePath: "/bin/agy",
            providerHomeDirectory: "/tmp/astra-antigravity-home",
            permissionPolicy: .restricted,
            executionPolicy: .default,
            permissionManifest: nil,
            timeoutSeconds: 30
        )

        #expect(adapter.modelAvailabilityAuthority == .suggestions)
        #expect(adapter.sharedLaunchStateKey(context: context)?.rawValue.contains("antigravity_cli:") == true)
        #expect(adapter.sharedLaunchStateKey(context: context)?.rawValue.contains("/tmp/astra-antigravity-home/.gemini/antigravity-cli/settings.json") == true)
        #expect(AgentRuntimeAdapterRegistry.adapter(for: .claudeCode).sharedLaunchStateKey(context: context) == nil)
        #expect(AgentRuntimeAdapterRegistry.adapter(for: .copilotCLI).sharedLaunchStateKey(context: context) == nil)
    }

    @Test("Adapters own provider stream parsing")
    func adaptersOwnProviderStreamParsing() {
        let claude = AgentRuntimeAdapterRegistry.adapter(for: .claudeCode)
        let copilot = AgentRuntimeAdapterRegistry.adapter(for: .copilotCLI)
        let antigravity = AgentRuntimeAdapterRegistry.adapter(for: .antigravityCLI)
        let cursor = AgentRuntimeAdapterRegistry.adapter(for: .cursorCLI)
        let claudeLine = #"{"type":"assistant","message":{"content":[{"type":"text","text":"hello"}]}}"#
        let copilotLine = #"{"type":"agent.message.delta","data":{"text":"hello"}}"#
        let antigravityLine = "hello from antigravity"
        let cursorLine = #"{"type":"assistant","message":{"content":[{"type":"text","text":"hello"}]}}"#
        let permissionPrompt = "Allow access to these paths? (y/n):"

        #expect(claude.parseProcessEvents(line: claudeLine, parsesJSONLines: true).count == 1)
        #expect(claude.parseWorkerStreamEvents(line: claudeLine, parsesJSONLines: true).parsedEvents.count == 1)
        #expect(copilot.parseProcessEvents(line: copilotLine, parsesJSONLines: true).isEmpty == false)
        #expect(copilot.parseWorkerStreamEvents(line: copilotLine, parsesJSONLines: true).agentEvents.isEmpty == false)
        #expect(antigravity.parseProcessEvents(line: antigravityLine, parsesJSONLines: false).isEmpty == false)
        #expect(antigravity.parseWorkerStreamEvents(line: antigravityLine, parsesJSONLines: false).agentEvents == [
            .text(text: "hello from antigravity\n")
        ])
        #expect(cursor.parseProcessEvents(line: cursorLine, parsesJSONLines: true).count == 1)
        #expect(cursor.parseWorkerStreamEvents(line: cursorLine, parsesJSONLines: true).agentEvents == [
            .text(text: "hello")
        ])
        #expect(claude.blockingProcessPermissionMessage(line: permissionPrompt, parsesJSONLines: false) == nil)
        #expect(copilot.blockingProcessPermissionMessage(line: permissionPrompt, parsesJSONLines: false) != nil)
        #expect(antigravity.blockingProcessPermissionMessage(line: permissionPrompt, parsesJSONLines: false) != nil)
    }

    @Test("Copilot launch exposes browser bridge from follow-up context")
    @MainActor
    func copilotLaunchExposesBrowserBridgeFromFollowUpContext() throws {
        ShelfBrowserBridgeRegistry.shared.reset()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-copilot-browser-context-\(UUID().uuidString)", isDirectory: true)
        defer {
            ShelfBrowserBridgeRegistry.shared.reset()
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let workspace = Workspace(name: "Browser Context", primaryPath: root.path)
        let task = AgentTask(
            title: "Continue task",
            goal: "Continue the task",
            workspace: workspace,
            model: "gpt-5",
            runtime: .copilotCLI
        )
        ShelfBrowserBridgeRegistry.shared.update(
            endpoint: "http://127.0.0.1:49152",
            currentURL: nil,
            currentTitle: nil,
            taskID: task.id,
            isPresented: false,
            isEnabled: true
        )

        let hiddenEnvironment = AgentRuntimeProcessRunner.scopedEnvironmentVariables(for: task)
        #expect(hiddenEnvironment["ASTRA_BROWSER_URL"] == nil)

        let plan = AgentRuntimeAdapterRegistry
            .adapter(for: .copilotCLI)
            .makeProcessLaunchPlan(context: AgentRuntimeProcessLaunchContext(
                prompt: "Use the browser shelf",
                task: task,
                workspacePath: workspace.primaryPath,
                executablePath: "/bin/copilot-not-present",
                providerHomeDirectory: root.appendingPathComponent("copilot-home").path,
                permissionPolicy: .restricted,
                executionPolicy: .default,
                permissionManifest: nil,
                timeoutSeconds: 30,
                phase: "resume",
                contextText: "Use the browser shelf to inspect the current page."
            ))

        #expect(plan.environment["ASTRA_BROWSER_URL"] == "http://127.0.0.1:49152")
        #expect(plan.browserShimDirectory?.hasSuffix(".runtime-bin") == true)
    }

    private static func copilotManifest(
        task: AgentTask,
        workspacePath: String,
        allowedTools: [String],
        askFirstTools: [String]
    ) -> RunPermissionManifest {
        let providerRender = ProviderPolicyRender(
            providerID: .copilotCLI,
            adapterVersion: 1,
            policyLevel: .review,
            configOwnership: .generated,
            permissionMode: PermissionPolicy.restricted.rawValue,
            allowedTools: allowedTools,
            runtimeSupportTools: CopilotPolicyAdapter().runtimeSupportTools,
            askFirstTools: askFirstTools,
            deniedTools: [],
            allowedShellPatterns: [],
            askFirstShellPatterns: [],
            deniedShellPatterns: [],
            allowedURLPatterns: [],
            deniedURLPatterns: [],
            cliArgumentsSummary: [],
            settingsSummary: "test",
            generatedConfigPreview: "",
            enforcementTiers: [.providerNative, .astraBrokered],
            diagnostics: [],
            usesBroadProviderPermissions: false
        )
        return RunPermissionManifest(
            taskID: task.id,
            runID: UUID(),
            phase: "test",
            providerID: .copilotCLI,
            providerVersion: nil,
            model: task.model,
            policyLevel: .review,
            policyScope: .builtInDefault,
            providerRender: providerRender,
            workspacePath: workspacePath,
            additionalPaths: [],
            environmentKeyNames: [],
            credentialLabels: [],
            approvalsGranted: [],
            approvalGrants: []
        )
    }

    private static func writeFakeCopilotExecutable(in directory: URL) throws -> String {
        let url = directory.appendingPathComponent("copilot")
        let script = """
        #!/bin/sh
        if [ "$1" = "help" ]; then
          cat <<'HELP'
        --allow-tool TOOL --available-tools=TOOLS --excluded-tools=TOOLS --output-format=FORMAT --stream=MODE --no-ask-user
        HELP
          exit 0
        fi
        if [ "$1" = "--version" ] || [ "$1" = "version" ]; then
          echo "copilot fake 1.0"
          exit 0
        fi
        exit 0
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private static func argumentValues(after flag: String, in arguments: [String]) -> [String] {
        guard let index = arguments.firstIndex(of: flag) else { return [] }
        let start = arguments.index(after: index)
        guard start < arguments.endIndex else { return [] }
        return Array(arguments[start...].prefix { !$0.hasPrefix("--") })
    }
}

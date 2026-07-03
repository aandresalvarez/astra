import Foundation
import SwiftData
import Testing
@testable import ASTRA
import ASTRACore

private func makeCodexRuntimeTestContainer() throws -> ModelContainer {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(
        for: ASTRASchema.current,
        migrationPlan: ASTRAMigrationPlan.self,
        configurations: [config]
    )
}

@Suite("Codex CLI Runtime")
struct CodexCLIRuntimeTests {
    @Test("Codex model suggestions match supported CLI models")
    func codexModelSuggestionsMatchSupportedCLIModels() {
        #expect(CodexCLIRuntime.availableModelNames() == [
            "gpt-5.5",
            "gpt-5.4",
            "gpt-5.4-mini",
            "gpt-5.3-codex-spark"
        ])
        #expect(CodexCLIRuntime.defaultModelName() == "gpt-5.5")
    }

    @Test("Codex stream parser records thread start")
    func codexStreamParserRecordsThreadStart() {
        let line = #"{"type":"thread.started","thread_id":"thread-123"}"#
        let parsed = CodexCLIRuntime.parseEvents(line: line, parsesJSONLines: true)

        if case .systemInit(let model, let sessionId) = parsed.first {
            #expect(model == nil)
            #expect(sessionId == "thread-123")
        } else {
            Issue.record("Expected system init event")
        }
    }

    @Test("Codex item completed agent message maps to visible output")
    func codexItemCompletedAgentMessageMapsToVisibleOutput() {
        let line = #"{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"I am Codex."}}"#
        let parsed = CodexCLIRuntime.parseEvents(line: line, parsesJSONLines: true)
        let agentEvents = CodexCLIRuntime.parseAgentEvents(line: line, parsesJSONLines: true)

        if case .result(let text, _, _, _, _, _, let isError) = parsed.first {
            #expect(text == "I am Codex.")
            #expect(isError == false)
        } else {
            Issue.record("Expected result event")
        }

        if case .completed(let summary) = agentEvents.first {
            #expect(summary == "I am Codex.")
        } else {
            Issue.record("Expected completed agent event")
        }
    }

    @Test("Codex turn completed usage includes cached input tokens")
    func codexTurnCompletedUsageIncludesCachedInputTokens() {
        let line = #"{"type":"turn.completed","usage":{"input_tokens":12,"cached_input_tokens":4,"output_tokens":5,"reasoning_output_tokens":3}}"#
        let parsed = CodexCLIRuntime.parseEvents(line: line, parsesJSONLines: true)
        let agentEvents = CodexCLIRuntime.parseAgentEvents(line: line, parsesJSONLines: true)

        if case .usage(let input, let output) = parsed.first {
            #expect(input == 16)
            #expect(output == 5)
        } else {
            Issue.record("Expected usage event")
        }

        if case .stats(let input, let output, _, _, _) = agentEvents.first {
            #expect(input == 16)
            #expect(output == 5)
        } else {
            Issue.record("Expected stats agent event")
        }
    }

    @MainActor
    @Test("Codex adapter follow-up mode accumulates usage instead of resetting task total")
    func codexAdapterFollowUpModeAccumulatesUsage() throws {
        let container = try makeCodexRuntimeTestContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Follow-up", goal: "Continue a Codex run")
        task.tokensUsed = 40
        let run = TaskRun(task: task)
        context.insert(task)
        context.insert(run)

        CodexCLIRuntimeAdapter().recordWorkerStreamEvent(
            .agent(.stats(inputTokens: 3, outputTokens: 7, costUSD: nil, durationMs: nil, turns: nil)),
            mode: .followUp,
            task: task,
            run: run,
            modelContext: context,
            recordingState: AgentEventRecordingState()
        )

        #expect(run.tokensUsed == 10)
        #expect(run.inputTokens == 3)
        #expect(run.outputTokens == 7)
        #expect(task.tokensUsed == 50)
    }

    @Test("Codex stream parser treats known lifecycle and item shapes as typed events")
    func codexStreamParserTreatsKnownLifecycleAndItemShapesAsTypedEvents() {
        let lines = [
            #"{"type":"turn.started"}"#,
            #"{"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"astra-browser read-page --format markdown","aggregated_output":"","exit_code":null,"status":"in_progress"}}"#,
            #"{"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"astra-browser read-page --format markdown","aggregated_output":"ok\n","exit_code":0,"status":"completed"}}"#,
            #"{"type":"item.completed","item":{"id":"item_2","type":"file_change","path":".astra/tasks/EBF58891/index.html","kind":"modified","summary":"Wrote the validation page"}}"#
        ]
        let capture = AgentRuntimeStreamDebugCapture()
        let parsedEvents = lines.map { line in
            let events = CodexCLIRuntime.parseAgentEvents(line: line, parsesJSONLines: true)
            capture.recordLine(line, parsesJSONLines: true)
            capture.recordParsed(events, rawLine: line)
            return events
        }

        #expect(parsedEvents.allSatisfy { !$0.isEmpty })
        #expect(parsedEvents.flatMap { $0 }.allSatisfy { event in
            guard case .unknown = event else { return true }
            return false
        })

        if case .toolUse(let name, let id, let summary) = parsedEvents[1].first {
            #expect(name == "command_execution")
            #expect(id == "item_1")
            #expect(summary?.contains("astra-browser read-page") == true)
        } else {
            Issue.record("Expected command execution item start to map to tool use")
        }

        if case .toolResult(let id, let content) = parsedEvents[2].first {
            #expect(id == "item_1")
            #expect(content.contains("ok"))
            #expect(content.contains("exit_code=0"))
        } else {
            Issue.record("Expected command execution item completion to map to tool result")
        }

        if case .fileChange(let path, let kind, let summary) = parsedEvents[3].first {
            #expect(path == ".astra/tasks/EBF58891/index.html")
            #expect(kind == "modified")
            #expect(summary == "Wrote the validation page")
        } else {
            Issue.record("Expected file change item completion to map to file change")
        }

        #expect(capture.snapshot().unknownJSONShapes.isEmpty)
    }

    @Test("Codex adapter requires visible result on successful run")
    func codexAdapterRequiresVisibleResultOnSuccessfulRun() {
        let adapter = CodexCLIRuntimeAdapter()

        #expect(adapter.requiresVisibleResultForSuccessfulRun(phase: "run"))
    }

    @Test("Codex exec command uses JSON, workspace, model, restricted policy, and automation isolation")
    func codexExecCommandUsesJSONWorkspaceModelRestrictedPolicyAndAutomationIsolation() throws {
        let plan = CodexCLIRuntime.buildCommand(
            executablePath: "/opt/codex",
            prompt: "Summarize the repo",
            model: "gpt-5.5",
            workspacePath: "/tmp/workspace",
            additionalPaths: ["/tmp/workspace", "/tmp/extra", "/tmp/extra"],
            permissionPolicy: .restricted,
            timeoutSeconds: 60,
            taskEnvironment: ["ASTRA_TASK_ID": "task-1"],
            providerHomeDirectory: "/tmp/codex-home",
            pathPrefix: ["/tmp/tools"],
            includeAstraToolsPath: true,
            permissionArguments: ProviderPolicyRender.codexLaunchPermissionArguments(
                policy: .restricted,
                resumingNativeSession: false
            )
        )

        #expect(plan.executablePath == "/opt/codex")
        #expect(plan.arguments.starts(with: [
            "exec",
            "--json",
            "--color", "never"
        ]))
        let modelIndex = try #require(plan.arguments.firstIndex(of: "--model"))
        #expect(plan.arguments[modelIndex + 1] == "gpt-5.5")
        let workspaceIndex = try #require(plan.arguments.firstIndex(of: "--cd"))
        #expect(plan.arguments[workspaceIndex + 1] == "/tmp/workspace")
        #expect(plan.arguments.contains("--add-dir"))
        #expect(plan.arguments.contains("/tmp/extra"))
        #expect(plan.arguments.contains("--sandbox"))
        #expect(plan.arguments.contains("workspace-write"))
        #expect(plan.arguments.contains(#"approval_policy="never""#))
        #expect(plan.arguments.contains("--ask-for-approval") == false)
        #expect(plan.arguments.contains("--skip-git-repo-check"))
        #expect(plan.arguments.contains("--ignore-user-config"))
        #expect(plan.arguments.contains("--ignore-rules"))
        // Sessions must persist (no --ephemeral) so follow-ups can `exec resume`.
        #expect(plan.arguments.contains("--ephemeral") == false)
        #expect(plan.arguments.contains("resume") == false)
        #expect(plan.arguments.last == "Summarize the repo")
        #expect(plan.environment["CODEX_HOME"] == "/tmp/codex-home")
        #expect(plan.environment["NO_COLOR"] == "1")
        #expect(plan.environment["ASTRA_TASK_ID"] == "task-1")
        #expect(plan.parsesJSONLines)
    }

    @Test("Codex sandbox roots follow provider home, inherited CODEX_HOME, and system requirements")
    func codexSandboxRootsFollowCodexLaunchState() {
        let providerRoots = CodexCLIRuntime.sandboxReadablePaths(
            providerHomeDirectory: "/tmp/provider-codex",
            environment: [
                "CODEX_HOME": "/tmp/inherited-codex",
                "HOME": "/tmp/user-home"
            ],
            processHomeDirectory: "/tmp/process-home"
        )
        #expect(providerRoots.contains("/tmp/provider-codex"))
        #expect(!providerRoots.contains("/tmp/inherited-codex"))
        #expect(!providerRoots.contains("/tmp/user-home/.codex"))
        #expect(providerRoots.contains("/etc/codex"))
        #if os(macOS)
        #expect(providerRoots.contains("/Library/Managed Preferences"))
        #expect(providerRoots.contains("/Library/Preferences"))
        #endif
        #expect(CodexCLIRuntime.directoriesToCreate(
            providerHomeDirectory: "/tmp/provider-codex",
            environment: ["CODEX_HOME": "/tmp/inherited-codex"]
        ) == ["/tmp/provider-codex"])

        let inheritedRoots = CodexCLIRuntime.sandboxReadablePaths(
            providerHomeDirectory: "",
            environment: [
                "CODEX_HOME": "/tmp/inherited-codex",
                "HOME": "/tmp/user-home"
            ],
            processHomeDirectory: "/tmp/process-home"
        )
        #expect(inheritedRoots.contains("/tmp/inherited-codex"))
        #expect(!inheritedRoots.contains("/tmp/user-home/.codex"))
        #expect(CodexCLIRuntime.directoriesToCreate(
            providerHomeDirectory: "",
            environment: ["CODEX_HOME": "/tmp/inherited-codex"]
        ) == ["/tmp/inherited-codex"])

        let homeRoots = CodexCLIRuntime.sandboxReadablePaths(
            providerHomeDirectory: "",
            environment: ["HOME": "/tmp/user-home"],
            processHomeDirectory: "/tmp/process-home"
        )
        #expect(homeRoots.contains("/tmp/user-home/.codex"))

        let processHomeRoots = CodexCLIRuntime.sandboxReadablePaths(
            providerHomeDirectory: "",
            environment: [:],
            processHomeDirectory: "/tmp/process-home"
        )
        #expect(processHomeRoots.contains("/tmp/process-home/.codex"))
    }

    @Test("Codex follow-up resumes the persisted session by thread id")
    func codexFollowUpResumesPersistedSession() throws {
        let plan = CodexCLIRuntime.buildCommand(
            executablePath: "/opt/codex",
            prompt: "Continue the work",
            model: "gpt-5.5",
            workspacePath: "/tmp/workspace",
            additionalPaths: [],
            permissionPolicy: .restricted,
            timeoutSeconds: 60,
            taskEnvironment: [:],
            resumeSessionID: "thread-abc-123",
            permissionArguments: ProviderPolicyRender.codexLaunchPermissionArguments(
                policy: .restricted,
                resumingNativeSession: true
            )
        )

        #expect(plan.arguments.starts(with: ["exec", "resume", "--json"]))
        #expect(plan.arguments.contains("thread-abc-123"))
        #expect(!plan.arguments.contains("--color"))
        #expect(!plan.arguments.contains("--cd"))
        #expect(!plan.arguments.contains("--add-dir"))
        // `exec resume` rejects -s/--sandbox, so the restricted policy preserves
        // its run-phase sandbox mode via the supported `-c sandbox_mode` override.
        #expect(!plan.arguments.contains("--sandbox"))
        #expect(plan.arguments.contains("-c"))
        #expect(plan.arguments.contains(#"approval_policy="never""#))
        #expect(plan.arguments.contains(#"sandbox_mode="workspace-write""#))
        #expect(plan.arguments.contains("--ephemeral") == false)
        #expect(plan.arguments.last == "Continue the work")

        let adapter = CodexCLIRuntimeAdapter()
        #expect(adapter.descriptor.supportsNativeContinuation)
        #expect(adapter.shouldClearStaleSessionOnFailure(
            phase: "resume",
            result: AgentProcessResult(exitCode: 1, error: "error: Session not found")
        ))
        #expect(!adapter.shouldClearStaleSessionOnFailure(
            phase: "resume",
            result: AgentProcessResult(exitCode: 1, error: "network timeout")
        ))
        #expect(!adapter.shouldClearStaleSessionOnFailure(
            phase: "run",
            result: AgentProcessResult(exitCode: 1, error: "session not found")
        ))
    }

    @Test("Codex resume preserves the sandbox policy via -c since --sandbox is invalid on resume")
    func codexResumePreservesSandboxPolicyViaConfigOverride() {
        // Parity with codexPermissionArguments: each non-autonomous policy maps to
        // the matching `sandbox_mode`, and no bare --sandbox flag leaks onto resume.
        let restricted = CodexCLIRuntime.codexResumePermissionArguments(policy: .restricted)
        #expect(restricted == ["-c", "approval_policy=\"never\"", "-c", "sandbox_mode=\"workspace-write\""])
        #expect(!restricted.contains("--sandbox"))

        let interactive = CodexCLIRuntime.codexResumePermissionArguments(policy: .interactive)
        #expect(interactive == ["-c", "approval_policy=\"never\"", "-c", "sandbox_mode=\"read-only\""])
        #expect(!interactive.contains("--sandbox"))

        // Autonomous stays externally sandboxed via the bypass flag (no -c needed).
        let autonomous = CodexCLIRuntime.codexResumePermissionArguments(policy: .autonomous)
        #expect(autonomous == ["--dangerously-bypass-approvals-and-sandbox"])
    }

    @Test("Codex autonomous policy grants full access without interactive approvals")
    func codexAutonomousPolicyGrantsFullAccessWithoutInteractiveApprovals() {
        let plan = CodexCLIRuntime.buildCommand(
            executablePath: "/opt/codex",
            prompt: "Implement the plan",
            model: "gpt-5.5",
            workspacePath: "/tmp/workspace",
            additionalPaths: [],
            permissionPolicy: .autonomous,
            timeoutSeconds: 60,
            taskEnvironment: [:],
            permissionArguments: ProviderPolicyRender.codexLaunchPermissionArguments(
                policy: .autonomous,
                resumingNativeSession: false
            )
        )

        #expect(plan.arguments.contains("--sandbox") == false)
        #expect(plan.arguments.contains("danger-full-access") == false)
        #expect(plan.arguments.contains("--dangerously-bypass-approvals-and-sandbox"))
        #expect(plan.arguments.contains("--ask-for-approval") == false)
    }

    @Test("Codex policy render records provider sandbox limitations")
    func codexPolicyRenderRecordsProviderSandboxLimitations() {
        let render = CodexPolicyAdapter().render(
            policy: .preset(.review),
            context: PolicyRenderContext(
                runtimeID: .codexCLI,
                model: "gpt-5.5",
                workspacePath: "/tmp/workspace",
                additionalPaths: [],
                requestedAllowedTools: ["Read", "Bash"],
                localToolCommands: [],
                environmentKeyNames: [],
                credentialLabels: [],
                providerFeatures: CodexPolicyAdapter().supportedFeatures
            )
        )

        #expect(render.providerID == AgentRuntimeID.codexCLI)
        #expect(render.generatedConfigPreview.contains("--sandbox workspace-write"))
        #expect(render.generatedConfigPreview.contains(#"approval_policy="never""#))
        #expect(render.generatedConfigPreview.contains("--ask-for-approval") == false)
        #expect(render.diagnostics.contains { $0.id == "codex_cli.fine-grained-provider-native-gap" })
        #expect(render.usesBroadProviderPermissions == false)
    }

    @Test("Codex locked policy render uses read-only provider mode")
    func codexLockedPolicyRenderUsesReadOnlyProviderMode() {
        let render = CodexPolicyAdapter().render(
            policy: .preset(.locked),
            context: PolicyRenderContext(
                runtimeID: .codexCLI,
                model: "gpt-5.5",
                workspacePath: "/tmp/workspace",
                additionalPaths: [],
                requestedAllowedTools: ["Read", "Bash"],
                localToolCommands: [],
                environmentKeyNames: [],
                credentialLabels: [],
                providerFeatures: CodexPolicyAdapter().supportedFeatures
            )
        )

        #expect(render.policyLevel == .locked)
        #expect(render.permissionMode == .readOnly)
        #expect(render.generatedConfigPreview.contains("--sandbox read-only"))
        #expect(render.generatedConfigPreview.contains("--sandbox workspace-write") == false)
        #expect(render.codexLaunchPermissionArguments(resumingNativeSession: true).contains("sandbox_mode=\"read-only\""))
    }

    @Test("Provider permission mode decodes legacy strings fail closed")
    func providerPermissionModeDecodesLegacyStringsFailClosed() throws {
        let known = try JSONDecoder().decode(
            ProviderPermissionMode.self,
            from: Data(#""restricted""#.utf8)
        )
        let readOnly = try JSONDecoder().decode(
            ProviderPermissionMode.self,
            from: Data(#""readOnly""#.utf8)
        )
        let unknown = try JSONDecoder().decode(
            ProviderPermissionMode.self,
            from: Data(#""future-provider-mode""#.utf8)
        )

        #expect(known == .restricted)
        #expect(readOnly == .readOnly)
        #expect(unknown == .restricted)
    }
}

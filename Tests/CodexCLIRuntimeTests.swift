import Foundation
import Testing
@testable import ASTRA
import ASTRACore

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

    @Test("Codex turn completed usage maps to stats")
    func codexTurnCompletedUsageMapsToStats() {
        let line = #"{"type":"turn.completed","usage":{"input_tokens":12,"cached_input_tokens":4,"output_tokens":5,"reasoning_output_tokens":3}}"#
        let parsed = CodexCLIRuntime.parseEvents(line: line, parsesJSONLines: true)
        let agentEvents = CodexCLIRuntime.parseAgentEvents(line: line, parsesJSONLines: true)

        if case .result(let text, _, let input, let output, _, _, let isError) = parsed.first {
            #expect(text == nil)
            #expect(input == 12)
            #expect(output == 5)
            #expect(isError == false)
        } else {
            Issue.record("Expected usage result event")
        }

        if case .stats(let input, let output, _, _, _) = agentEvents.first {
            #expect(input == 12)
            #expect(output == 5)
        } else {
            Issue.record("Expected stats agent event")
        }
    }

    @Test("Codex adapter requires visible result on successful run")
    func codexAdapterRequiresVisibleResultOnSuccessfulRun() {
        let adapter = CodexCLIRuntimeAdapter()

        #expect(adapter.requiresVisibleResultForSuccessfulRun(phase: "run"))
    }

    @Test("Codex exec command uses JSON output, workspace root, model, and restricted policy")
    func codexExecCommandUsesJSONWorkspaceModelRestrictedPolicyAndAutomationIsolation() {
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
            includeAstraToolsPath: true
        )

        #expect(plan.executablePath == "/opt/codex")
        #expect(plan.arguments.starts(with: [
            "exec",
            "--json",
            "--color", "never"
        ]))
        #expect(plan.arguments.contains("--model"))
        #expect(plan.arguments.contains("gpt-5.5"))
        #expect(plan.arguments.contains("--cd"))
        #expect(plan.arguments.contains("/tmp/workspace"))
        #expect(plan.arguments.contains("--add-dir"))
        #expect(plan.arguments.contains("/tmp/extra"))
        #expect(plan.arguments.contains("--sandbox"))
        #expect(plan.arguments.contains("workspace-write"))
        #expect(plan.arguments.contains("--ask-for-approval") == false)
        #expect(plan.arguments.contains("--skip-git-repo-check"))
        #expect(plan.arguments.contains("--ignore-user-config"))
        #expect(plan.arguments.contains("--ignore-rules"))
        #expect(plan.arguments.contains("--ephemeral"))
        #expect(plan.arguments.last == "Summarize the repo")
        #expect(plan.environment["CODEX_HOME"] == "/tmp/codex-home")
        #expect(plan.environment["NO_COLOR"] == "1")
        #expect(plan.environment["ASTRA_TASK_ID"] == "task-1")
        #expect(plan.parsesJSONLines)
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
            taskEnvironment: [:]
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
        #expect(render.generatedConfigPreview.contains("--ask-for-approval") == false)
        #expect(render.diagnostics.contains { $0.id == "codex_cli.fine-grained-provider-native-gap" })
        #expect(render.usesBroadProviderPermissions == false)
    }
}

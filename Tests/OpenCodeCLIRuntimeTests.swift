import Foundation
import Testing
@testable import ASTRA
import ASTRACore

@Suite("OpenCode CLI Runtime")
struct OpenCodeCLIRuntimeTests {
    @Test("OpenCode model suggestions match provider-qualified defaults")
    func openCodeModelSuggestionsMatchProviderQualifiedDefaults() {
        #expect(OpenCodeCLIRuntime.availableModelNames() == [
            "opencode/big-pickle",
            "opencode/deepseek-v4-flash-free",
            "opencode/mimo-v2.5-free",
            "opencode/minimax-m3-free",
            "opencode/nemotron-3-ultra-free"
        ])
        #expect(OpenCodeCLIRuntime.defaultModelName() == "opencode/big-pickle")
    }

    @Test("OpenCode parses configured model list from CLI output")
    func openCodeParsesConfiguredModelListFromCLIOutput() {
        let output = """
        opencode/big-pickle
        opencode/deepseek-v4-flash-free

        opencode/mimo-v2.5-free
        """

        #expect(OpenCodeCLIRuntime.parseModelNames(output) == [
            "opencode/big-pickle",
            "opencode/deepseek-v4-flash-free",
            "opencode/mimo-v2.5-free"
        ])
    }

    @Test("OpenCode run command uses JSON format, workspace directory, model, and restricted permissions")
    func openCodeRunCommandUsesJSONFormatWorkspaceModelAndRestrictedPermissions() throws {
        let plan = OpenCodeCLIRuntime.buildCommand(
            executablePath: "/opt/opencode",
            prompt: "Summarize the repo",
            model: "opencode/big-pickle",
            workspacePath: "/tmp/workspace",
            additionalPaths: ["/tmp/workspace", "/tmp/extra"],
            permissionPolicy: .restricted,
            timeoutSeconds: 60,
            taskEnvironment: ["ASTRA_TASK_ID": "task-1"],
            pathPrefix: ["/tmp/tools"],
            includeAstraToolsPath: true
        )

        #expect(plan.executablePath == "/opt/opencode")
        #expect(plan.arguments.starts(with: ["run", "--format", "json"]))
        let dirIndex = try #require(plan.arguments.firstIndex(of: "--dir"))
        #expect(plan.arguments[dirIndex + 1] == "/tmp/workspace")
        let modelIndex = try #require(plan.arguments.firstIndex(of: "--model"))
        #expect(plan.arguments[modelIndex + 1] == "opencode/big-pickle")
        #expect(plan.arguments.contains("--dangerously-skip-permissions") == false)
        #expect(plan.arguments.last == "Summarize the repo")
        #expect(plan.environment["NO_COLOR"] == "1")
        #expect(plan.environment["ASTRA_TASK_ID"] == "task-1")
        #expect(plan.parsesJSONLines)
    }

    @Test("OpenCode launch directory prefers git-backed additional path")
    func openCodeLaunchDirectoryPrefersGitBackedAdditionalPath() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-opencode-launch-\(UUID().uuidString)", isDirectory: true)
        let durableWorkspace = root.appendingPathComponent("Astra Dev Workspace", isDirectory: true)
        let codeRepository = root.appendingPathComponent("repo", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: durableWorkspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: codeRepository.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )

        let plan = OpenCodeCLIRuntime.buildCommand(
            executablePath: "/opt/opencode",
            prompt: "Summarize the repo",
            model: "opencode/big-pickle",
            workspacePath: durableWorkspace.path,
            additionalPaths: [codeRepository.path],
            permissionPolicy: .restricted,
            timeoutSeconds: 60,
            taskEnvironment: [:]
        )

        let dirIndex = try #require(plan.arguments.firstIndex(of: "--dir"))
        #expect(plan.arguments[dirIndex + 1] == codeRepository.path)
    }

    @Test("OpenCode launch directory keeps git-backed workspace path")
    func openCodeLaunchDirectoryKeepsGitBackedWorkspacePath() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-opencode-primary-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("repo", isDirectory: true)
        let otherRepository = root.appendingPathComponent("other", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(
            at: workspace.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: otherRepository.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )

        let plan = OpenCodeCLIRuntime.buildCommand(
            executablePath: "/opt/opencode",
            prompt: "Summarize the repo",
            model: "opencode/big-pickle",
            workspacePath: workspace.path,
            additionalPaths: [otherRepository.path],
            permissionPolicy: .restricted,
            timeoutSeconds: 60,
            taskEnvironment: [:]
        )

        let dirIndex = try #require(plan.arguments.firstIndex(of: "--dir"))
        #expect(plan.arguments[dirIndex + 1] == workspace.path)
    }

    @Test("OpenCode autonomous policy skips provider permissions")
    func openCodeAutonomousPolicySkipsProviderPermissions() {
        let args = OpenCodeCLIRuntime.permissionArguments(policy: .autonomous)

        #expect(args == ["--dangerously-skip-permissions"])
    }

    @Test("OpenCode JSON stream parser records text and session start")
    func openCodeJSONStreamParserRecordsTextAndSessionStart() {
        let startLine = #"{"type":"session","sessionID":"session-123","model":"opencode/big-pickle"}"#
        let textLine = #"{"type":"text","sessionID":"session-123","part":{"type":"text","text":"I am OpenCode.","time":{"end":123}}}"#

        let startParsed = OpenCodeCLIRuntime.parseEvents(line: startLine, parsesJSONLines: true)
        let textParsed = OpenCodeCLIRuntime.parseEvents(line: textLine, parsesJSONLines: true)
        let startAgentEvents = OpenCodeCLIRuntime.parseAgentEvents(line: startLine, parsesJSONLines: true)

        if case .systemInit(let model, let sessionID) = startParsed.first {
            #expect(model == "opencode/big-pickle")
            #expect(sessionID == "session-123")
        } else {
            Issue.record("Expected system init event")
        }

        if case .text(let text) = textParsed.first {
            #expect(text == "I am OpenCode.")
        } else {
            Issue.record("Expected text event")
        }

        if case .started(let sessionID, let model) = startAgentEvents.first {
            #expect(sessionID == "session-123")
            #expect(model == "opencode/big-pickle")
        } else {
            Issue.record("Expected started agent event")
        }
    }

    @Test("OpenCode JSON stream parser records reasoning and tool use")
    func openCodeJSONStreamParserRecordsReasoningAndToolUse() {
        let reasoningLine = #"{"type":"reasoning","sessionID":"session-123","part":{"type":"reasoning","text":"Inspecting.","time":{"end":123}}}"#
        let toolLine = #"{"type":"tool_use","sessionID":"session-123","part":{"id":"tool-1","type":"tool","tool":"bash","state":{"status":"completed","input":{"command":"git status"},"output":"clean"}}}"#

        let reasoningEvents = OpenCodeCLIRuntime.parseAgentEvents(line: reasoningLine, parsesJSONLines: true)
        let toolEvents = OpenCodeCLIRuntime.parseAgentEvents(line: toolLine, parsesJSONLines: true)

        if case .thinking(let text) = reasoningEvents.first {
            #expect(text == "Inspecting.")
        } else {
            Issue.record("Expected thinking agent event")
        }

        #expect(toolEvents.contains { event in
            if case .toolUse(let name, let id, let inputSummary) = event {
                return name == "bash" && id == "tool-1" && inputSummary?.contains("git status") == true
            }
            return false
        })
        #expect(toolEvents.contains { event in
            if case .toolResult(let id, let content) = event {
                return id == "tool-1" && content == "clean"
            }
            return false
        })
    }

    @Test("OpenCode stream parser surfaces non JSON output as text")
    func openCodeStreamParserSurfacesNonJSONOutputAsText() {
        let line = "warning: OpenCode needs attention"
        let parsed = OpenCodeCLIRuntime.parseEvents(line: line, parsesJSONLines: true)
        let agentEvents = OpenCodeCLIRuntime.parseAgentEvents(line: line, parsesJSONLines: true)

        if case .text(let text) = parsed.first {
            #expect(text == line)
        } else {
            Issue.record("Expected text event")
        }

        if case .text(let text) = agentEvents.first {
            #expect(text == line)
        } else {
            Issue.record("Expected text agent event")
        }
    }

    @Test("OpenCode stream parser preserves raw payload for unknown JSON events")
    func openCodeStreamParserPreservesRawPayloadForUnknownJSONEvents() {
        let line = #"{"type":"opencode.future_event","payload":{"value":42}}"#
        let agentEvents = OpenCodeCLIRuntime.parseAgentEvents(line: line, parsesJSONLines: true)

        if case .unknown(let provider, let type, let raw) = agentEvents.first {
            #expect(provider == "opencode")
            #expect(type == "opencode.future_event")
            #expect(raw == line)
        } else {
            Issue.record("Expected unknown agent event")
        }
    }

    @Test("OpenCode blocking diagnostics are detected in JSON mode")
    func openCodeBlockingDiagnosticsAreDetectedInJSONMode() {
        let message = OpenCodeCLIRuntime.blockingMessage(
            line: "Error: authentication required. Run opencode auth login.",
            parsesJSONLines: true
        )

        #expect(message?.contains("opencode auth login") == true)
    }

    @Test("OpenCode policy render records provider permission limitations")
    func openCodePolicyRenderRecordsProviderPermissionLimitations() {
        let render = OpenCodePolicyAdapter().render(
            policy: .preset(.review),
            context: PolicyRenderContext(
                runtimeID: .openCodeCLI,
                model: "opencode/big-pickle",
                workspacePath: "/tmp/workspace",
                additionalPaths: [],
                requestedAllowedTools: ["Read", "Bash"],
                localToolCommands: [],
                environmentKeyNames: [],
                credentialLabels: [],
                providerFeatures: OpenCodePolicyAdapter().supportedFeatures
            )
        )

        #expect(render.providerID == AgentRuntimeID.openCodeCLI)
        #expect(render.allowedTools.contains("Read"))
        #expect(render.generatedConfigPreview.contains("--dangerously-skip-permissions") == false)
        #expect(render.diagnostics.contains { $0.id == "opencode_cli.fine-grained-provider-native-gap" })
        #expect(render.usesBroadProviderPermissions == false)
    }

    @Test("OpenCode approved shell grants are visible to ASTRA broker")
    func openCodeApprovedShellGrantsAreVisibleToAstraBroker() {
        let grants = [
            PermissionGrant.shellCommand(executable: "gh", pattern: "pr list *")
        ]

        #expect(OpenCodePolicyAdapter().providerGrantStrings(for: grants) == ["shell(gh:pr list *)"])
        #expect(OpenCodePolicyAdapter().providerRuntimeGrantStrings(for: grants).contains("shell(gh:pr list *)"))
    }
}

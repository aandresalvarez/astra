import Foundation
import Testing
@testable import ASTRA
import ASTRACore

@Suite("Cursor CLI Runtime")
struct CursorCLIRuntimeTests {
    @Test("Cursor model suggestions match installed CLI defaults")
    func cursorModelSuggestionsMatchInstalledCLIDefaults() {
        #expect(CursorCLIRuntime.availableModelNames() == [
            "composer-2.5-fast",
            "composer-2.5",
            "gpt-5.5-medium",
            "gpt-5.5-high",
            "gpt-5.4-medium",
            "gpt-5.4-mini-medium",
            "gpt-5.3-codex",
            "claude-4-sonnet"
        ])
        #expect(CursorCLIRuntime.defaultModelName() == "composer-2.5-fast")
    }

    @Test("Cursor model list parser extracts model IDs")
    func cursorModelListParserExtractsModelIDs() {
        let output = """
        Available models

        auto - Auto
        composer-2.5-fast - Composer 2.5 Fast (default)
        gpt-5.5-medium - GPT-5.5 Fast

        Tip: use --model <id> to switch.
        """

        #expect(CursorCLIRuntime.parseModelNames(output) == [
            "auto",
            "composer-2.5-fast",
            "gpt-5.5-medium"
        ])
    }

    @Test("Cursor print command uses stream JSON, workspace, model, trust, and restricted sandbox")
    func cursorPrintCommandUsesStreamJSONWorkspaceModelTrustAndRestrictedSandbox() throws {
        let plan = CursorCLIRuntime.buildCommand(
            executablePath: "/opt/cursor-agent",
            prompt: "Summarize the repo",
            model: "composer-2.5-fast",
            workspacePath: "/tmp/workspace",
            additionalPaths: ["/tmp/workspace", "/tmp/extra"],
            permissionPolicy: .restricted,
            timeoutSeconds: 60,
            taskEnvironment: ["ASTRA_TASK_ID": "task-1"],
            pathPrefix: ["/tmp/tools"],
            includeAstraToolsPath: true
        )

        #expect(plan.executablePath == "/opt/cursor-agent")
        #expect(plan.arguments.starts(with: [
            "--print",
            "--output-format", "stream-json",
            "--trust"
        ]))
        let workspaceIndex = try #require(plan.arguments.firstIndex(of: "--workspace"))
        #expect(plan.arguments[workspaceIndex + 1] == "/tmp/workspace")
        let modelIndex = try #require(plan.arguments.firstIndex(of: "--model"))
        #expect(plan.arguments[modelIndex + 1] == "composer-2.5-fast")
        let sandboxIndex = try #require(plan.arguments.firstIndex(of: "--sandbox"))
        #expect(plan.arguments[sandboxIndex + 1] == "enabled")
        #expect(plan.arguments.contains("--force") == false)
        #expect(plan.arguments.contains("--mode") == false)
        #expect(plan.arguments.contains("--stream-partial-output") == false)
        #expect(plan.arguments.last == "Summarize the repo")
        #expect(plan.environment["NO_COLOR"] == "1")
        #expect(plan.environment["ASTRA_TASK_ID"] == "task-1")
        #expect(plan.parsesJSONLines)
    }

    @Test("Cursor interactive policy uses ask mode and sandbox")
    func cursorInteractivePolicyUsesAskModeAndSandbox() throws {
        let plan = CursorCLIRuntime.buildCommand(
            executablePath: "/opt/cursor-agent",
            prompt: "Explain only",
            model: "default",
            workspacePath: "/tmp/workspace",
            additionalPaths: [],
            permissionPolicy: .interactive,
            timeoutSeconds: 60,
            taskEnvironment: [:]
        )

        let modeIndex = try #require(plan.arguments.firstIndex(of: "--mode"))
        #expect(plan.arguments[modeIndex + 1] == "ask")
        let sandboxIndex = try #require(plan.arguments.firstIndex(of: "--sandbox"))
        #expect(plan.arguments[sandboxIndex + 1] == "enabled")
        #expect(plan.arguments.contains("--force") == false)
        #expect(plan.arguments.contains("--model"))
        #expect(plan.arguments.contains(CursorCLIRuntime.defaultModelName()))
    }

    @Test("Cursor autonomous policy grants force and disables sandbox")
    func cursorAutonomousPolicyGrantsForceAndDisablesSandbox() throws {
        let plan = CursorCLIRuntime.buildCommand(
            executablePath: "/opt/cursor-agent",
            prompt: "Implement the plan",
            model: "composer-2.5-fast",
            workspacePath: "/tmp/workspace",
            additionalPaths: [],
            permissionPolicy: .autonomous,
            timeoutSeconds: 60,
            taskEnvironment: [:]
        )

        let sandboxIndex = try #require(plan.arguments.firstIndex(of: "--sandbox"))
        #expect(plan.arguments[sandboxIndex + 1] == "disabled")
        #expect(plan.arguments.contains("--force"))
        #expect(plan.arguments.contains("--mode") == false)
    }

    @Test("Cursor stream parser records system start and assistant text")
    func cursorStreamParserRecordsSystemStartAndAssistantText() {
        let startLine = #"{"type":"system","subtype":"init","session_id":"chat-123","model":"composer-2.5-fast"}"#
        let textLine = #"{"type":"assistant","message":{"content":[{"type":"text","text":"I am Cursor."}]}}"#

        let startParsed = CursorCLIRuntime.parseEvents(line: startLine, parsesJSONLines: true)
        let textParsed = CursorCLIRuntime.parseEvents(line: textLine, parsesJSONLines: true)
        let startAgentEvents = CursorCLIRuntime.parseAgentEvents(line: startLine, parsesJSONLines: true)

        if case .systemInit(let model, let sessionId) = startParsed.first {
            #expect(model == "composer-2.5-fast")
            #expect(sessionId == "chat-123")
        } else {
            Issue.record("Expected system init event")
        }

        if case .text(let text) = textParsed.first {
            #expect(text == "I am Cursor.")
        } else {
            Issue.record("Expected text event")
        }

        if case .started(let sessionID, let model) = startAgentEvents.first {
            #expect(sessionID == "chat-123")
            #expect(model == "composer-2.5-fast")
        } else {
            Issue.record("Expected started agent event")
        }
    }

    @Test("Cursor stream parser records top level thinking deltas")
    func cursorStreamParserRecordsTopLevelThinkingDeltas() {
        let line = #"{"type":"thinking","subtype":"delta","text":"Inspecting the request.","session_id":"chat-123"}"#
        let parsed = CursorCLIRuntime.parseEvents(line: line, parsesJSONLines: true)
        let agentEvents = CursorCLIRuntime.parseAgentEvents(line: line, parsesJSONLines: true)

        if case .thinking(let text) = parsed.first {
            #expect(text == "Inspecting the request.")
        } else {
            Issue.record("Expected thinking event")
        }

        if case .thinking(let text) = agentEvents.first {
            #expect(text == "Inspecting the request.")
        } else {
            Issue.record("Expected thinking agent event")
        }
    }

    @Test("Cursor stream parser surfaces non JSON output as text")
    func cursorStreamParserSurfacesNonJSONOutputAsText() {
        let line = "warning: Cursor CLI needs attention"
        let parsed = CursorCLIRuntime.parseEvents(line: line, parsesJSONLines: true)
        let agentEvents = CursorCLIRuntime.parseAgentEvents(line: line, parsesJSONLines: true)

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

    @Test("Cursor stream parser preserves raw payload for unknown JSON events")
    func cursorStreamParserPreservesRawPayloadForUnknownJSONEvents() {
        let line = #"{"type":"cursor.future_event","payload":{"value":42}}"#
        let agentEvents = CursorCLIRuntime.parseAgentEvents(line: line, parsesJSONLines: true)

        if case .unknown(let provider, let type, let raw) = agentEvents.first {
            #expect(provider == "cursor")
            #expect(type == "cursor.future_event")
            #expect(raw == line)
        } else {
            Issue.record("Expected unknown agent event")
        }
    }

    @Test("Cursor result event preserves completion and usage")
    func cursorResultEventPreservesCompletionAndUsage() {
        let line = #"{"type":"result","subtype":"success","is_error":false,"result":"Done.","duration_ms":1200,"num_turns":1,"total_cost_usd":0.04,"usage":{"input_tokens":12,"cache_read_input_tokens":4,"cache_creation_input_tokens":2,"output_tokens":5}}"#
        let parsed = CursorCLIRuntime.parseEvents(line: line, parsesJSONLines: true)
        let agentEvents = CursorCLIRuntime.parseAgentEvents(line: line, parsesJSONLines: true)

        if case .result(let text, let cost, let input, let output, let duration, let turns, let isError) = parsed.first {
            #expect(text == "Done.")
            #expect(cost == 0.04)
            #expect(input == 18)
            #expect(output == 5)
            #expect(duration == 1200)
            #expect(turns == 1)
            #expect(isError == false)
        } else {
            Issue.record("Expected result event")
        }

        #expect(agentEvents.contains { event in
            if case .completed(let summary) = event {
                return summary == "Done."
            }
            return false
        })
        #expect(agentEvents.contains { event in
            if case .stats(let input, let output, let cost, let duration, let turns) = event {
                return input == 18 && output == 5 && cost == 0.04 && duration == 1200 && turns == 1
            }
            return false
        })
    }

    @Test("Cursor result event counts camel case usage tokens")
    func cursorResultEventCountsCamelCaseUsageTokens() {
        let line = #"{"type":"result","subtype":"success","is_error":false,"result":"Done.","usage":{"inputTokens":12,"outputTokens":5,"cacheReadTokens":4,"cacheWriteTokens":2}}"#
        let parsed = CursorCLIRuntime.parseEvents(line: line, parsesJSONLines: true)
        let agentEvents = CursorCLIRuntime.parseAgentEvents(line: line, parsesJSONLines: true)

        if case .result(_, _, let input, let output, _, _, _) = parsed.first {
            #expect(input == 18)
            #expect(output == 5)
        } else {
            Issue.record("Expected result event")
        }

        #expect(agentEvents.contains { event in
            if case .stats(let input, let output, _, _, _) = event {
                return input == 18 && output == 5
            }
            return false
        })
    }

    @Test("Cursor policy render records provider sandbox limitations")
    func cursorPolicyRenderRecordsProviderSandboxLimitations() {
        let render = CursorPolicyAdapter().render(
            policy: .preset(.review),
            context: PolicyRenderContext(
                runtimeID: .cursorCLI,
                model: "composer-2.5-fast",
                workspacePath: "/tmp/workspace",
                additionalPaths: [],
                requestedAllowedTools: ["Read", "Bash"],
                localToolCommands: [],
                environmentKeyNames: [],
                credentialLabels: [],
                providerFeatures: CursorPolicyAdapter().supportedFeatures
            )
        )

        #expect(render.providerID == AgentRuntimeID.cursorCLI)
        #expect(render.generatedConfigPreview.contains("--sandbox enabled"))
        #expect(render.generatedConfigPreview.contains("--force") == false)
        #expect(render.diagnostics.contains { $0.id == "cursor_cli.fine-grained-provider-native-gap" })
        #expect(render.usesBroadProviderPermissions == false)
    }
}

import Foundation
import Testing
import SwiftData
@testable import ASTRA
import ASTRACore

@Suite("Copilot Stream Event Parser")
struct CopilotStreamEventParserTests {
    @Test("Plain text output maps to text event")
    func plainText() {
        let parsed = CopilotStreamEventParser.parse(line: "hello from copilot")
        if case .text(let text) = parsed {
            #expect(text == "hello from copilot")
        } else {
            Issue.record("Expected text event")
        }
    }

    @Test("Agent message chunk maps to text")
    func agentMessageChunk() {
        let line = #"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"chunk"}}"#
        let parsed = CopilotStreamEventParser.parse(line: line)
        if case .text(let text) = parsed {
            #expect(text == "chunk")
        } else {
            Issue.record("Expected text event")
        }
    }

    @Test("Assistant message delta maps to text")
    func assistantMessageDelta() {
        let line = #"{"type":"assistant.message_delta","delta":{"content":[{"type":"text_delta","text":"hello"}]}}"#
        let parsed = CopilotStreamEventParser.parse(line: line)
        if case .text(let text) = parsed {
            #expect(text == "hello")
        } else {
            Issue.record("Expected text event")
        }
    }

    @Test("Assistant message delta maps Copilot data payload to text")
    func assistantMessageDeltaDataPayload() {
        let line = #"{"type":"assistant.message_delta","data":{"messageId":"msg-1","deltaContent":"Hello"},"id":"evt-1"}"#
        let parsed = CopilotStreamEventParser.parse(line: line)
        if case .text(let text) = parsed {
            #expect(text == "Hello")
        } else {
            Issue.record("Expected text event")
        }
    }

    @Test("Assistant final message maps to completion summary")
    func assistantFinalMessage() {
        let line = #"{"type":"assistant.message","message":{"content":[{"type":"text","text":"final answer"}]}}"#
        let parsed = CopilotStreamEventParser.parseAgentEvents(line: line)
        if case .completed(let summary) = parsed.first {
            #expect(summary == "final answer")
        } else {
            Issue.record("Expected completed event")
        }
    }

    @Test("Assistant final message maps Copilot data payload to completion summary")
    func assistantFinalMessageDataPayload() {
        let line = #"{"type":"assistant.message","data":{"content":"final answer"}}"#
        let parsed = CopilotStreamEventParser.parseAgentEvents(line: line)
        if case .completed(let summary) = parsed.first {
            #expect(summary == "final answer")
        } else {
            Issue.record("Expected completed event")
        }
    }

    @Test("Assistant reasoning delta maps Copilot data payload to thinking")
    func assistantReasoningDeltaDataPayload() {
        let line = #"{"type":"assistant.reasoning_delta","data":{"deltaContent":"checking repository state"}}"#
        let parsed = CopilotStreamEventParser.parseAgentEvents(line: line)
        if case .thinking(let text) = parsed.first {
            #expect(text == "checking repository state")
        } else {
            Issue.record("Expected thinking event")
        }
    }

    @Test("Session event with metadata maps to started")
    func sessionMetadata() {
        let line = #"{"type":"session.mcp_servers_loaded","session":{"id":"sess-1","model":"gpt-5"}}"#
        let parsed = CopilotStreamEventParser.parseAgentEvents(line: line)
        if case .started(let sessionID, let model) = parsed.first {
            #expect(sessionID == "sess-1")
            #expect(model == "gpt-5")
        } else {
            Issue.record("Expected started event")
        }
    }

    @Test("Known control events without content are ignored")
    func knownControlEventsWithoutContent() {
        let lines = [
            #"{"type":"session.mcp_servers_loaded"}"#,
            #"{"type":"user.message"}"#,
            #"{"type":"assistant.turn_start"}"#,
            #"{"type":"assistant.turn_end"}"#,
            #"{"type":"assistant.reasoning_delta"}"#
        ]
        for line in lines {
            #expect(CopilotStreamEventParser.parseAgentEvents(line: line).isEmpty)
        }
    }

    @Test("Tool call maps to tool use")
    func toolCall() {
        let line = #"{"type":"tool_call","tool":"shell","id":"call-1","command":"git status"}"#
        let parsed = CopilotStreamEventParser.parse(line: line)
        if case .toolUse(let name, let id, _) = parsed {
            #expect(name == "shell")
            #expect(id == "call-1")
        } else {
            Issue.record("Expected tool use")
        }
    }

    @Test("Tool call maps Copilot data payload to tool use")
    func toolCallDataPayload() {
        let line = #"{"type":"tool_call","id":"event-1","data":{"toolUseId":"call-1","toolName":"github","input":{"command":"gh pr list"}}}"#
        let parsed = CopilotStreamEventParser.parseAgentEvents(line: line)
        if case .toolUse(let name, let id, let inputSummary) = parsed.first {
            #expect(name == "github")
            #expect(id == "call-1")
            #expect(inputSummary?.contains("gh pr list") == true)
        } else {
            Issue.record("Expected tool use")
        }
    }

    @Test("Tool result maps to tool result")
    func toolResult() {
        let line = #"{"type":"tool_result","toolUseId":"call-1","output":"ok"}"#
        let parsed = CopilotStreamEventParser.parse(line: line)
        if case .toolResult(let id, let content) = parsed {
            #expect(id == "call-1")
            #expect(content == "ok")
        } else {
            Issue.record("Expected tool result")
        }
    }

    @Test("Tool result maps Copilot data payload to tool result")
    func toolResultDataPayload() {
        let line = #"{"type":"tool_result","id":"event-2","data":{"toolUseId":"call-1","output":"ok"}}"#
        let parsed = CopilotStreamEventParser.parseAgentEvents(line: line)
        if case .toolResult(let id, let content) = parsed.first {
            #expect(id == "call-1")
            #expect(content == "ok")
        } else {
            Issue.record("Expected tool result")
        }
    }

    @Test("Permission request maps to permission denied event")
    func permissionRequest() {
        let line = #"{"type":"permission_request","tool":"shell(rm)","message":"approval needed"}"#
        let parsed = CopilotStreamEventParser.parse(line: line)
        if case .permissionDenied(let tool, let reason) = parsed {
            #expect(tool == "shell(rm)")
            #expect(reason == "approval needed")
        } else {
            Issue.record("Expected permission event")
        }
    }

    @Test("Nested permission request extracts tool name from data payload")
    func nestedPermissionRequestToolName() {
        let line = #"{"type":"event","data":{"type":"permission_request","toolName":"Bash","message":"approval needed"}}"#
        let parsed = CopilotStreamEventParser.parse(line: line)
        if case .permissionDenied(let tool, let reason) = parsed {
            #expect(tool == "Bash")
            #expect(reason == "approval needed")
        } else {
            Issue.record("Expected permission event")
        }
    }

    @Test("Permission request infers tool name from text")
    func permissionRequestInfersToolNameFromText() {
        let line = #"{"type":"permission_request","message":"Permission denied: tool Bash is not allowed"}"#
        let parsed = CopilotStreamEventParser.parse(line: line)
        if case .permissionDenied(let tool, _) = parsed {
            #expect(tool == "Bash")
        } else {
            Issue.record("Expected permission event")
        }
    }

    @Test("Plain Copilot approval prompt maps to workspace access permission")
    func plainApprovalPromptMapsToPermission() {
        let line = "Allow access to these paths? (y/n):"
        let parsed = CopilotStreamEventParser.parse(line: line)
        if case .permissionDenied(let tool, let reason) = parsed {
            #expect(tool == "WorkspaceAccess")
            #expect(reason.contains("Allow access"))
            #expect(CopilotStreamEventParser.isBlockingPlainTextPermissionPrompt(line: line))
        } else {
            Issue.record("Expected permission event")
        }
    }

    @Test("Plain Copilot permission denial avoids unknown tool")
    func plainPermissionDeniedAvoidsUnknownTool() {
        let line = "Permission denied and could not request permission from user"
        let parsed = CopilotStreamEventParser.parse(line: line)
        if case .permissionDenied(let tool, let reason) = parsed {
            #expect(tool == "ToolApproval")
            #expect(!tool.isEmpty)
            #expect(tool != "unknown")
            #expect(reason.contains("Permission denied"))
        } else {
            Issue.record("Expected permission event")
        }
    }

    @Test("Usage event maps to result stats")
    func usageStats() {
        let line = #"{"type":"usage","usage":{"input_tokens":120,"output_tokens":30,"cost_usd":0.01},"duration_ms":500,"turns":2}"#
        let parsed = CopilotStreamEventParser.parse(line: line)
        if case .result(_, let cost, let input, let output, let duration, let turns, let isError) = parsed {
            #expect(cost == 0.01)
            #expect(input == 120)
            #expect(output == 30)
            #expect(duration == 500)
            #expect(turns == 2)
            #expect(!isError)
        } else {
            Issue.record("Expected result stats")
        }
    }

    @Test("Usage event maps Copilot data payload to result stats")
    func usageStatsDataPayload() {
        let line = #"{"type":"result","data":{"usage":{"input_tokens":120,"output_tokens":30,"cost_usd":0.01},"duration_ms":500,"turns":2,"summary":"done"}}"#
        let events = CopilotStreamEventParser.parseAll(line: line)
        #expect(events.count == 1)
        if case .result(let text, let cost, let input, let output, let duration, let turns, let isError) = events.first {
            #expect(text == "done")
            #expect(cost == 0.01)
            #expect(input == 120)
            #expect(output == 30)
            #expect(duration == 500)
            #expect(turns == 2)
            #expect(!isError)
        } else {
            Issue.record("Expected result stats")
        }
    }

    @Test("Error event maps Copilot data payload to failure")
    func errorDataPayload() {
        let line = #"{"type":"error","data":{"message":"GitHub authentication failed"}}"#
        let parsed = CopilotStreamEventParser.parse(line: line)
        if case .result(let text, _, _, _, _, _, let isError) = parsed {
            #expect(text == "GitHub authentication failed")
            #expect(isError)
        } else {
            Issue.record("Expected failed result")
        }
    }

    @Test("Result event with usage and summary maps to one result")
    func resultStatsAndSummary() {
        let line = #"{"type":"result","usage":{"input_tokens":12,"output_tokens":4,"cost_usd":0.02},"duration_ms":50,"turns":1,"summary":"done"}"#
        let events = CopilotStreamEventParser.parseAll(line: line)
        #expect(events.count == 1)
        if case .result(let text, let cost, let input, let output, let duration, let turns, let isError) = events.first {
            #expect(text == "done")
            #expect(cost == 0.02)
            #expect(input == 12)
            #expect(output == 4)
            #expect(duration == 50)
            #expect(turns == 1)
            #expect(!isError)
        } else {
            Issue.record("Expected one merged result event")
        }
    }
}

@Suite("Agent Runtime Stream Telemetry")
struct AgentRuntimeStreamTelemetryTests {
    @Test("Telemetry counts parsed, emitted, and unknown Copilot events")
    func countsStreamEvents() {
        let telemetry = AgentRuntimeStreamTelemetry(maxUnknownSamples: 2)

        telemetry.recordRawLine(parsesJSONLines: true)
        telemetry.recordParsed([
            .text(text: "hello"),
            .thinking(text: "thinking"),
            .toolUse(name: "shell", id: "tool-1", inputSummary: nil),
            .toolResult(id: "tool-1", content: "ok"),
            .stats(inputTokens: 10, outputTokens: 5, costUSD: 0.01, durationMs: 100, turns: 1),
            .completed(summary: "done"),
            .failed(message: "failed"),
            .unknown(provider: "copilot", type: "assistant.new_event", raw: #"{"type":"assistant.new_event","payload":"one"}"#),
            .unknown(provider: "copilot", type: "assistant.new_event", raw: #"{"type":"assistant.new_event","payload":"two"}"#),
            .unknown(provider: "copilot", type: "tool.new_event", raw: #"{"type":"tool.new_event"}"#),
            .unknown(provider: "copilot", type: "third.new_event", raw: #"{"type":"third.new_event"}"#)
        ])
        telemetry.recordRawLine(parsesJSONLines: false)
        telemetry.recordParsed([.text(text: "plain")])
        telemetry.recordEmitted([
            .text(text: "hello"),
            .completed(summary: "done")
        ])

        let snapshot = telemetry.snapshot()
        #expect(snapshot.rawLineCount == 2)
        #expect(snapshot.jsonLineCount == 1)
        #expect(snapshot.plainTextLineCount == 1)
        #expect(snapshot.parsedEventCount == 12)
        #expect(snapshot.emittedEventCount == 2)
        #expect(snapshot.textEventCount == 2)
        #expect(snapshot.thinkingEventCount == 1)
        #expect(snapshot.toolUseEventCount == 1)
        #expect(snapshot.toolResultEventCount == 1)
        #expect(snapshot.statsEventCount == 1)
        #expect(snapshot.completedEventCount == 1)
        #expect(snapshot.failedEventCount == 1)
        #expect(snapshot.unknownEventCount == 4)
        #expect(snapshot.unknownTypeCounts["assistant.new_event"] == 2)
        #expect(snapshot.unknownTypeCounts["tool.new_event"] == 1)
        #expect(snapshot.unknownSamples.map { $0.type } == ["assistant.new_event", "tool.new_event"])
        #expect(snapshot.fields["unknown_types"]?.contains("assistant.new_event:2") == true)
    }
}

@Suite("Agent Runtime Stream Debug")
struct AgentRuntimeStreamDebugTests {
    @Test("ASTRA_STREAM_DEBUG enables bounded stream diagnostics")
    func streamDebugFlagParsing() {
        #expect(AgentRuntimeStreamDebugCapture.isEnabled(environment: ["ASTRA_STREAM_DEBUG": "1"]))
        #expect(AgentRuntimeStreamDebugCapture.isEnabled(environment: ["ASTRA_STREAM_DEBUG": "true"]))
        #expect(AgentRuntimeStreamDebugCapture.isEnabled(environment: ["ASTRA_STREAM_DEBUG": "on"]))
        #expect(!AgentRuntimeStreamDebugCapture.isEnabled(environment: [:]))
        #expect(!AgentRuntimeStreamDebugCapture.isEnabled(environment: ["ASTRA_STREAM_DEBUG": "0"]))
        #expect(!AgentRuntimeStreamDebugCapture.isEnabled(environment: ["ASTRA_STREAM_DEBUG": "false"]))
    }

    @Test("Stream debug captures samples, counters, stderr tail, and unknown JSON shape")
    func streamDebugCaptureSnapshot() {
        let capture = AgentRuntimeStreamDebugCapture(
            maxRawSamples: 1,
            maxUnknownJSONShapes: 2,
            maxSampleLength: 200,
            maxStderrTailLength: 24
        )
        let unknownLine = #"{"type":"assistant.new_event","data":{"deltaContent":"hello","extra":true},"id":"evt-1"}"#

        capture.recordLine(unknownLine, parsesJSONLines: true)
        capture.recordParsed([
            .unknown(provider: "copilot", type: "assistant.new_event", raw: unknownLine)
        ], rawLine: unknownLine)
        capture.recordEmitted([AgentEvent]())
        capture.recordStderr("0123456789abcdefghijklmnopqrstuvwxyz")

        let snapshot = capture.snapshot()
        #expect(snapshot.rawLineCount == 1)
        #expect(snapshot.jsonLineCount == 1)
        #expect(snapshot.plainTextLineCount == 0)
        #expect(snapshot.parsedEventCount == 1)
        #expect(snapshot.emittedEventCount == 0)
        #expect(snapshot.rawSamples == [unknownLine])
        #expect(snapshot.stderrTail == "cdefghijklmnopqrstuvwxyz")
        #expect(snapshot.unknownJSONShapes.count == 1)
        #expect(snapshot.unknownJSONShapes[0].contains("type=assistant.new_event"))
        #expect(snapshot.unknownJSONShapes[0].contains("data_keys=deltaContent,extra"))
        #expect(snapshot.fields["unknown_json_shapes"] == "1")
        #expect(snapshot.fields["event_types"]?.contains("unknown:assistant.new_event:1") == true)
    }
}

@Suite("Agent Runtime Failure Diagnostics")
struct AgentRuntimeFailureDiagnosticsTests {
    @Test("Classifies selected model failures without treating the model as statically invalid")
    func classifiesModelUnavailable() {
        let diagnostic = AgentRuntimeFailureDiagnostic.classify(
            runtime: .copilotCLI,
            model: "gpt-5",
            exitCode: 1,
            rawError: "Error: model gpt-5 is not available for this organization",
            providerVersion: "GitHub Copilot CLI 1.0.40",
            stream: nil
        )

        #expect(diagnostic.category == .modelUnavailable)
        #expect(diagnostic.userMessage.contains("could not use model `gpt-5`"))
        #expect(diagnostic.userMessage.contains("organization policy"))
    }

    @Test("Classifies provider configuration errors and redacts sensitive output")
    func classifiesProviderConfigurationAndRedacts() {
        let diagnostic = AgentRuntimeFailureDiagnostic.classify(
            runtime: .copilotCLI,
            model: "gpt-5",
            exitCode: 1,
            rawError: "OPENAI_API_KEY=sk-test-secret failed for person@example.invalid in /Users/example/project: provider endpoint missing",
            providerVersion: "GitHub Copilot CLI 1.0.40",
            stream: nil
        )

        #expect(diagnostic.category == .providerConfigurationInvalid)
        #expect(!diagnostic.redactedSummary.contains("sk-test-secret"))
        #expect(!diagnostic.redactedSummary.contains("person@example.invalid"))
        #expect(!diagnostic.redactedSummary.contains("/Users/example/project"))
        #expect(diagnostic.redactedSummary.contains("[redacted-email]"))
        #expect(diagnostic.redactedSummary.contains("[redacted-path]"))
    }

    @Test("Classifies hidden Copilot approval prompts as permission denied")
    func classifiesHiddenApprovalPrompt() {
        let diagnostic = AgentRuntimeFailureDiagnostic.classify(
            runtime: .copilotCLI,
            model: "gpt-5",
            exitCode: 15,
            rawError: "Copilot is waiting for a permission approval ASTRA cannot answer directly: Allow access to these paths? (y/n):",
            providerVersion: "GitHub Copilot CLI 0.0.342",
            stream: nil
        )

        #expect(diagnostic.category == .permissionDenied)
        #expect(diagnostic.userMessage.contains("approval prompt"))
    }

    @Test("Includes stream counters in failure audit fields")
    func includesStreamCountersInAuditFields() {
        let telemetry = AgentRuntimeStreamTelemetry()
        telemetry.recordRawLine(parsesJSONLines: true)
        telemetry.recordParsed([])
        let snapshot = telemetry.snapshot()
        let diagnostic = AgentRuntimeFailureDiagnostic.classify(
            runtime: .copilotCLI,
            model: "gpt-5",
            exitCode: 1,
            rawError: nil,
            providerVersion: "GitHub Copilot CLI 1.0.40",
            stream: snapshot
        )

        let fields = diagnostic.auditFields(phase: "run", stream: snapshot)
        #expect(diagnostic.category == .noVisibleOutput)
        #expect(fields["runtime"] == AgentRuntimeID.copilotCLI.rawValue)
        #expect(fields["model"] == "gpt-5")
        #expect(fields["raw_lines"] == "1")
        #expect(fields["json_lines"] == "1")
        #expect(fields["parsed_events"] == "0")
        #expect(fields["failure_category"] == AgentRuntimeFailureCategory.noVisibleOutput.rawValue)
    }
}

@Suite("Copilot CLI Command Planning")
struct CopilotCLICommandPlanningTests {
    @Test("Newer CLI capabilities use JSONL streaming flags")
    func modernCapabilities() {
        let help = "--output-format=FORMAT --stream=MODE --no-ask-user --secret-env-vars=VAR -s, --silent"
        let capabilities = CopilotCLICapabilities(helpText: help)
        let plan = CopilotCLIRuntime.buildCommand(
            executablePath: "/bin/copilot",
            prompt: "Do work",
            model: "gpt-5",
            workspacePath: "/tmp/ws",
            additionalPaths: ["/tmp/ws", "/tmp/other"],
            permissionPolicy: .autonomous,
            allowedTools: [],
            timeoutSeconds: 60,
            capabilities: capabilities,
            taskEnvironment: ["TOKEN": "secret"],
            copilotHome: "/tmp/copilot-home"
        )

        #expect(plan.parsesJSONLines)
        #expect(plan.arguments.contains("--output-format=json"))
        #expect(plan.arguments.contains("--stream=on"))
        #expect(plan.arguments.contains("--no-ask-user"))
        #expect(plan.arguments.contains("--add-dir"))
        #expect(plan.environment["COPILOT_HOME"] == "/tmp/copilot-home")
        #expect(plan.environment["TOKEN"] == "secret")
    }

    @Test("Older CLI capabilities fall back to allow-all prompt mode")
    func legacyCapabilities() {
        let help = "--allow-all-tools Allow all tools; required for non-interactive mode"
        let capabilities = CopilotCLICapabilities(helpText: help)
        let plan = CopilotCLIRuntime.buildCommand(
            executablePath: "/bin/copilot",
            prompt: "Do work",
            model: "gpt-5",
            workspacePath: "/tmp/ws",
            additionalPaths: [],
            permissionPolicy: .autonomous,
            allowedTools: [],
            timeoutSeconds: 60,
            capabilities: capabilities,
            taskEnvironment: [:],
            copilotHome: "/tmp/copilot-home"
        )

        #expect(!plan.parsesJSONLines)
        #expect(plan.arguments.contains("--allow-all-tools"))
        #expect(!plan.arguments.contains("--allow-all-paths"))
        #expect(!plan.arguments.contains("--output-format=json"))
    }

    @Test("Autonomous mode uses allow-all when the CLI supports it")
    func autonomousUsesAllowAllWhenSupported() {
        let help = "--output-format=FORMAT --stream=MODE --no-ask-user --allow-all-tools"
        let capabilities = CopilotCLICapabilities(helpText: help)
        let plan = CopilotCLIRuntime.buildCommand(
            executablePath: "/bin/copilot",
            prompt: "Do work",
            model: "gpt-5",
            workspacePath: "/tmp/ws",
            additionalPaths: [],
            permissionPolicy: .autonomous,
            allowedTools: [],
            timeoutSeconds: 60,
            capabilities: capabilities,
            taskEnvironment: [:],
            copilotHome: "/tmp/copilot-home"
        )

        #expect(plan.arguments.contains("--allow-all-tools"))
        #expect(!plan.arguments.contains("--allow-tool"))
    }

    @Test("Restricted permissions map common Claude tools")
    func restrictedPermissions() {
        let args = CopilotCLIRuntime.copilotPermissionArguments(
            policy: .restricted,
            allowedTools: ["Read", "Bash", "Edit"],
            localToolCommands: ["stanford-graph-mail", "astra-browser"],
            requiresAllowAllToolsForPrompt: false
        )
        let joined = args.joined(separator: " ")
        #expect(args.first == "--allow-tool")
        #expect(!args.contains { $0.contains(",") })
        #expect(joined.contains("read"))
        #expect(joined.contains("write"))
        #expect(joined.contains("shell(git:*)"))
        #expect(joined.contains("shell(astra-browser:*)"))
        #expect(joined.contains("shell(stanford-graph-mail:*)"))
    }

    @Test("Local CLI commands map to Copilot shell permissions")
    func localToolPermissions() {
        let permissions = CopilotCLIRuntime.copilotShellPermissions(forLocalToolCommands: [
            "stanford-graph-mail",
            " /opt/homebrew/bin/gh ",
            "bad)tool",
            ""
        ])

        #expect(permissions.contains("shell(stanford-graph-mail:*)"))
        #expect(permissions.contains("shell(/opt/homebrew/bin/gh:*)"))
        #expect(!permissions.contains { $0.contains("bad)tool") })
    }
}

@Suite("Agent Runtime Persistence")
struct AgentRuntimePersistenceTests {
    @Test("Task and run persist selected runtime")
    func taskRunRuntime() {
        let task = AgentTask(title: "T", goal: "G", model: "gpt-5")
        task.runtimeID = AgentRuntimeID.copilotCLI.rawValue
        let run = TaskRun(task: task)
        #expect(task.resolvedRuntimeID == .copilotCLI)
        #expect(run.runtimeID == AgentRuntimeID.copilotCLI.rawValue)
    }

    @Test("Copilot prerequisite is declared")
    func prerequisite() {
        let prereq = CommonCLIPrerequisites.copilot
        #expect(prereq.binary == "copilot")
        #expect(prereq.displayName.contains("Copilot"))
        #expect(prereq.authHint != nil)
    }
}

@Suite("Copilot Worker Execution")
@MainActor
struct CopilotWorkerExecutionTests {
    @Test("Worker executes fake Copilot runtime and records output, stats, and files")
    func fakeCopilotExecution() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-copilot-worker-\(UUID().uuidString)", isDirectory: true)
        let workspaceURL = root.appendingPathComponent("workspace", isDirectory: true)
        let binURL = root.appendingPathComponent("copilot")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        if [ "$1" = "help" ]; then
          echo "--output-format=FORMAT --stream=MODE --no-ask-user --secret-env-vars=VAR"
          exit 0
        fi
        if [ "$1" = "--version" ] || [ "$1" = "version" ]; then
          echo "copilot fake 1.0"
          exit 0
        fi
        printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hello from fake copilot"}}'
        printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":3},"duration_ms":10,"turns":1}'
        printf 'changed\\n' > copilot-output.txt
        exit 0
        """
        try script.write(to: binURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binURL.path)

        let schema = ASTRASchema.current
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
        let context = container.mainContext

        let workspace = Workspace(name: "Copilot", primaryPath: workspaceURL.path)
        context.insert(workspace)
        let task = AgentTask(title: "T", goal: "Write a file", workspace: workspace, tokenBudget: 1000, model: "gpt-5")
        task.runtimeID = AgentRuntimeID.copilotCLI.rawValue
        task.status = .queued
        context.insert(task)
        try context.save()

        let worker = AgentRuntimeWorker()
        worker.copilotPath = binURL.path
        worker.copilotHome = root.appendingPathComponent("copilot-home", isDirectory: true).path
        worker.timeoutSeconds = 30

        await worker.execute(task: task, modelContext: context) { _ in }

        #expect(task.status == .completed)
        let run = try #require(task.runs.first)
        #expect(run.runtimeID == AgentRuntimeID.copilotCLI.rawValue)
        #expect(run.providerVersion == "copilot fake 1.0")
        #expect(run.output.contains("hello from fake copilot"))
        #expect(run.inputTokens == 2)
        #expect(run.outputTokens == 3)
        #expect(FileManager.default.fileExists(atPath: workspaceURL.appendingPathComponent("copilot-output.txt").path))
        #expect(run.fileChanges.contains { $0.path.hasSuffix("copilot-output.txt") })
    }

    @Test("Worker records Copilot data message deltas as visible output")
    func fakeCopilotDataMessageDeltasRecordOutput() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-copilot-data-delta-\(UUID().uuidString)", isDirectory: true)
        let workspaceURL = root.appendingPathComponent("workspace", isDirectory: true)
        let binURL = root.appendingPathComponent("copilot")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        if [ "$1" = "help" ]; then
          echo "--output-format=FORMAT --stream=MODE --no-ask-user --secret-env-vars=VAR"
          exit 0
        fi
        if [ "$1" = "--version" ] || [ "$1" = "version" ]; then
          echo "copilot fake 1.0"
          exit 0
        fi
        printf '%s\\n' '{"type":"assistant.message_delta","data":{"messageId":"msg-1","deltaContent":"Hello"},"id":"evt-1"}'
        printf '%s\\n' '{"type":"assistant.message_delta","data":{"messageId":"msg-1","deltaContent":" from"},"id":"evt-2"}'
        printf '%s\\n' '{"type":"assistant.message_delta","data":{"messageId":"msg-1","deltaContent":" Copilot"},"id":"evt-3"}'
        printf '%s\\n' '{"type":"result","data":{"usage":{"input_tokens":4,"output_tokens":5},"duration_ms":20,"turns":1}}'
        exit 0
        """
        try script.write(to: binURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binURL.path)

        let schema = ASTRASchema.current
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
        let context = container.mainContext

        let workspace = Workspace(name: "Copilot Data Delta", primaryPath: workspaceURL.path)
        context.insert(workspace)
        let task = AgentTask(title: "T", goal: "Say hello", workspace: workspace, tokenBudget: 1000, model: "gpt-5")
        task.runtimeID = AgentRuntimeID.copilotCLI.rawValue
        task.status = .queued
        context.insert(task)
        try context.save()

        let worker = AgentRuntimeWorker()
        worker.copilotPath = binURL.path
        worker.copilotHome = root.appendingPathComponent("copilot-home", isDirectory: true).path
        worker.timeoutSeconds = 30

        await worker.execute(task: task, modelContext: context) { _ in }

        #expect(task.status == .completed)
        let run = try #require(task.runs.first)
        #expect(run.providerVersion == "copilot fake 1.0")
        #expect(run.output == "Hello from Copilot")
        #expect(run.inputTokens == 4)
        #expect(run.outputTokens == 5)
        #expect(task.events.contains { $0.type == "agent.response" && $0.payload == "Hello from Copilot" })
    }

    @Test("Worker records Copilot edits to files that were already dirty")
    func fakeCopilotRecordsAlreadyDirtyFileEdits() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-copilot-dirty-\(UUID().uuidString)", isDirectory: true)
        let workspaceURL = root.appendingPathComponent("workspace", isDirectory: true)
        let binURL = root.appendingPathComponent("copilot")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        try Self.run(["git", "init"], in: workspaceURL)
        try Self.run(["git", "config", "user.email", "astra@example.invalid"], in: workspaceURL)
        try Self.run(["git", "config", "user.name", "ASTRA Tests"], in: workspaceURL)
        try Self.run(["git", "config", "commit.gpgsign", "false"], in: workspaceURL)
        try "clean\n".write(to: workspaceURL.appendingPathComponent("dirty.txt"), atomically: true, encoding: .utf8)
        try Self.run(["git", "add", "dirty.txt"], in: workspaceURL)
        try Self.run(["git", "commit", "-m", "initial"], in: workspaceURL)
        try "dirty before run\n".write(to: workspaceURL.appendingPathComponent("dirty.txt"), atomically: true, encoding: .utf8)

        let script = """
        #!/bin/sh
        if [ "$1" = "help" ]; then
          echo "--output-format=FORMAT --stream=MODE --no-ask-user --secret-env-vars=VAR"
          exit 0
        fi
        if [ "$1" = "--version" ] || [ "$1" = "version" ]; then
          echo "copilot fake 1.0"
          exit 0
        fi
        printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"edited dirty file"}}'
        printf '%s\\n' '{"type":"usage","usage":{"input_tokens":1,"output_tokens":1},"duration_ms":10,"turns":1}'
        printf 'changed during run\\n' >> dirty.txt
        printf 'new during run\\n' > new-file.txt
        exit 0
        """
        try script.write(to: binURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binURL.path)

        let schema = ASTRASchema.current
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
        let context = container.mainContext

        let workspace = Workspace(name: "Copilot Dirty", primaryPath: workspaceURL.path)
        context.insert(workspace)
        let task = AgentTask(title: "T", goal: "Edit files", workspace: workspace, tokenBudget: 1000, model: "gpt-5")
        task.runtimeID = AgentRuntimeID.copilotCLI.rawValue
        task.status = .queued
        context.insert(task)
        try context.save()

        let worker = AgentRuntimeWorker()
        worker.copilotPath = binURL.path
        worker.copilotHome = root.appendingPathComponent("copilot-home", isDirectory: true).path
        worker.timeoutSeconds = 30

        await worker.execute(task: task, modelContext: context) { _ in }

        let run = try #require(task.runs.first)
        #expect(run.fileChanges.contains { $0.path.hasSuffix("dirty.txt") })
        #expect(run.fileChanges.contains { $0.path.hasSuffix("new-file.txt") })
    }

    @Test("Worker surfaces classified Copilot provider failures")
    func fakeCopilotFailureRecordsDiagnostic() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-copilot-failure-\(UUID().uuidString)", isDirectory: true)
        let workspaceURL = root.appendingPathComponent("workspace", isDirectory: true)
        let binURL = root.appendingPathComponent("copilot")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        if [ "$1" = "help" ]; then
          echo "--output-format=FORMAT --stream=MODE --no-ask-user --secret-env-vars=VAR"
          exit 0
        fi
        if [ "$1" = "--version" ] || [ "$1" = "version" ]; then
          echo "copilot fake 1.0"
          exit 0
        fi
        printf '%s\\n' 'Error: model gpt-5 is not available for this organization and OPENAI_API_KEY=sk-test-secret for person@example.invalid' >&2
        exit 1
        """
        try script.write(to: binURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binURL.path)

        let schema = ASTRASchema.current
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
        let context = container.mainContext

        let workspace = Workspace(name: "Copilot Failure", primaryPath: workspaceURL.path)
        context.insert(workspace)
        let task = AgentTask(title: "T", goal: "Use gpt", workspace: workspace, tokenBudget: 1000, model: "gpt-5")
        task.runtimeID = AgentRuntimeID.copilotCLI.rawValue
        task.status = .queued
        context.insert(task)
        try context.save()

        let worker = AgentRuntimeWorker()
        worker.copilotPath = binURL.path
        worker.copilotHome = root.appendingPathComponent("copilot-home", isDirectory: true).path
        worker.timeoutSeconds = 30

        await worker.execute(task: task, modelContext: context) { _ in }

        #expect(task.status == .failed)
        let run = try #require(task.runs.first)
        #expect(run.status == .failed)
        #expect(run.exitCode == 1)
        let errorEvent = try #require(task.events.first { $0.type == "error" })
        #expect(errorEvent.payload.contains("could not use model `gpt-5`"))
        #expect(errorEvent.payload.contains("Provider error:"))
        #expect(!errorEvent.payload.contains("sk-test-secret"))
        #expect(!errorEvent.payload.contains("person@example.invalid"))
    }

    @Test("Approved plan precreates relative task folder before Copilot launch")
    func approvedPlanPrecreatesRelativeTaskFolder() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-copilot-plan-folder-\(UUID().uuidString)", isDirectory: true)
        let workspaceURL = root.appendingPathComponent("workspace", isDirectory: true)
        let binURL = root.appendingPathComponent("copilot")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        if [ "$1" = "help" ]; then
          echo "--output-format=FORMAT --stream=MODE --no-ask-user --secret-env-vars=VAR"
          exit 0
        fi
        if [ "$1" = "--version" ] || [ "$1" = "version" ]; then
          echo "copilot fake 1.0"
          exit 0
        fi
        prompt=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--prompt" ]; then
            shift
            prompt="$1"
          fi
          shift || true
        done
        task_folder="$(printf '%s\\n' "$prompt" | sed -n 's/^Task Output Folder: //p' | head -n 1)"
        if [ -z "$task_folder" ] || [ ! -d "$task_folder" ]; then
          printf 'missing task folder: %s\\n' "$task_folder" >&2
          exit 2
        fi
        printf 'artifact\\n' > "$task_folder/index.html"
        printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"created plan artifact"}}'
        printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":3},"duration_ms":10,"turns":1}'
        exit 0
        """
        try script.write(to: binURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binURL.path)

        let schema = ASTRASchema.current
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
        let context = container.mainContext

        let workspace = Workspace(name: "Copilot Plan", primaryPath: workspaceURL.path)
        context.insert(workspace)
        let task = AgentTask(title: "T", goal: "Execute plan", workspace: workspace, tokenBudget: 1000, model: "gpt-5")
        task.runtimeID = AgentRuntimeID.copilotCLI.rawValue
        task.status = .queued
        context.insert(task)
        try context.save()

        let worker = AgentRuntimeWorker()
        worker.copilotPath = binURL.path
        worker.copilotHome = root.appendingPathComponent("copilot-home", isDirectory: true).path
        worker.timeoutSeconds = 30

        let plan = TaskPlanPayload(
            title: "Write artifact",
            goal: "Create one HTML file",
            steps: [TaskPlanPayloadStep(id: "write", title: "Write HTML", likelyTools: ["Write"])]
        )
        await worker.executeApprovedPlan(task: task, plan: plan, modelContext: context) { _ in }

        #expect(task.status == .completed)
        #expect(FileManager.default.fileExists(atPath: task.taskFolder))
        #expect(FileManager.default.fileExists(atPath: (task.taskFolder as NSString).appendingPathComponent("outputs")))
        #expect(FileManager.default.fileExists(atPath: (task.taskFolder as NSString).appendingPathComponent("index.html")))
    }

    @Test("Worker pauses for approval when Copilot waits for hidden permission prompt")
    func copilotHiddenPermissionPromptPausesForApproval() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-copilot-permission-prompt-\(UUID().uuidString)", isDirectory: true)
        let workspaceURL = root.appendingPathComponent("workspace", isDirectory: true)
        let binURL = root.appendingPathComponent("copilot")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        if [ "$1" = "help" ]; then
          echo "--output-format=FORMAT --stream=MODE --no-ask-user --secret-env-vars=VAR"
          exit 0
        fi
        if [ "$1" = "--version" ] || [ "$1" = "version" ]; then
          echo "copilot fake 1.0"
          exit 0
        fi
        /usr/bin/python3 -u - <<'PY'
        import sys
        import time
        print('The following paths are outside the allowed directories:', flush=True)
        print('  - /Users/example/Documents/Astra\\\\', flush=True)
        print('Allow access to these paths? (y/n):', flush=True)
        time.sleep(20)
        PY
        exit $?
        """
        try script.write(to: binURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binURL.path)

        let schema = ASTRASchema.current
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
        let context = container.mainContext

        let workspace = Workspace(name: "Copilot Prompt", primaryPath: workspaceURL.path)
        context.insert(workspace)
        let task = AgentTask(title: "T", goal: "Trigger permission prompt", workspace: workspace, tokenBudget: 1000, model: "gpt-5")
        task.runtimeID = AgentRuntimeID.copilotCLI.rawValue
        task.status = .queued
        context.insert(task)
        try context.save()

        let worker = AgentRuntimeWorker()
        worker.copilotPath = binURL.path
        worker.copilotHome = root.appendingPathComponent("copilot-home", isDirectory: true).path
        worker.timeoutSeconds = 30

        await worker.execute(task: task, modelContext: context) { _ in }

        #expect(task.status == .pendingUser)
        let run = try #require(task.runs.first)
        #expect(run.status == .failed)
        #expect(run.stopReason == "permission_approval_required")
        #expect(task.events.contains { $0.type == "permission.denied" && $0.payload.contains("WorkspaceAccess") })
        #expect(task.events.contains { $0.type == "permission.approval.requested" && $0.payload.contains("Approve to continue") })
    }

    @discardableResult
    private static func run(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            throw NSError(
                domain: "CopilotRuntimeTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: error.isEmpty ? output : error]
            )
        }
        return output
    }
}

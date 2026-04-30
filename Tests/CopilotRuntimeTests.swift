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
        #expect(plan.arguments.contains("--allow-all-paths"))
        #expect(!plan.arguments.contains("--output-format=json"))
    }

    @Test("Restricted permissions map common Claude tools")
    func restrictedPermissions() {
        let args = CopilotCLIRuntime.copilotPermissionArguments(
            policy: .restricted,
            allowedTools: ["Read", "Bash", "Edit"],
            requiresAllowAllToolsForPrompt: false
        )
        let joined = args.joined(separator: " ")
        #expect(joined.contains("read"))
        #expect(joined.contains("write"))
        #expect(joined.contains("shell(git:*)"))
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
        printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hello from fake copilot"}}'
        printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":3},"duration_ms":10,"turns":1}'
        printf 'changed\\n' > copilot-output.txt
        exit 0
        """
        try script.write(to: binURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binURL.path)

        let schema = Schema(ASTRASchemaV1.models)
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

        let worker = ClaudeCodeWorker()
        worker.copilotPath = binURL.path
        worker.copilotHome = root.appendingPathComponent("copilot-home", isDirectory: true).path
        worker.timeoutSeconds = 30

        await worker.execute(task: task, modelContext: context) { _ in }

        #expect(task.status == .completed)
        let run = try #require(task.runs.first)
        #expect(run.runtimeID == AgentRuntimeID.copilotCLI.rawValue)
        #expect(run.output.contains("hello from fake copilot"))
        #expect(run.inputTokens == 2)
        #expect(run.outputTokens == 3)
        #expect(FileManager.default.fileExists(atPath: workspaceURL.appendingPathComponent("copilot-output.txt").path))
        #expect(run.fileChanges.contains { $0.path.hasSuffix("copilot-output.txt") })
    }
}

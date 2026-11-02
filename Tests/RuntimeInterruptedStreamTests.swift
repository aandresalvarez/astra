import ASTRACore
import ASTRAModels
import Foundation
import Testing
@testable import ASTRA

@Suite("Interrupted provider streams", .serialized)
@MainActor
struct RuntimeInterruptedStreamTests {
    struct Stream: Sendable, CustomTestStringConvertible {
        let runtime: AgentRuntimeID
        let executable: String
        let model: String
        let partial: String
        let final: String
        var testDescription: String { runtime.displayName }

        static let cases: [Self] = [
            .init(runtime: .claudeCode, executable: "claude", model: "claude-sonnet-4-6",
                  partial: #"{"type":"assistant","message":{"content":[{"type":"text","text":"Working on the question."}]}}"#,
                  final: #"{"type":"result","subtype":"success","is_error":false,"result":"The answer is seven."}"#),
            .init(runtime: .codexCLI, executable: "codex", model: "gpt-5.3-codex",
                  partial: #"{"type":"item.completed","item":{"type":"agent_message","id":"item-1","text":"Working on the question."}}"#,
                  final: #"{"type":"turn.completed","usage":{"input_tokens":2,"output_tokens":1}}"#),
            .init(runtime: .antigravityCLI, executable: "agy", model: "Gemini 3.5 Flash",
                  partial: #"{"event":"step_update","step_update":{"step_type":"agent_response","step_index":1,"state":"ACTIVE","text_delta":"Working on the question."}}"#,
                  final: #"{"event":"result","result":{"status":"SUCCESS","response":"The answer is seven."}}"#),
            .init(runtime: .copilotCLI, executable: "copilot", model: "gpt-5",
                  partial: #"{"type":"assistant.message","data":{"content":"Working on the question."}}"#,
                  final: #"{"type":"result","sessionId":"queue-test","exitCode":0,"result":"The answer is seven."}"#),
            .init(runtime: .cursorCLI, executable: "cursor-agent", model: "composer-2.5-fast",
                  partial: #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Working on the question."}]}}"#,
                  final: #"{"type":"result","subtype":"success","is_error":false,"result":"The answer is seven."}"#),
            .init(runtime: .openCodeCLI, executable: "opencode", model: "opencode/big-pickle",
                  partial: #"{"type":"text","sessionID":"s","part":{"type":"text","sessionID":"s","id":"p","messageID":"m","text":"Working on the question."}}"#,
                  final: #"{"type":"step_finish","sessionID":"s","part":{"type":"step-finish","sessionID":"s","id":"q","messageID":"m","reason":"stop","tokens":{"input":2,"output":1,"reasoning":0,"cache":{"read":0,"write":0}}}}"#)
        ]
    }

    @Test("Only a confirmed turn can finish its request", arguments: Stream.cases, [false, true])
    func interruptedStream(stream: Stream, sendsFinal: Bool) async throws {
        let harness = try HeadlessChatHarness(persistentStore: true)
        defer { harness.cleanup() }
        let lines = sendsFinal ? [stream.partial, stream.final] : [stream.partial]
        let body = "cat <<'FRAMES'\n" + lines.joined(separator: "\n") + "\nFRAMES\n"
        let script = stream.runtime == .copilotCLI ? HeadlessChatScenarioTests.copilotScript(body: body) : """
            #!/bin/sh
            if [ "$1" = "--help" ]; then echo "--output-format"; exit 0; fi
            if [ "$1" = "models" ]; then echo "opencode/big-pickle"; exit 0; fi
            \(body)
            """
        let executable = try harness.writeExecutable(named: stream.executable, script: script)
        let restore = stream.runtime == .antigravityCLI
            ? HeadlessChatScenarioTests.enableContinuationFixtureStructuredOutput(executablePath: executable) : nil
        defer { restore?() }
        let task = harness.makeTask(runtime: stream.runtime, goal: "Arithmetic question. What is three plus four?", model: stream.model)
        if stream.runtime == .openCodeCLI {
            let roots = ["XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME"]
            let environment = Dictionary(uniqueKeysWithValues: roots.map { ($0, harness.rootURL.appendingPathComponent($0).path) })
            let skill = Skill(name: "Arithmetic", environmentVariables: environment)
            skill.workspace = task.workspace
            harness.context.insert(skill)
            task.skills = [skill]
        }
        task.chainedGoal = "Check the answer."
        let worker = harness.makeWorker(runtime: stream.runtime, executablePath: executable)
        _ = await harness.execute(task: task, worker: worker)
        let run = try #require(task.runs.first)
        let errors = task.events.filter { $0.type == TaskEventTypes.System.error.rawValue }.map(\.payload)
        try #require(!run.output.isEmpty, "No output (\(run.stopReason)): \(errors)")
        let verdict = try #require(RuntimeTurnSettlementService.verdict(for: run, task: task))
        #expect((run.status == .completed) == sendsFinal)
        #expect((verdict.requestState == .completed) == sendsFinal)
        let receipt = try #require(try RuntimeExecutionOwner.existing(task: task, context: harness.context))
        #expect(receipt.stopProof?.permitsReplacement == sendsFinal)
        if !sendsFinal {
            #expect(task.status == .pendingUser)
            #expect(run.typedStopReason == .providerTurnEndMissing)
            #expect(verdict.chainedTaskID == nil)
            #expect(errors.contains { $0.contains("before confirming") })
            #expect(run.output.contains("Working on the question."))
        }
        try checkAdmission(after: task, harness: harness, released: sendsFinal)
    }

    private func checkAdmission(after task: AgentTask, harness: HeadlessChatHarness, released: Bool) throws {
        let runtime = task.resolvedRuntimeID
        let competitor = AgentTask(title: "Same workspace", goal: "A second question", workspace: task.workspace, runtime: runtime)
        harness.context.insert(competitor)
        try harness.context.save()
        let competingOwner = RuntimeExecutionOwner.acquire(task: competitor, context: harness.context, maxRunSeconds: 60)
        defer { competingOwner?.finish() }
        #expect((competingOwner != nil) == released)

        let directory = harness.rootURL.appendingPathExtension("independent")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = Workspace(name: "Independent", primaryPath: directory.path)
        let independent = AgentTask(title: "Independent", goal: "Another question", workspace: workspace, runtime: runtime)
        harness.context.insert(workspace)
        harness.context.insert(independent)
        try harness.context.save()
        let independentOwner = try #require(RuntimeExecutionOwner.acquire(task: independent, context: harness.context, maxRunSeconds: 60))
        independentOwner.finish()
    }

    @Test("Claude Ask acknowledges written permissions only after a confirmed root turn",
          arguments: ["complete", "missing-flag", "child-then-complete", "trailing-text", "trailing-request"])
    func claudeApprovalEnding(scenario: String) async throws {
        let h = try HeadlessChatHarness()
        defer { h.cleanup() }
        let result = #"{"type":"result","is_error":false,"result":"done"}"#
        let ask = #"{"type":"control_request","request_id":"first","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"pwd"}}}"#
        let tail: String
        switch scenario {
        case "missing-flag":
            tail = #"echo '{"type":"result","result":"partial"}'"#
        case "child-then-complete":
            tail = """
                echo '{"type":"result","is_error":false,"parent_tool_use_id":"child","result":"subtask"}'
                echo '\(ask.replacingOccurrences(of: "first", with: "second"))'
                IFS= read -r response || exit 1
                echo '\(result)'
                """
        case "trailing-text":
            tail = """
                echo '\(result)'
                echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Still working"}]}}'
                """
        case "trailing-request":
            tail = """
                echo '\(result)'
                echo '{"type":"control_request","request_id":"late","request":{"subtype":"ping"}}'
                """
        default: tail = "echo '\(result)'"
        }
        let executable = try h.writeExecutable(named: "claude", script: HeadlessChatScenarioTests.claudeScript(body: """
            IFS= read -r prompt || exit 1
            echo '\(ask)'
            IFS= read -r response || exit 1
            \(tail)
            """))
        let task = h.makeTask(runtime: .claudeCode, goal: "Synthetic approval", model: "claude-sonnet-4-6")
        let runner = AgentRuntimeProcessRunner { _ in .init(enforcement: .off) }
        let outcome = await runner.runRuntimeProcess(adapter: AgentRuntimeAdapterRegistry.adapter(for: .claudeCode),
            prompt: task.goal, task: task, workspacePath: h.workspaceURL.path, executablePath: executable,
            homeDirectory: h.rootURL.path, permissionPolicy: .restricted, timeoutSeconds: 8,
            liveApprovalsEnabled: true, maxRunSeconds: 12, onInteractiveAsk: { _ in .allow }, onLine: { _, _ in })
        let complete = scenario == "complete" || scenario == "child-then-complete"
        let written: Set<String> = scenario == "child-then-complete" ? ["first", "second"] : ["first"]
        #expect(outcome.exitCode == 0)
        #expect(outcome.providerTurnEnded == complete)
        #expect(outcome.writtenPermissionRequestIDs == written)
        #expect(outcome.acknowledgedPermissionRequestIDs == (complete ? written : []))
    }

    @Test("An explicitly failed Copilot result cannot complete a request even if the process exits zero", arguments: [
        #"{"type":"result","sessionId":"failed-copilot","exitCode":1,"usage":{"input_tokens":4,"output_tokens":5}}"#,
        #"{"type":"result","error":{"message":"quota exhausted"}}"#
    ])
    func failedCopilotEnvelope(result: String) async throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let executable = try h.writeExecutable(named: "copilot", script: HeadlessChatScenarioTests.copilotScript(body: """
            echo '{"type":"assistant.message","data":{"content":"Partial answer"}}'
            echo '\(result)'
            """))
        let task = h.makeTask(runtime: .copilotCLI, goal: "What is three plus four?", model: "gpt-5")
        task.chainedGoal = "Check the answer"
        _ = await h.execute(task: task, worker: h.makeWorker(runtime: .copilotCLI, executablePath: executable))
        let run = try #require(task.runs.first)
        let verdict = try #require(RuntimeTurnSettlementService.verdict(for: run, task: task))
        #expect(run.typedStopReason == .agentReportedError)
        #expect(verdict.requestState == .failed)
        #expect(verdict.chainedTaskID == nil)
        #expect(run.output.contains("Partial answer"))
    }

    @Test("An empty Codex turn distinguishes a missing ending from a confirmed empty result", arguments: [false, true])
    func emptyCodexTurn(ended: Bool) async throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let final = ended ? #"echo '{"type":"turn.completed","usage":{"input_tokens":4,"output_tokens":0}}'"# : ""
        let executable = try h.writeExecutable(named: "codex", script: """
            #!/bin/sh
            echo '{"type":"thread.started","thread_id":"empty-codex"}'
            \(final)
            """)
        let task = h.makeTask(runtime: .codexCLI, goal: "What is three plus four?", model: "gpt-5.3-codex")
        _ = await h.execute(task: task, worker: h.makeWorker(runtime: .codexCLI, executablePath: executable))
        let run = try #require(task.runs.first)
        #expect(run.typedStopReason == (ended ? .noUsableResult : .providerTurnEndMissing))
        let errors = task.events.filter { $0.type == TaskEventTypes.System.error.rawValue }.map(\.payload)
        #expect(errors.contains { $0.contains("Retry this task") } == ended)
        try checkAdmission(after: task, harness: h, released: ended)
    }
}

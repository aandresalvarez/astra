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
}

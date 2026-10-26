import Foundation
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

@Suite("OpenCode runner cleanup and accounting", .serialized)
@MainActor
struct OpenCodeRunnerCompletionTests {
    private let start = #"{"type":"step_start","sessionID":"s","part":{"type":"step-start","sessionID":"s","id":"start","messageID":"m"}}"#
    private let text = #"{"type":"text","sessionID":"s","part":{"type":"text","sessionID":"s","id":"text","messageID":"m","text":"Synthetic complete"}}"#
    private let finish = #"{"type":"step_finish","sessionID":"s","part":{"type":"step-finish","sessionID":"s","id":"end","messageID":"m","reason":"stop","tokens":{"input":100,"output":20,"reasoning":5,"cache":{"read":40,"write":10}}}}"#

    @Test("The production runner persists proof before releasing a competing runtime", arguments: ["natural", "cancel", "lost", "invalid"])
    func ownerBoundary(scenario: String) async throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .openCodeCLI, goal: "Synthetic", model: "test")
        let owner = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60))
        owner.remoteWorkExcluded = true // controlled local fixture, as the worker sets after SSH admission
        defer { owner.finish() }
        let contender = h.makeTask(runtime: .codexCLI, goal: "Competing", model: "test")
        #expect(RuntimeExecutionOwner.acquire(task: contender, context: h.context, maxRunSeconds: 60) == nil)
        let payload = [start, text] + (scenario == "lost" ? [] : [scenario == "invalid"
            ? finish.replacingOccurrences(of: "\"input\":100", with: "\"input\":-1") : finish])
        let path = h.workspaceURL.appendingPathComponent("stream.jsonl")
        // Final partial line exercises the post-reap drain, not only callbacks.
        try payload.joined(separator: "\n").write(to: path, atomically: true, encoding: .utf8)
        let script = scenario == "cancel"
            ? "trap 'exit 0' TERM; cat stream.jsonl; touch ready; while :; do sleep 0.1; done"
            : "cat stream.jsonl"
        let plan = AgentRuntimeProcessLaunchPlan(runtime: .openCodeCLI, executablePath: "/bin/sh", arguments: ["-c", script],
            currentDirectory: h.workspaceURL.path, environment: [:], browserShimDirectory: nil, providerVersion: nil, parsesJSONLines: true)
        let runner = AgentRuntimeProcessRunner { _ in .init(enforcement: .off) }
        runner.configureExecutionOwner(owner)
        let output = AgentLockedBuffer()
        let operation = Task { @MainActor in
            await runner.runRuntimeProcess(adapter: OpenCodeCompletionFixtureAdapter(plan: plan), prompt: "Synthetic", task: task,
                workspacePath: h.workspaceURL.path, executablePath: "/bin/sh", homeDirectory: h.workspaceURL.path,
                permissionPolicy: .restricted, timeoutSeconds: 10, maxRunSeconds: 60,
                onLine: { line, _ in output.append(line + "\n") })
        }
        if scenario == "cancel" {
            let deadline = ContinuousClock.now + .seconds(5)
            while !FileManager.default.fileExists(atPath: h.workspaceURL.appendingPathComponent("ready").path), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            owner.requestCancellation()
            runner.cancel()
        }
        let result = await operation.value
        #expect(result.executionStopProof?.permitsReplacement == (scenario == "natural"),
                "exit=\(result.exitCode), reason=\(result.runtimeStopReason ?? "none"), error=\(result.error)")
        if scenario == "invalid" {
            #expect(result.runtimeStopReason == "runtime_accounting_invalid")
            #expect(result.stoppedByASTRA)
        }
        if scenario == "natural" || scenario == "cancel" {
            #expect(result.executionTokensSpent == 175)
            #expect(output.value.split(separator: "\n").contains {
                OpenCodeStreamEventParser.parseAll(line: String($0)).contains {
                    if case .usage(150, 25) = $0 { true } else { false }
                }
            })
        }
        owner.finish()
        #expect(owner.persistedResourceRelease == (scenario == "natural"))
        let next = RuntimeExecutionOwner.acquire(task: contender, context: h.context, maxRunSeconds: 60)
        if scenario == "natural" {
            let next = try #require(next)
            defer { next.finish() }
            #expect(RuntimeExecutionOwner.acquire(task: contender, context: h.context, maxRunSeconds: 60) == nil)
        } else {
            #expect(next == nil)
            let reopened = RuntimeExecutionOwnerStore(root: RuntimeExecutionOwner.store(in: h.context).root)
            #expect(try reopened.read(taskID: task.id)?.executionID == owner.record.executionID)
            if case .blocked = RuntimeExecutionOwner.retryDecision(task: task, context: h.context) {} else { Issue.record("Uncertain execution admitted Retry") }
        }
    }

    @Test("Utility completion and line callbacks share accumulated usage, including the final partial line", arguments: [false, true])
    func utilityAccounting(callback: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("opencode-utility-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let second = finish.replacingOccurrences(of: "\"id\":\"end\"", with: "\"id\":\"end2\"")
        let path = root.appendingPathComponent("stream")
        try (finish + "\n" + second).write(to: path, atomically: true, encoding: .utf8)
        let plan = AgentRuntimeProcessLaunchPlan(runtime: .openCodeCLI, executablePath: "/bin/cat", arguments: [path.path],
            currentDirectory: root.path, environment: [:], browserShimDirectory: nil, providerVersion: nil, parsesJSONLines: true)
        let received = AgentLockedBuffer()
        let handler: (@Sendable (String) -> AgentUtilityRunResult?)?
        if callback {
            handler = { @Sendable line in received.append(line + "\n"); return nil }
        } else { handler = nil }
        let result = await AgentRuntimeProcessRunner.runScopedUtilityProcess(plan, timeoutSeconds: 10,
            stdoutLineHandler: handler,
            stderrChunkHandler: nil,
            completion: { code, stdout, stderr in .init(exitCode: code, output: stdout, error: stderr) },
            launchError: { .init(exitCode: -1, output: "", error: $0) },
            timeoutResult: { _ in .init(exitCode: -1, output: "", error: "timeout") })
        #expect(result.exitCode == 0)
        for stream in callback ? [result.output, received.value] : [result.output] {
            let last = try #require(stream.split(separator: "\n").last)
            #expect(OpenCodeStreamEventParser.parseAll(line: String(last)).contains {
                if case .usage(300, 50) = $0 { true } else { false }
            })
        }
    }
}

private struct OpenCodeCompletionFixtureAdapter: AgentRuntimeProcessLaunchPlanning, AgentRuntimeProcessEventParsing {
    let plan: AgentRuntimeProcessLaunchPlan
    var id: AgentRuntimeID { .openCodeCLI }
    var descriptor: AgentRuntimeDescriptor { AgentRuntimeAdapterRegistry.descriptor(for: id) }
    let providerRuntimeMessages = ProviderRuntimeMessages.claudeCode
    func makeProcessLaunchPlan(context: AgentRuntimeProcessLaunchContext) -> AgentRuntimeProcessLaunchPlan { plan }
    func parseProcessEvents(line: String, parsesJSONLines: Bool) -> [ParsedEvent] { OpenCodeStreamEventParser.parseAll(line: line) }
    func blockingProcessPermissionMessage(line: String, parsesJSONLines: Bool) -> String? { nil }
}

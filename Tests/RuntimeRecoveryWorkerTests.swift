import Foundation
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

@Suite("Durable automatic recovery worker flow", .serialized)
@MainActor
struct RuntimeRecoveryWorkerTests {
    @Test("Retry and another worker reconnect to a live execution without changing its context")
    func competingWorkerDoesNotLaunch() async throws {
        let harness = try HeadlessChatHarness(persistentStore: true)
        defer { harness.cleanup() }
        let path = try harness.writeExecutable(named: "claude", script: HeadlessChatScenarioTests.claudeScript(body: """
        echo $$ >> launches
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"owned-session","model":"claude-sonnet-4-6"}'
        while [ ! -f \(HeadlessChatScenarioTests.shQuote(harness.rootURL.appendingPathComponent("release").path)) ]; do sleep 0.05; done
        printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"OWNERSHIP_OK"}]}}'
        printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"result":"OWNERSHIP_OK","usage":{"input_tokens":3,"output_tokens":5}}'
        """))
        let task = harness.makeTask(runtime: .claudeCode, goal: "Reply OWNERSHIP_OK", model: "claude-sonnet-4-6")
        let first = harness.makeWorker(runtime: .claudeCode, executablePath: path)
        let second = harness.makeWorker(runtime: .codexCLI, executablePath: path)
        let execution = Task { await harness.execute(task: task, worker: first) }
        defer { first.cancel() }
        for _ in 0..<200 {
            if task.sessionId == "owned-session" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(task.sessionId == "owned-session")
        let coordinator = TaskLifecycleCoordinator(modelContext: harness.context, taskQueue: TaskQueue(poolSize: 0))
        #expect(coordinator.retryTask(task) == nil)
        await second.continueSession(task: task, message: "Competing request", modelContext: harness.context) { _ in }
        #expect(task.sessionId == "owned-session")
        #expect(task.runs.count == 1)
        try Data("release".utf8).write(to: harness.rootURL.appendingPathComponent("release"))
        _ = await execution.value
        #expect(task.runs.first?.status == .completed, "stop=\(task.runs.first?.stopReason ?? "nil") output=\(task.runs.first?.output ?? "nil")")
        let launches = try String(contentsOf: harness.workspaceURL.appendingPathComponent("launches"), encoding: .utf8).split(separator: "\n")
        #expect(launches.count == 1)
        #expect(task.events.contains { $0.payload.contains("reconnected") })
    }

    @Test("A suspended worker finishes under the original run and saved recovery intent")
    func recoveredWorker() async throws {
        let harness = try HeadlessChatHarness(persistentStore: true)
        defer { harness.cleanup() }
        let path = try harness.writeExecutable(named: "claude", script: HeadlessChatScenarioTests.claudeScript(body: """
        echo $$ >> launches
        kill -STOP $$
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"recovery-session","model":"claude-sonnet-4-6"}'
        printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"RECOVERED"}]}}'
        printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"result":"RECOVERED","usage":{"input_tokens":3,"output_tokens":5}}'
        """))
        let task = harness.makeTask(runtime: .claudeCode, goal: "Reply RECOVERED", model: "claude-sonnet-4-6")
        let worker = harness.makeWorker(runtime: .claudeCode, executablePath: path)
        worker.timeoutSeconds = 0.1
        worker.supervisionEnabled = true
        worker.supervisionInvestigatorOverride = { evidence in
            #expect(evidence.observation.ownedProcessSuspended == true)
            return .init(assessment: .suspectedStalled, explanation: "Synthetic suspended provider", evidenceIDs: ["runtime"])
        }
        _ = await harness.execute(task: task, worker: worker)
        let run = try #require(task.runs.first)
        #expect(task.runs.count == 1)
        #expect(run.status == .completed)
        #expect(run.providerSessionId == "recovery-session")
        let reports = try task.events.filter { $0.type == TaskEventTypes.System.runtimeRecovery.rawValue }.map {
            try JSONDecoder().decode(RuntimeRecoveryReport.self, from: Data($0.payload.utf8))
        }
        #expect(reports.filter { $0.phase == .intent }.count == 1)
        #expect(reports.filter { $0.phase == .resumed }.count == 1)
        #expect(reports.filter { $0.phase == .progress }.count == 1)
        #expect(Set(reports.map(\.operationID)).count == 1)
        #expect(Set(reports.compactMap(\.processID)).count == 1)
        #expect(run.tokensUsed >= 16_384)
        let launches = try String(contentsOf: harness.workspaceURL.appendingPathComponent("launches"), encoding: .utf8).split(separator: "\n")
        #expect(launches.count == 1)
        #expect(reports.first?.processID == Int32(launches[0]))
        let snapshot = TaskThreadSnapshot(goal: task.goal, createdAt: task.createdAt, events: task.events, runs: task.runs)
        #expect(snapshot.conversationItems.contains {
            if case .systemInfo(let text, _, _) = $0 { return text.contains("existing suspended provider process") }
            return false
        })
    }
}

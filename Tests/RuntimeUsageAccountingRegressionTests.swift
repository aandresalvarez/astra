import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

@Suite("Runtime usage accounting regressions", .serialized)
@MainActor
struct RuntimeUsageAccountingRegressionTests {
    @Test("Session baselines exclude other runtimes and later runs")
    func sessionIsolation() throws {
        let h = try HeadlessChatHarness()
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .codexCLI, goal: "Usage", model: "test")
        func run(_ runtime: AgentRuntimeID, at time: Double, input: Int) -> TaskRun {
            let r = TaskRun(task: task)
            r.runtimeID = runtime.rawValue; r.providerSessionId = "same-id"
            r.startedAt = Date(timeIntervalSince1970: time)
            r.inputTokens = input; r.outputTokens = 10; r.tokensUsed = input + 10
            h.context.insert(r); return r
        }
        _ = run(.claudeCode, at: 1, input: 500)
        _ = run(.codexCLI, at: 2, input: 100)
        let current = run(.codexCLI, at: 3, input: 0)
        _ = run(.codexCLI, at: 4, input: 900)
        #expect(ProviderSessionUsageEpoch.baseline(for: current, in: task) == .init(input: 100, output: 10))
    }

    @Test("A measured zero delta is not missing provider usage")
    func reportedZeroDoesNotEstimate() throws {
        let h = try HeadlessChatHarness()
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .antigravityCLI, goal: "Usage", model: "test")
        let adapter = AgentRuntimeAdapterRegistry.adapter(for: .antigravityCLI)
        let first = TaskRun(task: task); first.providerSessionId = "same"; h.context.insert(first)
        let next = TaskRun(task: task); next.providerSessionId = "same"; h.context.insert(next)
        for (run, mode) in [(first, AgentRuntimeRecordingMode.initial), (next, .followUp)] {
            adapter.recordWorkerStreamEvent(.agent(.stats(inputTokens: 100, outputTokens: 20, costUSD: nil, durationMs: nil, turns: nil)),
                mode: mode, task: task, run: run, modelContext: h.context, recordingState: AgentEventRecordingState())
        }
        AgentRuntimeWorker.recordEstimatedUsageIfProviderDidNotReport(runtimeAdapter: adapter, selectedRuntime: .antigravityCLI,
            prompt: "Synthetic prompt", task: task, run: next, modelContext: h.context, providerStarted: true)
        #expect(next.tokensUsed == 0)
        #expect(task.tokensUsed == 120)
        #expect(!task.events.contains { $0.payload.hasPrefix("estimated tokens:") })
    }

    @Test("Cursor failed results retain their measured usage")
    func failedResultsKeepUsage() {
        let line = #"{"type":"result","is_error":true,"result":"Synthetic error","usage":{"input_tokens":100,"output_tokens":20},"total_cost_usd":0.25}"#
        let events = CursorStreamEventParser.parseAgentEvents(line: line)
        #expect(events.contains { if case .failed = $0 { true } else { false } })
        #expect(events.contains { if case .stats(100, 20, 0.25, _, _) = $0 { true } else { false } })
        #expect(!events.contains { if case .completed = $0 { true } else { false } })
    }

    @Test("Copilot sums explicit USD across models")
    func copilotModelCosts() {
        let line = #"{"type":"session.shutdown","data":{"modelMetrics":{"a":{"usage":{"inputTokens":100,"outputTokens":20,"costUSD":1}},"b":{"usage":{"inputTokens":200,"outputTokens":30,"costUSD":2}}}}}"#
        #expect(CopilotStreamEventParser.parseAgentEvents(line: line).contains {
            if case .stats(300, 50, 3, _, _) = $0 { true } else { false }
        })
    }

    @Test("Confirmed zero reaches the persistent owner without an input estimate")
    func zeroUsageOwnerReopen() throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .codexCLI, goal: "Usage", model: "test", tokenBudget: 1000)
        task.status = .running
        let owner = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60))
        let run = TaskRun(task: task); h.context.insert(run)
        try owner.bind(run: run); try owner.prepareLaunch()
        let monitor = AgentProcessMonitor(tokenBudget: 1000, reportedUsageBaseline: .init(input: 100, output: 20))
        _ = monitor.processEvent(.usage(totalInputTokens: 100, totalOutputTokens: 20), process: nil)
        owner.stopped(proof: nil, turns: 1, tokens: monitor.recoveryTokensConsumed(estimatedInputTokens: 900), seconds: 1)
        owner.finish()
        let reopened = ModelContext(h.container)
        let receipt = try #require(try RuntimeExecutionOwner.store(in: reopened).read(taskID: task.id, taskOwnerID: task.persistentModelID))
        #expect(receipt.limits.tokensSpent == 0)
        #expect(receipt.limits.tokenCeiling == 1000)
        #expect(!receipt.canReplace)
    }

    @Test("Billing metadata persists without claiming a token report")
    func billingMetadata() throws {
        let h = try HeadlessChatHarness()
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .cursorCLI, goal: "Usage", model: "test")
        let run = TaskRun(task: task); h.context.insert(run)
        AgentRuntimeAdapterRegistry.adapter(for: .cursorCLI).recordWorkerStreamEvent(
            .agent(.usageMetadata(costUSD: 0.25, durationMs: 10, turns: 1)), mode: .initial,
            task: task, run: run, modelContext: h.context, recordingState: AgentEventRecordingState())
        #expect(run.costUSD == 0.25 && task.costUSD == 0.25)
        #expect(!ProviderUsageEvidence.hasReport(run: run, task: task))
    }

    @Test("Production stream accounting preserves Claude partial usage and deduplicates snapshots")
    func claudePartialMessages() async throws {
        let lines = [
            #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"m1","usage":{"input_tokens":900,"output_tokens":1}}}}"#,
            #"{"type":"stream_event","event":{"type":"message_delta","usage":{"output_tokens":200}}}"#,
            #"{"type":"assistant","message":{"id":"m1","content":[],"usage":{"input_tokens":900,"output_tokens":200}}}"#,
            #"{"type":"assistant","message":{"id":"m2","content":[],"usage":{"input_tokens":300,"output_tokens":50}}}"#
        ]
        let normalized = try await utilityLines(runtime: .claudeCode, lines: lines)
        let usage = normalized.flatMap { StreamEventParser.parseAll(line: $0) }.compactMap { event -> [Int]? in
            if case .usage(let input, let output) = event { return [input, output] }; return nil
        }
        #expect(usage == [[900,1], [900,200], [900,200], [1200,250]])
    }

    @Test("Production stream accounting accumulates distinct Copilot calls once")
    func copilotCalls() async throws {
        let a = #"{"type":"assistant.usage","id":"a","data":{"inputTokens":100,"outputTokens":10}}"#
        let b = #"{"type":"assistant.usage","id":"b","data":{"inputTokens":200,"outputTokens":20}}"#
        let lines = try await utilityLines(runtime: .copilotCLI, lines: [a, a, b])
        let usage = lines.flatMap { CopilotStreamEventParser.parseAgentEvents(line: $0) }.compactMap { event -> [Int]? in
            if case .stats(let input, let output, _, _, _) = event { return [input, output] }; return nil
        }
        #expect(usage == [[100,10], [100,10], [300,30]])
    }

    @Test("Malformed imported usage is rejected without invalid string ranges")
    func malformedUsage() {
        for payload in ["tokens: (in: 1, out: 2)", "tokens: ", "tokens: 3 (in: -1, out: 4)", "tokens: 4 (in: 1, out: 2)"] {
            #expect(ProviderUsageEvidence.Report(payload: payload) == nil)
        }
    }

    @Test("Estimated history cannot prove a reset or refill the live allowance")
    func estimatedHistoryIsNotResetEvidence() throws {
        let h = try HeadlessChatHarness()
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .antigravityCLI, goal: "Usage", model: "test")
        let first = TaskRun(task: task); first.providerSessionId = "same"; first.startedAt = .distantPast
        first.inputTokens = 5000; first.tokensUsed = 5000; task.tokensUsed = 5000; h.context.insert(first)
        h.context.insert(TaskEvent(task: task, eventType: TaskEventTypes.Task.stats,
            payload: "estimated tokens: 5000 (in: 5000, out: 0) | provider usage unavailable", run: first))
        let next = TaskRun(task: task); next.providerSessionId = "same"; h.context.insert(next)
        let baseline = ProviderSessionUsageEpoch.baseline(for: next, in: task)
        #expect(!baseline.isReset(input: 1000, output: 10))
        #expect(baseline.budgetBaseline == .zero)
        let monitor = AgentProcessMonitor(tokenBudget: 1000, reportedUsageBaseline: baseline.budgetBaseline)
        #expect(monitor.processEvent(.usage(totalInputTokens: 1000, totalOutputTokens: 10), process: nil))
        AgentRuntimeAdapterRegistry.adapter(for: .antigravityCLI).recordWorkerStreamEvent(
            .agent(.stats(inputTokens: 1000, outputTokens: 10, costUSD: nil, durationMs: nil, turns: nil)),
            mode: .followUp, task: task, run: next, modelContext: h.context, recordingState: AgentEventRecordingState())
        #expect(task.tokensUsed == 5010)
        #expect(TaskRequestBudget(run: next, task: task).reconciliationPending)
        try h.context.save()
        let page = try TaskThreadHistoryReader.initialPage(taskID: task.id, modelContext: h.context)
        #expect(page.runs.first { $0.id == next.id }?.requestUsageReconciliationPending == true)
        let tail = try TaskThreadHistoryReader.tailPage(taskID: task.id,
            since: .init(timestamp: .distantPast, id: UUID()), modelContext: h.context)
        #expect(tail.runs.first { $0.id == next.id }?.requestUsageReconciliationPending == true)
        #expect(!task.events.contains { $0.type == ProviderSessionUsageEpoch.resetEventType })
        #expect(task.events.contains { $0.type == TaskEventTypes.System.info.rawValue && $0.payload.contains("approximate") })
    }

    @Test("Retry budget presentation includes admission spend before and after a disk reopen")
    func retryBudgetPresentation() throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .codexCLI, goal: "Retry", model: "test", tokenBudget: 1000)
        let run = TaskRun(task: task); run.tokensUsed = 20; h.context.insert(run)
        let payload = "{\"runID\":\"\(run.id.uuidString)\",\"limits\":{\"tokensSpent\":900,\"tokenCeiling\":1000}}"
        h.context.insert(TaskEvent(task: task, eventType: TaskEventTypes.System.runtimeExecutionOwnership, payload: payload, run: run))
        try h.context.save()
        let projected = TaskRequestBudget(run: run, task: task)
        #expect(projected.tokensUsed == 920 && projected.progress == 0.92)
        let reopened = ModelContext(h.container); reopened.autosaveEnabled = false
        let loaded = try #require(try reopened.fetch(FetchDescriptor<AgentTask>()).first { $0.id == task.id })
        let loadedRun = try #require(loaded.runs.first)
        #expect(TaskRequestBudget(run: loadedRun, task: loaded) == projected)
        for index in 0..<1201 {
            let event = TaskEvent(task: loaded, type: "system.info", payload: "later \(index)", run: loadedRun)
            event.timestamp = Date().addingTimeInterval(Double(index + 1))
            reopened.insert(event)
        }
        let snapshot = TaskThreadSnapshotInput(task: loaded)
        #expect(snapshot.runs.first?.requestBudgetTokensUsed == 920)
    }

    @Test("A recent Copilot file cannot reattribute an old shutdown to this run")
    func staleCopilotShutdown() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("copilot-usage-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = root.appendingPathComponent("session-state/session")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let taskID = UUID(); let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) + 0.9)
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let old = formatter.string(from: now.addingTimeInterval(-0.8))
        let current = formatter.string(from: now.addingTimeInterval(0.05))
        let shutdown = #"{"type":"session.shutdown","timestamp":"\#(old)","data":{"modelMetrics":{"m":{"usage":{"inputTokens":1000,"outputTokens":0}}}}}"#
        let message = #"{"type":"user.message","timestamp":"\#(current)","data":{"content":"\#(taskID.uuidString)"}}"#
        let file = session.appendingPathComponent("events.jsonl")
        try (shutdown + "\n" + message).write(to: file, atomically: true, encoding: .utf8)
        let stale = CopilotSessionMetricsReader.newestTaskSession(copilotHome: root.path, taskID: taskID,
            modifiedSince: now.addingTimeInterval(-1), metricsSince: now, accepts: { _, _ in true })
        #expect(stale?.sessionID == "session" && stale?.metrics == nil)
        try (shutdown.replacingOccurrences(of: old, with: current) + "\n" + message).write(to: file, atomically: true, encoding: .utf8)
        let fresh = CopilotSessionMetricsReader.newestTaskSession(copilotHome: root.path, taskID: taskID,
            modifiedSince: now.addingTimeInterval(-1), metricsSince: now, accepts: { _, _ in true })
        #expect(fresh?.metrics?.inputTokens == 1000)
    }

    private func utilityLines(runtime: AgentRuntimeID, lines: [String]) async throws -> [String] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-regression-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("stream")
        try lines.joined(separator: "\n").write(to: path, atomically: true, encoding: .utf8)
        let plan = AgentRuntimeProcessLaunchPlan(runtime: runtime, executablePath: "/bin/cat", arguments: [path.path],
            currentDirectory: root.path, environment: [:], browserShimDirectory: nil, providerVersion: nil, parsesJSONLines: true)
        let result = await AgentRuntimeProcessRunner.runScopedUtilityProcess(plan, timeoutSeconds: 10,
            stdoutLineHandler: nil, stderrChunkHandler: nil,
            completion: { code, stdout, stderr in .init(exitCode: code, output: stdout, error: stderr) },
            launchError: { .init(exitCode: -1, output: "", error: $0) },
            timeoutResult: { _ in .init(exitCode: -1, output: "", error: "timeout") })
        #expect(result.exitCode == 0)
        return result.output.split(separator: "\n").map(String.init)
    }
}

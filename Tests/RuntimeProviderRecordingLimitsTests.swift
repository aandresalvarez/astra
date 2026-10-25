import Foundation
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

@Suite("Provider continuation accounting", .serialized)
@MainActor
struct RuntimeProviderRecordingLimitsTests {
    @Test("A provider blocked before launch spends no estimated tokens")
    func blockedProviderDoesNotSpendUsage() throws {
        let h = try HeadlessChatHarness()
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .antigravityCLI, goal: "Synthetic", model: "test")
        task.tokensUsed = 70
        let run = TaskRun(task: task)
        h.context.insert(run)
        AgentRuntimeWorker.recordEstimatedUsageIfProviderDidNotReport(
            runtimeAdapter: AgentRuntimeAdapterRegistry.adapter(for: .antigravityCLI),
            selectedRuntime: .antigravityCLI, prompt: "Waiting for shared configuration cleanup.",
            task: task, run: run, modelContext: h.context,
            runtimeStopReason: RuntimeProviderResourceRegistry.Block.stopReason)
        #expect(task.tokensUsed == 70 && run.tokensUsed == 0)
        #expect(!task.events.contains { $0.type == TaskEventTypes.Task.stats.rawValue })
    }

    @Test("Missing provider usage cannot overflow previously exhausted task limits")
    func estimatedUsageAfterSaturation() throws {
        let h = try HeadlessChatHarness()
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .antigravityCLI, goal: "Synthetic", model: "test")
        task.tokensUsed = Int.max
        let run = TaskRun(task: task)
        run.setOutput("A response without provider usage.")
        h.context.insert(run)
        AgentRuntimeWorker.recordEstimatedUsageIfProviderDidNotReport(
            runtimeAdapter: AgentRuntimeAdapterRegistry.adapter(for: .antigravityCLI),
            selectedRuntime: .antigravityCLI, prompt: "Continue within the saved limits.",
            task: task, run: run, modelContext: h.context)
        #expect(task.tokensUsed == Int.max)
        #expect(run.tokensUsed > 0)
        #expect(run.tokensUsed == run.inputTokens + run.outputTokens)
        #expect(task.events.contains { $0.type == TaskEventTypes.Task.stats.rawValue && $0.payload.contains("provider usage unavailable") })
    }

    @Test("Every adapter preserves earlier runs and counts cumulative updates only once", arguments: AgentRuntimeAdapterRegistry.runtimeIDs)
    func accounting(runtime: AgentRuntimeID) throws {
        let h = try HeadlessChatHarness()
        defer { h.cleanup() }
        let task = h.makeTask(runtime: runtime, goal: "Synthetic", model: "test")
        let first = TaskRun(task: task); h.context.insert(first)
        let next = TaskRun(task: task); h.context.insert(next)
        let adapter = AgentRuntimeAdapterRegistry.adapter(for: runtime)
        let state = AgentEventRecordingState()
        adapter.recordWorkerStreamEvent(.agent(.stats(inputTokens: 80, outputTokens: 20, costUSD: 1, durationMs: nil, turns: nil)),
            mode: .initial, task: task, run: first, modelContext: h.context, recordingState: state)
        for (input, output, cost) in [(20, 5, 0.1), (30, 10, 0.2), (30, 10, 0.2)] {
            adapter.recordWorkerStreamEvent(.agent(.stats(inputTokens: input, outputTokens: output, costUSD: cost, durationMs: nil, turns: nil)),
                mode: .followUp, task: task, run: next, modelContext: h.context, recordingState: state)
        }
        #expect(task.tokensUsed == 140)
        #expect(next.tokensUsed == 40)
        #expect(abs(task.costUSD - 1.2) < 0.000001)
        #expect(next.costUSD == 0.2)
        // Malformed/extreme provider totals must exhaust limits, never crash
        // while adding the new run to an existing task's usage.
        adapter.recordWorkerStreamEvent(.agent(.stats(inputTokens: Int.max, outputTokens: 0, costUSD: nil, durationMs: nil, turns: nil)),
            mode: .followUp, task: task, run: next, modelContext: h.context, recordingState: state)
        #expect(task.tokensUsed == Int.max)
        RuntimeSupervisionUsageRecorder.record(100, task: task, run: next, modelContext: h.context)
        #expect(task.tokensUsed == Int.max && next.tokensUsed == Int.max)
    }
}

import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

@Suite("Codex usage correction safety", .serialized)
@MainActor
struct CodexSessionUsageCorrectionSafetyTests {
    private typealias Service = CodexSessionUsageCorrectionService

    func seed(_ h: HeadlessChatHarness) -> (AgentTask, TaskRun, TaskRun) {
        h.context.autosaveEnabled = false
        let task = AgentTask(title: "Historical usage", goal: "Preserve context", runtime: .codexCLI)
        task.status = .completed
        task.tokenBudget = 9000
        h.context.insert(task)
        let runs = [100, 300].enumerated().map { index, input in
            let run = TaskRun(task: task)
            run.providerSessionId = "legacy-session"
            run.startedAt = Date(timeIntervalSince1970: 1_700_000_000 + Double(index * 60))
            run.status = .completed
            run.inputTokens = input
            run.outputTokens = input / 10
            run.tokensUsed = input + input / 10
            task.tokensUsed += run.tokensUsed
            h.context.insert(run)
            let event = TaskEvent(task: task, eventType: TaskEventTypes.Task.stats,
                payload: "tokens: \(run.tokensUsed) (in: \(input), out: \(input / 10))", run: run)
            event.timestamp = run.startedAt
            h.context.insert(event)
            return run
        }
        return (task, runs[0], runs[1])
    }

    @Test("Uncertain stopped tools preserve history and the recovery allowance")
    func uncertainOwnerIsUntouched() async throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (task, _, second) = seed(h)
        task.status = .pendingUser
        second.status = .failed
        second.typedStopReason = .runtimeConnectionLost
        let saved = try RuntimeRecoveryTestReceipt.install(task: task, run: second, context: h.context, toolsStopped: false)
        let result = await Service.correct(modelContext: h.context)
        #expect(result.sessionsDeferred == 1 && !result.completed)
        #expect(second.inputTokens == 300 && task.tokensUsed == 440)
        #expect(try RuntimeExecutionOwner.existing(task: task, context: h.context) == saved)
        #expect(!task.events.contains { $0.type == Service.correctedEventType })
    }

    @Test("A held execution lease blocks correction even before a running row is published")
    func liveLeaseIsUntouched() async throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let (task, _, second) = seed(h)
        let lease = try RuntimeExecutionOwner.store(in: h.context).acquire(taskID: task.id)
        defer { withExtendedLifetime(lease) {} }
        let result = await Service.correct(modelContext: h.context)
        #expect(result.sessionsDeferred == 1)
        #expect(second.inputTokens == 300 && task.tokensUsed == 440)
    }

    @Test("Missing execution receipts remain uncertain", arguments: ["runtime.execution_ownership", "imported.runtime.execution_ownership"])
    func missingReceiptIsUntouched(type: String) async throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let (task, _, second) = seed(h)
        h.context.insert(TaskEvent(task: task, type: type, payload: "{}"))
        let result = await Service.correct(modelContext: h.context)
        #expect(result.sessionsDeferred == 1)
        #expect(second.inputTokens == 300 && task.tokensUsed == 440)
    }

    @Test("A verified stopped owner allows history repair without refilling its limits")
    func stoppedOwnerKeepsLimits() async throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let (task, _, second) = seed(h)
        let saved = try RuntimeRecoveryTestReceipt.install(task: task, run: second, context: h.context)
        let result = await Service.correct(modelContext: h.context)
        #expect(result.runsCorrected == 1 && task.tokensUsed == 330)
        #expect(try RuntimeExecutionOwner.existing(task: task, context: h.context)?.limits == saved.limits)
        #expect(task.tokenBudget == 9000 && task.goal == "Preserve context")
    }

    @Test("Malformed or overflowing reports are not accounting evidence", arguments: [
        "tokens: -1 (in: -2, out: 1)",
        "tokens: (in: 100, out: 10)",
        "tokens: 1 (in: 9223372036854775807, out: 1)",
        "tokens: 999 (in: 100, out: 10)"
    ])
    func invalidReportsAreRejected(payload: String) {
        #expect(Service.report(fromStatsPayload: payload) == nil)
    }

    @Test("Runs tied after date serialization are preserved rather than ordered by UUID")
    func ambiguousRunOrderIsUntouched() async throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let (task, first, second) = seed(h)
        first.id = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        second.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        second.startedAt = first.startedAt
        let result = await Service.correct(modelContext: h.context)
        #expect(result.sessionsSkipped == 1)
        #expect(second.inputTokens == 300 && task.tokensUsed == 440)
        #expect(!task.events.contains { $0.type == ProviderSessionUsageEpoch.resetEventType })
    }

    @Test("A legacy total without a provider report is not a zero-usage launch")
    func missingSplitCountersAreInsufficient() async throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let (task, first, second) = seed(h)
        for event in task.events where event.run?.id == first.id { h.context.delete(event) }
        first.inputTokens = 0; first.outputTokens = 0
        let result = await Service.correct(modelContext: h.context)
        #expect(result.sessionsSkipped == 1)
        #expect(second.inputTokens == 300 && task.tokensUsed == 440)
    }

    @Test("Large aggregates are adjusted without overflowing an intermediate sum")
    func largeAggregateIsSafe() async throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let (task, _, second) = seed(h)
        task.tokensUsed = Int.max
        let result = await Service.correct(modelContext: h.context)
        #expect(result.runsCorrected == 1)
        #expect(second.inputTokens == 200 && task.tokensUsed == Int.max - 110)
    }

    @Test("Duplicate run identities cannot trap or mix reports across sessions")
    func duplicateRunIDsAreRejected() async throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let (task, first, second) = seed(h)
        second.id = first.id
        let result = await Service.correct(modelContext: h.context)
        #expect(result.sessionsSkipped == 1)
        #expect(second.inputTokens == 300 && task.tokensUsed == 440)
    }

    @Test("Conflicting reports at the same timestamp do not establish a final total")
    func ambiguousFinalReportIsRejected() async throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let (task, _, second) = seed(h)
        let event = TaskEvent(task: task, eventType: TaskEventTypes.Task.stats,
            payload: "tokens: 550 (in: 500, out: 50)", run: second)
        event.timestamp = second.startedAt
        h.context.insert(event)
        let result = await Service.correct(modelContext: h.context)
        #expect(result.sessionsSkipped == 1)
        #expect(second.inputTokens == 300 && task.tokensUsed == 440)
    }

    @Test("An active request fences a task whose presentation still says completed")
    func activeRequestIsUntouched() async throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let (task, _, second) = seed(h)
        h.context.insert(TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1, state: .waitingForWorker))
        let result = await Service.correct(modelContext: h.context)
        #expect(result.sessionsDeferred == 1)
        #expect(second.inputTokens == 300 && task.tokensUsed == 440)
    }

    @Test("Unreadable receipts are preserved and block correction")
    func unreadableOwnerIsUntouched() async throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let (task, _, second) = seed(h)
        do {
            let lease = try RuntimeExecutionOwner.store(in: h.context).acquire(taskID: task.id)
            try Data("broken receipt".utf8).write(to: lease.recordURL)
        }
        let result = await Service.correct(modelContext: h.context)
        #expect(result.sessionsDeferred == 1)
        #expect(second.inputTokens == 300 && task.tokensUsed == 440)
    }

    @Test("A partial aggregate is not clamped into an invented corrected total")
    func insufficientAggregateIsUntouched() async throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let (task, _, second) = seed(h)
        task.tokensUsed = 1
        let result = await Service.correct(modelContext: h.context)
        #expect(result.sessionsSkipped == 1)
        #expect(second.inputTokens == 300 && task.tokensUsed == 1)
    }

    @Test("Zero usage with an unverified failure does not establish prelaunch safety", arguments: ["", "policy_violation", "agent_reported_error"])
    func zeroUsageFailureIsUncertain(reason: String) async throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let (task, _, _) = seed(h)
        let failed = TaskRun(task: task)
        failed.status = .failed; failed.stopReason = reason
        h.context.insert(failed)
        let result = await Service.correct(modelContext: h.context)
        #expect(result.sessionsDeferred == 1 && task.tokensUsed == 440)
    }

    @Test("An older imported store cannot replay a retained run share as a full baseline")
    func preexistingTruncatedHistoryIsUntouched() async throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let (task, first, second) = seed(h)
        // Old import has neither the new completeness flag nor its marker.
        // The retained first run is a share of an earlier cumulative report.
        first.inputTokens = 50; first.outputTokens = 5; first.tokensUsed = 55
        second.inputTokens = 200; second.outputTokens = 20; second.tokensUsed = 220
        task.tokensUsed = 330
        try h.context.save()
        let restoredContext = ModelContext(h.container)
        restoredContext.autosaveEnabled = false
        let restored = try #require(try restoredContext.fetch(FetchDescriptor<AgentTask>()).first)
        let result = await Service.correct(modelContext: restoredContext)
        #expect(result.sessionsSkipped == 1 && restored.tokensUsed == 330)
        #expect(!restored.events.contains { $0.type == Service.correctedEventType })
    }
}

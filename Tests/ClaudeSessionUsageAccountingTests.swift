import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Claude native session usage accounting", .serialized)
@MainActor
struct ClaudeSessionUsageAccountingTests {
    private func result(input: Int, output: Int, cost: Double?, session: String = "session") throws -> String {
        var frame: [String: Any] = ["type": "result", "session_id": session, "is_error": false,
            "modelUsage": ["model": ["inputTokens": input, "outputTokens": output]], "num_turns": 1]
        if let cost { frame["total_cost_usd"] = cost }
        return String(decoding: try JSONSerialization.data(withJSONObject: frame), as: UTF8.self)
    }

    private func run(_ h: HeadlessChatHarness, task: AgentTask, at time: Double, session: String = "session") -> TaskRun {
        let run = TaskRun(task: task); run.runtimeID = AgentRuntimeID.claudeCode.rawValue
        run.providerSessionId = session; run.startedAt = Date(timeIntervalSince1970: time)
        h.context.insert(run); return run
    }

    private func record(_ line: String, task: AgentTask, run: TaskRun, context: ModelContext,
                        mode: AgentRuntimeRecordingMode = .followUp) {
        if let snapshot = ClaudeSessionUsageSnapshot(line: line) {
            ClaudeSessionUsageEvidence.record(snapshot, task: task, run: run, context: context)
        }
        let adapter = AgentRuntimeAdapterRegistry.adapter(for: .claudeCode)
        for event in adapter.parseWorkerStreamEvents(line: line, parsesJSONLines: true).events {
            adapter.recordWorkerStreamEvent(event, mode: mode, task: task, run: run,
                modelContext: context, recordingState: AgentEventRecordingState())
        }
    }

    @Test("Usage queries honor pending evidence deletion, resets and rollback in a persistent store")
    func pendingUsageEvidenceAndReset() throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        h.context.autosaveEnabled = false
        let task = h.makeTask(runtime: .claudeCode, goal: "Usage", model: "test")
        let prior = run(h, task: task, at: 1), next = run(h, task: task, at: 2)
        let snapshot = try #require(ClaudeSessionUsageSnapshot(line: result(input: 500, output: 100, cost: 0.1)))
        ClaudeSessionUsageEvidence.record(snapshot, task: task, run: prior, context: h.context)
        ClaudeSessionUsageEvidence.record(snapshot, task: task, run: prior, context: h.context)
        let evidence = try #require(TaskHistoryRead.events(for: task, ofTypes: [ClaudeSessionUsageEvidence.eventType]).first)
        #expect(TaskHistoryRead.events(for: task, ofTypes: [ClaudeSessionUsageEvidence.eventType]).count == 1)
        try h.context.save()
        let expected = ProviderSessionUsageBaseline(input: 500, output: 100, cost: 0.1)
        #expect(ProviderSessionUsageEpoch.baseline(for: next, in: task) == expected)
        SwiftDataTaskRollbackPreparation.prepare(task)
        h.context.delete(evidence)
        #expect(ProviderSessionUsageEpoch.baseline(for: next, in: task).reconciliationPending)
        h.context.rollback()
        #expect(ProviderSessionUsageEpoch.baseline(for: next, in: task) == expected)
        SwiftDataTaskRollbackPreparation.prepare(task)
        h.context.insert(TaskEvent(task: task, type: ProviderSessionUsageEpoch.resetEventType, payload: "reset", run: next))
        #expect(ProviderSessionUsageEpoch.baseline(for: next, in: task) == .zero)
        h.context.rollback()
        #expect(ProviderSessionUsageEpoch.baseline(for: next, in: task) == expected)
        ClaudeSessionUsageEvidence.markUnconfirmed(task: task, run: next, context: h.context)
        ClaudeSessionUsageEvidence.markUnconfirmed(task: task, run: next, context: h.context)
        #expect(TaskHistoryRead.events(for: task, ofTypes: [ClaudeSessionUsageEvidence.uncertainEventType]).count == 1)
    }

    @Test("Resumed live counters and native terminal totals charge only the new request after reopen")
    func resumeAfterReopen() throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Usage", model: "test", tokenBudget: 20_000)
        let prior = run(h, task: task, at: 1)
        record(try result(input: 13_021, output: 21, cost: 0.00095333), task: task, run: prior, context: h.context, mode: .initial)
        prior.status = .completed
        try h.context.save()
        let reopened = ModelContext(h.container)
        reopened.autosaveEnabled = false
        let loaded = try #require(try reopened.fetch(FetchDescriptor<AgentTask>()).first { $0.id == task.id })
        let next = TaskRun(task: loaded); next.runtimeID = AgentRuntimeID.claudeCode.rawValue
        next.providerSessionId = "session"; next.startedAt = Date(timeIntervalSince1970: 2); reopened.insert(next)
        let baseline = ProviderSessionUsageEpoch.baseline(for: next, in: loaded)
        #expect(baseline == .init(input: 13_021, output: 21, cost: 0.00095333))
        let accounting = RuntimeStreamUsageAccounting(runtime: .claudeCode, sessionInput: baseline.input, sessionOutput: baseline.output)
        let monitor = AgentProcessMonitor(tokenBudget: 20_000, reportedUsageBaseline: baseline)
        let lines = [
            #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"new","usage":{"input_tokens":2,"cache_creation_input_tokens":4577,"cache_read_input_tokens":12678,"output_tokens":8}}}}"#,
            #"{"type":"stream_event","event":{"type":"message_delta","usage":{"output_tokens":26}}}"#,
            try result(input: 30_278, output: 47, cost: 0.00200871)
        ]
        for line in lines {
            let normalized = accounting.normalize(line)
            #expect(!normalized.invalidUsage)
            record(normalized.line, task: loaded, run: next, context: reopened)
            for event in StreamEventParser.parseAll(line: normalized.line) {
                #expect(!monitor.processEvent(event, process: nil))
            }
        }
        #expect(next.tokensUsed == 17_283 && next.inputTokens == 17_257 && next.outputTokens == 26)
        #expect(loaded.tokensUsed == 30_325)
        #expect(abs(next.costUSD - 0.00105538) < 0.000000001)
        #expect(abs(loaded.costUSD - 0.00200871) < 0.000000001)
        #expect(monitor.recoveryTokensConsumed(estimatedInputTokens: 30_000) == 17_283)
        #expect(ProviderSessionUsageEpoch.baseline(for: next, in: loaded) == baseline)
        #expect(!TaskRequestBudget(run: next, task: loaded).reconciliationPending)
        #expect(!loaded.events.contains { $0.type == ProviderSessionUsageEpoch.resetEventType })
    }

    @Test("Legacy inflated history grants no inferred baseline and stays unchanged")
    func legacyHistoryIsConservative() throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Legacy", model: "test")
        let first = run(h, task: task, at: 1); first.inputTokens = 13_021; first.outputTokens = 21; first.tokensUsed = 13_042
        let second = run(h, task: task, at: 2); second.inputTokens = 30_278; second.outputTokens = 47; second.tokensUsed = 30_325
        task.tokensUsed = 43_367; task.costUSD = 0.003
        h.context.insert(TaskEvent(task: task, eventType: TaskEventTypes.Task.stats,
            payload: "tokens: 30325 (in: 30278, out: 47) | cost: $0.0020 | turns: 1", run: second))
        #expect(!TaskRequestBudget(run: first, task: task).reconciliationPending)
        #expect(TaskRequestBudget(run: second, task: task).reconciliationPending)
        try h.context.save()
        let reopened = ModelContext(h.container); reopened.autosaveEnabled = false
        let loaded = try #require(try reopened.fetch(FetchDescriptor<AgentTask>()).first { $0.id == task.id })
        let legacySecond = try #require(loaded.runs.first { $0.id == second.id })
        #expect(TaskRequestBudget(run: legacySecond, task: loaded).reconciliationPending)
        let legacyPage = try TaskThreadHistoryReader.initialPage(taskID: task.id, modelContext: reopened, runPageSize: 1)
        #expect(legacyPage.runs.first?.id == second.id && legacyPage.runs.first?.requestUsageReconciliationPending == true)
        let legacyTail = try TaskThreadHistoryReader.tailPage(taskID: task.id,
            since: .init(timestamp: .distantPast, id: UUID()), modelContext: reopened, runPageSize: 1)
        #expect(legacyTail.runs.first?.id == second.id && legacyTail.runs.first?.requestUsageReconciliationPending == true)
        #expect(!loaded.events.contains { $0.type == ClaudeSessionUsageEvidence.uncertainEventType })
        let current = run(h, task: task, at: 3)
        let baseline = ProviderSessionUsageEpoch.baseline(for: current, in: task)
        #expect(baseline.input == 0 && baseline.output == 0 && baseline.reconciliationPending && !baseline.costIsConfirmed)
        record(try result(input: 52_262, output: 70, cost: 0.00314311), task: task, run: current, context: h.context)
        #expect(current.tokensUsed == 52_332)
        #expect(first.tokensUsed == 13_042 && second.tokensUsed == 30_325)
        #expect(task.tokensUsed == 43_367 + 52_332 && task.costUSD == 0.003)
        #expect(TaskRequestBudget(run: current, task: task).reconciliationPending)
        let checkpoint = #"{"effectiveTokenBudget":250000,"requestTokensUsed":52332}"#
        h.context.insert(TaskEvent(task: task, eventType: TaskEventTypes.System.runtimeResultCaptured, payload: checkpoint, run: current))
        #expect(TaskRequestBudget(run: current, task: task).reconciliationPending)
        try h.context.save()
        let page = try TaskThreadHistoryReader.initialPage(taskID: task.id, modelContext: h.context)
        #expect(page.runs.first { $0.id == current.id }?.requestUsageReconciliationPending == true)
        let tail = try TaskThreadHistoryReader.tailPage(taskID: task.id,
            since: .init(timestamp: .distantPast, id: UUID()), modelContext: h.context)
        #expect(tail.runs.first { $0.id == current.id }?.requestUsageReconciliationPending == true)
        let next = run(h, task: task, at: 4)
        let nextBaseline = ProviderSessionUsageEpoch.baseline(for: next, in: task)
        #expect(nextBaseline.input == 52_262 && nextBaseline.output == 70)
        #expect(nextBaseline.costIsConfirmed && !nextBaseline.reconciliationPending)
        #expect(abs(nextBaseline.cost - 0.00314311) < 0.000000001)
        record(try result(input: 52_362, output: 80, cost: 0.0032), task: task, run: next, context: h.context)
        #expect(next.tokensUsed == 110 && !TaskRequestBudget(run: next, task: task).reconciliationPending)
        #expect(abs(next.costUSD - 0.00005689) < 0.000000001)
    }

    @Test("A typed native zero starts a new epoch without losing observed process usage")
    func nativeResetAndZero() throws {
        for resetInput in [0, 30] {
            let h = try HeadlessChatHarness(); defer { h.cleanup() }
            let task = h.makeTask(runtime: .claudeCode, goal: "Reset", model: "test")
            let prior = run(h, task: task, at: 1)
            record(try result(input: 1000, output: 100, cost: 1), task: task, run: prior, context: h.context, mode: .initial)
            let current = run(h, task: task, at: 2)
            let baseline = ProviderSessionUsageEpoch.baseline(for: current, in: task)
            let accounting = RuntimeStreamUsageAccounting(runtime: .claudeCode, sessionInput: baseline.input, sessionOutput: baseline.output)
            let monitor = AgentProcessMonitor(tokenBudget: 100, reportedUsageBaseline: baseline)
            let partial = #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"reset","usage":{"input_tokens":\#(resetInput),"output_tokens":0}}}}"#
            for raw in [partial, try result(input: resetInput, output: 0, cost: 0)] {
                let line = accounting.normalize(raw).line
                record(line, task: task, run: current, context: h.context)
                for event in StreamEventParser.parseAll(line: line) { #expect(!monitor.processEvent(event, process: nil)) }
            }
            #expect(current.tokensUsed == resetInput)
            #expect(monitor.recoveryTokensConsumed(estimatedInputTokens: 900) == resetInput)
            #expect(task.events.filter { $0.run?.id == current.id && $0.type == ProviderSessionUsageEpoch.resetEventType }.count == 1)
            let next = run(h, task: task, at: 3)
            #expect(ProviderSessionUsageEpoch.baseline(for: next, in: task) == .init(input: resetInput, output: 0, cost: 0))
        }
    }

    @Test("Only exact native model counters create evidence, including subagents and zero")
    func snapshotValidation() throws {
        let raw = #"{"type":"result","session_id":"session","usage":{"input_tokens":4,"cache_creation_input_tokens":12683,"cache_read_input_tokens":89591,"output_tokens":448},"modelUsage":{"m":{"inputTokens":8,"outputTokens":800,"cacheReadInputTokens":127039,"cacheCreationInputTokens":52190}},"total_cost_usd":0.1829233}"#
        let snapshot = try #require(ClaudeSessionUsageSnapshot(line: raw))
        #expect(snapshot.input == 179_237 && snapshot.output == 800 && snapshot.costUSD == 0.1829233)
        #expect(RuntimeStreamUsageAccounting(runtime: .claudeCode, sessionInput: 50, sessionOutput: 5).normalize(raw).line == raw)
        #expect(ClaudeSessionUsageSnapshot(line: try result(input: 0, output: 0, cost: 0))?.input == 0)
        for invalid in ["null", "true", "false", "-1", "1.5", "1e200"] {
            let frame = #"{"type":"result","session_id":"session","modelUsage":{"m":{"inputTokens":\#(invalid),"outputTokens":0}}}"#
            #expect(ClaudeSessionUsageSnapshot(line: frame) == nil)
        }
        #expect(ClaudeSessionUsageSnapshot(line: raw.replacingOccurrences(of: "0.1829233", with: "true")) == nil)
        for models in ["null", "{}", #"{"m":{"inputTokens":1}}"#] {
            #expect(ClaudeSessionUsageSnapshot(line: #"{"type":"result","session_id":"session","modelUsage":\#(models)}"#) == nil)
        }
    }

    @Test("Invocation fallback projects onto the session without inventing a native snapshot")
    func invocationFallback() {
        let accounting = RuntimeStreamUsageAccounting(runtime: .claudeCode, sessionInput: 100, sessionOutput: 10)
        for value in [0, 20] {
            let frame = #"{"type":"result","session_id":"session","modelUsage":{},"usage":{"input_tokens":\#(value),"output_tokens":0}}"#
            let line = accounting.normalize(frame).line
            #expect(StreamEventParser.parseAll(line: line).contains {
                if case .result(_, _, let input, 10, _, _, _) = $0 { input == 100 + value } else { false }
            })
            #expect(ClaudeSessionUsageSnapshot(line: line) == nil)
        }
        let missing = #"{"type":"result","session_id":"session","usage":{}}"#
        #expect(accounting.normalize(missing).line == missing)
        #expect(!StreamEventParser.parseAll(line: missing).contains { if case .usage = $0 { true } else { false } })
    }

    @Test("Snapshot scope excludes other sessions, later runs and the current run; missing cost remains unknown")
    func snapshotScopeAndCost() throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Scope", model: "test")
        let prior = run(h, task: task, at: 1)
        let line = try result(input: 100, output: 10, cost: nil)
        let snapshot = try #require(ClaudeSessionUsageSnapshot(line: line))
        ClaudeSessionUsageEvidence.record(snapshot, task: task, run: prior, context: h.context)
        ClaudeSessionUsageEvidence.record(snapshot, task: task, run: prior, context: h.context)
        #expect(task.events.filter { $0.type == ClaudeSessionUsageEvidence.eventType }.count == 1)
        let current = run(h, task: task, at: 2)
        let later = run(h, task: task, at: 3)
        record(try result(input: 900, output: 90, cost: 2), task: task, run: later, context: h.context)
        let baseline = ProviderSessionUsageEpoch.baseline(for: current, in: task)
        #expect(baseline.input == 100 && baseline.output == 10 && !baseline.costIsConfirmed && baseline.reconciliationPending)
        record(try result(input: 120, output: 12, cost: 1), task: task, run: current, context: h.context)
        #expect(current.tokensUsed == 22 && current.costUSD == 0)
        #expect(TaskRequestBudget(run: current, task: task).reconciliationPending)
        let other = run(h, task: task, at: 4, session: "different")
        #expect(ProviderSessionUsageEpoch.baseline(for: other, in: task) == .zero)
    }

    @Test("A missing native snapshot cannot make a later cumulative cost count the gap twice")
    func snapshotGapDoesNotDuplicateCost() throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Gap", model: "test")
        let first = run(h, task: task, at: 1)
        record(try result(input: 100, output: 10, cost: 1), task: task, run: first, context: h.context, mode: .initial)
        let fallback = run(h, task: task, at: 2)
        let accounting = RuntimeStreamUsageAccounting(runtime: .claudeCode, sessionInput: 100, sessionOutput: 10)
        let line = #"{"type":"result","session_id":"session","usage":{"input_tokens":20,"output_tokens":2},"total_cost_usd":1.2}"#
        record(accounting.normalize(line).line, task: task, run: fallback, context: h.context)
        #expect(fallback.tokensUsed == 22 && abs(fallback.costUSD - 0.2) < 0.000000001)
        let current = run(h, task: task, at: 3)
        let baseline = ProviderSessionUsageEpoch.baseline(for: current, in: task)
        #expect(baseline.input == 0 && baseline.output == 0)
        #expect(baseline.reconciliationPending && !baseline.costIsConfirmed)
        record(try result(input: 150, output: 15, cost: 1.5), task: task, run: current, context: h.context)
        #expect(current.tokensUsed == 165 && current.costUSD == 0)
        #expect(abs(task.costUSD - 1.2) < 0.000000001)
        #expect(TaskRequestBudget(run: current, task: task).reconciliationPending)
        let next = run(h, task: task, at: 4)
        #expect(ProviderSessionUsageEpoch.baseline(for: next, in: task) == .init(input: 150, output: 15, cost: 1.5))
    }

    @Test("A gap may hide a native reset, so a final-only report receives no stale baseline credit")
    func finalOnlyAfterSnapshotGap() throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Hidden reset", model: "test")
        let first = run(h, task: task, at: 1)
        record(try result(input: 1000, output: 0, cost: 1), task: task, run: first, context: h.context, mode: .initial)
        let gap = run(h, task: task, at: 2)
        gap.inputTokens = 20; gap.tokensUsed = 20; task.tokensUsed += 20
        let current = run(h, task: task, at: 3)
        let baseline = ProviderSessionUsageEpoch.baseline(for: current, in: task)
        #expect(baseline.input == 0 && baseline.output == 0 && baseline.reconciliationPending)
        let monitor = AgentProcessMonitor(tokenBudget: 1100, reportedUsageBaseline: baseline)
        let raw = #"{"type":"result","session_id":"session","usage":{"input_tokens":1180,"output_tokens":0},"modelUsage":{"m":{"inputTokens":1200,"outputTokens":0}},"total_cost_usd":1.2}"#
        let accounting = RuntimeStreamUsageAccounting(runtime: .claudeCode, sessionInput: baseline.input, sessionOutput: baseline.output)
        let line = accounting.normalize(raw).line
        record(line, task: task, run: current, context: h.context)
        for event in StreamEventParser.parseAll(line: line) { _ = monitor.processEvent(event, process: nil) }
        #expect(current.tokensUsed == 1200 && current.costUSD == 0)
        #expect(monitor.recoveryTokensConsumed(estimatedInputTokens: 900) == 1200)
        #expect(TaskRequestBudget(run: current, task: task).reconciliationPending)
    }

    @Test("Tied snapshot timestamps require identical evidence, not UUID ordering")
    func snapshotEventTieOrdering() throws {
        for conflicting in [false, true] {
            let h = try HeadlessChatHarness(); defer { h.cleanup() }
            let task = h.makeTask(runtime: .claudeCode, goal: "Event ties", model: "test")
            let prior = run(h, task: task, at: 1)
            record(try result(input: 100, output: 10, cost: 1), task: task, run: prior, context: h.context, mode: .initial)
            let first = try #require(task.events.first { $0.type == ClaudeSessionUsageEvidence.eventType })
            first.id = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
            first.timestamp = Date(timeIntervalSince1970: 1)
            let other: TaskEvent
            if conflicting {
                record(try result(input: 150, output: 15, cost: 1.5), task: task, run: prior, context: h.context)
                other = try #require(task.events.first { $0.type == ClaudeSessionUsageEvidence.eventType && $0.id != first.id })
            } else {
                other = TaskEvent(task: task, type: first.type, payload: first.payload, run: prior)
                h.context.insert(other)
            }
            other.id = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
            other.timestamp = first.timestamp
            let next = run(h, task: task, at: 2)
            let baseline = ProviderSessionUsageEpoch.baseline(for: next, in: task)
            if conflicting {
                #expect(baseline.input == 0 && baseline.output == 0 && baseline.reconciliationPending && !baseline.costIsConfirmed)
            } else {
                #expect(baseline == .init(input: 100, output: 10, cost: 1))
            }
        }
    }

    @Test("Rounded run timestamps cannot prove which native snapshot is the latest")
    func snapshotTieOrdering() throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Ties", model: "test")
        let first = run(h, task: task, at: 1.1)
        first.id = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let second = run(h, task: task, at: 1.9)
        second.id = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        record(try result(input: 100, output: 10, cost: 1), task: task, run: first, context: h.context, mode: .initial)
        record(try result(input: 150, output: 15, cost: 1.5), task: task, run: second, context: h.context)
        let next = run(h, task: task, at: 2)
        #expect(ProviderSessionUsageEpoch.baseline(for: next, in: task) == .init(input: 150, output: 15, cost: 1.5))
        first.startedAt = Date(timeIntervalSince1970: 1); second.startedAt = first.startedAt
        let ambiguous = ProviderSessionUsageEpoch.baseline(for: next, in: task)
        #expect(ambiguous.input == 0 && ambiguous.output == 0 && ambiguous.reconciliationPending && !ambiguous.costIsConfirmed)
        record(try result(input: 170, output: 17, cost: 1.7), task: task, run: next, context: h.context)
        #expect(next.tokensUsed == 187 && next.costUSD == 0)
        #expect(TaskRequestBudget(run: next, task: task).reconciliationPending)
        #expect(first.tokensUsed == 110 && second.tokensUsed == 55)
        let after = run(h, task: task, at: 3)
        let trusted = ProviderSessionUsageEpoch.baseline(for: after, in: task)
        #expect(trusted.input == 170 && trusted.output == 17 && trusted.costIsConfirmed && !trusted.reconciliationPending)
    }
}

extension HeadlessChatScenarioTests {
    @Test("Claude worker persists session snapshots and charges the next request once")
    func claudeSessionSnapshotsAcrossRequests() async throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let marker = Self.shQuoteSandboxPath(h.rootURL.appendingPathComponent("usage-first").path)
        let cli = try h.writeExecutable(named: "claude", script: Self.claudeScript(body: """
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"usage-session","model":"test"}'
        if [ -e \(marker) ]; then
          printf '%s\\n' '{"type":"assistant","message":{"id":"second","content":[],"usage":{"input_tokens":20,"output_tokens":2}}}'
          printf '%s\\n' '{"type":"result","is_error":false,"session_id":"usage-session","result":"Second","usage":{"input_tokens":20,"output_tokens":2},"modelUsage":{"m":{"inputTokens":120,"outputTokens":12}},"total_cost_usd":0.15,"num_turns":1}'
        else
          touch \(marker)
          printf '%s\\n' '{"type":"result","is_error":false,"session_id":"usage-session","result":"First","modelUsage":{"m":{"inputTokens":100,"outputTokens":10}},"total_cost_usd":0.1,"num_turns":1}'
        fi
        """))
        let task = h.makeTask(runtime: .claudeCode, goal: "Count once", model: "test", tokenBudget: 200_000)
        let worker = h.makeWorker(runtime: .claudeCode, executablePath: cli)
        _ = await h.execute(task: task, worker: worker)
        #expect(task.status == .completed && task.tokensUsed == 110)
        _ = await h.continueTask(task: task, message: "New independent request", worker: worker)
        let latest = try #require(task.runs.max(by: TaskRun.isChronologicallyOrdered))
        #expect(task.status == .completed && task.tokensUsed == 132 && latest.tokensUsed == 22)
        #expect(abs(task.costUSD - 0.15) < 0.000000001)
        #expect(task.events.filter { $0.type == ClaudeSessionUsageEvidence.eventType }.count == 2)
        #expect(!TaskRequestBudget(run: latest, task: task).reconciliationPending)
    }
}

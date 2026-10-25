import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// A natively resumed turn that ends cleanly with reasoning only must be
/// re-run once without the resume (Cursor does this on a minority of resumes),
/// while a turn that shows real output is never touched.
@Suite("Native resume empty-turn fallback")
@MainActor
struct NativeResumeEmptyTurnTests {
    // MARK: Gate

    private func gate() -> NativeResumeEmptyTurnGate {
        NativeResumeEmptyTurnGate(isSubstantiveLine: { line, _ in line.hasPrefix("real") })
    }

    @Test("Reasoning lines are held and released in order by the first real one")
    func firstRealLineReleasesHeldLinesInOrder() {
        let gate = gate()
        var forwarded: [String] = []
        gate.accept("think-1", true) { line, _ in forwarded.append(line) }
        gate.accept("think-2", true) { line, _ in forwarded.append(line) }
        #expect(forwarded.isEmpty)
        #expect(gate.producedNothing)

        gate.accept("real-1", true) { line, _ in forwarded.append(line) }
        gate.accept("after", true) { line, _ in forwarded.append(line) }
        #expect(forwarded == ["think-1", "think-2", "real-1", "after"])
        #expect(!gate.producedNothing)
    }

    @Test("A turn that never shows anything real forwards nothing until flushed or discarded")
    func emptyTurnCanBeDiscardedOrFlushed() {
        let flushed = gate()
        var forwarded: [String] = []
        flushed.accept("think-1", true) { line, _ in forwarded.append(line) }
        #expect(flushed.producedNothing)
        flushed.flush { line, _ in forwarded.append(line) }
        #expect(forwarded == ["think-1"])

        let discarded = gate()
        var dropped: [String] = []
        discarded.accept("think-1", true) { line, _ in dropped.append(line) }
        discarded.discard()
        discarded.flush { line, _ in dropped.append(line) }
        #expect(dropped.isEmpty)
    }

    @Test("Only reasoning and bookkeeping are held; anything unfamiliar counts as real")
    func eventClassification() {
        let held: [AgentEvent] = [
            .control(type: "x"), .started(sessionID: "s", model: nil), .thinking(text: "t"),
            .stats(inputTokens: 1, outputTokens: 1, costUSD: nil, durationMs: nil, turns: nil),
            .completed(summary: nil), .completed(summary: "  "),
            .unknown(provider: "cursor", type: "thinking", raw: "{}")
        ]
        let real: [AgentEvent] = [
            .text(text: "hi"), .toolUse(name: "Bash", id: "1", inputSummary: nil),
            .toolResult(id: "1", content: "ok"), .failed(message: "no"), .notice(message: "n"),
            .completed(summary: "done"), .unknown(provider: "cursor", type: "tool_call", raw: "{}")
        ]
        for event in held { #expect(!NativeResumeEmptyTurnGate.isSubstantive(event), "\(event)") }
        for event in real { #expect(NativeResumeEmptyTurnGate.isSubstantive(event), "\(event)") }
    }

    // MARK: Worker

    private static let initialTurn = [
        #"{"type":"system","subtype":"init","session_id":"chat-xyz","model":"Composer 2.5 Fast","permissionMode":"default"}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"OK"}]},"session_id":"chat-xyz"}"#,
        #"{"type":"result","subtype":"success","duration_ms":5,"is_error":false,"result":"OK","session_id":"chat-xyz"}"#
    ]
    private static let reasoningOnlyTurn = [
        #"{"type":"system","subtype":"init","session_id":"chat-xyz","model":"Composer 2.5 Fast","permissionMode":"default"}"#,
        #"{"type":"thinking","subtype":"delta","text":"hmm","session_id":"chat-xyz","timestamp_ms":1}"#,
        #"{"type":"thinking","subtype":"completed","session_id":"chat-xyz","timestamp_ms":2}"#,
        #"{"type":"result","subtype":"success","duration_ms":5,"is_error":false,"result":"","session_id":"chat-xyz"}"#
    ]
    private static let reasoningOnlyWithUsage = [
        reasoningOnlyTurn[0], reasoningOnlyTurn[1], reasoningOnlyTurn[2],
        #"{"type":"result","subtype":"success","duration_ms":5,"is_error":false,"result":"","session_id":"chat-xyz","usage":{"inputTokens":100,"outputTokens":10,"cacheReadTokens":0,"cacheWriteTokens":0}}"#
    ]
    private static let freshAnswerWithUsage = [
        #"{"type":"system","subtype":"init","session_id":"chat-new","model":"Composer 2.5 Fast","permissionMode":"default"}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"4172"}]},"session_id":"chat-new"}"#,
        #"{"type":"result","subtype":"success","duration_ms":5,"is_error":false,"result":"4172","session_id":"chat-new","usage":{"inputTokens":50,"outputTokens":5,"cacheReadTokens":0,"cacheWriteTokens":0}}"#
    ]
    private static let freshAnswerTurn = [
        #"{"type":"system","subtype":"init","session_id":"chat-new","model":"Composer 2.5 Fast","permissionMode":"default"}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"4172"}]},"session_id":"chat-new"}"#,
        #"{"type":"result","subtype":"success","duration_ms":5,"is_error":false,"result":"4172","session_id":"chat-new"}"#
    ]

    /// Runs a Cursor task through its first turn and a follow-up whose native
    /// session exists, feeding the runner's scripts in order.
    private func runFollowUp(
        scripts: [ScriptedStreamRunner.Script],
        configure: (AgentRuntimeWorker, AgentTask) -> Void = { _, _ in }
    ) async throws -> (runner: ScriptedStreamRunner, task: AgentTask, container: ModelContainer) {
        let root = "/tmp/native_empty_\(UUID().uuidString.prefix(8))"
        let home = "\(root)/home"
        try FileManager.default.createDirectory(atPath: "\(home)/.cursor/chats/hash/chat-xyz", withIntermediateDirectories: true)
        let workspacePath = "\(root)/ws"
        try FileManager.default.createDirectory(atPath: workspacePath, withIntermediateDirectories: true)

        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Empty Turn", primaryPath: workspacePath)
        context.insert(workspace)
        let task = AgentTask(
            title: "Cursor empty turn", goal: "Remember 4172", workspace: workspace,
            model: "composer-2.5-fast", runtime: .cursorCLI
        )
        task.status = .queued
        context.insert(task)
        try context.save()

        let runner = ScriptedStreamRunner(scripts: scripts)
        let worker = AgentRuntimeWorker(
            processRunner: runner,
            providerSettingsSnapshotProvider: { .headlessScenario }
        )
        worker.runtimeReadinessService = RuntimeReadinessService(runner: InstantSuccessBinaryRunner())
        worker.skipPermissions = true
        worker.permissionPolicy = .autonomous
        worker.defaultAgentPolicyLevelRaw = AgentPolicyLevel.autonomous.rawValue
        worker.defaultRuntimeID = .cursorCLI
        worker.setExecutablePath("/bin/sh", for: .cursorCLI)
        worker.providerSessionStoreHome = home

        DirectWorkerLaunchAdmission.admitInitialRun(task, modelContext: context)
        await worker.execute(task: task, modelContext: context) { _ in }
        #expect(task.sessionId == "chat-xyz")
        try #require(try RuntimeExecutionOwner.existing(task: task, context: context)?.canReplace == true,
            "The initial fixture turn must provide a bound cleanup receipt before continuation")

        configure(worker, task)
        DirectWorkerLaunchAdmission.admitContinuation(task, modelContext: context)
        let submission = try ExecutionRequestSubmissionService.submitFollowUp(message: "What number did I give you?", for: task, into: context).get()
        let request = try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: context))
        _ = TaskTurnRequestStateMachine.transition(request, to: .admitted)
        await worker.continueSession(task: task, message: "What number did I give you?",
            existingMessageEventID: submission.eventID, turnRequestID: submission.requestID, modelContext: context) { _ in }
        try? FileManager.default.removeItem(atPath: root)
        return (runner, task, container)
    }

    @Test("An empty resumed Cursor turn is re-run once without --resume and its answer is recorded")
    func emptyResumedTurnIsRerunFresh() async throws {
        let (runner, task, container) = try await runFollowUp(scripts: [
            .init(lines: Self.initialTurn),
            .init(lines: Self.reasoningOnlyTurn),
            .init(lines: Self.freshAnswerTurn)
        ])
        defer { withExtendedLifetime(container) {} }

        // initial launch, the resumed attempt, then the fresh re-run
        #expect(runner.nativeSessionIDs == [nil, "chat-xyz", nil])
        let latest = try #require(task.runs.max { $0.startedAt < $1.startedAt })
        #expect(latest.status == .completed)
        #expect(latest.output.contains("4172"))
        #expect(task.sessionId == "chat-new")
        #expect(latest.stopReason != "no_usable_result")
    }

    @Test("Expired fallback time never launches a replacement with unlimited zero timeout")
    func expiredFallbackDoesNotLaunch() async throws {
        let (runner, task, container) = try await runFollowUp(scripts: [
            .init(lines: Self.initialTurn),
            .init(lines: Self.reasoningOnlyTurn, delayAfterStop: 0.2),
            .init(lines: Self.freshAnswerTurn)
        ], configure: { worker, _ in worker.maxRunSeconds = 0.1 })
        defer { withExtendedLifetime(container) {} }
        #expect(runner.nativeSessionIDs.count == 2)
        #expect(task.runs.max { $0.startedAt < $1.startedAt }?.stopReason == "recovery_limits_exhausted")
    }

    @Test("The re-run only gets the wall-clock allowance the first attempt left")
    func rerunSharesTheRunDeadline() async throws {
        let (runner, _, container) = try await runFollowUp(scripts: [
            .init(lines: Self.initialTurn),
            .init(lines: Self.reasoningOnlyTurn),
            .init(lines: Self.freshAnswerTurn)
        ], configure: { worker, _ in worker.maxRunSeconds = 600 })
        defer { withExtendedLifetime(container) {} }

        try #require(runner.maxRunSeconds.count == 3)
        let resumed = try #require(runner.maxRunSeconds[1])
        let rerun = try #require(runner.maxRunSeconds[2])
        #expect(resumed == 600)
        #expect(rerun < resumed)
        #expect(rerun > 0)
    }

    @Test("The full-history prompt is budget-checked before the re-run, and a hard stop blocks it")
    func rerunPromptIsBudgetChecked() async throws {
        // Long earlier history: the standard window drops most of it, the extended one keeps it.
        let padHistory: (AgentRuntimeWorker, AgentTask) -> Void = { _, task in
            let outputs = (TaskWorkspaceAccess(task: task).taskFolder as NSString).appendingPathComponent("outputs")
            try? FileManager.default.createDirectory(atPath: outputs, withIntermediateDirectories: true)
            for turn in 2...9 {
                let path = (outputs as NSString).appendingPathComponent(String(format: "turn_%03d.md", turn))
                try? String(repeating: "Earlier turn \(turn) detail. ", count: 150).write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        // Measure both prompts with an ample budget first.
        let (measured, _, measuredContainer) = try await runFollowUp(scripts: [
            .init(lines: Self.initialTurn),
            .init(lines: Self.reasoningOnlyTurn),
            .init(lines: Self.freshAnswerTurn)
        ], configure: padHistory)
        defer { withExtendedLifetime(measuredContainer) {} }
        try #require(measured.prompts.count == 3)
        let compact = AgentProcessMonitor.estimatedTokenCount(for: measured.prompts[1])
        let full = AgentProcessMonitor.estimatedTokenCount(for: measured.prompts[2])
        try #require(full > compact, "the fallback prompt must be the larger one for this test to mean anything")

        let (runner, _, container) = try await runFollowUp(scripts: [
            .init(lines: Self.initialTurn),
            .init(lines: Self.reasoningOnlyTurn),
            .init(lines: Self.freshAnswerTurn)
        ], configure: { worker, task in
            padHistory(worker, task)
            worker.budgetEnforcementModeOverride = .hardStop
            task.tokenBudget = (compact + full) / 2
        })
        defer { withExtendedLifetime(container) {} }

        // initial launch and the resumed attempt happen; the oversized re-run does not
        #expect(runner.nativeSessionIDs == [nil, "chat-xyz"])
    }

    @Test("Fallback prompt counts unreported input already charged to the owner")
    func fallbackPromptUsesOwnerConsumption() async throws {
        let (measured, _, firstContainer) = try await runFollowUp(scripts: [
            .init(lines: Self.initialTurn), .init(lines: Self.reasoningOnlyTurn), .init(lines: Self.freshAnswerTurn)
        ])
        defer { withExtendedLifetime(firstContainer) {} }
        try #require(measured.prompts.count == 3)
        let full = AgentRuntimeProcessRunner.estimatedLaunchInputTokens(prompt: measured.prompts[2], runtime: .cursorCLI)
        let (runner, task, container) = try await runFollowUp(scripts: [
            .init(lines: Self.initialTurn), .init(lines: Self.reasoningOnlyTurn, chargedTokens: 500),
            .init(lines: Self.freshAnswerTurn)
        ], configure: { worker, task in
            worker.budgetEnforcementModeOverride = .hardStop
            task.tokenBudget = full + 100
        })
        defer { withExtendedLifetime(container) {} }
        #expect(runner.nativeSessionIDs == [nil, "chat-xyz"])
        #expect(task.runs.max { $0.startedAt < $1.startedAt }?.status == .budgetExceeded)
    }

    @Test("The re-run is told how many provider turns the empty attempt spent")
    func rerunCarriesTheTurnCount() async throws {
        let (runner, _, container) = try await runFollowUp(scripts: [
            .init(lines: Self.initialTurn),
            .init(lines: Self.reasoningOnlyTurn),
            .init(lines: Self.freshAnswerTurn)
        ])
        defer { withExtendedLifetime(container) {} }
        #expect(runner.turnsAlreadyUsed == [0, 0, 1])
    }

    @Test("The turn ceiling shrinks by what an earlier attempt spent, and never below one")
    func remainingTurnsArithmetic() {
        #expect(AgentRuntimeProcessRunner.remainingTurns(maxTurns: 0, alreadyUsed: 1) == 0)
        #expect(AgentRuntimeProcessRunner.remainingTurns(maxTurns: 5, alreadyUsed: 0) == 5)
        #expect(AgentRuntimeProcessRunner.remainingTurns(maxTurns: 5, alreadyUsed: 1) == 4)
        #expect(AgentRuntimeProcessRunner.remainingTurns(maxTurns: 1, alreadyUsed: 1) == 1)
    }

    @Test("If the re-run fails before its init frame, the abandoned session is no longer the task's")
    func failedRerunDoesNotLeaveTheOldSession() async throws {
        let (runner, task, container) = try await runFollowUp(scripts: [
            .init(lines: Self.initialTurn),
            .init(lines: Self.reasoningOnlyTurn),
            .init(lines: [], exitCode: 1)
        ])
        defer { withExtendedLifetime(container) {} }
        #expect(runner.nativeSessionIDs == [nil, "chat-xyz", nil])
        #expect(task.sessionId == nil)
    }

    @Test("A hard budget stop on the re-run still drops the abandoned session")
    func budgetStoppedRerunDropsTheOldSession() async throws {
        let padHistory: (AgentRuntimeWorker, AgentTask) -> Void = { _, task in
            let outputs = (TaskWorkspaceAccess(task: task).taskFolder as NSString).appendingPathComponent("outputs")
            try? FileManager.default.createDirectory(atPath: outputs, withIntermediateDirectories: true)
            for turn in 2...9 {
                let path = (outputs as NSString).appendingPathComponent(String(format: "turn_%03d.md", turn))
                try? String(repeating: "Earlier turn \(turn) detail. ", count: 150).write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        let (measured, _, measuredContainer) = try await runFollowUp(scripts: [
            .init(lines: Self.initialTurn), .init(lines: Self.reasoningOnlyTurn), .init(lines: Self.freshAnswerTurn)
        ], configure: padHistory)
        defer { withExtendedLifetime(measuredContainer) {} }
        try #require(measured.prompts.count == 3)
        let compact = AgentProcessMonitor.estimatedTokenCount(for: measured.prompts[1])
        let full = AgentProcessMonitor.estimatedTokenCount(for: measured.prompts[2])
        try #require(full > compact)

        let (runner, task, container) = try await runFollowUp(scripts: [
            .init(lines: Self.initialTurn), .init(lines: Self.reasoningOnlyTurn), .init(lines: Self.freshAnswerTurn)
        ], configure: { worker, task in
            padHistory(worker, task)
            worker.budgetEnforcementModeOverride = .hardStop
            task.tokenBudget = (compact + full) / 2
        })
        defer { withExtendedLifetime(container) {} }

        #expect(runner.nativeSessionIDs == [nil, "chat-xyz"])
        #expect(task.sessionId == nil)
    }

    @Test("The discarded attempt's usage still counts: it is added to the run and taken off the re-run's budget")
    func discardedAttemptUsageIsKept() async throws {
        let (runner, task, container) = try await runFollowUp(scripts: [
            .init(lines: Self.initialTurn),
            .init(lines: Self.reasoningOnlyWithUsage),
            .init(lines: Self.freshAnswerWithUsage)
        ])
        defer { withExtendedLifetime(container) {} }

        #expect(runner.tokensAlreadyUsed == [0, 0, 110])
        let latest = try #require(task.runs.max { $0.startedAt < $1.startedAt })
        #expect(latest.inputTokens == 150)
        #expect(latest.outputTokens == 15)
        #expect(latest.tokensUsed == 165)
    }

    @Test("Usage the re-run never reports is recorded from the discarded attempt on its own")
    func discardedUsageIsRecordedWhenTheRerunReportsNone() async throws {
        let (_, task, container) = try await runFollowUp(scripts: [
            .init(lines: Self.initialTurn),
            .init(lines: Self.reasoningOnlyWithUsage),
            .init(lines: Self.freshAnswerTurn)
        ])
        defer { withExtendedLifetime(container) {} }

        let latest = try #require(task.runs.max { $0.startedAt < $1.startedAt })
        #expect(latest.tokensUsed == 110)
    }

    @Test("Usage carry adds to every later usage event and stands alone only when none came")
    func usageCarryArithmetic() throws {
        let carry = DiscardedAttemptUsage()
        carry.record(from: [
            .thinking(text: "t"),
            .stats(inputTokens: 100, outputTokens: 10, costUSD: 0.5, durationMs: nil, turns: nil)
        ])
        #expect(carry.totalTokens == 110)

        let events = carry.apply(to: [
            .agent(.text(text: "hi")),
            .agent(.stats(inputTokens: 50, outputTokens: 5, costUSD: 0.25, durationMs: 7, turns: 1))
        ])
        try #require(events.count == 2)
        guard case .agent(.stats(let input, let output, let cost, let duration, _)) = events[1] else {
            Issue.record("expected a stats event"); return
        }
        #expect(input == 150 && output == 15 && cost == 0.75 && duration == 7)
        #expect(carry.unappliedEvents().isEmpty)

        let alone = DiscardedAttemptUsage()
        alone.record(from: [.stats(inputTokens: 3, outputTokens: 2, costUSD: nil, durationMs: nil, turns: nil)])
        #expect(alone.unappliedEvents().count == 1)
        #expect(alone.unappliedEvents().isEmpty)

        #expect(DiscardedAttemptUsage().apply(to: [.agent(.text(text: "x"))]).count == 1)
        let extreme = DiscardedAttemptUsage()
        extreme.record(from: [.stats(inputTokens: Int.max, outputTokens: 10, costUSD: nil, durationMs: nil, turns: nil)])
        #expect(extreme.totalTokens == Int.max)
        let combined = extreme.apply(to: [.agent(.stats(inputTokens: 100, outputTokens: Int.max, costUSD: nil, durationMs: nil, turns: nil))])
        try #require(combined.count == 1)
        guard case .agent(.stats(let largeInput, let largeOutput, _, _, _)) = combined[0] else {
            Issue.record("Expected preserved cumulative usage"); return
        }
        #expect(largeInput == Int.max && largeOutput == Int.max)
    }

    @Test("The token ceiling shrinks by what an earlier attempt spent; unlimited and malformed budgets are left alone")
    func remainingTokenBudgetArithmetic() {
        #expect(AgentRuntimeProcessRunner.remainingTokenBudget(1000, alreadyUsed: 110) == 890)
        #expect(AgentRuntimeProcessRunner.remainingTokenBudget(100, alreadyUsed: 110) == 1)
        #expect(AgentRuntimeProcessRunner.remainingTokenBudget(Int.max, alreadyUsed: 110) == Int.max)
        #expect(AgentRuntimeProcessRunner.remainingTokenBudget(0, alreadyUsed: 110) == 0)
        #expect(AgentRuntimeProcessRunner.remainingTokenBudget(-5, alreadyUsed: 110) == -5)
    }

    @Test("The full-history prompt is judged against the budget the discarded attempt left, and that usage is still recorded")
    func rerunIsBudgetCheckedAgainstWhatIsLeft() async throws {
        let padHistory: (AgentRuntimeWorker, AgentTask) -> Void = { _, task in
            let outputs = (TaskWorkspaceAccess(task: task).taskFolder as NSString).appendingPathComponent("outputs")
            try? FileManager.default.createDirectory(atPath: outputs, withIntermediateDirectories: true)
            for turn in 2...9 {
                let path = (outputs as NSString).appendingPathComponent(String(format: "turn_%03d.md", turn))
                try? String(repeating: "Earlier turn \(turn) detail. ", count: 150).write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        let scripts: [ScriptedStreamRunner.Script] = [
            .init(lines: Self.initialTurn), .init(lines: Self.reasoningOnlyWithUsage), .init(lines: Self.freshAnswerWithUsage)
        ]
        let (measured, _, measuredContainer) = try await runFollowUp(scripts: scripts, configure: padHistory)
        defer { withExtendedLifetime(measuredContainer) {} }
        try #require(measured.prompts.count == 3)
        let full = AgentProcessMonitor.estimatedTokenCount(for: measured.prompts[2])

        // The full prompt fits the whole budget, but not what is left after the discarded attempt's 110 tokens.
        let (runner, task, container) = try await runFollowUp(scripts: scripts, configure: { worker, task in
            padHistory(worker, task)
            worker.budgetEnforcementModeOverride = .hardStop
            task.tokenBudget = full + 50
        })
        defer { withExtendedLifetime(container) {} }

        #expect(runner.nativeSessionIDs == [nil, "chat-xyz"])
        let latest = try #require(task.runs.max { $0.startedAt < $1.startedAt })
        #expect(latest.tokensUsed == 110)
    }

    @Test("A resumed turn that shows real output is not re-run")
    func realResumedTurnIsKept() async throws {
        let answered = [
            Self.freshAnswerTurn[0].replacingOccurrences(of: "chat-new", with: "chat-xyz"),
            Self.freshAnswerTurn[1].replacingOccurrences(of: "chat-new", with: "chat-xyz"),
            Self.freshAnswerTurn[2].replacingOccurrences(of: "chat-new", with: "chat-xyz")
        ]
        let (runner, task, container) = try await runFollowUp(scripts: [
            .init(lines: Self.initialTurn),
            .init(lines: answered)
        ])
        defer { withExtendedLifetime(container) {} }

        #expect(runner.nativeSessionIDs == [nil, "chat-xyz"])
        let latest = try #require(task.runs.max { $0.startedAt < $1.startedAt })
        #expect(latest.output.contains("4172"))
        #expect(task.sessionId == "chat-xyz")
    }

    @Test("A successful empty result without stop proof cannot launch a replacement")
    func missingStopProofBlocksFallback() async throws {
        let (runner, task, container) = try await runFollowUp(scripts: [
            .init(lines: Self.initialTurn),
            .init(lines: Self.reasoningOnlyTurn, providesStopProof: false),
            .init(lines: Self.freshAnswerTurn)
        ])
        defer { withExtendedLifetime(container) {} }
        #expect(runner.nativeSessionIDs == [nil, "chat-xyz"])
        let owner = try #require(try RuntimeExecutionOwner.existing(task: task, context: container.mainContext))
        #expect(!owner.canReplace)
        #expect(owner.resourcesReleased != true)
    }

    @Test("A reaped scripted child without a native final signal cannot authorize fallback")
    func missingNativeFinalBlocksFallback() async throws {
        let (runner, task, container) = try await runFollowUp(scripts: [
            .init(lines: Self.initialTurn),
            .init(lines: Array(Self.reasoningOnlyTurn.dropLast())),
            .init(lines: Self.freshAnswerTurn)
        ])
        defer { withExtendedLifetime(container) {} }
        #expect(runner.nativeSessionIDs == [nil, "chat-xyz"])
        let owner = try #require(try RuntimeExecutionOwner.existing(task: task, context: container.mainContext))
        #expect(owner.stopProof?.reaped == true)
        #expect(owner.stopProof?.toolsStopped == false)
        #expect(!owner.canReplace)
        #expect(owner.resourcesReleased != true)
    }

    @Test("A resumed turn that fails is not re-run")
    func failedResumedTurnIsNotRetried() async throws {
        let (runner, _, container) = try await runFollowUp(scripts: [
            .init(lines: Self.initialTurn),
            .init(lines: Self.reasoningOnlyTurn, exitCode: 1)
        ])
        defer { withExtendedLifetime(container) {} }
        #expect(runner.nativeSessionIDs == [nil, "chat-xyz"])
    }
}

final class ScriptedStreamRunner: AgentRuntimeProcessRunning {
    struct Script {
        var lines: [String]
        var exitCode = 0
        var providesStopProof = true
        var delayAfterStop: TimeInterval = 0
        var chargedTokens = 0
    }

    @MainActor private var owner: RuntimeExecutionOwner?
    @MainActor func configureExecutionOwner(_ owner: RuntimeExecutionOwner?) { self.owner = owner }
    private var scripts: [Script]
    private(set) var nativeSessionIDs: [String?] = []
    private(set) var maxRunSeconds: [TimeInterval?] = []
    private(set) var turnsAlreadyUsed: [Int] = []
    private(set) var tokensAlreadyUsed: [Int] = []
    private(set) var prompts: [String] = []

    init(scripts: [Script]) { self.scripts = scripts }

    func cancel() {}
    func isHostControlBrokerAvailable() -> Bool { true }

    @MainActor
    func runRuntimeProcess(
        adapter: any AgentRuntimeProcessLaunchPlanning & AgentRuntimeProcessEventParsing,
        prompt: String,
        task: AgentTask,
        workspacePath: String,
        executablePath: String,
        homeDirectory: String,
        permissionPolicy: PermissionPolicy,
        executionPolicy: AgentRuntimeExecutionPolicy,
        permissionManifest: RunPermissionManifest?,
        budgetEnforcementMode: BudgetEnforcementMode,
        timeoutSeconds: TimeInterval,
        phase: RunPhase,
        contextText: String,
        nativeContinuationSessionID: String?,
        runID: UUID?,
        launchResourcePlan: TaskLaunchResourcePlan?,
        capabilityResolutionSnapshot: TaskCapabilityResolutionSnapshot?,
        runtimeRequirements: TaskRuntimeRequirementSet?,
        liveApprovalsEnabled: Bool,
        noSemanticProgressTimeoutSeconds: TimeInterval?,
        maxRunSeconds: TimeInterval?,
        onInteractiveAsk: ((AgentInteractiveAskRequest) async -> InteractiveAskOutcome)?,
        onLine: @escaping (String, Bool) -> Void
    ) async -> AgentProcessResult {
        guard let owner, owner.isActive else {
            Issue.record("The scripted provider requires an active execution owner")
            return AgentProcessResult(exitCode: -1, error: "Fixture ownership missing")
        }
        guard !scripts.isEmpty else {
            Issue.record("The worker launched more attempts than the fixture supplied")
            return AgentProcessResult(exitCode: -1, error: "Fixture script missing")
        }
        nativeSessionIDs.append(nativeContinuationSessionID)
        self.maxRunSeconds.append(maxRunSeconds)
        turnsAlreadyUsed.append(executionPolicy.providerTurnsAlreadyUsed)
        tokensAlreadyUsed.append(executionPolicy.providerTokensAlreadyUsed)
        prompts.append(prompt)
        let script = scripts.removeFirst()
        // The fallback now needs an actual reaped child receipt. A scripted
        // success alone is deliberately insufficient to authorize replacement.
        // Arguments carry fixture JSON as data, never as executable shell text.
        let process = AgentExecutionScopedProcess(executablePath: "/bin/sh",
            arguments: ["-c", "printf '%s\\n' \"$@\"; exit \(script.exitCode)", "fixture"] + script.lines,
            currentDirectory: NSTemporaryDirectory(), environment: [:])
        let stdoutReader = AgentProcessPipeReader(process.stdoutFileHandle)
        let stderrReader = AgentProcessPipeReader(process.stderrFileHandle)
        let executionID: UUID
        do { try owner.prepareLaunch(sessionID: nativeContinuationSessionID); executionID = owner.record.executionID }
        catch { return AgentProcessResult(exitCode: -1, error: "Fixture ownership failed") }
        let exitCode = await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() }
            catch { owner.didNotLaunch(); continuation.resume(returning: -1); return }
            do { try owner.launched(process) }
            catch { Issue.record("The scripted child could not bind its execution owner"); process.terminate() }
        }
        var stdout = Data()
        let stdoutEOF = stdoutReader.finish { stdout.append($0) }
        stderrReader.finish { _ in }
        let evidence = RuntimeExecutionProcessEvidence(runtime: adapter.id)
        for line in String(decoding: stdout, as: UTF8.self).split(separator: "\n").map(String.init) {
            let events = adapter.parseProcessEvents(line: line, parsesJSONLines: true)
            evidence.observeFrame(line, parsesJSONLines: true, events: events)
            for event in events {
                if case .systemInit(_, let sessionID) = event { owner.session(sessionID) }
            }
            onLine(line, true)
        }
        evidence.processExited(naturally: process.naturalSuccessfulExit, stdoutEOF: stdoutEOF)
        let proof = script.providesStopProof
            ? process.stopProof(executionID: executionID, toolsStopped: evidence.toolsStopped, remoteWorkExcluded: owner.remoteWorkExcluded) : nil
        owner.stopped(proof: proof, turns: 1, tokens: script.chargedTokens, seconds: 0.05)
        if script.delayAfterStop > 0 { try? await Task.sleep(for: .seconds(script.delayAfterStop)) }
        var result = AgentProcessResult(exitCode: Int(exitCode))
        result.executionStopProof = proof
        result.executionTurnsSpent = 1
        result.executionTokensSpent = script.chargedTokens
        result.executionSecondsSpent = 0.05
        return result
    }
}

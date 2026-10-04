import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
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
    private static let freshAnswerTurn = [
        #"{"type":"system","subtype":"init","session_id":"chat-new","model":"Composer 2.5 Fast","permissionMode":"default"}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"4172"}]},"session_id":"chat-new"}"#,
        #"{"type":"result","subtype":"success","duration_ms":5,"is_error":false,"result":"4172","session_id":"chat-new"}"#
    ]

    /// Runs a Cursor task through its first turn and a follow-up whose native
    /// session exists, feeding the runner's scripts in order.
    private func runFollowUp(
        scripts: [ScriptedStreamRunner.Script]
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

        DirectWorkerLaunchAdmission.admitContinuation(task, modelContext: context)
        await worker.continueSession(task: task, message: "What number did I give you?", modelContext: context) { _ in }
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
    }

    private var scripts: [Script]
    private(set) var nativeSessionIDs: [String?] = []

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
        nativeSessionIDs.append(nativeContinuationSessionID)
        let script = scripts.isEmpty ? Script(lines: []) : scripts.removeFirst()
        for line in script.lines { onLine(line, true) }
        return AgentProcessResult(exitCode: script.exitCode)
    }
}

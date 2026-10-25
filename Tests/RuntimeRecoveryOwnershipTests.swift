import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@Suite("Durable recovery ownership", .serialized)
@MainActor
struct RuntimeRecoveryOwnershipTests {
    private func record(taskID: UUID, state: RuntimeExecutionOwnerRecord.State = .stopped) throws -> RuntimeExecutionOwnerRecord {
        let dead = RuntimeProcessIdentity(pid: Int32.max, startedSeconds: 1, startedMicroseconds: 1)
        let id = UUID()
        return .init(taskID: taskID, ownerID: UUID(), executionID: id,
            appProcess: try #require(RuntimeProcessIdentity.read(ProcessInfo.processInfo.processIdentifier)),
            providerProcess: dead, runtime: AgentRuntimeID.claudeCode.rawValue, sessionID: "original-session",
            state: state, limits: .init(tokenCeiling: 10000, turnsRemaining: 3, secondsRemaining: 45, tokensSpent: 600, costSpent: 0.2),
            stopProof: .init(executionID: id, process: dead, reaped: true, processGroupEmpty: true,
                toolsStopped: true, remoteWorkExcluded: true, capturedAt: Date()), resourceClaims: [], updatedAt: Date())
    }

    @Test("One kernel lease serializes different store objects and restores its journal")
    func exclusiveLease() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ownership-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let a = RuntimeExecutionOwnerStore(root: root), b = RuntimeExecutionOwnerStore(root: root)
        let id = UUID()
        var lease: RuntimeExecutionOwnerStore.Lease? = try a.acquire(taskID: id)
        let receipt = try record(taskID: id)
        try lease?.save(receipt)
        #expect(throws: (any Error).self) { try b.acquire(taskID: id) }
        #expect(try b.read(taskID: id) == receipt)
        lease = nil
        let restored = try b.acquire(taskID: id)
        #expect(try restored.read() == receipt)
    }

    @Test("Missing, stale, remote or incomplete proof never authorizes a replacement", arguments: ["missing", "execution", "process", "group", "tools", "remote", "live"])
    func stopProofMustBeComplete(fault: String) throws {
        var value = try record(taskID: UUID())
        let proof = try #require(value.stopProof)
        switch fault {
        case "missing": value.stopProof = nil
        case "execution": value.executionID = UUID()
        case "process": value.providerProcess = nil
        case "live": value.providerProcess = try #require(RuntimeProcessIdentity.read(ProcessInfo.processInfo.processIdentifier))
        default: value.stopProof = .init(executionID: proof.executionID, process: proof.process, reaped: true,
            processGroupEmpty: fault != "group", toolsStopped: fault != "tools", remoteWorkExcluded: fault != "remote", capturedAt: Date())
        }
        #expect(!value.canReplace)
        #expect(!RuntimeSessionInspection.inspect(value, ownedHere: false).canReplace)
    }

    @Test("Session inspection distinguishes work, input, completion and a proved stop")
    func sessionStates() throws {
        var value = try record(taskID: UUID())
        #expect(RuntimeSessionInspection.inspect(value, ownedHere: false).state == .stopped)
        value.state = .finished
        #expect(RuntimeSessionInspection.inspect(value, ownedHere: false).state == .finished)
        value.providerProcess = try #require(RuntimeProcessIdentity.read(ProcessInfo.processInfo.processIdentifier))
        value.state = .working
        #expect(RuntimeSessionInspection.inspect(value, ownedHere: true).state == .working)
        #expect(RuntimeSessionInspection.inspect(value, ownedHere: true).canReconnect)
        value.state = .waitingForInput
        #expect(RuntimeSessionInspection.inspect(value, ownedHere: true).state == .waitingForInput)
        #expect(!RuntimeSessionInspection.inspect(value, ownedHere: false).canReconnect)
    }

    @Test("Open or detached tools cannot be certified by a model or by silence")
    func toolEvidence() {
        let evidence = RuntimeExecutionProcessEvidence()
        #expect(!evidence.toolsStopped)
        evidence.observe(.text(text: "The model thinks all work stopped"))
        #expect(!evidence.toolsStopped)
        evidence.observe(.result(text: nil, costUSD: nil, totalInputTokens: 0, totalOutputTokens: 0, durationMs: nil, numTurns: 1, isError: false))
        #expect(evidence.toolsStopped)
        evidence.observe(.toolUse(name: "Bash", id: "tool-1", input: ["command": "sleep 60 &"]))
        evidence.observe(.toolResult(toolId: "tool-1", content: "Started", isError: false))
        #expect(!evidence.toolsStopped)
    }

    @Test("Known Cursor thinking completion is bookkeeping, but unfamiliar frames block proof")
    func cursorCompletionAndUnknownFrames() {
        let known = CursorStreamEventParser.parseAll(line: #"{"type":"thinking","subtype":"completed"}"#)
        #expect(known.count == 1)
        if case .control("thinking.completed") = known.first {} else { Issue.record("Thinking completion was not recognized") }
        let evidence = RuntimeExecutionProcessEvidence()
        evidence.observeFrame("not-json", parsesJSONLines: true, events: [.text(text: "unclassified")])
        evidence.observe(.result(text: nil, costUSD: nil, totalInputTokens: 0, totalOutputTokens: 0, durationMs: nil, numTurns: 1, isError: false))
        #expect(!evidence.toolsStopped)
    }

    @Test("Editing task settings cannot enlarge a recovery allowance")
    func changedSettingsCannotRefillRecovery() {
        let task = AgentTask(title: "Limits", goal: "Synthetic")
        task.tokenBudget = 1000000; task.maxTurns = 500
        var policy = AgentRuntimeExecutionPolicy.default
        policy.recoveryAllowance = .init(tokenCeiling: 1000, turnsRemaining: 2, secondsRemaining: 7, tokensSpent: 900, costSpent: 0)
        let allowance = AgentRuntimeProcessRunner.attemptAllowance(task: task, policy: policy)
        #expect(allowance.tokens == 100)
        #expect(allowance.turns == 2)
    }

    @Test("The owner freezes the admitted configuration rather than later task edits")
    func frozenLaunchLimits() throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Synthetic", model: "claude-sonnet-4-6", tokenBudget: 1000)
        task.maxTurns = 2
        let snapshot = AgentTaskLaunchSnapshot(task: task)
        task.tokenBudget = 100000; task.maxTurns = 50
        let admitted = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: task)
        let owner = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60, launchTask: admitted))
        defer { owner.finish() }
        #expect(owner.record.limits.tokenCeiling == 1000)
        #expect(owner.record.limits.turnsRemaining == 2)
    }

    @Test("Two contexts, Retry and automatic recovery share one execution owner", arguments: AgentRuntimeAdapterRegistry.runtimeIDs)
    func competingOwners(runtime: AgentRuntimeID) throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let task = h.makeTask(runtime: runtime, goal: "Synthetic", model: "claude-sonnet-4-6")
        task.status = .running
        let owner = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60))
        defer { owner.finish() }
        let run = TaskRun(task: task); h.context.insert(run)
        try owner.bind(run: run)
        let context = ModelContext(h.context.container)
        let other = try #require(try context.fetch(FetchDescriptor<AgentTask>()).first { $0.id == task.id })
        #expect(RuntimeExecutionOwner.acquire(task: other, context: context, maxRunSeconds: 60) == nil)
        if case .blocked = RuntimeExecutionOwner.retryDecision(task: task, context: h.context) {} else { Issue.record("Retry bypassed the owner") }
        #expect(task.runs.count == 1)
        #expect(!owner.authorizeAutomaticRestart())
    }

    @Test("ASTRA restart preserves an uncertain launch and blocks retry without resetting usage", arguments: AgentRuntimeAdapterRegistry.runtimeIDs)
    func startupDoesNotInventTermination(runtime: AgentRuntimeID) throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let task = h.makeTask(runtime: runtime, goal: "Synthetic", model: "claude-sonnet-4-6")
        task.status = .running; task.tokensUsed = 600
        let run = TaskRun(task: task); h.context.insert(run); try h.context.save()
        let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1, state: .running)
        request.runID = run.id
        h.context.insert(request); try h.context.save()
        #expect(TaskActivityPresentation.resolve(taskID: task.id, taskStatus: task.status, requests: [request.snapshot]).isRunning)
        var value = try record(taskID: task.id, state: .launching)
        value.runtime = runtime.rawValue; value.runID = run.id; value.providerProcess = nil; value.stopProof = nil
        do { let lease = try RuntimeExecutionOwner.store(in: h.context).acquire(taskID: task.id); try lease.save(value) }
        _ = TaskRunLifecycleService.recoverOrphanedRunningRuns(modelContext: h.context, autoExportWorkspaces: false)
        _ = TaskTurnRequestRecoveryService.recoverInterruptedRequests(modelContext: h.context, autoExportWorkspaces: false)
        #expect(run.status == .failed && run.typedStopReason == .runtimeConnectionLost)
        #expect(try RuntimeExecutionOwner.existing(task: task, context: h.context)?.stopProof == nil)
        #expect(TaskPresentationState.failedRunLabel(stopReason: run.stopReason) == "Connection lost")
        #expect(task.status == .pendingUser)
        #expect(request.state == .failed && request.terminalReason == "runtime_connection_lost")
        #expect(!TaskActivityPresentation.resolve(taskID: task.id, taskStatus: task.status, requests: [request.snapshot]).isRunning)
        let coordinator = TaskLifecycleCoordinator(modelContext: h.context, taskQueue: TaskQueue(poolSize: 0))
        #expect(coordinator.retryTask(task) == nil)
        #expect(task.tokensUsed == 600)
        #expect(task.runs.count == 1)
    }

    @Test("A proved retry inherits the original remaining limits and session", arguments: [RuntimeExecutionOwnerRecord.State.stopped, .finished])
    func remainingLimitsSurviveNewOwner(state: RuntimeExecutionOwnerRecord.State) throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Synthetic", model: "claude-sonnet-4-6")
        task.status = .running; task.tokensUsed = 600
        let previous = try record(taskID: task.id, state: state)
        do { let lease = try RuntimeExecutionOwner.store(in: h.context).acquire(taskID: task.id); try lease.save(previous) }
        let owner = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 999))
        defer { owner.finish() }
        #expect(owner.isRecovery)
        #expect(owner.record.limits == previous.limits)
        #expect(owner.record.sessionID == previous.sessionID)
        #expect(task.tokensUsed == 600)
        #expect(owner.record.ownerID != previous.ownerID)
    }

    @Test("An abandoned prelaunch recovery cannot refill limits or reuse a different provider's session")
    func prelaunchRecoveryRetainsLimits() throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Synthetic", model: "claude-sonnet-4-6")
        let previous = try record(taskID: task.id)
        do { let lease = try RuntimeExecutionOwner.store(in: h.context).acquire(taskID: task.id); try lease.save(previous) }
        let first = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 999))
        first.finish() // admission/preflight failed without launching
        let next = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 999))
        defer { next.finish() }
        #expect(next.record.limits == previous.limits)
        task.sessionId = nil
        next.restoreSession(for: .codexCLI)
        #expect(task.sessionId == nil)
        next.restoreSession(for: .claudeCode)
        #expect(task.sessionId == "original-session")
    }

    @Test("Manual Retry preserves usage and submits context continuation once")
    func manualRetryPreservesContextAndUsage() async throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Do the original work", model: "claude-sonnet-4-6")
        task.status = .failed; task.tokensUsed = 600; task.costUSD = 0.2; task.sessionId = "original-session"
        let run = TaskRun(task: task); run.status = .failed; h.context.insert(run)
        let value = try record(taskID: task.id)
        do { let lease = try RuntimeExecutionOwner.store(in: h.context).acquire(taskID: task.id); try lease.save(value) }
        let queue = TaskQueue(poolSize: 0)
        let coordinator = TaskLifecycleCoordinator(modelContext: h.context, taskQueue: queue)
        let pending = coordinator.retryTask(task)
        #expect(coordinator.retryTask(task) == nil)
        let requests = try TaskTurnRequestRepository.requests(for: task, in: h.context)
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        let source = try #require(task.events.first { $0.id == request.sourceEventID })
        let payload = try #require(ExecutionRequestSubmissionService.decodeSourcePayload(source))
        #expect(payload.launchMode == .continuation)
        #expect(payload.message?.hasPrefix("Continue where you left off") == true)
        #expect(task.tokensUsed == 600 && task.costUSD == 0.2)
        #expect(task.sessionId == "original-session")
        queue.cancelTurnRequest(id: request.id, workspace: task.workspace, modelContext: h.context)
        await pending?.value
        if let id = task.workspace?.id { await WorkspacePersistenceCoordinator.waitForPendingExport(workspaceID: id) }
    }

    @Test("Startup recognizes a settled completion only with its matching execution receipt")
    func settledCompletionAfterCrash() throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Synthetic", model: "claude-sonnet-4-6")
        task.status = .completed
        let run = TaskRun(task: task); run.status = .completed; h.context.insert(run)
        var value = try record(taskID: task.id, state: .unverified)
        value.runID = run.id
        do { let lease = try RuntimeExecutionOwner.store(in: h.context).acquire(taskID: task.id); try lease.save(value) }
        #expect(try RuntimeExecutionOwner.inspection(task: task, context: h.context)?.state == .finished)
        value.executionID = UUID()
        do { let lease = try RuntimeExecutionOwner.store(in: h.context).acquire(taskID: task.id); try lease.save(value) }
        #expect(try RuntimeExecutionOwner.inspection(task: task, context: h.context)?.state == .unknown)
    }

    @Test("Legacy app-restart runs with no stop receipt cannot be retried")
    func legacyRestartMissingReceipt() throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Synthetic", model: "claude-sonnet-4-6")
        task.status = .cancelled; task.tokensUsed = 600
        let run = TaskRun(task: task); run.status = .cancelled; run.stopReason = "app_restarted"; h.context.insert(run)
        #expect(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60) == nil)
        let coordinator = TaskLifecycleCoordinator(modelContext: h.context, taskQueue: TaskQueue(poolSize: 0))
        #expect(coordinator.retryTask(task) == nil)
        #expect(task.tokensUsed == 600 && task.runs.count == 1)
    }

    @Test("Explicit turns and Retry both require tool cleanup proof")
    func userTurnCannotBypassLiveExecutionOrRetryProof() throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Synthetic", model: "claude-sonnet-4-6")
        var value = try record(taskID: task.id, state: .unverified)
        let proof = try #require(value.stopProof)
        value.stopProof = .init(executionID: proof.executionID, process: proof.process, reaped: true,
            processGroupEmpty: true, toolsStopped: false, remoteWorkExcluded: false, capturedAt: Date())
        do { let lease = try RuntimeExecutionOwner.store(in: h.context).acquire(taskID: task.id); try lease.save(value) }
        if case .blocked = RuntimeExecutionOwner.retryDecision(task: task, context: h.context) {} else { Issue.record("Retry bypassed missing tool proof") }
        #expect(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60) == nil)
        #expect(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 999, newUserTurn: true) == nil)
        let preserved = try #require(try RuntimeExecutionOwner.existing(task: task, context: h.context))
        #expect(preserved.limits == value.limits)
        #expect(preserved.executionID == value.executionID)

    }

    @Test("A completed provider turn cannot grant Retry without tool termination proof")
    func completedTurnRetryRequiresToolProof() throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Synthetic", model: "claude-sonnet-4-6")
        task.status = .completed; task.tokensUsed = 600
        var value = try record(taskID: task.id, state: .finished)
        let proof = try #require(value.stopProof)
        value.stopProof = .init(executionID: proof.executionID, process: proof.process, reaped: true,
            processGroupEmpty: true, toolsStopped: false, remoteWorkExcluded: false, capturedAt: Date())
        do { let lease = try RuntimeExecutionOwner.store(in: h.context).acquire(taskID: task.id); try lease.save(value) }
        #expect(RuntimeSessionInspection.inspect(value, ownedHere: false).state == .unknown)
        #expect(!RuntimeSessionInspection.inspect(value, ownedHere: false).canReplace)
        let coordinator = TaskLifecycleCoordinator(modelContext: h.context, taskQueue: TaskQueue(poolSize: 0))
        #expect(coordinator.retryTask(task) == nil)
        #expect(task.tokensUsed == 600)
        #expect(try TaskTurnRequestRepository.requests(for: task, in: h.context).isEmpty)
        #expect(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60) == nil)
        #expect(RuntimeExecutionOwner.acquire(task: task, context: h.context,
            maxRunSeconds: 60, newUserTurn: true) == nil)
    }

    @Test("A failed validation keeps the unfinished task's limits after its provider completed")
    func providerCompletionIsNotTaskCompletion() throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Synthetic", model: "claude-sonnet-4-6")
        task.status = .failed
        let run = TaskRun(task: task); run.status = .completed; h.context.insert(run)
        var value = try record(taskID: task.id, state: .stopped)
        value.runID = run.id
        do { let lease = try RuntimeExecutionOwner.store(in: h.context).acquire(taskID: task.id); try lease.save(value) }
        #expect(try RuntimeExecutionOwner.existing(task: task, context: h.context)?.state == .stopped)
        let owner = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context,
            maxRunSeconds: 999, newUserTurn: true))
        defer { owner.finish() }
        #expect(owner.isRecovery && owner.record.limits == value.limits)
    }

    @Test("Losing a tracked task's journal never makes it a fresh unowned task")
    func missingTrackedJournalBlocks() throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Synthetic", model: "claude-sonnet-4-6")
        let owner = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60))
        let run = TaskRun(task: task); h.context.insert(run); try owner.bind(run: run)
        run.status = .failed; owner.finish()
        do {
            let lease = try RuntimeExecutionOwner.store(in: h.context).acquire(taskID: task.id)
            try FileManager.default.removeItem(at: lease.recordURL)
        }
        if case .blocked = RuntimeExecutionOwner.retryDecision(task: task, context: h.context) {} else { Issue.record("Missing receipt bypassed Retry") }
        #expect(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60, newUserTurn: true) == nil)
        #expect(task.runs.count == 1)
    }

    @Test("An unreadable journal never becomes an unowned task")
    func corruptJournalBlocks() throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Synthetic", model: "claude-sonnet-4-6")
        let store = RuntimeExecutionOwner.store(in: h.context)
        do { let lease = try store.acquire(taskID: task.id); try Data("broken".utf8).write(to: lease.recordURL) }
        #expect(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60) == nil)
        #expect(task.runs.isEmpty)
    }
}

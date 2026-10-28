import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import WorkspaceToolSupport
@testable import ASTRAPersistence
@testable import ASTRA

@Suite("Completed human turns retain execution ownership", .serialized)
@MainActor
struct RuntimeCompletedUserTurnContinuationTests {
    private func completed(_ task: AgentTask, context: ModelContext) throws -> RuntimeExecutionOwnerRecord {
        let run = TaskRun(task: task)
        run.status = .completed; run.typedStopReason = .completed; run.completedAt = Date()
        run.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encodeSnapshot(.host)
        context.insert(run); task.status = .completed
        var receipt = try RuntimeRecoveryTestReceipt.install(task: task, run: run, context: context, toolsStopped: false)
        receipt.state = .finished; receipt.settlementInProgress = false
        receipt.settlementLocalWorkStopped = true; receipt.settlementToolsStopped = true
        receipt.resourceClaims = TaskExecutionResourceAdmissionPolicy.lockClaims(for: nil, task: task,
            runMode: "previous", sandboxEnforcement: .off)
        receipt.providerSharedStateKey = "claude_code:original"
        try save(receipt, context: context); try context.save()
        return receipt
    }

    private func save(_ record: RuntimeExecutionOwnerRecord, context: ModelContext) throws {
        let lease = try RuntimeExecutionOwner.store(in: context).acquire(taskID: record.taskID, taskOwnerID: record.taskOwnerID)
        try lease.save(record)
    }

    private func followUp(_ task: AgentTask, context: ModelContext) throws -> TaskTurnRequest {
        let submission = try ExecutionRequestSubmissionService.submitFollowUp(message: "A new instruction", for: task, into: context).get()
        return try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: context))
    }

    @Test("A settled interrupted turn admits saved human input while retaining every fence", arguments:
        [TaskRunStopReason.repetitionDetected, .timeout, .maxBudgetReached, .failed, .runtimeConnectionLost])
    func interruptedTurnCanContinue(reason: TaskRunStopReason) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let task = h.makeTask(runtime: .copilotCLI, goal: "Preserve partial work", model: "test")
        var previous = try completed(task, context: h.context)
        let run = try #require(task.runs.first)
        let status: RunStatus = reason == .timeout ? .timeout : reason == .maxBudgetReached ? .budgetExceeded : .failed
        run.status = status; run.typedStopReason = reason; run.setOutput("Partial implementation and validation")
        task.status = .failed
        previous.state = .unverified; previous.inheritedToolUncertainty = true
        try save(previous, context: h.context)
        let request = try followUp(task, context: h.context)
        _ = TaskTurnRequestStateMachine.transition(request, to: .waitingForResource,
            blockingTaskID: task.id, blockerSummary: "Previous execution cleanup is not yet confirmed.")
        try h.context.save()
        _ = TaskTurnRequestRecoveryService.recoverInterruptedRequests(modelContext: h.context, autoExportWorkspaces: false)
        #expect(request.state.isActive && request.runID == nil)
        let permitted = RuntimeCompletedUserTurnContinuation.permits(task: task, request: request, context: h.context)
        #expect(permitted)
        guard permitted else { return }
        #expect(RuntimeRecoveryPresentation.blockedMessage(task: task, context: h.context) == nil)
        let queue = TaskQueue(poolSize: 0); queue.refreshResourceOwnership(in: h.context)
        let previousClaims = previous.resourceClaims ?? []
        queue.localResourceLocks = previousClaims
        queue.releaseResourceLocks(previousClaims, task: task, modelContext: h.context)
        #expect(queue.localResourceLocks.isEmpty)
        #expect(!queue.persistedResourceLocks.isEmpty)
        let claims = queue.resourceLockClaims(for: request, task: task, runMode: "continue")
        #expect(!queue.canAcquireResourceLocks(claims))
        #expect(queue.canAcquireResourceLocks(claims, task: task, context: h.context))
        let owner = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context,
            maxRunSeconds: 60, userRequest: request, resourceClaims: claims))
        defer { owner.finish() }
        #expect(owner.record.ownerID == previous.ownerID)
        #expect(owner.record.inheritedToolUncertainty == true)
        #expect(!owner.record.canReplace && owner.record.resourcesReleased == false)
        #expect(try RuntimeExecutionOwner.store(in: h.context).retainedExecutions(of: owner.record) == [previous])
        #expect(run.status == status && run.typedStopReason == reason)
        #expect(run.output == "Partial implementation and validation")
        let other = h.makeTask(runtime: .claudeCode, goal: "Competing", model: "test")
        #expect(RuntimeExecutionOwner.acquire(task: other, context: h.context, maxRunSeconds: 60) == nil)
    }

    @Test("Interrupted continuation still requires a bound stopped process and completed local settlement", arguments:
        ["live", "group", "unreaped", "settling", "children", "noEnd", "unknownEnvironment", "cancelled", "archive", "retry"])
    func interruptedTurnKeepsSafetyBoundaries(fault: String) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let task = h.makeTask(runtime: .copilotCLI, goal: "Partial work", model: "test")
        var receipt = try completed(task, context: h.context)
        let run = try #require(task.runs.first)
        run.status = .failed; run.typedStopReason = .repetitionDetected; task.status = .failed
        receipt.state = .unverified
        let request = try followUp(task, context: h.context)
        switch fault {
        case "live":
            let live = try #require(RuntimeProcessIdentity.read(ProcessInfo.processInfo.processIdentifier))
            receipt.providerProcess = live
            receipt.stopProof = .init(executionID: receipt.executionID, process: live,
                reaped: true, processGroupEmpty: true, toolsStopped: false,
                remoteWorkExcluded: true, capturedAt: Date())
        case "settling": receipt.settlementInProgress = true
        case "children": receipt.settlementLocalWorkStopped = false
        case "noEnd": run.completedAt = nil
        case "unknownEnvironment": run.executionEnvironmentSnapshotJSON = nil
        case "cancelled": receipt.cancellationRequested = true
        case "archive": receipt.retainedExecutionHead = UUID()
        case "retry": request.kind = .retry
        default:
            let proof = try #require(receipt.stopProof)
            receipt.stopProof = .init(executionID: proof.executionID, process: proof.process,
                reaped: fault != "unreaped", processGroupEmpty: fault != "group",
                toolsStopped: false, remoteWorkExcluded: true, capturedAt: Date())
        }
        try save(receipt, context: h.context); try h.context.save()
        #expect(!RuntimeCompletedUserTurnContinuation.permits(task: task, request: request, context: h.context))
        #expect(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60, userRequest: request) == nil)
        #expect(try RuntimeExecutionOwner.existing(task: task, context: h.context) == receipt)
    }

    @Test("The worker continues an interrupted task without changing its partial files or failed run")
    func workerContinuesInterruptedTurn() async throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Partial implementation", model: "claude-opus-5")
        var previous = try completed(task, context: h.context)
        let interrupted = try #require(task.runs.first)
        interrupted.status = .failed; interrupted.typedStopReason = .repetitionDetected
        interrupted.setOutput("Preserved partial implementation")
        task.status = .failed; previous.state = .unverified
        try save(previous, context: h.context)
        let partialFile = h.workspaceURL.appendingPathComponent("partial.sql")
        try Data("select 1;\n".utf8).write(to: partialFile)
        let path = try h.writeExecutable(named: "claude", script: HeadlessChatScenarioTests.claudeScript(body:
            "printf '%s\\n' '{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"Partial work is preserved.\",\"is_error\":false,\"num_turns\":1,\"usage\":{\"input_tokens\":10,\"output_tokens\":5}}'"))
        let worker = h.makeWorker(runtime: .claudeCode, executablePath: path, permissionPolicy: .autonomous)
        _ = await h.continueTask(task: task, message: "What is the status of this work?", worker: worker)
        #expect(task.status == .completed)
        #expect(task.runs.count == 2)
        #expect(interrupted.status == .failed && interrupted.typedStopReason == .repetitionDetected)
        #expect(interrupted.output == "Preserved partial implementation")
        #expect(try String(contentsOf: partialFile, encoding: .utf8) == "select 1;\n")
        let saved = try #require(try RuntimeExecutionOwner.existing(task: task, context: h.context))
        #expect(saved.ownerID == previous.ownerID && saved.inheritedToolUncertainty == true)
        #expect(try RuntimeExecutionOwner.store(in: h.context).retainedExecutions(of: saved) == [previous])
    }

    @Test("New human input keeps the owner, claims and immutable prior proof; retries remain blocked")
    func retainedOwner() throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Synthetic", model: "test")
        let previous = try completed(task, context: h.context)
        let request = try followUp(task, context: h.context)
        #expect(!previous.canReplace)
        #expect(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60, newUserTurn: true) == nil)
        #expect(RuntimeCompletedUserTurnContinuation.permits(task: task, request: request, context: h.context))
        let queue = TaskQueue(poolSize: 0)
        queue.refreshResourceOwnership(in: h.context)
        let claims = queue.resourceLockClaims(for: request, task: task, runMode: "continue")
        #expect(!queue.canAcquireResourceLocks(claims))
        #expect(queue.canAcquireResourceLocks(claims, task: task, context: h.context))
        let owner = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context,
            maxRunSeconds: 60, userRequest: request, resourceClaims: claims))
        defer { owner.finish() }
        #expect(owner.record.ownerID == previous.ownerID)
        #expect(owner.record.executionID != previous.executionID)
        #expect(owner.record.inheritedToolUncertainty == true)
        #expect(owner.record.retainedProviderSharedStateKeys == ["claude_code:original"])
        #expect(owner.record.continuingUserRequestID == request.id)
        let store = RuntimeExecutionOwner.store(in: h.context)
        #expect(try store.retainedExecutions(of: owner.record) == [previous])
        #expect(!owner.record.canReplace && owner.record.resourcesReleased == false)
        let other = h.makeTask(runtime: .claudeCode, goal: "Competing", model: "test")
        #expect(RuntimeExecutionOwner.acquire(task: other, context: h.context, maxRunSeconds: 60) == nil)
        owner.finish()
        let shared = AgentRuntimeSharedStateKey(runtime: .claudeCode, identifier: "original")
        #expect(throws: (any Error).self) {
            try RuntimeProviderResourceRegistry.assertAvailable(shared, ownerID: previous.ownerID, in: [store.root])
        }
        try RuntimeProviderResourceRegistry.assertAvailable(shared, ownerID: previous.ownerID,
            in: [store.root], reference: owner.providerOwnershipReference)
    }

    @Test("A retained pre-upgrade receipt stays immutable when its current journal is attributed")
    func retainedLegacyCrashCanContinue() throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Legacy retained receipt", model: "test")
        var previous = try completed(task, context: h.context)
        let store = RuntimeExecutionOwner.store(in: h.context)
        // Model an older build that had only the portable-ID journal.
        do {
            let scoped = try store.acquire(taskID: task.id, taskOwnerID: task.persistentModelID)
            try FileManager.default.removeItem(at: scoped.recordURL)
        }
        previous.taskOwnerID = nil
        do {
            let legacy = try store.acquire(taskID: task.id)
            try legacy.save(previous)
            try store.retain(previous) // crash before successor publication
        }
        h.context.insert(TaskEvent(task: task, eventType: TaskEventTypes.System.runtimeExecutionOwnership,
            payload: TaskEvent.payloadString(previous)))
        try h.context.save()
        let retainedURL = store.root.appendingPathComponent("retained").appendingPathComponent(task.id.uuidString)
            .appendingPathComponent(previous.ownerID.uuidString).appendingPathComponent(previous.executionID.uuidString + ".json")
        let before = try Data(contentsOf: retainedURL)
        let request = try followUp(task, context: h.context)
        let owner = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context,
            maxRunSeconds: 60, userRequest: request))
        defer { owner.finish() }
        #expect(owner.record.taskOwnerID == task.persistentModelID)
        #expect(owner.record.ownerID == previous.ownerID)
        #expect(try store.retainedExecutions(of: owner.record) == [previous])
        #expect(try Data(contentsOf: retainedURL) == before)
        var changed = previous
        changed.taskOwnerID = task.persistentModelID
        changed.limits.tokensSpent += 1
        #expect(throws: (any Error).self) { try store.retain(changed) }
    }

    @Test("An already consumed, cancelled, or unauthored request cannot continue", arguments: ["consumed", "cancelled", "retry", "failed", "timeout", "cancelOwner", "unsettled", "live", "group", "archive"])
    func rejected(fault: String) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Synthetic", model: "test")
        var receipt = try completed(task, context: h.context)
        let request = try followUp(task, context: h.context)
        switch fault {
        case "consumed": request.startedAt = Date()
        case "cancelled": _ = TaskTurnRequestStateMachine.transition(request, to: .cancelled, terminalReason: "cancelled_by_user")
        case "retry": request.kind = .retry
        case "failed": task.runs.first?.status = .failed
        case "timeout": task.runs.first?.typedStopReason = .timeout
        case "cancelOwner": receipt.cancellationRequested = true
        case "unsettled": receipt.settlementInProgress = true
        case "live": receipt.providerProcess = RuntimeProcessIdentity.read(ProcessInfo.processInfo.processIdentifier)
        case "archive": receipt.retainedExecutionHead = UUID()
        default:
            let proof = try #require(receipt.stopProof)
            receipt.stopProof = .init(executionID: proof.executionID, process: proof.process, reaped: true,
                processGroupEmpty: false, toolsStopped: false, remoteWorkExcluded: false, capturedAt: Date())
        }
        try save(receipt, context: h.context)
        #expect(!RuntimeCompletedUserTurnContinuation.permits(task: task, request: request, context: h.context))
        #expect(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60, userRequest: request) == nil)
    }

    @Test("Restart preserves a queued new instruction and a separately cancelled request")
    func restart() throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Synthetic", model: "test")
        let previous = try completed(task, context: h.context)
        let cancelled = try followUp(task, context: h.context)
        _ = TaskTurnRequestStateMachine.transition(cancelled, to: .cancelled, terminalReason: "cancelled_by_user")
        let pending = try followUp(task, context: h.context)
        _ = TaskTurnRequestStateMachine.transition(pending, to: .waitingForResource)
        try h.context.save()
        _ = TaskTurnRequestRecoveryService.recoverInterruptedRequests(modelContext: h.context, autoExportWorkspaces: false)
        #expect(pending.state.isActive && pending.runID == nil)
        #expect(cancelled.state == .cancelled && cancelled.terminalReason == "cancelled_by_user")
        #expect(try RuntimeExecutionOwner.existing(task: task, context: h.context) == previous)
        #expect(RuntimeRecoveryPresentation.blockedMessage(task: task, context: h.context) == nil)
    }

    @Test("Unlaunched human preparation resumes without refilling limits; launch intent still fences it", arguments: ["preparing", "notStarted", "bound", "launching"])
    func unlaunchedPreparation(phase: String) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Synthetic", model: "test")
        let prior = try completed(task, context: h.context)
        let request = try followUp(task, context: h.context)
        let first = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context,
            maxRunSeconds: 45, userRequest: request))
        var saved = first.record
        first.finish()
        saved.limits.turnsRemaining = 2; saved.limits.secondsRemaining = 12; saved.limits.tokensSpent = 700
        if phase == "notStarted" { saved.state = .notStarted }
        if phase == "launching" { saved.state = .launching }
        if phase == "bound" {
            let run = TaskRun(task: task); run.status = .running; h.context.insert(run)
            saved.runID = run.id
            let source = try #require(TaskHistoryRead.event(id: request.sourceEventID, in: task)); source.run = run
            _ = TaskTurnRequestStateMachine.transition(request, to: .admitted)
            _ = TaskTurnRequestStateMachine.transition(request, to: .running, runID: run.id)
        }
        try save(saved, context: h.context)
        let next = RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 900, userRequest: request)
        if phase == "launching" { #expect(next == nil); return }
        let admitted = try #require(next); defer { admitted.finish() }
        #expect(admitted.record.ownerID == prior.ownerID)
        #expect(admitted.record.limits == saved.limits)
        #expect(admitted.record.inheritedToolUncertainty == true)
        if phase == "bound" {
            admitted.finish()
            let repeated = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context,
                maxRunSeconds: 900, userRequest: request))
            #expect(repeated.record.limits == saved.limits)
            #expect(repeated.record.runID == saved.runID)
            repeated.finish()
        }
        #expect(try RuntimeExecutionOwner.store(in: h.context).retainedExecutions(of: admitted.record).map(\.executionID) == [saved.executionID, prior.executionID])
    }

    @Test("Committed settlement admits a new message even if finish never persisted", arguments: [RuntimeExecutionOwnerRecord.State.stopped, .unverified])
    func crashBeforeFinish(state: RuntimeExecutionOwnerRecord.State) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Synthetic", model: "test")
        var receipt = try completed(task, context: h.context)
        receipt.state = state; try save(receipt, context: h.context)
        let request = try followUp(task, context: h.context)
        task.status = .pendingUser
        let next = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context,
            maxRunSeconds: 60, userRequest: request))
        defer { next.finish() }
        #expect(next.record.ownerID == receipt.ownerID)
        #expect(try RuntimeExecutionOwner.store(in: h.context).retainedExecutions(of: next.record) == [receipt])
        #expect(!next.record.canReplace)
    }

    @Test("A new human instruction cannot supersede unsent preparation, but can follow a failed preflight")
    func newInstructionAfterPreflight() throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Synthetic", model: "test")
        _ = try completed(task, context: h.context)
        let firstRequest = try followUp(task, context: h.context)
        let first = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60, userRequest: firstRequest))
        first.finish()
        let nextRequest = try followUp(task, context: h.context)
        #expect(!RuntimeCompletedUserTurnContinuation.permits(task: task, request: nextRequest, context: h.context))
        _ = TaskTurnRequestStateMachine.transition(firstRequest, to: .failed, terminalReason: "preflight_failed")
        #expect(RuntimeCompletedUserTurnContinuation.permits(task: task, request: nextRequest, context: h.context))
    }

    @Test("Three tool-using continuations with SSH configured retain every execution")
    func workerContinuations() async throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        SSHConnectionManager.save([SSHConnection(name: "configured-unused", host: "unused.example.test",
            user: "fixture", remotePath: "/srv")], workspacePath: h.workspaceURL.path)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ProviderStreams/claude/foreground-tool-completion.jsonl")
        let localFixture = h.rootURL.appendingPathComponent("frames.jsonl")
        try FileManager.default.copyItem(at: fixture, to: localFixture)
        let path = try h.writeExecutable(named: "claude", script: HeadlessChatScenarioTests.claudeScript(body:
            "cat " + HeadlessChatScenarioTests.shQuote(localFixture.path)))
        let task = h.makeTask(runtime: .claudeCode, goal: "Synthetic tool turn", model: "claude-opus-5")
        let worker = h.makeWorker(runtime: .claudeCode, executablePath: path, permissionPolicy: .autonomous)
        let policy = AgentRuntimeExecutionPolicy.default.withRemoteSSHRoute(
            RemoteWorkspaceSSHRoute(targets: ["fixture@unused.example.test"], route: .nativeShell))
        var ownerID: UUID?
        for turn in 1...3 {
            _ = await h.continueTask(task: task, message: "Tool instruction \(turn)", worker: worker, executionPolicy: policy)
            if task.status != .completed {
                Issue.record("Turn \(turn): status=\(task.status.rawValue), runs=\(task.runs.map { $0.stopReason }), errors=\(task.events.filter { $0.type == "error" }.map(\.payload))")
                return
            }
            #expect(task.runs.count == turn)
            let receipt = try #require(try RuntimeExecutionOwner.existing(task: task, context: h.context))
            if let ownerID { #expect(receipt.ownerID == ownerID) } else { ownerID = receipt.ownerID }
            #expect(receipt.stopProof?.toolsStopped == false)
            #expect(!receipt.canReplace && receipt.resourcesReleased != true)
            #expect(RuntimeCompletedUserTurnContinuation.hasCompletedTurn(receipt, task: task, context: h.context))
            #expect(try RuntimeExecutionOwner.store(in: h.context).retainedExecutions(of: receipt).count == turn - 1)
        }
    }
}

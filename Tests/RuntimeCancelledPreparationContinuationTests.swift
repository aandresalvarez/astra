import Darwin
import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import WorkspaceToolSupport
@testable import ASTRAPersistence
@testable import ASTRA

@Suite("Cancelled preparation preserves human continuation", .serialized)
@MainActor
struct RuntimeCancelledPreparationContinuationTests {
    @Test("Cancelled preparation without a run requires its untouched human request and joined work", arguments:
        ["safe", "initial", "unjoined", "missingProof", "activeRequest", "consumed", "wrongSource", "retry"])
    func cancellationBeforeRun(fault: String) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let task = h.makeTask(runtime: .copilotCLI, goal: "Preparation only", model: "test")
        if fault != "initial" {
            let run = TaskRun(task: task); h.context.insert(run)
            run.status = .completed; run.typedStopReason = .completed; run.completedAt = Date()
            run.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encodeSnapshot(.host)
            task.status = .completed
            var prior = try RuntimeRecoveryTestReceipt.install(task: task, run: run, context: h.context, toolsStopped: false)
            prior.state = .finished; prior.settlementInProgress = false
            prior.settlementLocalWorkStopped = true; prior.settlementToolsStopped = true
            prior.resourceClaims = TaskExecutionResourceAdmissionPolicy.lockClaims(for: nil, task: task,
                runMode: "previous", sandboxEnforcement: .off)
            let lease = try RuntimeExecutionOwner.store(in: h.context).acquire(taskID: task.id, taskOwnerID: task.persistentModelID)
            try lease.save(prior)
        }
        let submitted = try ExecutionRequestSubmissionService.submitFollowUp(message: "Never launched", for: task, into: h.context).get()
        let request = try #require(try TaskTurnRequestRepository.request(id: submitted.requestID, in: h.context))
        let owner = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60, userRequest: request))
        let runsBefore = task.runs.count
        RuntimePrelaunchCancellation.settle(task: task, request: request, owner: owner,
            context: h.context, localWorkStopped: fault != "unjoined")
        owner.finish()
        #expect(request.state == .cancelled && request.runID == nil && request.startedAt == nil)
        #expect(task.runs.count == runsBefore)
        var saved = owner.record
        switch fault {
        case "missingProof": saved.settlementLocalWorkStopped = nil; saved.settlementToolsStopped = nil
        case "activeRequest": request.state = .admitted
        case "consumed": request.startedAt = Date()
        case "wrongSource": TaskHistoryRead.event(id: request.sourceEventID, in: task)?.type = "system.info"
        default: break
        }
        do {
            let lease = try RuntimeExecutionOwner.store(in: h.context).acquire(taskID: task.id, taskOwnerID: task.persistentModelID)
            try lease.save(saved)
        }
        let submittedNext = try ExecutionRequestSubmissionService.submitFollowUp(message: "New human instruction", for: task, into: h.context).get()
        let next = try #require(try TaskTurnRequestRepository.request(id: submittedNext.requestID, in: h.context))
        if fault == "retry" { next.kind = .retry }
        let successor = RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60, userRequest: next)
        #expect((successor != nil) == (fault == "safe" || fault == "initial"))
        successor?.finish()
    }

    @Test("Stop during an inherited help probe preserves a continuable, joined attempt", arguments: [false, true])
    func inheritedProbeCancellation(cancelCaller: Bool) async throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let task = h.makeTask(runtime: .antigravityCLI, goal: "Preserve partial work", model: "gemini-test")
        let original = TaskRun(task: task); h.context.insert(original)
        original.status = .completed; original.typedStopReason = .completed; original.completedAt = Date()
        original.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encodeSnapshot(.host)
        original.setOutput("Preserved implementation"); task.status = .completed
        var prior = try RuntimeRecoveryTestReceipt.install(task: task, run: original, context: h.context, toolsStopped: false)
        prior.state = .finished; prior.settlementInProgress = false
        prior.settlementLocalWorkStopped = true; prior.settlementToolsStopped = true
        prior.resourceClaims = TaskExecutionResourceAdmissionPolicy.lockClaims(for: nil, task: task,
            runMode: "previous", sandboxEnforcement: .off)
        let store = RuntimeExecutionOwner.store(in: h.context)
        do { let lease = try store.acquire(taskID: task.id, taskOwnerID: task.persistentModelID); try lease.save(prior) }
        let pidFile = h.rootURL.appendingPathComponent("probe.pid")
        let launched = h.rootURL.appendingPathComponent("provider-launched")
        let path = try h.writeExecutable(named: "agy", script: """
        #!/bin/sh
        if [ "$1" = "--help" ]; then
          trap '' TERM
          echo $$ > '\(pidFile.path)'
          exec /bin/sleep 30
        fi
        : > '\(launched.path)'
        printf '%s\\n' 'A continued answer.'
        """)
        let worker = h.makeWorker(runtime: .antigravityCLI, executablePath: path)
        worker.antigravityLaunchPreparation = AntigravityLaunchPreparation(defaults: InMemoryDefaults())
        let waiting = Task { await h.continueTask(task: task, message: "Will stop during preparation", worker: worker) }
        defer { waiting.cancel() }
        let started = await h.waitUntil(task: task, timeoutSeconds: 8) { _ in
            FileManager.default.fileExists(atPath: pidFile.path)
        }
        try #require(started)
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { if kill(pid, 0) == 0 { kill(pid, SIGKILL) } }
        if cancelCaller { waiting.cancel() } else { worker.cancel() }
        _ = await waiting.value
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        #expect(!FileManager.default.fileExists(atPath: launched.path))
        let saved = try #require(try RuntimeExecutionOwner.existing(task: task, context: h.context))
        #expect(saved.state == .notStarted && saved.cancellationRequested == true)
        #expect(saved.settlementInProgress == false && saved.settlementLocalWorkStopped == true
            && saved.settlementToolsStopped == true)
        #expect(saved.hasUnverifiedTools && saved.resourcesReleased != true)
        let submission = try ExecutionRequestSubmissionService.submitFollowUp(message: "Continue safely", for: task, into: h.context).get()
        let next = try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: h.context))
        #expect(RuntimeCompletedUserTurnContinuation.permits(task: task, request: next, context: h.context))
        let successor = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context,
            maxRunSeconds: 60, userRequest: next))
        defer { successor.finish() }
        #expect(successor.record.ownerID == prior.ownerID && successor.record.hasUnverifiedTools)
        #expect(original.output == "Preserved implementation")
        #expect(try store.retainedExecutions(of: successor.record).count == 2)
    }

    @Test("Stop after launch permits human input only with a joined local stop and its cancelled request", arguments:
        ["safe", "initial", "live", "settling", "activeRequest", "retry"])
    func settledCancellation(fault: String) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let task = h.makeTask(runtime: .antigravityCLI, goal: "Partial work", model: "test")
        let submission = try ExecutionRequestSubmissionService.submitFollowUp(message: "Original instruction", for: task, into: h.context).get()
        let request = try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: h.context))
        let run = TaskRun(task: task); h.context.insert(run)
        run.status = .cancelled; run.typedStopReason = .cancelled; run.completedAt = Date()
        run.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encodeSnapshot(.host)
        run.setOutput("Partial work retained")
        task.status = .cancelled
        _ = TaskTurnRequestStateMachine.transition(request, to: .admitted)
        _ = TaskTurnRequestStateMachine.transition(request, to: .running, runID: run.id)
        _ = TaskTurnRequestStateMachine.transition(request, to: .cancelled, terminalReason: "cancelled_by_user")
        TaskHistoryRead.event(id: request.sourceEventID, in: task)?.run = run
        var record = try RuntimeRecoveryTestReceipt.install(task: task, run: run, context: h.context, toolsStopped: false)
        record.cancellationRequested = true; record.continuingUserRequestID = request.id
        if fault == "initial" { record.continuingUserRequestID = nil }
        record.state = .unverified; record.settlementInProgress = false
        record.settlementLocalWorkStopped = true; record.settlementToolsStopped = true
        record.resourceClaims = TaskExecutionResourceAdmissionPolicy.lockClaims(for: nil, task: task,
            runMode: "cancelled", sandboxEnforcement: .off)
        if fault == "live" { record.providerProcess = RuntimeProcessIdentity.read(ProcessInfo.processInfo.processIdentifier) }
        if fault == "settling" { record.settlementInProgress = true }
        if fault == "activeRequest" { request.state = .running }
        do {
            let lease = try RuntimeExecutionOwner.store(in: h.context).acquire(taskID: task.id, taskOwnerID: task.persistentModelID)
            try lease.save(record)
        }
        let nextSubmission = try ExecutionRequestSubmissionService.submitFollowUp(message: "New instruction", for: task, into: h.context).get()
        let next = try #require(try TaskTurnRequestRepository.request(id: nextSubmission.requestID, in: h.context))
        if fault == "retry" { next.kind = .retry }
        let admitted = RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60, userRequest: next)
        #expect((admitted != nil) == (fault == "safe" || fault == "initial"))
        if let admitted {
            #expect(admitted.record.ownerID == record.ownerID && admitted.record.resourcesReleased == false)
            #expect(run.output == "Partial work retained" && run.status == .cancelled)
            admitted.finish()
        }
    }

    @Test("Stop before launch preserves history and allows a new message after reopening", arguments:
        ["safe", "launchIntent", "unsettled", "activeRequest", "missingArchive", "retry"])
    func cancelledPreparation(fault: String) throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let task = h.makeTask(runtime: .antigravityCLI, goal: "Preserve work", model: "test")
        let original = TaskRun(task: task)
        original.status = .completed; original.typedStopReason = .completed; original.completedAt = Date()
        original.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encodeSnapshot(.host)
        original.setOutput("Preserved implementation")
        h.context.insert(original); task.status = .completed
        var prior = try RuntimeRecoveryTestReceipt.install(task: task, run: original, context: h.context, toolsStopped: false)
        prior.state = .finished; prior.settlementInProgress = false
        prior.settlementLocalWorkStopped = true; prior.settlementToolsStopped = true
        prior.resourceClaims = TaskExecutionResourceAdmissionPolicy.lockClaims(for: nil, task: task,
            runMode: "previous", sandboxEnforcement: .off)
        let store = RuntimeExecutionOwner.store(in: h.context)
        do { let lease = try store.acquire(taskID: task.id, taskOwnerID: task.persistentModelID); try lease.save(prior) }
        let submission = try ExecutionRequestSubmissionService.submitFollowUp(message: "Implement recommendations", for: task, into: h.context).get()
        let request = try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: h.context))
        let owner = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60, userRequest: request))
        let cancelled = TaskRun(task: task); h.context.insert(cancelled)
        try owner.bind(run: cancelled)
        _ = TaskTurnRequestStateMachine.transition(request, to: .admitted)
        _ = TaskTurnRequestStateMachine.transition(request, to: .running, runID: cancelled.id)
        TaskHistoryRead.event(id: request.sourceEventID, in: task)?.run = cancelled
        owner.requestCancellation()
        try owner.beginSettlement(); try owner.completeSettlement(localWorkStopped: true, toolsStopped: true)
        cancelled.status = .cancelled; cancelled.typedStopReason = .cancelled; cancelled.completedAt = Date()
        _ = TaskTurnRequestStateMachine.transition(request, to: .cancelled, terminalReason: "cancelled_by_user")
        task.status = .cancelled; owner.finish()
        var saved = owner.record
        switch fault {
        case "launchIntent": saved.state = .launching
        case "unsettled": saved.settlementLocalWorkStopped = false
        case "activeRequest": request.state = .running
        case "missingArchive": saved.retainedExecutionHead = UUID()
        default: break
        }
        do { let lease = try store.acquire(taskID: task.id, taskOwnerID: task.persistentModelID); try lease.save(saved) }
        try h.context.save()
        // Reopen the database: imported UI state cannot grant admission.
        let reopened = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: Array(h.container.configurations))
        let context = reopened.mainContext
        let restored = try #require(try context.fetch(FetchDescriptor<AgentTask>()).first { $0.id == task.id })
        let nextSubmission = try ExecutionRequestSubmissionService.submitFollowUp(message: "Continue safely", for: restored, into: context).get()
        let next = try #require(try TaskTurnRequestRepository.request(id: nextSubmission.requestID, in: context))
        if fault == "retry" { next.kind = .retry }
        let permitted = RuntimeCompletedUserTurnContinuation.permits(task: restored, request: next, context: context)
        #expect(permitted == (fault == "safe"))
        let successor = RuntimeExecutionOwner.acquire(task: restored, context: context, maxRunSeconds: 60, userRequest: next)
        if fault != "safe" { #expect(successor == nil); return }
        let admitted = try #require(successor); defer { admitted.finish() }
        #expect(admitted.record.ownerID == prior.ownerID)
        #expect(admitted.record.inheritedToolUncertainty == true && !admitted.record.canReplace)
        let restoredOriginal = try #require(restored.runs.first { $0.id == original.id })
        let restoredCancelled = try #require(restored.runs.first { $0.id == cancelled.id })
        #expect(restoredOriginal.output == "Preserved implementation" && restoredOriginal.status == .completed)
        #expect(restoredCancelled.status == .cancelled)
        #expect(try store.retainedExecutions(of: admitted.record).count == 2)
        let other = h.makeTask(runtime: .antigravityCLI, goal: "Competing task", model: "test")
        #expect(RuntimeExecutionOwner.acquire(task: other, context: h.context, maxRunSeconds: 60) == nil)
    }

    @Test("Three Antigravity turns pass the local gate while retaining uncertain prior effects", .timeLimit(.minutes(1)))
    func sharedProviderWorkerContinuations() async throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        SSHConnectionManager.save([SSHConnection(name: "configured-unused", host: "unused.example.test",
            user: "fixture", remotePath: "/srv")], workspacePath: h.workspaceURL.path)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ProviderStreams/antigravity/answer-write-signoff.jsonl")
        let localFixture = h.rootURL.appendingPathComponent("frames.jsonl")
        try FileManager.default.copyItem(at: fixture, to: localFixture)
        let path = try h.writeExecutable(named: "agy", script: HeadlessChatScenarioTests.antigravityScript(body:
            "if [ \"$1\" = \"--help\" ]; then echo '--output-format'; exit 0; fi\ncat "
                + HeadlessChatScenarioTests.shQuote(localFixture.path)))
        let task = h.makeTask(runtime: .antigravityCLI, goal: "Synthetic turn", model: "gemini-test")
        let worker = h.makeWorker(runtime: .antigravityCLI, executablePath: path, permissionPolicy: .autonomous)
        let policy = AgentRuntimeExecutionPolicy.default.withRemoteSSHRoute(
            RemoteWorkspaceSSHRoute(targets: ["fixture@unused.example.test"], route: .nativeShell))
        var logicalOwner: UUID?
        for turn in 1...3 {
            _ = await h.continueTask(task: task, message: "Instruction \(turn)", worker: worker, executionPolicy: policy)
            #expect(task.status == .completed)
            guard task.status == .completed else {
                Issue.record("Turn \(turn): stops=\(task.runs.map(\.stopReason)), errors=\(task.events.filter { $0.type == "error" }.map(\.payload))")
                return
            }
            let receipt = try #require(try RuntimeExecutionOwner.existing(task: task, context: h.context))
            if let logicalOwner { #expect(receipt.ownerID == logicalOwner) } else { logicalOwner = receipt.ownerID }
            #expect(receipt.hasUnverifiedTools && receipt.resourcesReleased != true)
            #expect(try RuntimeExecutionOwner.store(in: h.context).retainedExecutions(of: receipt).count == turn - 1)
        }
        #expect(task.runs.count == 3)
        let preserved = h.workspaceURL.appendingPathComponent("preserved.sql")
        try Data("select 1;\n".utf8).write(to: preserved)
        let key = try AgentRuntimeSharedStateKey(runtime: .antigravityCLI,
            fileURL: AntigravityCLIRuntime.settingsURL(providerHomeDirectory:
                h.rootURL.appendingPathComponent("antigravity_cli-home").path))
        var blocker: ProviderSharedStateProcessLock? = try await ProviderSharedStateProcessLock.acquire(key)
        defer { withExtendedLifetime(blocker) {} }
        let waiting = Task { await h.continueTask(task: task, message: "Will be cancelled", worker: worker, executionPolicy: policy) }
        defer { waiting.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !task.events.contains(where: { $0.run?.id == task.runs.max(by: { $0.startedAt < $1.startedAt })?.id
            && $0.type == ProviderLaunchSignatureService.eventType }) || task.runs.count != 4 {
            guard ContinuousClock.now < deadline else { Issue.record("Worker never reached launch admission"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
        worker.cancel()
        _ = await waiting.value
        let cancelled = try #require(task.runs.max(by: { $0.startedAt < $1.startedAt }))
        #expect(cancelled.status == .cancelled && cancelled.output.isEmpty)
        let stopped = try #require(try RuntimeExecutionOwner.existing(task: task, context: h.context))
        #expect(stopped.providerProcess == nil && stopped.state == .notStarted)
        blocker = nil
        _ = await h.continueTask(task: task, message: "Continue after Stop", worker: worker, executionPolicy: policy)
        #expect(task.status == .completed && task.runs.count == 5)
        #expect(try String(contentsOf: preserved, encoding: .utf8) == "select 1;\n")
        #expect(cancelled.status == .cancelled)
        let final = try #require(try RuntimeExecutionOwner.existing(task: task, context: h.context))
        #expect(final.ownerID == logicalOwner && final.hasUnverifiedTools && final.resourcesReleased != true)
        #expect(try RuntimeExecutionOwner.store(in: h.context).retainedExecutions(of: final).count == 4)
    }
}

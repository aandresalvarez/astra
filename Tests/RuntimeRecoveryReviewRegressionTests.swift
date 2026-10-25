import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

/// Only fixtures that model an already-reaped execution may install a receipt.
/// Legacy/no-receipt tests deliberately do not use this helper.
@MainActor
enum RuntimeRecoveryTestReceipt {
    @discardableResult
    static func install(task: AgentTask, run: TaskRun?, context: ModelContext,
                        toolsStopped: Bool = true) throws -> RuntimeExecutionOwnerRecord {
        let dead = RuntimeProcessIdentity(pid: Int32.max, startedSeconds: 1, startedMicroseconds: 1)
        let executionID = UUID()
        let value = RuntimeExecutionOwnerRecord(taskID: task.id, ownerID: UUID(), executionID: executionID,
            runID: run?.id, appProcess: dead, providerProcess: dead,
            runtime: task.resolvedRuntimeID.rawValue, sessionID: task.sessionId,
            state: toolsStopped ? .stopped : .unverified,
            limits: .init(tokenCeiling: AgentRuntimeProcessRunner.effectiveTokenBudget(for: task),
                turnsRemaining: 4, secondsRemaining: 60, tokensSpent: max(400, task.tokensUsed), costSpent: 0.1),
            stopProof: .init(executionID: executionID, process: dead, reaped: true, processGroupEmpty: true,
                toolsStopped: toolsStopped, remoteWorkExcluded: true, capturedAt: Date()), resourceClaims: [], updatedAt: Date())
        let lease = try RuntimeExecutionOwner.store(in: context).acquire(taskID: task.id)
        try lease.save(value)
        return value
    }
}

@Suite("Recovery review regressions", .serialized)
@MainActor
struct RuntimeRecoveryReviewRegressionTests {
    @Test("Both Resume and Retry refuse the same unresolved tool receipt before queuing")
    func recoveryButtonsShareProof() throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Synthetic", model: "claude-sonnet-4-6")
        task.status = .failed; task.sessionId = "saved-session"; task.tokensUsed = 400
        let run = TaskRun(task: task); run.status = .failed; h.context.insert(run)
        let saved = try RuntimeRecoveryTestReceipt.install(task: task, run: run, context: h.context, toolsStopped: false)
        let coordinator = TaskLifecycleCoordinator(modelContext: h.context, taskQueue: TaskQueue(poolSize: 0))
        #expect(coordinator.retryTask(task) == nil)
        #expect(coordinator.resumeTask(task) == nil)
        #expect(try TaskTurnRequestRepository.requests(for: task, in: h.context).isEmpty)
        #expect(try RuntimeExecutionOwner.existing(task: task, context: h.context)?.ownerID == saved.ownerID)
        #expect(task.runs.count == 1 && task.tokensUsed == 400)
    }

    @Test("The durable source distinguishes approved work from recovery, regardless of phase")
    func admissionUsesSource() throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Synthetic", model: "claude-sonnet-4-6")
        let run = TaskRun(task: task); h.context.insert(run)
        let prior = try RuntimeRecoveryTestReceipt.install(task: task, run: run, context: h.context, toolsStopped: false)
        let plan = TaskPlanPayload(title: "Approved", goal: "Synthetic", steps: [.init(id: "one", title: "Step")])
        let permission = TaskPermissionContinuation.capture(task: task, run: run, modelContext: h.context, mode: .live)
        let submissions: [(Result<ExecutionRequestSubmissionService.Submission, ExecutionRequestSubmissionService.SubmissionError>, Bool)] = [
            (ExecutionRequestSubmissionService.submitResume(message: "Continue", for: task, into: h.context), false),
            (ExecutionRequestSubmissionService.submitRetry(message: "Continue", continuation: true, for: task, into: h.context), false),
            (ExecutionRequestSubmissionService.submitFollowUp(message: "New instruction", for: task, into: h.context), true),
            (ExecutionRequestSubmissionService.submitPlan(plan: plan, mode: .nextStep, mutation: .existingTask, for: task, into: h.context), true),
            (ExecutionRequestSubmissionService.submitPermissionResume(message: "Approved", executionPolicy: .default,
                for: task, into: h.context, continuation: permission, approvalID: "approval"), true)
        ]
        for (submission, permitted) in submissions {
            guard case .success(let submitted) = submission else { Issue.record("Submission failed"); continue }
            let request = try #require(try TaskTurnRequestRepository.request(id: submitted.requestID, in: h.context))
            let intent = RuntimeExecutionAdmission.resolve(request: request, task: task)
            #expect(intent.isNewUserTurn == permitted)
            let owner = RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 999,
                newUserTurn: intent.isNewUserTurn)
            #expect(owner == nil)
            #expect(try RuntimeExecutionOwner.existing(task: task, context: h.context)?.limits == prior.limits)
        }
        #expect(!RuntimeExecutionAdmission.resolve(request: nil, task: task).isNewUserTurn)
    }

    @Test("All legacy execution outcomes without a receipt block competing admission", arguments: ["failed", "cancelled", "timeout", "completed", "app_restarted"])
    func legacyReceiptsAreRequired(reason: String) throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Legacy", model: "claude-sonnet-4-6")
        task.status = .failed; task.tokensUsed = 400
        let run = TaskRun(task: task); run.status = .failed; run.stopReason = reason; h.context.insert(run)
        if case .blocked = RuntimeExecutionOwner.retryDecision(task: task, context: h.context) {} else { Issue.record("Legacy Retry was admitted") }
        #expect(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60, newUserTurn: true) == nil)
        #expect(task.tokensUsed == 400 && task.runs.count == 1)
    }

    @Test("An interrupted settlement cannot be reopened or cleared by a saved completion")
    func interruptedSettlementFencesEveryEntry() throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Synthetic", model: "claude-sonnet-4-6")
        let run = TaskRun(task: task); h.context.insert(run)
        try RuntimeRecoveryTestReceipt.install(task: task, run: run, context: h.context)
        let owner = try #require(RuntimeExecutionOwner.acquireSettlement(task: task, run: run, context: h.context).owner)
        try owner.beginSettlement()
        // This releases the live lease just as an app exit does, without a completion receipt.
        owner.finish()
        task.status = .completed; run.status = .completed; try h.context.save()
        let reopened = ModelContext(h.context.container)
        let recovered = try #require(try reopened.fetch(FetchDescriptor<AgentTask>()).first { $0.id == task.id })
        let receipt = try #require(try RuntimeExecutionOwner.existing(task: recovered, context: reopened))
        #expect(receipt.settlementInProgress == true)
        #expect(!receipt.canAcceptUserTurn && !receipt.canReplace)
        #expect(RuntimeExecutionOwner.acquireSettlement(task: task, run: run, context: h.context).owner == nil)
        #expect(RuntimeExecutionOwner.acquire(task: recovered, context: reopened, maxRunSeconds: 60, newUserTurn: true) == nil)
    }

    @Test("Validation commands are reaped, but arbitrary tools do not certify detached work")
    func validationLifetimeProof() async throws {
        let scope = RuntimeSettlementExecutionScope(mayLaunch: true)
        let result = await RuntimeSettlementExecutionScope.$current.withValue(scope) {
            await RuntimeValidationCommandRunner.run(path: "/bin/sh", arguments: ["-c", "sleep 0.1 & wait; printf VALIDATED"],
                environment: [:], directory: NSTemporaryDirectory(), timeout: 5)
        }
        #expect(result.exitCode == 0 && result.stdout == "VALIDATED")
        #expect(scope.localWorkStopped)
        #expect(!scope.toolsStopped)
        let timed = RuntimeSettlementExecutionScope(mayLaunch: true)
        let timeout = await RuntimeSettlementExecutionScope.$current.withValue(timed) {
            await RuntimeValidationCommandRunner.run(path: "/bin/sh", arguments: ["-c", "sleep 30"],
                environment: [:], directory: NSTemporaryDirectory(), timeout: 0.05)
        }
        #expect(timeout.timedOut && timed.localWorkStopped)
    }

    @Test("A new tool-free user turn cannot erase earlier detached-tool uncertainty")
    func uncertaintySurvivesOwnershipHandoff() throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Synthetic", model: "claude-sonnet-4-6")
        let previous = try RuntimeRecoveryTestReceipt.install(task: task, run: nil, context: h.context, toolsStopped: false)
        #expect(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60, newUserTurn: true) == nil)
        #expect(try RuntimeExecutionOwner.existing(task: task, context: h.context)?.limits == previous.limits)
        // A historical handoff's newer receipt cannot erase inherited tool uncertainty.
        var finished = previous
        finished.state = .finished
        finished.inheritedToolUncertainty = true
        finished.stopProof = .init(executionID: finished.executionID, process: previous.providerProcess!,
            reaped: true, processGroupEmpty: true, toolsStopped: true, remoteWorkExcluded: true, capturedAt: Date())
        do { let lease = try RuntimeExecutionOwner.store(in: h.context).acquire(taskID: task.id); try lease.save(finished) }
        #expect(!finished.canAcceptUserTurn && !finished.canReplace)
        if case .blocked = RuntimeExecutionOwner.retryDecision(task: task, context: h.context) {} else { Issue.record("Old tools were forgotten") }

    }

    @Test("A no-provider record cannot bypass unverified settlement work", arguments: [RuntimeExecutionOwnerRecord.State.notStarted, .preparing])
    func prelaunchStatesRespectSettlement(state: RuntimeExecutionOwnerRecord.State) throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Synthetic", model: "claude-sonnet-4-6")
        let run = TaskRun(task: task); h.context.insert(run)
        var saved = try RuntimeRecoveryTestReceipt.install(task: task, run: run, context: h.context)
        saved.state = state; saved.settlementLocalWorkStopped = false
        do { let lease = try RuntimeExecutionOwner.store(in: h.context).acquire(taskID: task.id); try lease.save(saved) }
        #expect(!saved.canRecoverPreparation && !saved.canAcceptUserTurn && !saved.canReplace)
        #expect(RuntimeExecutionOwner.acquireSettlement(task: task, run: run, context: h.context).owner == nil)
        #expect(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60, newUserTurn: true) == nil)
    }

    @Test("Legacy interrupted preparations retain inherited work", arguments: ["inherited", "settlement", "provider"])
    func legacyPreparationCannotForgetWork(fault: String) throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Synthetic", model: "test")
        var saved = try RuntimeRecoveryTestReceipt.install(task: task, run: nil, context: h.context)
        saved.state = .preparing
        if fault != "provider" { saved.providerProcess = nil }
        saved.stopProof = nil
        saved.inheritedToolUncertainty = fault == "inherited"
        saved.settlementToolsStopped = fault == "settlement" ? false : nil
        do { let lease = try RuntimeExecutionOwner.store(in: h.context).acquire(taskID: task.id); try lease.save(saved) }
        #expect(!saved.canRecoverPreparation)
        #expect(RuntimeResourceOwnership.retainsResources(saved))
        #expect(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60) == nil)
        #expect(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60, newUserTurn: true) == nil)
        if case .blocked = RuntimeExecutionOwner.retryDecision(task: task, context: h.context) {} else { Issue.record("Uncertain preparation admitted Retry") }
        #expect(try RuntimeExecutionOwner.existing(task: task, context: h.context)?.limits == saved.limits)
    }

    @Test("Recovery accounting saturates across attempts without refilling limits")
    func extremeRecoveryUsage() throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .openCodeCLI, goal: "Synthetic", model: "test")
        _ = try RuntimeRecoveryTestReceipt.install(task: task, run: nil, context: h.context)
        let owner = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60))
        defer { owner.finish() }
        owner.stopped(proof: nil, turns: 1, tokens: Int.max, seconds: 1)
        #expect(owner.record.limits.tokensSpent == Int.max)
        #expect(owner.record.limits.tokensRemaining == 0)
        #expect(!owner.authorizeAutomaticRestart())
        let run = TaskRun(task: task); h.context.insert(run); try owner.bind(run: run)
        run.tokensUsed = Int.max
        owner.finish()
        #expect(try RuntimeExecutionOwner.existing(task: task, context: h.context)?.limits.tokensSpent == Int.max)
    }

    @Test("Background objective assessment never inherits the closing validation scope")
    func independentAssessmentLifetime() async throws {
        let h = try HeadlessChatHarness()
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Synthetic", model: "claude-sonnet-4-6")
        let scope = RuntimeSettlementExecutionScope(mayLaunch: true)
        let assessment = RuntimeSettlementExecutionScope.$current.withValue(scope) {
            ObjectiveAssessmentService.schedule(task: task) { _ in
                #expect(RuntimeSettlementExecutionScope.current == nil)
                await Task.yield()
                #expect(RuntimeSettlementExecutionScope.current == nil)
            }
        }
        scope.seal()
        await assessment.value
        #expect(scope.localWorkStopped && scope.toolsStopped)
        #expect(throws: (any Error).self) { try scope.begin(UUID()) }
    }

    @Test("A busy kernel lease defers every startup recovery path without changing the live verdict")
    func competingStartupPreservesLiveOwner() async throws {
        let fixture = try PermissionApprovalContinuationTests.Fixture(disk: true)
        defer { fixture.cleanup() }
        let tests = RuntimeTurnSettlementTests()
        let (run, request) = try tests.runningTurn(fixture)
        tests.approval(fixture, run: run)
        try fixture.context.save()
        var busy: RuntimeExecutionOwnerStore.Lease? = try RuntimeExecutionOwner.store(in: fixture.context).acquire(taskID: fixture.task.id)
        let eventCount = fixture.task.events.count
        RuntimeTurnSettlementRecoveryService.prepare(modelContext: fixture.context, autoExport: false)
        #expect(!TaskRunLifecycleService.recoverOrphanedRunningRuns(modelContext: fixture.context, autoExportWorkspaces: false).hasChanges)
        #expect(!TaskTurnRequestRecoveryService.recoverInterruptedRequests(modelContext: fixture.context, autoExportWorkspaces: false).hasChanges)
        #expect(LivePermissionApprovalRecovery.recover(modelContext: fixture.context, autoExportWorkspaces: false) == 0)
        #expect(fixture.task.events.count == eventCount)
        #expect(fixture.task.status == .running && run.status == .running && request.state == .running)
        let checkpoint = tests.checkpoint(fixture, request: request)
        try RuntimeTurnSettlementService.capture(checkpoint, task: fixture.task, run: run, modelContext: fixture.context)
        let capturedCount = fixture.task.events.count
        #expect(!(await RuntimeTurnSettlementService.settle(checkpoint: checkpoint, task: fixture.task, run: run, modelContext: fixture.context)))
        let queue = TaskQueue(poolSize: 0)
        await RuntimeTurnSettlementRecoveryService.resume(modelContext: fixture.context, taskQueue: queue, autoExport: false)
        #expect(fixture.task.events.count == capturedCount)
        #expect(fixture.task.status == .running && run.status == .running && request.state == .running)
        #expect(RuntimeTurnSettlementService.verdict(for: run, task: fixture.task) == nil)
        #expect(try RuntimeTurnSettlementService.checkpoint(for: run, task: fixture.task) != nil)
        withExtendedLifetime(busy) {}
        busy = nil
        #expect(await RuntimeTurnSettlementService.settle(checkpoint: checkpoint, task: fixture.task, run: run, modelContext: fixture.context))
        #expect(RuntimeTurnSettlementService.verdict(for: run, task: fixture.task) != nil)
    }

    @Test("A superseded checkpoint cannot pause a newer owner")
    func staleSettlementDefers() async throws {
        let fixture = try PermissionApprovalContinuationTests.Fixture(disk: true)
        defer { fixture.cleanup() }
        let tests = RuntimeTurnSettlementTests()
        let (run, request) = try tests.runningTurn(fixture)
        let checkpoint = tests.checkpoint(fixture, request: request)
        try RuntimeTurnSettlementService.capture(checkpoint, task: fixture.task, run: run, modelContext: fixture.context)
        let newerRun = TaskRun(task: fixture.task)
        fixture.context.insert(newerRun)
        try RuntimeRecoveryTestReceipt.install(task: fixture.task, run: newerRun, context: fixture.context)
        let count = fixture.task.events.count
        #expect(!(await RuntimeTurnSettlementService.settle(checkpoint: checkpoint, task: fixture.task, run: run, modelContext: fixture.context)))
        #expect(fixture.task.events.count == count && fixture.task.status == .running)
        #expect(RuntimeTurnSettlementService.verdict(for: run, task: fixture.task) == nil)
    }

    @Test("Unresolved settlement retains exclusive ownership through its verdict save")
    func unresolvedSettlementHoldsLease() async throws {
        let fixture = try PermissionApprovalContinuationTests.Fixture(disk: true)
        defer { fixture.cleanup() }
        let tests = RuntimeTurnSettlementTests()
        let (run, request) = try tests.runningTurn(fixture)
        let checkpoint = tests.checkpoint(fixture, request: request)
        try RuntimeTurnSettlementService.capture(checkpoint, task: fixture.task, run: run, modelContext: fixture.context)
        do {
            let lease = try RuntimeExecutionOwner.store(in: fixture.context).acquire(taskID: fixture.task.id)
            var saved = try #require(try lease.read())
            saved.settlementInProgress = true
            try lease.save(saved)
        }
        var persisted = false
        let result = await RuntimeTurnSettlementService.settle(checkpoint: checkpoint, task: fixture.task, run: run,
            modelContext: fixture.context, verdictPersistence: {
                #expect(throws: (any Error).self) {
                    _ = try RuntimeExecutionOwner.store(in: fixture.context).acquire(taskID: fixture.task.id)
                }
                try fixture.context.save()
                persisted = true
            }, autoExport: false)
        #expect(result && persisted)
    }

    @Test("Malformed checkpoint recovery saves its error before releasing ownership")
    func malformedCheckpointPersistsFailure() async throws {
        let fixture = try PermissionApprovalContinuationTests.Fixture(disk: true)
        defer { fixture.cleanup() }
        let tests = RuntimeTurnSettlementTests()
        let (run, _) = try tests.runningTurn(fixture)
        fixture.context.insert(TaskEvent(task: fixture.task, eventType: TaskEventTypes.System.runtimeResultCaptured,
            payload: "{broken", run: run))
        try fixture.context.save()
        await RuntimeTurnSettlementRecoveryService.resume(modelContext: fixture.context, taskQueue: TaskQueue(poolSize: 0), autoExport: false)
        let (container, task) = try tests.reopen(fixture)
        defer { withExtendedLifetime(container) {} }
        #expect(task.status == .pendingUser)
        #expect(task.events.contains { $0.payload.contains("settlement could not be saved") })
        #expect(RuntimeTurnSettlementService.verdict(for: run, task: fixture.task) == nil)
    }

    @Test("Runless final validation cannot bypass an interrupted settlement barrier")
    func runlessPlanRetainsValidationBarrier() async throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Finalize", model: "claude-sonnet-4-6")
        let owner = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60))
        try owner.beginSettlement()
        owner.finish()
        let saved = try #require(try RuntimeExecutionOwner.existing(task: task, context: h.context))
        task.status = .queued
        let plan = TaskPlanPayload(title: "Already done", goal: "Finalize", steps: [
            TaskPlanPayloadStep(id: "done", title: "Done", status: .done)
        ])
        let worker = AgentRuntimeWorker()
        await worker.executeApprovedPlan(task: task, plan: plan, mode: .nextStep, modelContext: h.context) { _ in }
        #expect(task.status == .pendingUser && task.runs.isEmpty)
        #expect(!task.events.contains { $0.type == TaskPlanEventTypes.executionCompleted })
        let after = try #require(try RuntimeExecutionOwner.existing(task: task, context: h.context))
        #expect(after.ownerID == saved.ownerID && after.settlementInProgress == true)
    }

    @Test("Provider usage reconciliation cannot omit input or double-charge a resumed owner")
    func usageIsConservativeAndIdempotent() throws {
        let monitor = AgentProcessMonitor(tokenBudget: 10000)
        #expect(monitor.recoveryTokensConsumed(estimatedInputTokens: 900) >= 900)
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .antigravityCLI, goal: "Synthetic", model: "gemini-2.5-pro")
        let owner = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60))
        let run = TaskRun(task: task); h.context.insert(run); try owner.bind(run: run)
        run.tokensUsed = 1200
        owner.reconcileUsage(); owner.reconcileUsage()
        #expect(owner.record.limits.tokensSpent == 1200)
        owner.finish()
        #expect(try RuntimeExecutionOwner.existing(task: task, context: h.context)?.limits.tokensSpent == 1200)
    }
}

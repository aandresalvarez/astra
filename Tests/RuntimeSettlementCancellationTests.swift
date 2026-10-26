import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

@Suite("Settlement cancellation commits", .serialized)
@MainActor
struct RuntimeSettlementCancellationTests {
    @Test("Cancelling ordinary test validation cannot become a test failure or successful run")
    func ordinaryValidationCancellationWins() async throws {
        let h = try HeadlessChatHarness()
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Simple response", model: "test")
        task.status = .running; task.validationStrategy = .runTests; task.testCommand = "make test"
        let run = TaskRun(task: task); h.context.insert(run); run.setOutput("The response is ready.")
        try "test:\n\t@touch validation-started\n\t@sleep 10\n".write(to: h.workspaceURL.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
        let checkpoint = RuntimeTurnSettlementService.Checkpoint(requestID: nil, result: .init(exitCode: 0),
            runtime: .claudeCode, phase: .run, executionPath: h.workspaceURL.path,
            launchSnapshot: .init(task: task), permissionPolicy: .restricted, sandboxEnforcement: .off,
            verifierRuntime: .init(runtime: .claudeCode, claudePath: "/bin/false"), timeoutSeconds: 10,
            budgetEnforcementMode: BudgetEnforcementMode.hardStop.rawValue, effectiveTokenBudget: 200_000,
            tokensUsed: 0, agentReportedError: false, cancelled: false, failureDiagnostic: nil,
            approvedPlan: nil, chainedGoal: "", scheduleID: nil)
        let scope = RuntimeSettlementExecutionScope(mayLaunch: true)
        let work = Task { @MainActor in
            try await RuntimeSettlementExecutionScope.$current.withValue(scope) {
                try await RuntimeTurnOutcomeService.apply(checkpoint: checkpoint, task: task, run: run, modelContext: h.context)
            }
        }
        let marker = h.workspaceURL.appendingPathComponent("validation-started")
        for _ in 0..<500 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))
        scope.cancel()
        task.status = .cancelled
        try await work.value
        #expect(run.status == .cancelled)
        #expect(run.typedStopReason == .cancelled)
        #expect(!task.events.contains { $0.type == "system.error" || $0.type == "task.completed" })
    }

    @Test("Cancellation during origin lookup cannot emit completion")
    func originLookupCancellationWins() async throws {
        let h = try HeadlessChatHarness()
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Finish", model: "test")
        task.status = .running
        let run = TaskRun(task: task); h.context.insert(run)
        h.context.insert(TaskEvent(task: task, eventType: TaskEventTypes.Conversation.userMessage,
            payload: "Post a review on PR #12", run: run))
        var queried = false
        let result = await TaskSuccessfulCompletionService.apply(task: task, run: run, modelContext: h.context,
            successPayload: "Completed", permissionPolicy: .restricted, reviewOriginURL: { _ in
                queried = true
                task.status = .cancelled
                await Task.yield()
                return "https://github.com/example/repo"
            })
        #expect(queried)
        #expect(!result)
        #expect(!task.events.contains { $0.type == "task.completed" || $0.type == GitHubReviewPublicationEventTypes.targetBound })
        #expect(run.typedStopReason == .cancelled)
    }

    @Test("Queued writes from a retired execution are discarded at commit time")
    func retiredQueuedWritesAreDiscarded() async {
        var current = true
        var committed = 0
        let queue = OrderedMainActorTaskQueue { current }
        queue.add { committed += 1 }
        current = false
        await queue.drainAll()
        #expect(committed == 0)
    }

    @Test("Only the admitted successor can transfer the prior generation's provider pointer")
    func admittedSuccessorTransfersPointer() async throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .antigravityCLI, goal: "Successor", model: "test")
        let key = AgentRuntimeSharedStateKey(runtime: .antigravityCLI, identifier: UUID().uuidString)
        let root = h.rootURL.appendingPathComponent("provider-leases")
        let gate = AgentRuntimeSharedStateGate(processLockRoot: root,
            registeredStoreRoots: [RuntimeExecutionOwner.store(in: h.context).root])
        let firstAcquired = RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60)
        let first = try #require(firstAcquired)
        let lease = try await gate.acquire(key, owner: first)
        first.didNotLaunch(); first.finish()
        await gate.release(lease)
        let nextAcquired = RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60)
        let next = try #require(nextAcquired)
        defer { next.finish() }
        #expect(next.record.ownerID != first.record.ownerID)
        do {
            let unrelated = try await ProviderSharedStateProcessLock.acquire(key, root: root)
            #expect(throws: (any Error).self) { try unrelated.handoff(key, reference: nil, prepare: {}) }
        }
        let successor = try await gate.acquire(key, owner: next)
        #expect(next.record.providerSharedStateReleased == false)
        next.didNotLaunch(); next.finish()
        await gate.release(successor)
    }
}

extension RuntimeTurnSettlementTests {
    @Test("A prepared successful result becomes a cancelled verdict after the user stops settlement")
    func preparedResultCancellationWins() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let (run, request) = try runningTurn(fixture)
        let captured = checkpoint(fixture, request: request)
        run.status = .completed; run.typedStopReason = .completed; fixture.task.status = .completed
        RuntimeSettlementProgress.stagePrepared(task: fixture.task, run: run, modelContext: fixture.context)
        fixture.task.status = .cancelled
        _ = TaskTurnRequestStateMachine.transition(request, to: .cancelled, terminalReason: "cancelled")
        try fixture.context.save()
        let settled = await RuntimeTurnSettlementService.settle(checkpoint: captured, task: fixture.task,
            run: run, modelContext: fixture.context, autoExport: false)
        #expect(settled)
        #expect(run.status == .cancelled)
        #expect(run.typedStopReason == .cancelled)
        #expect(request.state == .cancelled)
        #expect(RuntimeTurnSettlementService.verdict(for: run, task: fixture.task)?.requestState == .cancelled)
    }
}

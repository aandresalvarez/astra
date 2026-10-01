import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

extension PermissionApprovalContinuationTests {
    @Test("Rerouted approvals use the actual provider without changing editable task configuration", arguments: [false, true])
    func reroutedApprovalUsesRunRuntime(futureUse: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try reroutePermissionRequest(fixture, futureUse: futureUse)
        let outcome = PermissionApprovalResolutionService.approve(task: fixture.task, scope: .task, modelContext: fixture.context)
        if futureUse {
            guard case .saved = outcome else { Issue.record("Rerouted future-use authority was not saved"); return }
        } else {
            guard case .queued(let submission) = outcome else { Issue.record("Rerouted approval was rejected"); return }
            let resumed = try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: fixture.context))
            #expect(resumed.runtimeIDSnapshot == AgentRuntimeID.claudeCode.rawValue)
        }
        #expect(fixture.task.resolvedRuntimeID == .codexCLI)
        #expect(TaskRuntimePermissionGrants.approvedCredentialLabels(for: fixture.task, runtime: .claudeCode) == [fixture.label])
        #expect(TaskRuntimePermissionGrants.approvedCredentialLabels(for: fixture.task, runtime: .codexCLI).isEmpty)
        #expect(!TaskRuntimePermissionOpenRequestStore.hasOpenRequest(for: fixture.task))
    }

    @Test("Live approval of a rerouted provider resolves its waiter instead of denying it as stale")
    func reroutedLiveApprovalUsesRunRuntime() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup(); InFlightPermissionCenter.shared.failAll(taskID: fixture.task.id) }
        _ = try reroutePermissionRequest(fixture)
        let payload = try #require(TaskRuntimePermissionOpenRequestStore.latestRequestPayload(for: fixture.task))
        let requestID = try #require(PermissionApprovalEventPayload.decoded(from: payload)?.requestID)
        let waiter = Task { await InFlightPermissionCenter.shared.awaitDecision(taskID: fixture.task.id,
            ask: .init(requestID: requestID, toolName: "Jira", inputSummary: nil)) }
        for _ in 0..<100 where InFlightPermissionCenter.shared.pendingAsks(taskID: fixture.task.id).isEmpty {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard case .live = PermissionApprovalResolutionService.approve(task: fixture.task, scope: .task,
            modelContext: fixture.context) else { Issue.record("Rerouted live approval rejected"); return }
        #expect(await waiter.value)
        #expect(fixture.task.events.contains { $0.type == TaskEventTypes.Tool.permissionLiveApprovalCommitted.rawValue })
    }

    @Test("Restart recovery for a rerouted run keeps its provider and one-time grants")
    func reroutedRecoveryUsesRunRuntime() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let binding = try reroutePermissionRequest(fixture)
        LivePermissionApprovalRecovery.record(binding: binding, requestID: "rerouted-recovery", runtime: .claudeCode,
            grants: [.credential(label: fixture.label)], taskScope: false, task: fixture.task, modelContext: fixture.context)
        try fixture.context.save()
        #expect(LivePermissionApprovalRecovery.recover(modelContext: fixture.context, autoExportWorkspaces: false) == 1)
        let resumed = try #require(try TaskTurnRequestRepository.requests(for: fixture.task, in: fixture.context).last)
        #expect(resumed.runtimeIDSnapshot == AgentRuntimeID.claudeCode.rawValue)
        let source = try #require(fixture.task.events.first { $0.id == resumed.sourceEventID })
        #expect(ExecutionRequestSubmissionService.decodeSourcePayload(source)?.executionPolicyOverride?.permissionGrants == [.credential(label: fixture.label)])
        #expect(LivePermissionApprovalRecovery.recover(modelContext: fixture.context, autoExportWorkspaces: false) == 0)
    }

    @Test("A task's next-runtime setting cannot invalidate authority for its current run")
    func taskRuntimeEditDoesNotInvalidateRunApproval() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.blockedRequest()
        fixture.task.runtimeID = AgentRuntimeID.claudeCode.rawValue
        guard case .queued(let submission) = PermissionApprovalResolutionService.approve(task: fixture.task, scope: .once,
            modelContext: fixture.context) else { Issue.record("Recorded run authority was rejected"); return }
        let resumed = try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: fixture.context))
        #expect(resumed.runtimeIDSnapshot == AgentRuntimeID.codexCLI.rawValue)
        #expect(fixture.task.resolvedRuntimeID == .claudeCode)
    }

    @Test("A failed permission-promotion save releases the pool slot so approval can continue its task")
    func failedPromotionReleasesWorker() async throws {
        let fixture = try Fixture(runtime: .claudeCode)
        defer { fixture.cleanup() }
        let runner = CredentialBlockedRunner(connectorID: fixture.connectorID)
        let worker = AgentRuntimeWorker(processRunner: runner, providerSettingsSnapshotProvider: { .headlessScenario })
        worker.runtimeReadinessService = RuntimeReadinessService(runner: InstantSuccessBinaryRunner())
        enum Failure: Error { case save }
        worker.permissionPromotionPersistence = { throw Failure.save }
        let queue = TaskQueue(poolSize: 1, workerFactory: { worker }, sandboxEnforcementProvider: { .off })
        defer { queue.cancelAll() }
        queue.applySettings(claudePath: "/bin/sh", defaultRuntimeID: .claudeCode,
            timeoutSeconds: 10, validationModel: "claude-sonnet-4-6", defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue)
        _ = TaskStateMachine.enqueueFromUITestSeed(fixture.task, modelContext: fixture.context)
        guard case .success(let initial) = ExecutionRequestSubmissionService.submitInitial(for: fixture.task,
            into: fixture.context) else { Issue.record("Initial request not submitted"); return }
        await queue.signalExecutionRequest(id: initial.requestID, task: fixture.task, modelContext: fixture.context).value
        #expect(!worker.isRunning)
        #expect(fixture.task.status == .pendingUser)
        #expect(fixture.task.events.contains { $0.type == TaskEventTypes.System.error.rawValue && $0.payload.contains("permission pause could not be saved") })
        let first = try #require(try TaskTurnRequestRepository.request(id: initial.requestID, in: fixture.context))
        #expect(first.state == .failed)
        worker.permissionPromotionPersistence = nil
        guard case .queued(let submission) = PermissionApprovalResolutionService.approve(task: fixture.task, scope: .once,
            modelContext: fixture.context) else { Issue.record("Saved pause could not resume"); return }
        await queue.signalExecutionRequest(id: submission.requestID, task: fixture.task, modelContext: fixture.context).value
        #expect(runner.launchCount == 2)
        #expect(fixture.task.status == .completed)
        #expect(!worker.isRunning)
    }

    private func reroutePermissionRequest(_ fixture: Fixture, futureUse: Bool = false) throws -> PermissionApprovalContinuation {
        let binding = try fixture.blockedRequest()
        let run = try #require(fixture.task.runs.first)
        run.runtimeID = AgentRuntimeID.claudeCode.rawValue
        let event = try #require(fixture.task.events.first { $0.type == TaskEventTypes.Tool.permissionApprovalRequested.rawValue })
        var approval = try #require(PermissionApprovalEventPayload.decoded(from: event.payload))
        approval.providerID = .claudeCode
        if futureUse { approval.behavior = .futureUse }
        let payload = try #require(approval.encodedString())
        event.payload = payload
        TaskRuntimePermissionOpenRequestStore.recordOpenRequest(payload: payload, task: fixture.task)
        try fixture.context.save()
        return binding
    }
}

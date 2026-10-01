import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

extension PermissionApprovalContinuationTests {
    @Test("Settlement saves acknowledgement after a transient receipt failure, surviving restart")
    func settlementAcknowledgementSurvivesRestart() throws {
        let fixture = try Fixture(disk: true)
        defer { fixture.cleanup() }
        let binding = try fixture.blockedRequest(completed: true)
        let run = try #require(fixture.task.runs.first)
        LivePermissionApprovalRecovery.record(binding: binding, requestID: "receipt-retry", runtime: .codexCLI,
            grants: [.credential(label: fixture.label)], taskScope: false, task: fixture.task, modelContext: fixture.context)
        try fixture.context.save()
        enum Failure: Error { case save }
        #expect(!LivePermissionApprovalRecovery.recordDelivery(requestID: "receipt-retry", toolName: "Jira",
            task: fixture.task, run: run, modelContext: fixture.context, persist: { throw Failure.save }))
        let request = try #require(try TaskTurnRequestRepository.requests(for: fixture.task, in: fixture.context).first)
        PersistedTurnRuntimeEventLinker.finishRuntime(request: request, run: run, task: fixture.task,
            acknowledgedPermissionRequestIDs: ["receipt-retry"], in: fixture.context)
        let reopened = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(url: fixture.storeURL)])
        let id = fixture.task.id
        let saved = try #require(try reopened.mainContext.fetch(FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == id })).first)
        #expect(saved.events.filter { $0.type == TaskEventTypes.Tool.permissionApprovalDelivered.rawValue }.count == 1)
        #expect(LivePermissionApprovalRecovery.recover(modelContext: reopened.mainContext, autoExportWorkspaces: false) == 0)
        #expect(!saved.events.contains { $0.type == TaskEventTypes.ExecutionRequest.permissionResume.rawValue })
    }

    @Test("Promotion persistence failure is reported before asynchronous handoff can start")
    func promotionSaveFailureThrows() throws {
        let fixture = try Fixture(disk: true)
        defer { fixture.cleanup() }
        _ = try fixture.blockedRequest()
        let run = try #require(fixture.task.runs.first)
        let binding = TaskPermissionContinuation.capture(task: fixture.task, run: run, modelContext: fixture.context)
        let raw = fixture.payload(requestID: "connector-credentials-\(fixture.connectorID.uuidString.lowercased())", behavior: .futureUse)
        let payload = TaskPermissionContinuation.attach(raw, continuation: binding, behavior: .futureUse)
        TaskRuntimePermissionOpenRequestStore.recordOpenRequest(payload: payload, task: fixture.task)
        fixture.task.status = .running
        run.status = .running
        try fixture.context.save()
        enum Failure: Error { case save }
        var handoffStarted = false
        do {
            _ = try TaskPermissionContinuation.applyBlockingOutcomeIfNeeded(task: fixture.task, run: run,
                modelContext: fixture.context, persist: { throw Failure.save })
            handoffStarted = true
        } catch Failure.save {}
        #expect(!handoffStarted)
        #expect(fixture.task.status == .pendingUser)
        #expect(run.typedStopReason == .permissionApprovalRequired)
    }

    @Test("Compatibility presentation and approval select the latest unresolved request")
    func compatibilitySelectsUnresolvedRequest() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.task.runtimePermissionOpenRequestsJSON = nil
        let first = fixture.payload(requestID: "still-open", behavior: .futureUse)
        let second = PermissionBroker.approvalPayload(providerID: .codexCLI, request: .tool(name: "Write", context: nil),
            reason: "Write approval", grants: [.tool(name: "Write")], requestID: "already-closed").encodedString()!
        for (index, payload) in [first, second].enumerated() {
            let event = TaskEvent(task: fixture.task, type: "permission.approval.requested", payload: payload)
            event.timestamp = Date().addingTimeInterval(Double(index - 10))
            fixture.context.insert(event)
        }
        fixture.context.insert(TaskEvent(task: fixture.task, type: "permission.request.resolved",
            payload: PermissionRequestResolution(requestID: "already-closed", approved: true, toolName: "Write").payloadString))
        #expect(TaskRuntimePermissionOpenRequestStore.latestRequestPayload(for: fixture.task) == first)
        #expect(TaskRuntimePermissionOpenRequestStore.state(for: fixture.task).latestRequestPayload == first)
        #expect(TaskRuntimePermissionOpenRequestStore.latestApprovalGrants(for: fixture.task) == [.credential(label: fixture.label)])
        #expect(TaskRuntimePermissionOpenRequestStore.latestRequestedToolName(for: fixture.task) == "Connector credentials")
        guard case .saved = PermissionApprovalResolutionService.approve(task: fixture.task, scope: .task,
            modelContext: fixture.context) else { Issue.record("Expected saved connector authority"); return }
        #expect(!TaskRuntimePermissionOpenRequestStore.hasOpenRequest(for: fixture.task))
        #expect(TaskRuntimePermissionGrants.approvedCredentialLabels(for: fixture.task, runtime: .codexCLI) == [fixture.label])
        #expect(!fixture.task.events.contains { $0.type == TaskEventTypes.ExecutionRequest.permissionResume.rawValue })
    }

    @Test("Legacy connector offers resume only a recorded permission stop", arguments: ["timeout", "error", "completed", "permission"])
    func legacyOffersFollowRecordedStop(reason: String) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.blockedRequest(completed: true, legacy: true)
        let run = try #require(fixture.task.runs.first)
        switch reason {
        case "timeout": run.status = .timeout; run.typedStopReason = .timeout
        case "error": run.status = .failed; run.typedStopReason = .agentReportedError
        case "completed": run.status = .completed; run.typedStopReason = .completed
        default: run.status = .failed; run.typedStopReason = .permissionApprovalRequired
        }
        fixture.task.status = reason == "permission" ? .pendingUser : .failed
        let outcome = PermissionApprovalResolutionService.approve(task: fixture.task, scope: .task, modelContext: fixture.context)
        if reason == "permission" {
            guard case .queued = outcome else { Issue.record("Permission-stopped offer must continue"); return }
        } else {
            guard case .saved = outcome else { Issue.record("Nonblocking legacy offer must only save authority"); return }
            #expect(fixture.task.status == .failed)
            #expect(!fixture.task.events.contains { $0.type == TaskEventTypes.ExecutionRequest.permissionResume.rawValue })
        }
    }

    @Test("An unwritten live response is retried before approved-plan fallback can complete the step",
          arguments: [TaskPlanExecutionMode.fullPlan, .nextStep])
    func undeliveredPlanApprovalRetries(mode: TaskPlanExecutionMode) async throws {
        let fixture = try Fixture(runtime: .claudeCode)
        defer { fixture.cleanup(); InFlightPermissionCenter.shared.failAll(taskID: fixture.task.id) }
        let runner = CredentialBlockedRunner(connectorID: fixture.connectorID, failLiveDelivery: true,
            providerCompletedWithoutReceipt: true, liveAskToolName: "WebSearch", acknowledgeResponse: false)
        let queue = TaskQueue(poolSize: 1, workerFactory: {
            let worker = AgentRuntimeWorker(processRunner: runner, providerSettingsSnapshotProvider: { .headlessScenario })
            worker.runtimeReadinessService = RuntimeReadinessService(runner: InstantSuccessBinaryRunner())
            return worker
        }, sandboxEnforcementProvider: { .off })
        defer { queue.cancelAll() }
        queue.applySettings(claudePath: "/bin/sh", defaultRuntimeID: .claudeCode,
            timeoutSeconds: 10, validationModel: "claude-sonnet-4-6", defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue)
        let plan = TaskPlanPayload(title: "Inspect tickets", goal: "Answer the ticket question",
            steps: [.init(id: "step-1", title: "Inspect tickets", likelyTools: ["Jira"])])
        TaskPlanService.recordCreated(plan, task: fixture.task, modelContext: fixture.context)
        guard case .success(let initial) = ExecutionRequestSubmissionService.submitPlan(plan: plan,
            mode: mode, mutation: .existingTask, for: fixture.task, into: fixture.context) else { Issue.record("Plan not submitted"); return }
        let handle = queue.signalExecutionRequest(id: initial.requestID, task: fixture.task, modelContext: fixture.context)
        for _ in 0..<200 where InFlightPermissionCenter.shared.pendingAsks(taskID: fixture.task.id).isEmpty {
            try await Task.sleep(for: .milliseconds(25))
        }
        guard case .live = PermissionApprovalResolutionService.approve(task: fixture.task, scope: .once,
            modelContext: fixture.context) else { Issue.record("Expected live approval"); return }
        await handle.value
        let resumed = try #require(try TaskTurnRequestRepository.requests(for: fixture.task, in: fixture.context).last)
        #expect(resumed.id != initial.requestID)
        await queue.signalExecutionRequest(id: resumed.id, task: fixture.task, modelContext: fixture.context).value
        #expect(runner.launchCount == 2)
        #expect(fixture.task.status == .completed)
        if mode == .nextStep {
            #expect(TaskPlanService.reconstruct(for: fixture.task).plan?.steps.first?.status == .done)
        }
        #expect(fixture.task.events.filter { $0.type == TaskEventTypes.ExecutionRequest.permissionResume.rawValue }.count == 1)
    }
}

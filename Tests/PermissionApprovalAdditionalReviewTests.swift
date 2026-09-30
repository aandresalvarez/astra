import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

extension PermissionApprovalContinuationTests {
    @Test("A cancelled task saves future-use authority without changing status or queuing work")
    func cancelledFutureUseApprovalSaves() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.task.status = .cancelled
        TaskRuntimePermissionOpenRequestStore.recordOpenRequest(
            payload: fixture.payload(requestID: "cancelled-offer", behavior: .futureUse), task: fixture.task)
        guard case .saved = PermissionApprovalResolutionService.approve(task: fixture.task, scope: .task,
            modelContext: fixture.context) else { Issue.record("Future-use approval did not save"); return }
        #expect(fixture.task.status == .cancelled)
        #expect(TaskRuntimePermissionGrants.approvedCredentialLabels(for: fixture.task, runtime: .codexCLI) == [fixture.label])
        #expect(try TaskTurnRequestRepository.requests(for: fixture.task, in: fixture.context).isEmpty)
        #expect(!TaskRuntimePermissionOpenRequestStore.hasOpenRequest(for: fixture.task))
    }

    @Test("Allow once reaches the resumed approved-plan provider launch", arguments: [TaskPlanExecutionMode.fullPlan, .nextStep])
    func planOnceGrantReachesLaunch(mode: TaskPlanExecutionMode) async throws {
        let fixture = try Fixture(runtime: .claudeCode)
        defer { fixture.cleanup() }
        let runner = CredentialBlockedRunner(connectorID: fixture.connectorID)
        let queue = reviewQueue(runner: runner)
        defer { queue.cancelAll() }
        let plan = TaskPlanPayload(title: "Inspect tickets", goal: "Answer the ticket question",
            steps: [.init(id: "step-1", title: "Inspect tickets", likelyTools: ["Jira"])])
        TaskPlanService.recordCreated(plan, task: fixture.task, modelContext: fixture.context)
        guard case .success(let initial) = ExecutionRequestSubmissionService.submitPlan(plan: plan,
            mode: mode, mutation: .existingTask, for: fixture.task, into: fixture.context) else {
            Issue.record("Plan did not submit"); return
        }
        await queue.signalExecutionRequest(id: initial.requestID, task: fixture.task, modelContext: fixture.context).value
        #expect(fixture.task.status == .pendingUser)
        guard case .queued(let resumed) = PermissionApprovalResolutionService.approve(task: fixture.task, scope: .once,
            modelContext: fixture.context) else { Issue.record("Plan did not resume"); return }
        await queue.signalExecutionRequest(id: resumed.requestID, task: fixture.task, modelContext: fixture.context).value
        #expect(runner.launchCount == 2)
        #expect(runner.launchPolicies.last?.permissionGrantsOverride == [.credential(label: fixture.label)])
        #expect(runner.launchPolicies.last?.allowedToolsOverride?.contains("Jira") == true)
        #expect(TaskRuntimePermissionGrants.approvedCredentialLabels(for: fixture.task, runtime: .claudeCode).isEmpty)
        let request = try #require(try TaskTurnRequestRepository.request(id: resumed.requestID, in: fixture.context))
        #expect(request.state == .completed)
    }

    @Test("A failed live delivery is recovered and dispatched in the current session")
    func failedLiveDeliveryRecoversWithoutRestart() async throws {
        let fixture = try Fixture(runtime: .claudeCode)
        defer { fixture.cleanup(); InFlightPermissionCenter.shared.failAll(taskID: fixture.task.id) }
        let runner = CredentialBlockedRunner(connectorID: fixture.connectorID, failLiveDelivery: true)
        let queue = reviewQueue(runner: runner, policyLevel: .review)
        defer { queue.cancelAll() }
        _ = TaskStateMachine.enqueueFromUITestSeed(fixture.task, modelContext: fixture.context)
        guard case .success(let initial) = ExecutionRequestSubmissionService.submitInitial(for: fixture.task,
            into: fixture.context) else { Issue.record("Initial turn did not submit"); return }
        let handle = queue.signalExecutionRequest(id: initial.requestID, task: fixture.task, modelContext: fixture.context)
        for _ in 0..<200 where InFlightPermissionCenter.shared.pendingAsks(taskID: fixture.task.id).isEmpty {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(!InFlightPermissionCenter.shared.pendingAsks(taskID: fixture.task.id).isEmpty)
        guard case .live = PermissionApprovalResolutionService.approve(task: fixture.task, scope: .once,
            modelContext: fixture.context) else { Issue.record("Expected live approval"); return }
        await handle.value
        // The original request's handle stops at its terminal state. Its
        // replacement is dispatched by the same queue loop asynchronously.
        for _ in 0..<200 where fixture.task.status != .completed || runner.launchCount != 2 {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(runner.launchCount == 2)
        #expect(fixture.task.status == .completed)
        #expect(fixture.task.events.filter { $0.type == TaskEventTypes.ExecutionRequest.permissionResume.rawValue }.count == 1)
        #expect(runner.launchPolicies.last?.permissionGrantsOverride?.isEmpty == false)
        #expect(LivePermissionApprovalRecovery.recover(modelContext: fixture.context, autoExportWorkspaces: false) == 0)
    }

    private func reviewQueue(runner: CredentialBlockedRunner, policyLevel: AgentPolicyLevel = .autonomous) -> TaskQueue {
        let queue = TaskQueue(poolSize: 1, workerFactory: {
            let worker = AgentRuntimeWorker(processRunner: runner, providerSettingsSnapshotProvider: { .headlessScenario })
            worker.runtimeReadinessService = RuntimeReadinessService(runner: InstantSuccessBinaryRunner())
            return worker
        }, sandboxEnforcementProvider: { .off })
        queue.applySettings(claudePath: "/bin/sh", defaultRuntimeID: .claudeCode, timeoutSeconds: 10,
            validationModel: "claude-sonnet-4-6", defaultPolicyLevelRaw: policyLevel.rawValue)
        return queue
    }

    @Test("Run settlement preserves acknowledgement, cancellation, and supersession guards", arguments: ["acknowledged", "cancelled", "superseded", "running", "closed"])
    func settlementDoesNotRecoverIneligibleApproval(state: String) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let binding = try fixture.blockedRequest()
        let run = try #require(fixture.task.runs.first)
        LivePermissionApprovalRecovery.record(binding: binding, requestID: "guarded", runtime: .codexCLI,
            grants: [.credential(label: fixture.label)], taskScope: false, task: fixture.task, modelContext: fixture.context)
        switch state {
        case "acknowledged":
            #expect(LivePermissionApprovalRecovery.recordDelivery(requestID: "guarded", toolName: "Jira",
                task: fixture.task, run: run, modelContext: fixture.context, persist: { try fixture.context.save() }))
        case "cancelled": fixture.task.status = .cancelled
        case "closed": fixture.task.isDone = true
        case "running": run.status = .running
        default:
            _ = ExecutionRequestSubmissionService.submitFollowUp(message: "A newer turn", for: fixture.task, into: fixture.context)
        }
        let request = try #require(try TaskTurnRequestRepository.requests(for: fixture.task, in: fixture.context).first)
        PersistedTurnRuntimeEventLinker.finishRuntime(request: request, run: run, task: fixture.task, in: fixture.context)
        #expect(!fixture.task.events.contains { $0.type == TaskEventTypes.ExecutionRequest.permissionResume.rawValue })
    }

    @Test("Legacy pipe-write receipts cannot suppress recovery without provider completion evidence")
    func legacyWriteReceiptDoesNotAcknowledge() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let binding = try fixture.blockedRequest()
        let run = try #require(fixture.task.runs.first)
        LivePermissionApprovalRecovery.record(binding: binding, requestID: "legacy", runtime: .codexCLI,
            grants: [], taskScope: true, task: fixture.task, modelContext: fixture.context)
        fixture.context.insert(TaskEvent(task: fixture.task, eventType: TaskEventTypes.Tool.permissionApprovalDelivered,
            payload: PermissionRequestResolution(requestID: "legacy", approved: true, toolName: "Jira").payloadString, run: run))
        try fixture.context.save()
        #expect(LivePermissionApprovalRecovery.recover(modelContext: fixture.context, autoExportWorkspaces: false) == 1)
    }

    @Test("An unrelated worker failure leaves credential discovery as future-use", arguments: ["timeout", "exit", "provider"])
    func failedWorkerOfferDoesNotResume(failure: String) async throws {
        let fixture = try Fixture(runtime: .claudeCode)
        defer { fixture.cleanup() }
        let result = AgentProcessResult(exitCode: failure == "exit" ? 1 : 0, timedOut: failure == "timeout")
        let runner = CredentialBlockedRunner(connectorID: fixture.connectorID, firstResult: result,
            providerReportedError: failure == "provider")
        let queue = TaskQueue(poolSize: 1, workerFactory: {
            let worker = AgentRuntimeWorker(processRunner: runner, providerSettingsSnapshotProvider: { .headlessScenario })
            worker.runtimeReadinessService = RuntimeReadinessService(runner: InstantSuccessBinaryRunner())
            return worker
        }, sandboxEnforcementProvider: { .off })
        defer { queue.cancelAll() }
        queue.applySettings(claudePath: "/bin/sh", defaultRuntimeID: .claudeCode, timeoutSeconds: 10,
            validationModel: "claude-sonnet-4-6", defaultPolicyLevelRaw: AgentPolicyLevel.autonomous.rawValue)
        _ = TaskStateMachine.enqueueFromUITestSeed(fixture.task, modelContext: fixture.context)
        guard case .success(let initial) = ExecutionRequestSubmissionService.submitInitial(for: fixture.task,
            into: fixture.context) else { Issue.record("Initial request not submitted"); return }
        await queue.signalExecutionRequest(id: initial.requestID, task: fixture.task, modelContext: fixture.context).value
        let payload = try #require(TaskRuntimePermissionOpenRequestStore.latestRequestPayload(for: fixture.task))
        #expect(PermissionApprovalEventPayload.decoded(from: payload)?.behavior == .futureUse)
        #expect(fixture.task.runs.first?.typedStopReason != .permissionApprovalRequired)
        let status = fixture.task.status
        guard case .saved = PermissionApprovalResolutionService.approve(task: fixture.task, scope: .task,
            modelContext: fixture.context) else { Issue.record("Failed worker turn resumed"); return }
        #expect(fixture.task.status == status)
        #expect(runner.launchCount == 1)
        #expect(!fixture.task.events.contains { $0.type == TaskEventTypes.ExecutionRequest.permissionResume.rawValue })
    }

    @Test("Accepted pipe bytes stay recoverable until the provider completes its turn", arguments: [false, true])
    func pipeWriteRequiresProviderAcknowledgement(completed: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var binding = try fixture.blockedRequest()
        binding.mode = .live
        let run = try #require(fixture.task.runs.first)
        run.status = .running
        run.completedAt = nil
        fixture.task.completedAt = nil
        LivePermissionApprovalRecovery.record(binding: binding, requestID: "unread", runtime: .codexCLI,
            grants: [.credential(label: fixture.label)], taskScope: false, task: fixture.task, modelContext: fixture.context)
        let channel = AgentLivePermissionDeliveryChannel()
        // No subprocess reads this pipe: a successful write is only local evidence.
        let process = AgentExecutionScopedProcess(executablePath: "/bin/sh", arguments: [],
            currentDirectory: fixture.root.path, environment: [:], providesStdinChannel: true)
        defer { process.closeStdinChannel() }
        #expect(channel.writeResponse("approved", to: process, outcome: .allowWithAcknowledgementReceipt {
            await MainActor.run {
                _ = LivePermissionApprovalRecovery.recordDelivery(requestID: "unread", toolName: "Jira",
                    task: fixture.task, run: run, modelContext: fixture.context, persist: { try fixture.context.save() })
            }
        }))
        #expect(!fixture.task.events.contains { $0.type == TaskEventTypes.Tool.permissionApprovalDelivered.rawValue })
        if completed { channel.observeProviderCompletion() }
        await channel.recordAcknowledgements()
        try fixture.context.save()
        TaskRunLifecycleService.recoverOrphanedRunningRuns(modelContext: fixture.context, autoExportWorkspaces: false)
        TaskTurnRequestRecoveryService.recoverInterruptedRequests(modelContext: fixture.context, autoExportWorkspaces: false)
        #expect(LivePermissionApprovalRecovery.recover(modelContext: fixture.context, autoExportWorkspaces: false) == (completed ? 0 : 1))
    }

    @Test("A failed response write never records acknowledgement even when a terminal result arrives")
    func failedPipeWriteCannotAcknowledge() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let process = AgentExecutionScopedProcess(executablePath: "/bin/sh", arguments: [],
            currentDirectory: fixture.root.path, environment: [:], providesStdinChannel: true)
        process.closeStdinChannel()
        let channel = AgentLivePermissionDeliveryChannel()
        #expect(!channel.writeResponse("approved", to: process, outcome: .allowWithAcknowledgementReceipt {
            Issue.record("Failed write was acknowledged")
        }))
        channel.observeProviderCompletion()
        await channel.recordAcknowledgements()
    }

    @Test("All undelivered one-time approvals of a run recover together regardless of event order", arguments: [false, true])
    func multipleLiveApprovalsRecoverTogether(reverse: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var binding = try fixture.blockedRequest()
        binding.mode = .live
        let run = try #require(fixture.task.runs.first)
        run.status = .running
        run.completedAt = nil
        fixture.task.completedAt = nil
        let first = PermissionGrant.credential(label: fixture.label)
        let second = PermissionGrant.credential(label: "connector:\(UUID().uuidString):API_TOKEN")
        let approvals = [("first", first), ("second", second), ("first", first)]
        for (id, grant) in reverse ? approvals.reversed().map({ $0 }) : approvals {
            LivePermissionApprovalRecovery.record(binding: binding, requestID: id, runtime: .codexCLI,
                grants: [grant], taskScope: false, task: fixture.task, modelContext: fixture.context)
        }
        try fixture.context.save()
        TaskRunLifecycleService.recoverOrphanedRunningRuns(modelContext: fixture.context, autoExportWorkspaces: false)
        TaskTurnRequestRecoveryService.recoverInterruptedRequests(modelContext: fixture.context, autoExportWorkspaces: false)
        #expect(LivePermissionApprovalRecovery.recover(modelContext: fixture.context, autoExportWorkspaces: false) == 1)
        let event = try #require(fixture.task.events.first { $0.type == TaskEventTypes.ExecutionRequest.permissionResume.rawValue })
        let source = try #require(ExecutionRequestSubmissionService.decodeSourcePayload(event))
        #expect(Set(source.executionPolicyOverride?.permissionGrants ?? []) == Set([first, second]))
        #expect(LivePermissionApprovalRecovery.recover(modelContext: fixture.context, autoExportWorkspaces: false) == 0)
        #expect(fixture.task.events.filter { $0.type == TaskEventTypes.ExecutionRequest.permissionResume.rawValue }.count == 1)
        #expect(TaskRuntimePermissionGrants.approvedCredentialLabels(for: fixture.task, runtime: .codexCLI).isEmpty)
    }

    @Test("Success audit follows the saved, live, and queued approval commit", arguments: ["saved", "live", "queued"])
    func approvalAuditFollowsPersistence(expectedOutcome: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup(); InFlightPermissionCenter.shared.failAll(taskID: fixture.task.id) }
        var waiter: Task<Bool, Never>?
        if expectedOutcome == "saved" {
            fixture.task.status = .failed
            TaskRuntimePermissionOpenRequestStore.recordOpenRequest(
                payload: fixture.payload(requestID: "audit", behavior: .futureUse), task: fixture.task)
        } else {
            var binding = try fixture.blockedRequest()
            if expectedOutcome == "live" {
                binding.mode = .live
                TaskRuntimePermissionOpenRequestStore.closeAllOpenRequests(for: fixture.task)
                TaskRuntimePermissionOpenRequestStore.recordOpenRequest(payload: TaskPermissionContinuation.attach(
                    fixture.payload(requestID: "audit"), continuation: binding), task: fixture.task)
                waiter = Task { await InFlightPermissionCenter.shared.awaitDecision(taskID: fixture.task.id,
                    ask: .init(requestID: "audit", toolName: "Jira", inputSummary: nil)) }
                while InFlightPermissionCenter.shared.pendingAsks(taskID: fixture.task.id).isEmpty { await Task.yield() }
            }
        }
        let result = PermissionApprovalResolutionService.approve(task: fixture.task, scope: .task,
            modelContext: fixture.context, persist: {
                #expect(AppLogger.entries.filter { $0.taskID == fixture.task.id && $0.category == "PermissionApproval" }.isEmpty)
                try fixture.context.save()
            })
        switch (expectedOutcome, result) {
        case ("saved", .saved), ("live", .live), ("queued", .queued): break
        default: Issue.record("Unexpected approval outcome")
        }
        if let waiter { #expect(await waiter.value) }
        let audit = try #require(AppLogger.entries.last { $0.taskID == fixture.task.id && $0.category == "PermissionApproval" })
        #expect(audit.message.contains("task.approved"))
        #expect(audit.message.contains("approval_scope=task"))
        #expect(audit.message.contains("runtime=codex_cli"))
        #expect(audit.message.contains("outcome=\(expectedOutcome)"))
    }

    @Test("A failed approval save emits no success audit, and a retry logs once")
    func failedApprovalCannotAuditSuccess() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.blockedRequest()
        enum Failure: Error { case save }
        guard case .failed = PermissionApprovalResolutionService.approve(task: fixture.task, scope: .once,
            modelContext: fixture.context, persist: { throw Failure.save }) else { Issue.record("Expected failure"); return }
        #expect(AppLogger.entries.filter { $0.taskID == fixture.task.id && $0.category == "PermissionApproval" }.isEmpty)
        guard case .queued = PermissionApprovalResolutionService.approve(task: fixture.task, scope: .once,
            modelContext: fixture.context) else { Issue.record("Retry did not queue"); return }
        let entries = AppLogger.entries.filter { $0.taskID == fixture.task.id && $0.category == "PermissionApproval" }
        #expect(entries.count == 1)
        #expect(entries.first?.message.contains("approval_scope=once") == true)
    }
}

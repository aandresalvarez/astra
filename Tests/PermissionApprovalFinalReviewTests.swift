import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

extension PermissionApprovalContinuationTests {
    @Test("Legacy recovery still requires current saved authority and never overrides a denial",
          arguments: ["missing-grant", "denied", "cancelled", "closed", "new-turn", "runtime-mismatch", "future-use"])
    func legacyRecoveryRejectsIneligibleRequests(reason: String) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.blockedRequest(completed: true, legacy: true)
        TaskRuntimePermissionOpenRequestStore.closeAllOpenRequests(for: fixture.task)
        if reason != "missing-grant" {
            _ = TaskRuntimePermissionGrants.record(grants: [.credential(label: fixture.label)], providerID: .codexCLI,
                task: fixture.task, modelContext: fixture.context, source: "legacy-approval")
        }
        switch reason {
        case "denied":
            fixture.context.insert(TaskEvent(task: fixture.task, eventType: TaskEventTypes.Tool.permissionRequestResolved,
                payload: PermissionRequestResolution(requestID: "connector-credentials-\(fixture.connectorID.uuidString.lowercased())",
                    approved: false, toolName: "Jira").payloadString))
        case "cancelled": fixture.task.status = .cancelled
        case "closed": fixture.task.isDone = true
        case "new-turn":
            _ = ExecutionRequestSubmissionService.submitFollowUp(message: "A newer request", for: fixture.task, into: fixture.context)
            fixture.task.status = .completed
        case "runtime-mismatch": fixture.task.runs.first?.runtimeID = AgentRuntimeID.claudeCode.rawValue
        case "future-use":
            let event = try #require(fixture.task.events.last { $0.type == "permission.approval.requested" })
            var payload = try #require(PermissionApprovalEventPayload.decoded(from: event.payload))
            payload.behavior = .futureUse
            event.payload = try #require(payload.encodedString())
        default: break
        }
        #expect(!LegacyApprovedPermissionContinuation.isAvailable(task: fixture.task))
        #expect(LegacyApprovedPermissionContinuation.submit(task: fixture.task, modelContext: fixture.context) == nil)
        #expect(!fixture.task.events.contains { $0.type == TaskEventTypes.ExecutionRequest.permissionResume.rawValue })
    }

    @Test("A mixed receipt recovery retains every grant of the originating turn")
    func mixedReceiptRecoveryKeepsEarlierGrant() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let binding = try fixture.blockedRequest()
        let run = try #require(fixture.task.runs.first)
        let first = PermissionGrant.credential(label: fixture.label)
        let second = PermissionGrant.shellCommand(executable: "npm", pattern: "install *")
        LivePermissionApprovalRecovery.record(binding: binding, requestID: "first", runtime: .codexCLI,
            grants: [first], taskScope: false, task: fixture.task, modelContext: fixture.context)
        LivePermissionApprovalRecovery.record(binding: binding, requestID: "second", runtime: .codexCLI,
            grants: [second], taskScope: false, task: fixture.task, modelContext: fixture.context)
        try fixture.context.save()
        #expect(LivePermissionApprovalRecovery.recordDelivery(requestID: "first", toolName: "Jira",
            task: fixture.task, run: run, modelContext: fixture.context, persist: { try fixture.context.save() }))
        enum Failure: Error { case save }
        #expect(!LivePermissionApprovalRecovery.recordDelivery(requestID: "second", toolName: "Bash",
            task: fixture.task, run: run, modelContext: fixture.context, persist: { throw Failure.save }))
        try fixture.context.save()
        #expect(LivePermissionApprovalRecovery.recover(modelContext: fixture.context, autoExportWorkspaces: false) == 1)
        let event = try #require(fixture.task.events.first { $0.type == TaskEventTypes.ExecutionRequest.permissionResume.rawValue })
        let payload = try #require(ExecutionRequestSubmissionService.decodeSourcePayload(event))
        #expect(Set(payload.executionPolicyOverride?.permissionGrants ?? []) == Set([first, second]))
        #expect(TaskRuntimePermissionGrants.approvedCredentialLabels(for: fixture.task, runtime: .codexCLI).isEmpty)
        #expect(LivePermissionApprovalRecovery.recover(modelContext: fixture.context, autoExportWorkspaces: false) == 0)
    }

    @Test("Observed completion survives a receipt save failure and prevents settlement replay")
    func failedReceiptSaveRetainsProcessAcknowledgement() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let binding = try fixture.blockedRequest(completed: true)
        let run = try #require(fixture.task.runs.first)
        LivePermissionApprovalRecovery.record(binding: binding, requestID: "completed", runtime: .codexCLI,
            grants: [.credential(label: fixture.label)], taskScope: false, task: fixture.task, modelContext: fixture.context)
        try fixture.context.save()
        let process = AgentExecutionScopedProcess(executablePath: "/bin/sh", arguments: [],
            currentDirectory: fixture.root.path, environment: [:], providesStdinChannel: true)
        defer { process.closeStdinChannel() }
        let channel = AgentLivePermissionDeliveryChannel()
        let written = channel.writeResponse("approved", to: process, requestID: "completed", outcome: .allowWithAcknowledgementReceipt {
            await MainActor.run {
                enum Failure: Error { case save }
                #expect(!LivePermissionApprovalRecovery.recordDelivery(requestID: "completed", toolName: "Jira",
                    task: fixture.task, run: run, modelContext: fixture.context, persist: { throw Failure.save }))
            }
        })
        #expect(written)
        channel.observeProviderCompletion()
        await channel.recordAcknowledgements()
        #expect(channel.acknowledgedPermissionRequestIDs == ["completed"])
        #expect(!fixture.task.events.contains { !$0.isDeleted && $0.type == TaskEventTypes.Tool.permissionApprovalDelivered.rawValue })
        let request = try #require(try TaskTurnRequestRepository.requests(for: fixture.task, in: fixture.context).first)
        PersistedTurnRuntimeEventLinker.finishRuntime(request: request, run: run, task: fixture.task,
            acknowledgedPermissionRequestIDs: channel.acknowledgedPermissionRequestIDs, in: fixture.context)
        #expect(!fixture.task.events.contains { $0.type == TaskEventTypes.ExecutionRequest.permissionResume.rawValue })
    }

    @Test("A completed live turn without a durable receipt never relaunches in this session", arguments: [false, true])
    func completedProviderWithoutReceiptDoesNotReplay(planLaunch: Bool) async throws {
        let fixture = try Fixture(runtime: .claudeCode)
        defer { fixture.cleanup(); InFlightPermissionCenter.shared.failAll(taskID: fixture.task.id) }
        let runner = CredentialBlockedRunner(connectorID: fixture.connectorID, failLiveDelivery: true,
            providerCompletedWithoutReceipt: true, liveAskToolName: "WebSearch")
        let queue = TaskQueue(poolSize: 1, workerFactory: {
            let worker = AgentRuntimeWorker(processRunner: runner, providerSettingsSnapshotProvider: { .headlessScenario })
            worker.runtimeReadinessService = RuntimeReadinessService(runner: InstantSuccessBinaryRunner())
            return worker
        }, sandboxEnforcementProvider: { .off })
        defer { queue.cancelAll() }
        queue.applySettings(claudePath: "/bin/sh", defaultRuntimeID: .claudeCode,
            timeoutSeconds: 10, validationModel: "claude-sonnet-4-6", defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue)
        let initial: ExecutionRequestSubmissionService.Submission
        if planLaunch {
            let plan = TaskPlanPayload(title: "Inspect tickets", goal: "Answer the ticket question",
                steps: [.init(id: "step-1", title: "Inspect tickets", likelyTools: ["Jira"])])
            TaskPlanService.recordCreated(plan, task: fixture.task, modelContext: fixture.context)
            guard case .success(let submission) = ExecutionRequestSubmissionService.submitPlan(plan: plan,
                mode: .fullPlan, mutation: .existingTask, for: fixture.task, into: fixture.context) else {
                Issue.record("Plan not submitted"); return
            }
            initial = submission
        } else {
            _ = TaskStateMachine.enqueueFromUITestSeed(fixture.task, modelContext: fixture.context)
            guard case .success(let submission) = ExecutionRequestSubmissionService.submitInitial(for: fixture.task,
                into: fixture.context) else { Issue.record("Initial turn not submitted"); return }
            initial = submission
        }
        let handle = queue.signalExecutionRequest(id: initial.requestID, task: fixture.task, modelContext: fixture.context)
        for _ in 0..<200 where InFlightPermissionCenter.shared.pendingAsks(taskID: fixture.task.id).isEmpty {
            try await Task.sleep(for: .milliseconds(25))
        }
        guard case .live = PermissionApprovalResolutionService.approve(task: fixture.task, scope: .once,
            modelContext: fixture.context) else { Issue.record("Expected live approval"); return }
        await handle.value
        #expect(runner.launchCount == 1)
        #expect(fixture.task.status == .completed)
        #expect(!fixture.task.events.contains { $0.type == TaskEventTypes.ExecutionRequest.permissionResume.rawValue })
        #expect(fixture.task.events.contains { !$0.isDeleted && $0.type == TaskEventTypes.Tool.permissionApprovalDelivered.rawValue })
    }

    @Test("Legacy recovery uses saved authority after approval notice compaction", arguments: [false, true])
    func legacyRecoverySurvivesApprovalCompaction(alreadyCompacted: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.blockedRequest(completed: true, legacy: true)
        TaskRuntimePermissionOpenRequestStore.closeAllOpenRequests(for: fixture.task)
        _ = TaskRuntimePermissionGrants.record(grants: [.credential(label: fixture.label)], providerID: .codexCLI,
            task: fixture.task, modelContext: fixture.context, source: "legacy-approval")
        let approval = TaskEvent(task: fixture.task, eventType: TaskEventTypes.Task.approved,
            payload: "Runtime permission approved by user for this task.")
        fixture.context.insert(approval)
        if alreadyCompacted { fixture.context.delete(approval) }
        let cutoff = Date()
        for index in 0..<240 {
            let event = TaskEvent(task: fixture.task, type: "agent.thinking", payload: "Earlier work")
            event.timestamp = cutoff.addingTimeInterval(Double(index + 1))
            fixture.context.insert(event)
        }
        AgentEventCompactor.compactEvents(for: fixture.task, modelContext: fixture.context)
        try fixture.context.save()
        #expect(LegacyApprovedPermissionContinuation.isAvailable(task: fixture.task))
        if !alreadyCompacted { #expect(fixture.task.events.contains { !$0.isDeleted && $0.id == approval.id }) }
        let submission = try #require(LegacyApprovedPermissionContinuation.submit(task: fixture.task, modelContext: fixture.context))
        #expect(try TaskTurnRequestRepository.request(id: submission.requestID, in: fixture.context)?.state == .waitingForWorker)
        #expect(LegacyApprovedPermissionContinuation.submit(task: fixture.task, modelContext: fixture.context) == nil)
    }
    @Test("Materializing legacy requests preserves older independent asks and excludes resolved asks")
    func materializesAllLegacyRequests() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.task.runtimePermissionOpenRequestsJSON = nil
        for (index, id) in ["older", "closed", "latest"].enumerated() {
            let event = TaskEvent(task: fixture.task, type: "permission.approval.requested",
                payload: fixture.payload(requestID: id))
            event.timestamp = Date().addingTimeInterval(Double(index - 10))
            fixture.context.insert(event)
        }
        fixture.context.insert(TaskEvent(task: fixture.task, type: "permission.request.resolved",
            payload: PermissionRequestResolution(requestID: "closed", approved: true, toolName: "Jira").payloadString))
        #expect(TaskRuntimePermissionOpenRequestStore.openRequestPayloads(for: fixture.task).count == 2)
        TaskRuntimePermissionOpenRequestStore.resolveRequest(payload: fixture.payload(requestID: "latest"), task: fixture.task)
        let remaining = TaskRuntimePermissionOpenRequestStore.openRequestPayloads(for: fixture.task)
        #expect(remaining.count == 1)
        #expect(remaining.first.flatMap(PermissionApprovalEventPayload.decoded(from:))?.requestID == "older")
        #expect(TaskRuntimePermissionOpenRequestStore.hasOpenRequest(for: fixture.task))
    }

    @Test("Blocking credential promotion is saved before returning to asynchronous handoff work")
    func blockingPromotionIsDurable() throws {
        let fixture = try Fixture(disk: true)
        defer { fixture.cleanup() }
        _ = try fixture.blockedRequest()
        let run = try #require(fixture.task.runs.first)
        let raw = fixture.payload(requestID: "connector-credentials-\(fixture.connectorID.uuidString.lowercased())", behavior: .futureUse)
        let payload = TaskPermissionContinuation.attach(raw, continuation: TaskPermissionContinuation.capture(
            task: fixture.task, run: run, modelContext: fixture.context), behavior: .futureUse)
        TaskRuntimePermissionOpenRequestStore.recordOpenRequest(payload: payload, task: fixture.task)
        fixture.task.status = .running
        run.status = .running
        try fixture.context.save()
        #expect(try TaskPermissionContinuation.applyBlockingOutcomeIfNeeded(task: fixture.task, run: run, modelContext: fixture.context))
        let fresh = ModelContext(fixture.container)
        let id = fixture.task.id
        let saved = try #require(try fresh.fetch(FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == id })).first)
        #expect(saved.status == .pendingUser)
        #expect(saved.runs.first?.typedStopReason == .permissionApprovalRequired)
        let approval = try #require(TaskRuntimePermissionOpenRequestStore.latestRequestPayload(for: saved)
            .flatMap(PermissionApprovalEventPayload.decoded(from:)))
        #expect(approval.behavior != .futureUse)
    }

    @Test("Saving a delivery receipt refreshes the workspace mirror without later worker settlement")
    func deliveryReceiptExportsMirror() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let binding = try fixture.blockedRequest(completed: true)
        let run = try #require(fixture.task.runs.first)
        LivePermissionApprovalRecovery.record(binding: binding, requestID: "exported", runtime: .codexCLI,
            grants: [.credential(label: fixture.label)], taskScope: false, task: fixture.task, modelContext: fixture.context)
        #expect(LivePermissionApprovalRecovery.recordDelivery(requestID: "exported", toolName: "Jira",
            task: fixture.task, run: run, modelContext: fixture.context))
        let url = try #require(WorkspaceConfigManager.autoExportTarget(for: fixture.root.path).url)
        var mirrored = false
        for _ in 0..<200 {
            if let text = try? String(contentsOf: url, encoding: .utf8),
               text.contains(TaskEventTypes.Tool.permissionApprovalDelivered.rawValue) { mirrored = true; break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(mirrored)
    }

    @Test("A terminal frame before the approval write still queues same-session recovery")
    func completionBeforeResponseStillRecovers() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let binding = try fixture.blockedRequest(completed: true)
        let run = try #require(fixture.task.runs.first)
        LivePermissionApprovalRecovery.record(binding: binding, requestID: "late-write", runtime: .codexCLI,
            grants: [.credential(label: fixture.label)], taskScope: false, task: fixture.task, modelContext: fixture.context)
        try fixture.context.save()
        let process = AgentExecutionScopedProcess(executablePath: "/bin/sh", arguments: [],
            currentDirectory: fixture.root.path, environment: [:], providesStdinChannel: true)
        defer { process.closeStdinChannel() }
        let channel = AgentLivePermissionDeliveryChannel()
        channel.observeProviderCompletion()
        #expect(!channel.writeResponse("approved", to: process, requestID: "late-write",
            outcome: .allowWithAcknowledgementReceipt { Issue.record("Unwritten approval was acknowledged") }))
        await channel.recordAcknowledgements()
        #expect(channel.acknowledgedPermissionRequestIDs.isEmpty)
        let request = try #require(try TaskTurnRequestRepository.requests(for: fixture.task, in: fixture.context).first)
        let tests = RuntimeTurnSettlementTests()
        let captured = tests.checkpoint(fixture, request: request)
        try RuntimeTurnSettlementService.capture(captured, task: fixture.task, run: run, modelContext: fixture.context)
        #expect(await RuntimeTurnSettlementService.settle(checkpoint: captured, task: fixture.task,
            run: run, modelContext: fixture.context))
        #expect(fixture.task.events.filter { $0.type == TaskEventTypes.ExecutionRequest.permissionResume.rawValue }.count == 1)
    }

}

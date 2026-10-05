import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

extension PermissionApprovalContinuationTests {
    @Test("Permission continuation preserves scope despite live edits and does not embed read approvals")
    func continuationPreservesResourceAuthority() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let binding = try fixture.blockedRequest()
        let requests = try TaskTurnRequestRepository.requests(for: fixture.task, in: fixture.context)
        let origin = try #require(requests.first { $0.runID == binding.runID })
        let accepted = try #require(origin.executionPolicySnapshot?.resourceScope)
        let approvedFile = FileManager.default.temporaryDirectory.appendingPathComponent("scope-approval-\(UUID().uuidString)")
        try "approved-read-not-prompt".write(to: approvedFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: approvedFile) }
        fixture.task.inputs = [approvedFile.path]
        fixture.task.constraints = ["ASTRA_GIT_ACCESS=invalid-live-edit"]
        fixture.task.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encodeSnapshot(
            WorkspaceExecutionEnvironment(id: "edited", kind: .dockerImage, displayName: "Edited", image: "edited:latest"))
        let policy = AgentRuntimeExecutionPolicy(permissionGrantsOverride: [.sandboxPath(path: approvedFile.path, access: "read")])
        let submitted = try ExecutionRequestSubmissionService.submitPermissionResume(message: "Continue",
            executionPolicy: policy, for: fixture.task, into: fixture.context, continuation: binding).get()
        let request = try #require(try TaskTurnRequestRepository.request(id: submitted.requestID, in: fixture.context))
        let resumed = try #require(request.executionPolicySnapshot?.resourceScope)
        #expect(resumed.promptInputs == accepted.promptInputs)
        #expect(resumed.executionEnvironment == accepted.executionEnvironment)
        #expect(resumed.gitAccess == accepted.gitAccess)
        #expect(resumed.coversRead(to: approvedFile.path))
        #expect(!resumed.coversWrite(to: approvedFile.path))
        #expect(!PromptInputContextReader.contextParts(for: resumed).joined().contains("approved-read-not-prompt"))
    }

    @Test("Permission continuation cannot reconstruct a legacy scope from live settings")
    func legacyPermissionScopeRequiresResubmission() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let binding = try fixture.blockedRequest()
        let requests = try TaskTurnRequestRepository.requests(for: fixture.task, in: fixture.context)
        let origin = try #require(requests.first { $0.runID == binding.runID })
        origin.executionPolicySnapshotJSON = TaskEvent.payloadString(TaskExecutionPolicySnapshotV1(task: fixture.task))
        guard case .failure(.emptySource) = ExecutionRequestSubmissionService.submitPermissionResume(
            message: "Continue", executionPolicy: .default, for: fixture.task, into: fixture.context,
            continuation: binding) else { Issue.record("Legacy scope was silently reconstructed"); return }
        #expect(!fixture.task.events.contains { $0.type == "execution.request.permission_resume" })
    }

    @Test("Compaction preserves committed approvals and delivery receipts for restart recovery")
    func compactionPreservesLiveRecoveryEvents() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let binding = try fixture.blockedRequest()
        let run = try #require(fixture.task.runs.first)
        LivePermissionApprovalRecovery.record(binding: binding, requestID: "live", runtime: .codexCLI,
            grants: [], taskScope: true, task: fixture.task, modelContext: fixture.context)
        #expect(LivePermissionApprovalRecovery.recordDelivery(requestID: "live", toolName: "Jira",
            task: fixture.task, run: run, modelContext: fixture.context, persist: { try fixture.context.save() }))
        let cutoff = Date()
        for index in 0..<240 {
            let event = TaskEvent(task: fixture.task, type: "agent.thinking", payload: "Earlier work")
            event.timestamp = cutoff.addingTimeInterval(Double(index + 1))
            fixture.context.insert(event)
        }
        AgentEventCompactor.compactEvents(for: fixture.task, modelContext: fixture.context)
        try fixture.context.save()
        #expect(fixture.task.events.contains { $0.type == TaskEventTypes.Tool.permissionLiveApprovalCommitted.rawValue })
        #expect(fixture.task.events.contains { $0.id == binding.sourceEventID })
        #expect(fixture.task.events.contains { $0.type == TaskEventTypes.Tool.permissionApprovalDelivered.rawValue
            && PermissionRequestResolution.decode(from: $0.payload)?.requestID == "live" })
        #expect(LivePermissionApprovalRecovery.recover(modelContext: fixture.context, autoExportWorkspaces: false) == 0)
    }

    @Test("A plan continuation with missing source metadata fails without submitting a follow-up")
    func missingPlanSourceFailsClosed() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let plan = TaskPlanPayload(title: "Approved work", goal: "Inspect tickets",
            steps: [.init(id: "step-1", title: "Inspect", likelyTools: ["Jira"])])
        guard case .success(let submission) = ExecutionRequestSubmissionService.submitPlan(plan: plan,
            mode: .nextStep, mutation: .existingTask, for: fixture.task, into: fixture.context) else {
            Issue.record("Plan not submitted"); return
        }
        let request = try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: fixture.context))
        let run = TaskRun(task: fixture.task)
        fixture.context.insert(run)
        _ = TaskTurnRequestStateMachine.transition(request, to: .admitted)
        _ = TaskTurnRequestStateMachine.transition(request, to: .running, runID: run.id)
        _ = TaskTurnRequestStateMachine.transition(request, to: .failed)
        let binding = TaskPermissionContinuation.capture(task: fixture.task, run: run, modelContext: fixture.context)
        let event = try #require(fixture.task.events.first { $0.id == submission.eventID })
        event.payload = "invalid source"
        guard case .failure(.emptySource) = ExecutionRequestSubmissionService.submitPermissionResume(
            message: "Continue", executionPolicy: .default, for: fixture.task, into: fixture.context,
            continuation: binding) else { Issue.record("Invalid plan became a follow-up"); return }
        #expect(!fixture.task.events.contains { $0.type == "execution.request.permission_resume" })
    }

    @Test("An approved relaunch stays closed when imported without typed request state")
    func approvedRelaunchDoesNotReopenFromEvents() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.blockedRequest()
        guard case .queued = PermissionApprovalResolutionService.approve(task: fixture.task, scope: .task,
            modelContext: fixture.context) else { Issue.record("Expected continuation"); return }
        fixture.task.runtimePermissionOpenRequestsJSON = nil
        #expect(!TaskRuntimePermissionOpenRequestStore.hasOpenRequest(for: fixture.task))
        guard case .ignored = PermissionApprovalResolutionService.approve(task: fixture.task, scope: .task,
            modelContext: fixture.context) else { Issue.record("Imported approval relaunched"); return }
        #expect(fixture.task.events.filter { $0.type == "execution.request.permission_resume" }.count == 1)
    }

    @Test("A stale live approval denies only its waiter after the closure is saved")
    func staleLiveWaiterIsReleasedAfterSave() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup(); InFlightPermissionCenter.shared.failAll(taskID: fixture.task.id) }
        var binding = try fixture.blockedRequest()
        binding.mode = .live
        TaskRuntimePermissionOpenRequestStore.closeAllOpenRequests(for: fixture.task)
        let payload = TaskPermissionContinuation.attach(fixture.payload(requestID: "stale"), continuation: binding)
        TaskRuntimePermissionOpenRequestStore.recordOpenRequest(payload: payload, task: fixture.task)
        let waiter = Task { await InFlightPermissionCenter.shared.awaitDecision(taskID: fixture.task.id,
            ask: .init(requestID: "stale", toolName: "Jira", inputSummary: nil)) }
        while InFlightPermissionCenter.shared.pendingAsks(taskID: fixture.task.id).isEmpty { await Task.yield() }
        _ = ExecutionRequestSubmissionService.submitFollowUp(message: "A newer question", for: fixture.task, into: fixture.context)
        enum Failure: Error { case save }
        guard case .failed = PermissionApprovalResolutionService.approve(task: fixture.task, scope: .task,
            modelContext: fixture.context, persist: { throw Failure.save }) else { Issue.record("Expected save failure"); return }
        #expect(InFlightPermissionCenter.shared.pendingAsks(taskID: fixture.task.id).count == 1)
        #expect(TaskRuntimePermissionOpenRequestStore.hasOpenRequest(for: fixture.task))
        guard case .ignored = PermissionApprovalResolutionService.approve(task: fixture.task, scope: .task,
            modelContext: fixture.context) else { Issue.record("Stale request continued"); return }
        #expect(await waiter.value == false)
        #expect(InFlightPermissionCenter.shared.pendingAsks(taskID: fixture.task.id).isEmpty)
        #expect(TaskRuntimePermissionGrants.approvedCredentialLabels(for: fixture.task, runtime: .codexCLI).isEmpty)
    }

    @Test("An unsaved delivery receipt cannot suppress restart recovery")
    func deliveryReceiptSaveFailureStillRecovers() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let binding = try fixture.blockedRequest()
        let run = try #require(fixture.task.runs.first)
        LivePermissionApprovalRecovery.record(binding: binding, requestID: "live", runtime: .codexCLI,
            grants: [.credential(label: fixture.label)], taskScope: false, task: fixture.task, modelContext: fixture.context)
        enum Failure: Error { case save }
        #expect(!LivePermissionApprovalRecovery.recordDelivery(requestID: "live", toolName: "Jira",
            task: fixture.task, run: run, modelContext: fixture.context, persist: { throw Failure.save }))
        try fixture.context.save()
        #expect(LivePermissionApprovalRecovery.recover(modelContext: fixture.context, autoExportWorkspaces: false) == 1)
    }

    @Test("User cancellation after restart settlement still suppresses live recovery")
    func restartRecoveryRespectsSubsequentUserCancellation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let binding = try fixture.blockedRequest()
        let run = try #require(fixture.task.runs.first)
        LivePermissionApprovalRecovery.record(binding: binding, requestID: "live", runtime: .codexCLI,
            grants: [], taskScope: true, task: fixture.task, modelContext: fixture.context)
        run.status = .running
        run.completedAt = nil
        fixture.task.completedAt = nil
        try fixture.context.save()
        TaskRunLifecycleService.recoverOrphanedRunningRuns(modelContext: fixture.context, autoExportWorkspaces: false)
        let cancelled = TaskEvent(task: fixture.task, eventType: TaskEventTypes.Task.cancelled,
            payload: "Task cancelled by user.", run: run)
        cancelled.timestamp = Date().addingTimeInterval(1)
        fixture.context.insert(cancelled)
        try fixture.context.save()
        #expect(LivePermissionApprovalRecovery.recover(modelContext: fixture.context, autoExportWorkspaces: false) == 0)
    }

    @Test("Permission continuations preserve approved-plan source and execution mode", arguments: [TaskPlanExecutionMode.fullPlan, .nextStep])
    func planApprovalPreservesFinalization(mode: TaskPlanExecutionMode) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let plan = TaskPlanPayload(title: "Approved work", goal: "Answer the ticket question",
            steps: [.init(id: "step-1", title: "Inspect", likelyTools: ["Jira"])])
        TaskPlanService.recordCreated(plan, task: fixture.task, modelContext: fixture.context)
        let result = ExecutionRequestSubmissionService.submitPlan(plan: plan, mode: mode, mutation: .existingTask,
            for: fixture.task, into: fixture.context)
        guard case .success(let submission) = result else { Issue.record("Plan not submitted"); return }
        let origin = try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: fixture.context))
        let acceptedScope = try #require(origin.executionPolicySnapshot?.resourceScope)
        #expect(acceptedScope.gitAccess == .readOnly)
        let run = TaskRun(task: fixture.task)
        fixture.context.insert(run)
        _ = TaskTurnRequestStateMachine.transition(origin, to: .admitted)
        _ = TaskTurnRequestStateMachine.transition(origin, to: .running, runID: run.id)
        _ = TaskTurnRequestStateMachine.transition(origin, to: .failed)
        run.recordPermissionApprovalRequired()
        fixture.task.status = .pendingUser
        let binding = TaskPermissionContinuation.capture(task: fixture.task, run: run, modelContext: fixture.context)
        TaskRuntimePermissionOpenRequestStore.recordOpenRequest(
            payload: TaskPermissionContinuation.attach(fixture.payload(requestID: "plan"), continuation: binding), task: fixture.task)
        var editedPlan = plan
        editedPlan.steps = [.init(id: "changed", title: "git commit the changes")]
        TaskPlanService.recordCreated(editedPlan, task: fixture.task, modelContext: fixture.context)
        fixture.task.constraints = ["ASTRA_GIT_ACCESS=read_write"]
        try fixture.context.save()
        guard case .queued(let resumed) = PermissionApprovalResolutionService.approve(task: fixture.task, scope: .once,
            modelContext: fixture.context) else { Issue.record("Plan continuation not queued"); return }
        let request = try #require(try TaskTurnRequestRepository.request(id: resumed.requestID, in: fixture.context))
        let event = try #require(fixture.task.events.first { $0.id == resumed.eventID })
        let payload = try #require(ExecutionRequestSubmissionService.decodeSourcePayload(event))
        #expect(request.kind == .planStep)
        #expect(fixture.task.status == .queued)
        #expect(payload.launchMode == .approvedPlan)
        #expect(payload.planSnapshot == plan)
        #expect(payload.planExecutionMode == mode)
        #expect(request.executionPolicySnapshot?.resourceScope == acceptedScope)
        #expect(payload.executionPolicyOverride?.permissionGrants == [.credential(label: fixture.label)])
    }
}

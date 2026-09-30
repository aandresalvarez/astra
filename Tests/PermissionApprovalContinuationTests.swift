import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Durable permission approval continuation", .serialized)
@MainActor
struct PermissionApprovalContinuationTests {
    @Test("Successful provider exit waits for approval and delayed approval answers the original question once")
    func successfulExitStillWaitsAndApprovalContinues() async throws {
        let fixture = try Fixture(runtime: .claudeCode)
        defer { fixture.cleanup() }
        let runner = CredentialBlockedRunner(connectorID: fixture.connectorID)
        let queue = TaskQueue(poolSize: 1, workerFactory: {
            let worker = AgentRuntimeWorker(processRunner: runner, providerSettingsSnapshotProvider: { .headlessScenario })
            worker.runtimeReadinessService = RuntimeReadinessService(runner: InstantSuccessBinaryRunner())
            return worker
        }, sandboxEnforcementProvider: { .off })
        defer { queue.cancelAll() }
        queue.applySettings(claudePath: "/bin/sh", defaultRuntimeID: .claudeCode,
            timeoutSeconds: 10, validationModel: "claude-sonnet-4-6", defaultPolicyLevelRaw: AgentPolicyLevel.autonomous.rawValue)
        _ = TaskStateMachine.enqueueFromUITestSeed(fixture.task, modelContext: fixture.context)
        let initial = try #require(ExecutionRequestSubmissionService.submitInitial(for: fixture.task, into: fixture.context).success)
        await queue.signalExecutionRequest(id: initial.requestID, task: fixture.task, modelContext: fixture.context).value
        #expect(fixture.task.status == .pendingUser)
        #expect(fixture.task.runs.count == 1)
        #expect(fixture.task.runs.first?.typedStopReason == .permissionApprovalRequired)
        #expect(!fixture.task.events.contains { $0.type == "task.completed" })

        // Elapsed time and mutable task fields cannot change the approved turn.
        fixture.task.updatedAt = Date().addingTimeInterval(-3_600)
        fixture.task.goal = "A different editable goal"
        let coordinator = TaskLifecycleCoordinator(modelContext: fixture.context, taskQueue: queue)
        let continuation = coordinator.approveSimilarRuntimePermissionForTask(fixture.task)
        #expect(coordinator.approveSimilarRuntimePermissionForTask(fixture.task) == nil)
        await continuation?.value
        #expect(runner.launchCount == 2)
        #expect(fixture.task.runs.count == 2)
        #expect(fixture.task.status == .completed)
        #expect(fixture.task.runs.max(by: { $0.startedAt < $1.startedAt })?.output == "You have two open tickets.")
        #expect(runner.continuationPrompt?.contains("Original blocked user request: do i have any open ticket?") == true)
        #expect(fixture.task.events.filter { $0.type == "execution.request.permission_resume" }.count == 1)
    }

    @Test("A completed task's blocked credential approval creates a durable continuation")
    func completedTaskApprovalQueuesContinuation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let binding = try fixture.blockedRequest(completed: true)
        guard case .queued(let submission) = PermissionApprovalResolutionService.approve(
            task: fixture.task, scope: .task, modelContext: fixture.context
        ) else { Issue.record("Expected continuation"); return }
        let source = try #require(fixture.task.events.first { $0.id == submission.eventID })
        let payload = try #require(ExecutionRequestSubmissionService.decodeSourcePayload(source))
        #expect(payload.permissionContinuation == binding)
        #expect(payload.message?.contains(binding.originalUserRequest) == true)
        #expect(!TaskRuntimePermissionOpenRequestStore.hasOpenRequest(for: fixture.task))
        #expect(TaskRuntimePermissionGrants.approvedCredentialLabels(for: fixture.task, runtime: .codexCLI).contains(fixture.label))
        let request = try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: fixture.context))
        #expect(request.state == .waitingForWorker)
        #expect(request.executionPolicySnapshot?.turnIntentSnapshot?.acceptedTurn == binding.originalUserRequest)
    }

    @Test("Save failure leaves permission actionable with no grant or continuation; retry succeeds")
    func persistenceFailureRollsBackWholeApproval() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.blockedRequest()
        enum Failure: Error { case save }
        let outcome = PermissionApprovalResolutionService.approve(task: fixture.task, scope: .task,
            modelContext: fixture.context, persist: { throw Failure.save })
        guard case .failed = outcome else { Issue.record("Expected persistence failure"); return }
        #expect(TaskRuntimePermissionOpenRequestStore.hasOpenRequest(for: fixture.task))
        #expect(TaskRuntimePermissionGrants.approvedCredentialLabels(for: fixture.task, runtime: .codexCLI).isEmpty)
        #expect(!fixture.task.events.contains { !$0.isDeleted && ($0.type == "execution.request.permission_resume" || $0.type == "task.approved") })
        #expect(try TaskTurnRequestRepository.activeRequests(for: fixture.task, in: fixture.context).isEmpty)
        #expect(fixture.task.events.contains { $0.payload.contains("could not be saved") })
        guard case .queued = PermissionApprovalResolutionService.approve(task: fixture.task, scope: .task,
            modelContext: fixture.context) else { Issue.record("Retry did not submit"); return }
    }

    @Test("Approving one card preserves another request and one-run grants stay out of task grants")
    func resolvesOnlySelectedRequest() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let future = fixture.payload(requestID: "future", behavior: .futureUse)
        TaskRuntimePermissionOpenRequestStore.recordOpenRequest(payload: future, task: fixture.task)
        _ = try fixture.blockedRequest()
        guard case .queued(let submission) = PermissionApprovalResolutionService.approve(task: fixture.task, scope: .once,
            modelContext: fixture.context) else { Issue.record("Expected continuation"); return }
        #expect(TaskRuntimePermissionOpenRequestStore.openRequestPayloads(for: fixture.task) == [future])
        #expect(TaskRuntimePermissionGrants.approvedCredentialLabels(for: fixture.task, runtime: .codexCLI).isEmpty)
        let event = try #require(fixture.task.events.first { $0.id == submission.eventID })
        #expect(ExecutionRequestSubmissionService.decodeSourcePayload(event)?.executionPolicyOverride?.permissionGrants == [.credential(label: fixture.label)])
    }

    @Test("Explicit future-use permission saves authority without scheduling execution")
    func futureUseDoesNotRelaunch() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.task.status = .completed
        TaskRuntimePermissionOpenRequestStore.recordOpenRequest(payload: fixture.payload(requestID: "future", behavior: .futureUse), task: fixture.task)
        guard case .saved = PermissionApprovalResolutionService.approve(task: fixture.task, scope: .task,
            modelContext: fixture.context) else { Issue.record("Expected save only"); return }
        #expect(fixture.task.status == .completed)
        #expect(try TaskTurnRequestRepository.requests(for: fixture.task, in: fixture.context).isEmpty)
        #expect(fixture.task.events.contains { $0.payload.contains("Permission saved for future use.") })
    }

    @Test("Cancelled, closed, and superseded requests never restart work")
    func staleApprovalsCannotLaunch() throws {
        for reason in ["cancelled", "closed", "new-turn", "new-run", "runtime-change"] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            _ = try fixture.blockedRequest()
            switch reason {
            case "cancelled": fixture.task.status = .cancelled
            case "closed": fixture.task.isDone = true
            case "new-turn":
                _ = ExecutionRequestSubmissionService.submitFollowUp(message: "A newer user question", for: fixture.task, into: fixture.context)
            case "runtime-change": fixture.task.runtimeID = AgentRuntimeID.claudeCode.rawValue
            default:
                let run = TaskRun(task: fixture.task)
                fixture.context.insert(run)
            }
            guard case .ignored = PermissionApprovalResolutionService.approve(task: fixture.task, scope: .task,
                modelContext: fixture.context) else { Issue.record("Stale request launched: \(reason)"); continue }
            #expect(!fixture.task.events.contains { $0.type == "execution.request.permission_resume" })
            #expect(TaskRuntimePermissionGrants.approvedCredentialLabels(for: fixture.task, runtime: .codexCLI).isEmpty)
        }
    }

    @Test("Live approval answers only the selected ask and a failed save answers neither")
    func independentLiveAsks() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var binding = try fixture.blockedRequest()
        binding.mode = .live
        TaskRuntimePermissionOpenRequestStore.closeAllOpenRequests(for: fixture.task)
        for id in ["first", "second"] {
            let payload = TaskPermissionContinuation.attach(fixture.payload(requestID: id), continuation: binding)
            TaskRuntimePermissionOpenRequestStore.recordOpenRequest(payload: payload, task: fixture.task)
        }
        let first = Task { await InFlightPermissionCenter.shared.awaitDecision(taskID: fixture.task.id,
            ask: .init(requestID: "first", toolName: "Jira", inputSummary: "First ask")) }
        let second = Task { await InFlightPermissionCenter.shared.awaitDecision(taskID: fixture.task.id,
            ask: .init(requestID: "second", toolName: "Jira", inputSummary: "Second ask")) }
        for _ in 0..<100 where InFlightPermissionCenter.shared.pendingAsks(taskID: fixture.task.id).count < 2 { await Task.yield() }
        enum Failure: Error { case save }
        guard case .failed = PermissionApprovalResolutionService.approve(task: fixture.task, scope: .task,
            modelContext: fixture.context, persist: { throw Failure.save }) else { Issue.record("Expected save failure"); return }
        #expect(InFlightPermissionCenter.shared.pendingAsks(taskID: fixture.task.id).count == 2)
        guard case .live = PermissionApprovalResolutionService.approve(task: fixture.task, scope: .task,
            modelContext: fixture.context) else { Issue.record("Expected live resolution"); return }
        #expect(await second.value)
        #expect(InFlightPermissionCenter.shared.pendingAsks(taskID: fixture.task.id).map(\.requestID) == ["first"])
        #expect(TaskRuntimePermissionOpenRequestStore.openRequestPayloads(for: fixture.task).count == 1)
        #expect(!fixture.task.events.contains { $0.type == "execution.request.permission_resume" })
        InFlightPermissionCenter.shared.failAll(taskID: fixture.task.id)
        #expect(await first.value == false)
    }

    @Test("Committed live decisions recover after real startup settlement unless delivery was recorded")
    func liveApprovalCrashWindow() throws {
        for acknowledged in [false, true] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            var binding = try fixture.blockedRequest()
            binding.mode = .live
            TaskRuntimePermissionOpenRequestStore.closeAllOpenRequests(for: fixture.task)
            LivePermissionApprovalRecovery.record(binding: binding, requestID: "live", runtime: .codexCLI,
                grants: [.credential(label: fixture.label)], taskScope: false, task: fixture.task, modelContext: fixture.context)
            let run = try #require(fixture.task.runs.first)
            run.status = .running
            run.completedAt = nil
            fixture.task.completedAt = nil
            fixture.context.insert(TaskEvent(task: fixture.task, type: "permission.request.resolved",
                    payload: PermissionRequestResolution(requestID: "live", approved: true, toolName: "Jira").payloadString,
                    run: run))
            if acknowledged {
                #expect(LivePermissionApprovalRecovery.recordDelivery(requestID: "live", toolName: "Jira",
                    task: fixture.task, run: run, modelContext: fixture.context, persist: { try fixture.context.save() }))
            }
            try fixture.context.save()
            TaskRunLifecycleService.recoverOrphanedRunningRuns(modelContext: fixture.context, autoExportWorkspaces: false)
            TaskTurnRequestRecoveryService.recoverInterruptedRequests(modelContext: fixture.context, autoExportWorkspaces: false)
            #expect(fixture.task.status == .cancelled)
            #expect(LivePermissionApprovalRecovery.recover(modelContext: fixture.context, autoExportWorkspaces: false) == (acknowledged ? 0 : 1))
            #expect(LivePermissionApprovalRecovery.recover(modelContext: fixture.context, autoExportWorkspaces: false) == 0)
            #expect(fixture.task.events.filter { $0.type == "execution.request.permission_resume" }.count == (acknowledged ? 0 : 1))
        }
    }

    @Test("A legacy event-backed connector request resumes its own run")
    func legacyConnectorRequestContinues() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let binding = try fixture.blockedRequest(completed: true, legacy: true)
        fixture.task.runtimePermissionOpenRequestsJSON = nil
        guard case .queued(let submission) = PermissionApprovalResolutionService.approve(task: fixture.task, scope: .task,
            modelContext: fixture.context) else { Issue.record("Legacy request did not resume"); return }
        let source = try #require(fixture.task.events.first { $0.id == submission.eventID })
        #expect(ExecutionRequestSubmissionService.decodeSourcePayload(source)?.permissionContinuation?.runID == binding.runID)
    }

    @Test("Duplicate submission keys return the original execution request")
    func duplicateSubmissionIsIdempotent() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let binding = try fixture.blockedRequest()
        let first = try #require(ExecutionRequestSubmissionService.submitPermissionResume(message: "Resume", executionPolicy: .default,
            for: fixture.task, into: fixture.context, continuation: binding, approvalID: "same-approval").success)
        let second = try #require(ExecutionRequestSubmissionService.submitPermissionResume(message: "Resume", executionPolicy: .default,
            for: fixture.task, into: fixture.context, continuation: binding, approvalID: "same-approval",
            prepare: { Issue.record("Duplicate must not apply mutations twice") }).success)
        #expect(first == second)
        #expect(fixture.task.events.filter { $0.type == "execution.request.permission_resume" }.count == 1)
    }

    @Test("Approval and continuation survive reopening the store before queue signalling")
    func persistedApprovalSurvivesRestart() throws {
        let fixture = try Fixture(disk: true)
        defer { fixture.cleanup() }
        let binding = try fixture.blockedRequest()
        guard case .queued(let submission) = PermissionApprovalResolutionService.approve(task: fixture.task, scope: .task,
            modelContext: fixture.context) else { Issue.record("Expected durable submission"); return }
        let reopened = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(url: fixture.storeURL)])
        let context = reopened.mainContext
        let task = try #require(try context.fetch(FetchDescriptor<AgentTask>()).first)
        _ = TaskTurnRequestRecoveryService.recoverInterruptedRequests(modelContext: context, autoExportWorkspaces: false)
        let request = try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: context))
        #expect(request.state == .waitingForWorker)
        #expect(request.runID == nil)
        #expect(!TaskRuntimePermissionOpenRequestStore.hasOpenRequest(for: task))
        #expect(TaskRuntimePermissionGrants.approvedCredentialLabels(for: task, runtime: .codexCLI).contains(fixture.label))
        let source = try #require(task.events.first { $0.id == request.sourceEventID })
        #expect(ExecutionRequestSubmissionService.decodeSourcePayload(source)?.permissionContinuation == binding)
    }

    @MainActor
    struct Fixture {
        let root: URL
        let storeURL: URL
        let container: ModelContainer
        let context: ModelContext
        let task: AgentTask
        let connectorID = UUID()
        var label: String { "connector:\(connectorID.uuidString):JIRA_API_TOKEN" }

        init(runtime: AgentRuntimeID = .codexCLI, disk: Bool = false) throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("permission-continuation-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            storeURL = root.appendingPathComponent("test.store")
            container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
                configurations: [disk ? ModelConfiguration(url: storeURL) : ModelConfiguration(isStoredInMemoryOnly: true)])
            context = container.mainContext
            let workspace = Workspace(name: "Permission continuation", primaryPath: root.path)
            task = AgentTask(title: "Open tickets", goal: "do i have any open ticket?", workspace: workspace, runtime: runtime)
            context.insert(workspace)
            context.insert(task)
            try context.save()
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }

        func payload(requestID: String, behavior: PermissionApprovalBehavior? = nil) -> String {
            let request = PermissionRequest.connectorCredentials(connectorID: connectorID, displayName: "Jira", labels: [label])
            var payload = PermissionBroker.approvalPayload(providerID: task.resolvedRuntimeID, request: request,
                reason: "The connector call was blocked pending approval.", grants: [.credential(label: label)], requestID: requestID)
            payload.behavior = behavior
            return payload.encodedString()!
        }

        func blockedRequest(completed: Bool = false, legacy: Bool = false) throws -> PermissionApprovalContinuation {
            let source = try #require(ExecutionRequestSubmissionService.submitInitial(for: task, into: context).success)
            let request = try #require(try TaskTurnRequestRepository.request(id: source.requestID, in: context))
            let run = TaskRun(task: task)
            run.startedAt = Date().addingTimeInterval(-3_600)
            run.completedAt = Date().addingTimeInterval(-3_500)
            context.insert(run)
            _ = TaskTurnRequestStateMachine.transition(request, to: .admitted)
            _ = TaskTurnRequestStateMachine.transition(request, to: .running, runID: run.id)
            _ = TaskTurnRequestStateMachine.transition(request, to: .failed)
            task.status = completed ? .completed : .pendingUser
            run.status = completed ? .completed : .failed
            run.typedStopReason = completed ? .completed : .permissionApprovalRequired
            let binding = TaskPermissionContinuation.capture(task: task, run: run, modelContext: context)
            let raw = payload(requestID: "connector-credentials-\(connectorID.uuidString.lowercased())")
            let encoded = legacy ? raw : TaskPermissionContinuation.attach(raw, continuation: binding)
            TaskRuntimePermissionOpenRequestStore.recordOpenRequest(payload: encoded, task: task)
            context.insert(TaskEvent(task: task, type: "permission.approval.requested", payload: encoded, run: run))
            try context.save()
            return binding
        }
    }
}

private extension Result where Success == ExecutionRequestSubmissionService.Submission {
    var success: Success? { if case .success(let value) = self { return value }; return nil }
}

/// Exercises the complete worker/queue path while keeping provider and Jira
/// traffic local. The first successful process exit leaves a real broker ledger
/// record; the second launch must carry the approved credential grant.
private final class CredentialBlockedRunner: AgentRuntimeProcessRunning {
    let connectorID: UUID
    var launchCount = 0
    var continuationPrompt: String?
    init(connectorID: UUID) { self.connectorID = connectorID }
    func cancel() {}
    func isHostControlBrokerAvailable() -> Bool { true }

    @MainActor
    func runRuntimeProcess(
        adapter: any AgentRuntimeProcessLaunchPlanning & AgentRuntimeProcessEventParsing,
        prompt: String, task: AgentTask, workspacePath: String, executablePath: String, homeDirectory: String,
        permissionPolicy: PermissionPolicy, executionPolicy: AgentRuntimeExecutionPolicy, permissionManifest: RunPermissionManifest?,
        budgetEnforcementMode: BudgetEnforcementMode, timeoutSeconds: TimeInterval, phase: RunPhase, contextText: String,
        nativeContinuationSessionID: String?, runID: UUID?, launchResourcePlan: TaskLaunchResourcePlan?,
        capabilityResolutionSnapshot: TaskCapabilityResolutionSnapshot?, runtimeRequirements: TaskRuntimeRequirementSet?,
        liveApprovalsEnabled: Bool, noSemanticProgressTimeoutSeconds: TimeInterval?, maxRunSeconds: TimeInterval?,
        onInteractiveAsk: ((AgentInteractiveAskRequest) async -> InteractiveAskOutcome)?, onLine: @escaping (String, Bool) -> Void
    ) async -> AgentProcessResult {
        launchCount += 1
        let label = "connector:\(connectorID.uuidString):JIRA_API_TOKEN"
        let answer: String
        if launchCount == 1 {
            BrokeredCredentialApprovalLedger.shared.record(.init(connectorID: connectorID, connectorName: "Jira", alias: "jira",
                serviceType: "jira", credentialLabels: [label]), taskID: task.id, runID: runID)
            answer = "Approve Jira access so I can check your open tickets."
        } else {
            continuationPrompt = prompt
            #expect(permissionManifest?.approvalGrants.contains(.credential(label: label)) == true)
            answer = "You have two open tickets."
        }
        onLine(#"{"type":"system","subtype":"init","session_id":"permission-test","model":"claude-sonnet-4-6"}"#, false)
        let event: [String: Any] = ["type": "assistant", "message": ["content": [["type": "text", "text": answer]]]]
        let data = try! JSONSerialization.data(withJSONObject: event)
        onLine(String(data: data, encoding: .utf8)!, false)
        onLine(#"{"type":"result","subtype":"success","result":"Done","total_cost_usd":0,"duration_ms":10,"num_turns":1}"#, false)
        return AgentProcessResult(exitCode: 0)
    }
}

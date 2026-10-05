import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Runtime turn settlement", .serialized)
@MainActor
struct RuntimeTurnSettlementTests {
    typealias Fixture = PermissionApprovalContinuationTests.Fixture
    enum SaveFailure: Error { case injected }

    func runningTurn(_ fixture: Fixture, plan: RuntimeTurnSettlementService.ApprovedPlan? = nil) throws -> (TaskRun, TaskTurnRequest) {
        fixture.context.autosaveEnabled = false
        let submitted = if let plan {
            ExecutionRequestSubmissionService.submitPlan(plan: plan.plan, mode: plan.step == nil ? .fullPlan : .nextStep,
                mutation: .existingTask, for: fixture.task, into: fixture.context)
        } else { ExecutionRequestSubmissionService.submitInitial(for: fixture.task, into: fixture.context) }
        guard case .success(let source) = submitted else { throw SaveFailure.injected }
        let request = try #require(try TaskTurnRequestRepository.request(id: source.requestID, in: fixture.context))
        let run = TaskRun(task: fixture.task)
        run.runtimeID = fixture.task.resolvedRuntimeID.rawValue
        fixture.context.insert(run)
        fixture.task.status = .running
        _ = TaskTurnRequestStateMachine.transition(request, to: .admitted)
        _ = TaskTurnRequestStateMachine.transition(request, to: .running, runID: run.id)
        fixture.task.events.first { $0.id == source.eventID }?.run = run
        run.setOutput("You have two open tickets.")
        try fixture.context.save()
        return (run, request)
    }

    func approval(_ fixture: Fixture, run: TaskRun, id: String = "live") {
        let binding = TaskPermissionContinuation.capture(task: fixture.task, run: run, modelContext: fixture.context, mode: .live)
        LivePermissionApprovalRecovery.record(binding: binding, requestID: id, runtime: fixture.task.resolvedRuntimeID,
            grants: [.credential(label: fixture.label)], taskScope: false, task: fixture.task, modelContext: fixture.context)
    }

    func checkpoint(_ fixture: Fixture, request: TaskTurnRequest, result: AgentProcessResult = .init(exitCode: 0),
                    plan: RuntimeTurnSettlementService.ApprovedPlan? = nil, chain: String = "",
                    launchSnapshot: AgentTaskLaunchSnapshot? = nil, executionPath: String? = nil,
                    enforcement: ExecutionSandboxEnforcement = .off) -> RuntimeTurnSettlementService.Checkpoint {
        .init(requestID: request.id, result: result, runtime: fixture.task.resolvedRuntimeID,
            phase: .run, executionPath: executionPath ?? fixture.root.path, launchSnapshot: launchSnapshot ?? .init(task: fixture.task),
            permissionPolicy: .autonomous, sandboxEnforcement: enforcement,
            verifierRuntime: .init(runtime: fixture.task.resolvedRuntimeID, claudePath: "/bin/sh"),
            timeoutSeconds: 10, budgetEnforcementMode: BudgetEnforcementMode.warning.rawValue,
            effectiveTokenBudget: Int.max, tokensUsed: fixture.task.tokensUsed, agentReportedError: false,
            cancelled: false, failureDiagnostic: nil, approvedPlan: plan, chainedGoal: chain, scheduleID: fixture.task.originScheduleID)
    }

    func reopen(_ fixture: Fixture) throws -> (ModelContainer, AgentTask) {
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(url: fixture.storeURL)])
        let id = fixture.task.id
        let task = try #require(try container.mainContext.fetch(FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == id })).first)
        return (container, task)
    }

    @Test("Restarted validation retains copy source protection for tests and approved plans", arguments: [false, true])
    func restartedValidationKeepsScope(planRun: Bool) async throws {
        let fixture = try Fixture(disk: true)
        defer { fixture.cleanup() }
        fixture.task.isolationStrategy = .copy
        fixture.task.validationStrategy = planRun ? .manual : .runTests
        fixture.task.testCommand = "make test"
        let plan = TaskPlanPayload(title: "Inspect", goal: "Inspect tickets",
            steps: [.init(id: "inspect", title: "Inspect")],
            validationContract: TaskValidationContract(assertions: [
                .init(id: "tests", description: "Tests pass", method: .command, command: "make test")
            ]))
        let envelope: RuntimeTurnSettlementService.ApprovedPlan? = planRun ? .init(plan: plan, step: nil) : nil
        if planRun { TaskPlanService.recordCreated(plan, task: fixture.task, modelContext: fixture.context) }
        let (run, request) = try runningTurn(fixture, plan: envelope)
        let snapshot = try #require(TaskExecutionLaunchSnapshotApplicator.snapshot(request: request, from: fixture.task))
        let scope = try #require(snapshot.resourceScope)
        let copy = scope.workingDirectory
        defer { try? FileManager.default.removeItem(atPath: copy) }
        try FileManager.default.createDirectory(atPath: copy, withIntermediateDirectories: true)
        let marker = fixture.root.appendingPathComponent("source-marker")
        try "original".write(to: marker, atomically: true, encoding: .utf8)
        try "test:\n\t@printf changed > '\(marker.path)'\n".write(
            toFile: copy + "/Makefile", atomically: true, encoding: .utf8)
        let captured = checkpoint(fixture, request: request, plan: envelope,
            launchSnapshot: snapshot, executionPath: copy, enforcement: .strict)
        try RuntimeTurnSettlementService.capture(captured, task: fixture.task, run: run, modelContext: fixture.context)
        let (savedContainer, savedTask) = try reopen(fixture)
        let savedRun = try #require(savedTask.runs.first)
        let restored = try #require(try RuntimeTurnSettlementService.checkpoint(for: savedRun, task: savedTask))
        savedTask.testCommand = "swift test"
        #expect(await RuntimeTurnSettlementService.settle(checkpoint: restored, task: savedTask,
            run: savedRun, modelContext: savedContainer.mainContext))
        #expect(try String(contentsOf: marker, encoding: .utf8) == "original")
        #expect(try TaskTurnRequestRepository.request(id: request.id, in: savedContainer.mainContext)?.state == .failed)
        #expect(savedTask.events.contains {
            $0.type == TaskValidationEventTypes.assertionFailed || $0.type == TaskEventTypes.System.error.rawValue
        })
    }

    @Test("A captured acknowledgement and response survive restart before the verdict, without provider replay")
    func resumeCapturedResult() async throws {
        let fixture = try Fixture(disk: true)
        defer { fixture.cleanup() }
        let (run, request) = try runningTurn(fixture)
        approval(fixture, run: run)
        var result = AgentProcessResult(exitCode: 0)
        result.writtenPermissionRequestIDs = ["live"]
        result.acknowledgedPermissionRequestIDs = ["live"]
        try RuntimeTurnSettlementService.capture(checkpoint(fixture, request: request, result: result),
            task: fixture.task, run: run, modelContext: fixture.context)
        let (savedContainer, savedTask) = try reopen(fixture)
        let savedRun = try #require(savedTask.runs.first)
        #expect(savedRun.status == .running)
        #expect(savedRun.output == "You have two open tickets.")
        #expect(savedTask.events.contains { $0.type == TaskEventTypes.Tool.permissionApprovalDelivered.rawValue })
        RuntimeTurnSettlementRecoveryService.prepare(modelContext: savedContainer.mainContext, autoExport: false)
        TaskRunLifecycleService.recoverOrphanedRunningRuns(modelContext: savedContainer.mainContext, autoExportWorkspaces: false)
        TaskTurnRequestRecoveryService.recoverInterruptedRequests(modelContext: savedContainer.mainContext, autoExportWorkspaces: false)
        #expect(savedRun.status == .running)
        let queue = TaskQueue(poolSize: 1)
        defer { queue.cancelAll() }
        await RuntimeTurnSettlementRecoveryService.resume(modelContext: savedContainer.mainContext, taskQueue: queue, autoExport: false)
        #expect(savedTask.status == .completed)
        #expect(savedTask.runs.count == 1)
        #expect(RuntimeTurnSettlementService.verdict(for: savedRun, task: savedTask)?.requestState == .completed)
        #expect(try TaskTurnRequestRepository.request(id: request.id, in: savedContainer.mainContext)?.state == .completed)
        #expect(!savedTask.events.contains { $0.type == TaskEventTypes.ExecutionRequest.permissionResume.rawValue })
    }

    @Test("An unwritten approval blocks completion and child creation for ordinary and plan runs", arguments: [false, true])
    func unwrittenApprovalPrecedesEffects(planRun: Bool) async throws {
        let fixture = try Fixture(runtime: .claudeCode)
        defer { fixture.cleanup() }
        let plan = TaskPlanPayload(title: "Tickets", goal: "Inspect tickets", steps: [.init(id: "tickets", title: "Inspect")])
        let envelope: RuntimeTurnSettlementService.ApprovedPlan? = planRun ? .init(plan: plan, step: plan.steps[0]) : nil
        if planRun { TaskPlanService.recordCreated(plan, task: fixture.task, modelContext: fixture.context) }
        let (run, request) = try runningTurn(fixture, plan: envelope)
        approval(fixture, run: run)
        let captured = checkpoint(fixture, request: request, plan: envelope, chain: "Publish the answer")
        try RuntimeTurnSettlementService.capture(captured, task: fixture.task, run: run, modelContext: fixture.context)
        #expect(await RuntimeTurnSettlementService.settle(checkpoint: captured, task: fixture.task, run: run, modelContext: fixture.context))
        RuntimeTurnSettlementService.dispatchChainedTask(task: fixture.task, run: run, modelContext: fixture.context)
        #expect(run.typedStopReason == .permissionApprovalRequired)
        #expect(request.state == .failed)
        #expect(RuntimeTurnSettlementService.verdict(for: run, task: fixture.task)?.chainedTaskID == nil)
        #expect(fixture.task.workspace?.tasks.filter { $0.chainedFromID == fixture.task.id }.isEmpty == true)
        #expect(fixture.task.events.filter { $0.type == TaskEventTypes.ExecutionRequest.permissionResume.rawValue }.count == 1)
        if planRun { #expect(TaskPlanService.reconstruct(for: fixture.task).plan?.steps.first?.status != .done) }
    }

    @Test("A written response without a terminal result requires reconciliation rather than replay")
    func uncertainDeliveryDoesNotReplay() async throws {
        let fixture = try Fixture(disk: true)
        defer { fixture.cleanup() }
        let (run, request) = try runningTurn(fixture)
        approval(fixture, run: run)
        var result = AgentProcessResult(exitCode: 1)
        result.writtenPermissionRequestIDs = ["live"]
        let captured = checkpoint(fixture, request: request, result: result, chain: "Publish")
        try RuntimeTurnSettlementService.capture(captured, task: fixture.task, run: run, modelContext: fixture.context)
        #expect(await RuntimeTurnSettlementService.settle(checkpoint: captured, task: fixture.task, run: run, modelContext: fixture.context))
        #expect(fixture.task.status == .pendingUser)
        #expect(!fixture.task.events.contains { $0.type == TaskEventTypes.ExecutionRequest.permissionResume.rawValue })
        let (savedContainer, savedTask) = try reopen(fixture)
        #expect(LivePermissionApprovalRecovery.recover(modelContext: savedContainer.mainContext, autoExportWorkspaces: false) == 0)
        #expect(savedTask.runs.count == 1)
        #expect(savedTask.events.contains { $0.type == TaskEventTypes.System.runtimeReconciliationRequired.rawValue })
    }

    @Test("A failed capture cannot persist a receipt alone; restart preserves authority without automatic execution")
    func failedCaptureIsNotAcknowledged() throws {
        let fixture = try Fixture(disk: true)
        defer { fixture.cleanup() }
        let (run, request) = try runningTurn(fixture)
        approval(fixture, run: run)
        try fixture.context.save()
        var result = AgentProcessResult(exitCode: 0)
        result.acknowledgedPermissionRequestIDs = ["live"]
        #expect(throws: SaveFailure.self) {
            try RuntimeTurnSettlementService.capture(checkpoint(fixture, request: request, result: result),
                task: fixture.task, run: run, modelContext: fixture.context, persist: { throw SaveFailure.injected })
        }
        let (savedContainer, savedTask) = try reopen(fixture)
        #expect(!savedTask.events.contains { $0.type == TaskEventTypes.Tool.permissionApprovalDelivered.rawValue })
        #expect(!savedTask.events.contains { $0.type == TaskEventTypes.System.runtimeResultCaptured.rawValue })
        RuntimeTurnSettlementRecoveryService.prepare(modelContext: savedContainer.mainContext, autoExport: false)
        #expect(savedTask.status == .pendingUser)
        #expect(LivePermissionApprovalRecovery.recover(modelContext: savedContainer.mainContext, autoExportWorkspaces: false) == 0)
        #expect(savedTask.events.contains { $0.type == TaskEventTypes.Tool.permissionLiveApprovalCommitted.rawValue })
    }

    @Test("Failed verdict persistence releases no child, and recovery dispatches one durable child exactly once")
    func effectsRequireSavedVerdict() async throws {
        let fixture = try Fixture(runtime: .claudeCode, disk: true)
        defer { fixture.cleanup() }
        let (run, request) = try runningTurn(fixture)
        let captured = checkpoint(fixture, request: request, chain: "Inspect the next ticket")
        try RuntimeTurnSettlementService.capture(captured, task: fixture.task, run: run, modelContext: fixture.context)
        try await RuntimeTurnOutcomeService.apply(checkpoint: captured, task: fixture.task, run: run, modelContext: fixture.context)
        #expect(!RuntimeTurnSettlementService.commit(checkpoint: captured, task: fixture.task, run: run,
            modelContext: fixture.context, persist: { throw SaveFailure.injected }))
        RuntimeTurnSettlementService.dispatchChainedTask(task: fixture.task, run: run, modelContext: fixture.context)
        #expect(fixture.task.workspace?.tasks.filter { $0.chainedFromID == fixture.task.id }.isEmpty == true)
        let (savedContainer, savedTask) = try reopen(fixture)
        let queue = TaskQueue(poolSize: 1)
        defer { queue.cancelAll() }
        await RuntimeTurnSettlementRecoveryService.resume(modelContext: savedContainer.mainContext, taskQueue: queue, autoExport: false)
        await RuntimeTurnSettlementRecoveryService.resume(modelContext: savedContainer.mainContext, taskQueue: queue, autoExport: false)
        #expect(savedTask.workspace?.tasks.filter { $0.chainedFromID == savedTask.id }.count == 1)
    }

    @Test("Plan settlement after restart checks the approved step before releasing downstream work")
    func planCheckpointCannotBypassFinalization() async throws {
        let fixture = try Fixture(disk: true)
        defer { fixture.cleanup() }
        let plan = TaskPlanPayload(title: "Tickets", goal: "Inspect", steps: [.init(id: "tickets", title: "Inspect", outputs: [.init(scope: .workspace, path: "missing.txt")])])
        TaskPlanService.recordCreated(plan, task: fixture.task, modelContext: fixture.context)
        let envelope = RuntimeTurnSettlementService.ApprovedPlan(plan: plan, step: plan.steps[0])
        let (run, request) = try runningTurn(fixture, plan: envelope)
        try RuntimeTurnSettlementService.capture(checkpoint(fixture, request: request, plan: envelope, chain: "Publish"),
            task: fixture.task, run: run, modelContext: fixture.context)
        let (savedContainer, savedTask) = try reopen(fixture)
        let queue = TaskQueue(poolSize: 1)
        defer { queue.cancelAll() }
        await RuntimeTurnSettlementRecoveryService.resume(modelContext: savedContainer.mainContext, taskQueue: queue, autoExport: false)
        #expect(savedTask.status == .pendingUser)
        #expect(try TaskTurnRequestRepository.request(id: request.id, in: savedContainer.mainContext)?.state == .failed)
        #expect(savedTask.workspace?.tasks.filter { $0.chainedFromID == savedTask.id }.isEmpty == true)
    }

    @Test("Missing, mismatched or cancelled request ownership cannot commit completion effects", arguments: ["missing", "mismatched", "cancelled"])
    func invalidRequestOwnershipBlocksEffects(invalidOwner: String) async throws {
        let fixture = try Fixture(runtime: .claudeCode)
        defer { fixture.cleanup() }
        let (run, request) = try runningTurn(fixture)
        let captured = checkpoint(fixture, request: request, chain: "Publish the answer")
        try RuntimeTurnSettlementService.capture(captured, task: fixture.task, run: run, modelContext: fixture.context)
        if invalidOwner == "missing" {
            fixture.context.delete(request)
        } else if invalidOwner == "mismatched" {
            request.runID = UUID()
        } else {
            _ = TaskTurnRequestStateMachine.transition(request, to: .cancelled, terminalReason: "User cancelled")
        }
        try fixture.context.save()
        #expect(!RuntimeTurnSettlementService.commit(checkpoint: captured, task: fixture.task, run: run,
            modelContext: fixture.context))
        #expect(RuntimeTurnSettlementService.verdict(for: run, task: fixture.task) == nil)
        #expect(RuntimeTurnSettlementService.hasUnsettledResult(task: fixture.task, run: run))
        RuntimeTurnSettlementService.dispatchChainedTask(task: fixture.task, run: run, modelContext: fixture.context)
        #expect(fixture.task.workspace?.tasks.filter { $0.chainedFromID == fixture.task.id }.isEmpty == true)
    }

    @Test("A cancelled or already-owned request cannot authorize another provider launch", arguments: [false, true])
    func invalidRequestCannotLaunch(cancelled: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let (_, request) = try runningTurn(fixture)
        if cancelled {
            _ = TaskTurnRequestStateMachine.transition(request, to: .cancelled, terminalReason: "User cancelled")
        }
        let newRun = TaskRun(task: fixture.task)
        fixture.context.insert(newRun)
        let begin = PersistedTurnRuntimeEventLinker.beginRuntime(requestID: request.id, run: newRun,
            task: fixture.task, in: fixture.context)
        #expect(!begin.persisted)
        #expect(newRun.status == .failed)
        #expect(request.runID != newRun.id)
        #expect(request.state == (cancelled ? .cancelled : .running))
    }
    @Test("A continuation preserves the original execution envelope across later settings edits")
    func continuationPreservesEnvelope() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.task.testCommand = "original test command"
        fixture.task.tokenBudget = 12000
        let (run, request) = try runningTurn(fixture)
        fixture.task.testCommand = "different test command"
        fixture.task.validationStrategy = .runTests
        fixture.task.tokenBudget = 99
        let binding = TaskPermissionContinuation.capture(task: fixture.task, run: run, modelContext: fixture.context)
        guard case .success(let resumed) = ExecutionRequestSubmissionService.submitPermissionResume(message: "Continue",
            executionPolicy: .default, for: fixture.task, into: fixture.context, continuation: binding, approvalID: "envelope")
        else { Issue.record("Continuation was not saved"); return }
        let saved = try #require(try TaskTurnRequestRepository.request(id: resumed.requestID, in: fixture.context))
        #expect(saved.tokenBudgetSnapshot == request.tokenBudgetSnapshot)
        #expect(saved.executionPolicySnapshot?.testCommand == "original test command")
        #expect(saved.executionPolicySnapshot?.validationStrategyRawValue == ValidationStrategy.manual.rawValue)
        #expect(saved.resourceClaimsJSON == request.resourceClaimsJSON)
        #expect(fixture.task.testCommand == "different test command")
    }

    @Test("Schedule routing requires a saved verdict and survives repeated restart dispatch")
    func scheduleRoutingIsDurableAndIdempotent() async throws {
        let fixture = try Fixture(disk: true)
        defer { fixture.cleanup() }
        let schedule = TaskSchedule(name: "Ticket check", workspace: fixture.task.workspace)
        schedule.resultMode = .scheduleLog
        fixture.context.insert(schedule)
        fixture.task.originScheduleID = schedule.id
        let (run, request) = try runningTurn(fixture)
        let captured = checkpoint(fixture, request: request)
        try RuntimeTurnSettlementService.capture(captured, task: fixture.task, run: run, modelContext: fixture.context)
        let queue = TaskQueue(poolSize: 1)
        defer { queue.cancelAll() }
        queue.routeScheduleResult(task: fixture.task, scheduleID: schedule.id, modelContext: fixture.context)
        #expect(schedule.runResults.isEmpty)
        #expect(await RuntimeTurnSettlementService.settle(checkpoint: captured, task: fixture.task, run: run, modelContext: fixture.context))
        let (savedContainer, savedTask) = try reopen(fixture)
        await RuntimeTurnSettlementRecoveryService.resume(modelContext: savedContainer.mainContext, taskQueue: queue, autoExport: false)
        await RuntimeTurnSettlementRecoveryService.resume(modelContext: savedContainer.mainContext, taskQueue: queue, autoExport: false)
        let id = schedule.id
        let savedSchedule = try #require(try savedContainer.mainContext.fetch(FetchDescriptor<TaskSchedule>(predicate: #Predicate { $0.id == id })).first)
        #expect(savedSchedule.runResults.count == 1)
        #expect(savedSchedule.runResults.first?.summary.contains("two open tickets") == true)
        #expect(savedTask.events.filter { $0.type == TaskEventTypes.System.runtimeScheduleResultRouted.rawValue }.count == 1)
    }

    @Test("An unreadable originating snapshot cannot silently use edited continuation settings")
    func malformedOriginCannotContinue() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let (run, request) = try runningTurn(fixture)
        request.executionPolicySnapshotJSON = "unreadable"
        let binding = TaskPermissionContinuation.capture(task: fixture.task, run: run, modelContext: fixture.context)
        let result = ExecutionRequestSubmissionService.submitPermissionResume(message: "Continue",
            executionPolicy: .default, for: fixture.task, into: fixture.context, continuation: binding,
            approvalID: "unreadable")
        guard case .failure = result else { Issue.record("Unreadable launch settings must block continuation"); return }
        #expect(!fixture.task.events.contains { $0.type == TaskEventTypes.ExecutionRequest.permissionResume.rawValue })
        #expect(try TaskTurnRequestRepository.requests(for: fixture.task, in: fixture.context).count == 1)
    }

}

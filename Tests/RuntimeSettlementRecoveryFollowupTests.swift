import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Runtime settlement recovery follow-up", .serialized)
@MainActor
struct RuntimeSettlementRecoveryFollowupTests {
    let helper = RuntimeTurnSettlementTests()
    typealias Fixture = PermissionApprovalContinuationTests.Fixture

    @Test("Recovered turns update both session projections exactly once")
    func recoveredSessionHistory() async throws {
        let fixture = try Fixture(disk: true)
        defer { fixture.cleanup() }
        let (run, request) = try helper.runningTurn(fixture)
        var checkpoint = helper.checkpoint(fixture, request: request)
        checkpoint.sessionMessage = "Original ticket question before restart"
        try RuntimeTurnSettlementService.capture(checkpoint, task: fixture.task, run: run, modelContext: fixture.context)
        let (container, task) = try helper.reopen(fixture)
        let queue = TaskQueue(poolSize: 1)
        defer { queue.cancelAll() }
        await RuntimeTurnSettlementRecoveryService.resume(modelContext: container.mainContext, taskQueue: queue, autoExport: false)
        await RuntimeTurnSettlementRecoveryService.resume(modelContext: container.mainContext, taskQueue: queue, autoExport: false)
        let folder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        let state = try #require(TaskContextStateManager.load(taskFolder: folder))
        #expect(state.turns.count == 1)
        #expect(state.turns.first?.runID == run.id)
        #expect(state.turns.first?.ask == checkpoint.sessionMessage)
        let history = try String(contentsOfFile: SessionHistoryManager.historyPath(taskFolder: folder), encoding: .utf8)
        #expect(history.components(separatedBy: "<!-- ASTRA run").count == 2)
        #expect(history.contains("Original ticket question before restart"))
    }

    @Test("Failed verdict recovery requires cleanup and never repeats validation", arguments: [false, true])
    func failedVerdictDoesNotRepeatValidation(runsCommand: Bool) async throws {
        let fixture = try Fixture(runtime: .claudeCode, disk: true)
        defer { fixture.cleanup() }
        let counter = fixture.root.appendingPathComponent("validation-count.txt")
        fixture.task.validationStrategy = runsCommand ? .runTests : .manual
        try ".PHONY: test\ntest:\n\t@echo ran >> validation-count.txt\n".write(
            to: fixture.root.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
        fixture.task.executionRootPath = fixture.root.path
        fixture.task.testCommand = "make test"
        let (run, request) = try helper.runningTurn(fixture)
        // The provider fixture already has a verified stop receipt. Attach its
        // real workspace claims before validation, without changing that proof.
        do {
            let lease = try RuntimeExecutionOwner.store(in: fixture.context).acquire(taskID: fixture.task.id, taskOwnerID: fixture.task.persistentModelID)
            var providerReceipt = try #require(try lease.read())
            providerReceipt.resourceClaims = TaskExecutionResourceAdmissionPolicy.lockClaims(
                for: request, task: fixture.task, runMode: "settlement", sandboxEnforcement: .off)
            try lease.save(providerReceipt)
        }
        let checkpoint = helper.checkpoint(fixture, request: request)
        try RuntimeTurnSettlementService.capture(checkpoint, task: fixture.task, run: run, modelContext: fixture.context)
        #expect(await RuntimeTurnSettlementService.settle(checkpoint: checkpoint, task: fixture.task, run: run,
            modelContext: fixture.context, verdictPersistence: { throw RuntimeTurnSettlementTests.SaveFailure.injected }, autoExport: false) == false)
        // The validated result survives the failed verdict save. A completed
        // arbitrary command still cannot attest that detached work stopped.
        #expect(try RuntimeSettlementProgress.prepared(task: fixture.task, run: run)?.taskStatus == .completed)
        #expect(try RuntimeSettlementProgress.prepared(task: fixture.task, run: run)?.finalizationComplete == true)
        #expect(RuntimeTurnSettlementService.verdict(for: run, task: fixture.task) == nil)
        let receipt = try #require(try RuntimeExecutionOwner.existing(task: fixture.task, context: fixture.context))
        #expect(receipt.settlementToolsStopped == !runsCommand)
        #expect(receipt.canReplace == !runsCommand)
        try fixture.context.save() // An unrelated save must not make validation replayable.
        let (container, task) = try helper.reopen(fixture)
        let queue = TaskQueue(poolSize: 1)
        defer { queue.cancelAll() }
        await RuntimeTurnSettlementRecoveryService.resume(modelContext: container.mainContext, taskQueue: queue, autoExport: false)
        await RuntimeTurnSettlementRecoveryService.resume(modelContext: container.mainContext, taskQueue: queue, autoExport: false)
        #expect(task.status == (runsCommand ? .pendingUser : .completed))
        let recoveredRun = try #require(task.runs.first)
        #expect(task.runs.count == 1)
        #expect(recoveredRun.id == run.id && recoveredRun.output == run.output)
        #expect(RuntimeTurnSettlementService.verdict(for: recoveredRun, task: task)?.requestState == (runsCommand ? .failed : .completed))
        #expect(try TaskTurnRequestRepository.request(id: request.id, in: container.mainContext)?.state == (runsCommand ? .failed : .completed))
        let folder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        // This failure happened after projection, so the original response
        // remains available even when the execution must stay protected.
        #expect(TaskContextStateManager.load(taskFolder: folder)?.turns.count == 1)
        if runsCommand {
            #expect(try String(contentsOf: counter, encoding: .utf8) == "ran\n")
            #expect(task.events.contains { $0.type == TaskEventTypes.Task.completed.rawValue
                && $0.payload.contains(ValidationOutcomeMarker.testsPassed.rawValue) })
            #expect(task.events.contains { $0.type == TaskEventTypes.System.runtimeReconciliationRequired.rawValue })
            #expect(RuntimeResourceOwnership.retainsResources(receipt))
            let claims = try #require(receipt.resourceClaims)
            #expect(!claims.isEmpty)
            #expect(try RuntimeResourceOwnership.permitsRelease(claims,
                store: RuntimeExecutionOwner.store(in: container.mainContext), context: container.mainContext) == false)
            if case .blocked = RuntimeExecutionOwner.retryDecision(task: task, context: container.mainContext) {} else {
                Issue.record("An arbitrary validation command authorized Retry without cleanup proof")
            }
            #expect(RuntimeExecutionOwner.acquire(task: task, context: container.mainContext,
                maxRunSeconds: 60, newUserTurn: true) == nil)
            #expect(try RuntimeExecutionOwner.existing(task: task, context: container.mainContext) == receipt)
        } else {
            #expect(!FileManager.default.fileExists(atPath: counter.path))
            #expect(try RuntimeExecutionOwner.existing(task: task, context: container.mainContext)?.canReplace == true)
        }
        #expect(task.events.filter { !$0.isDeleted && $0.type == TaskEventTypes.Task.completed.rawValue }.count == 1)
        #expect(task.events.filter { !$0.isDeleted && $0.type == TaskEventTypes.System.runtimeTurnSettled.rawValue }.count == 1)
    }

    @Test("Interrupted validation without a prepared result requires reconciliation without replay")
    func interruptedPreparationDoesNotReplay() async throws {
        let fixture = try Fixture(disk: true)
        defer { fixture.cleanup() }
        let counter = fixture.root.appendingPathComponent("must-not-run.txt")
        fixture.task.validationStrategy = .runTests
        fixture.task.testCommand = "touch '" + counter.path + "'"
        let (run, request) = try helper.runningTurn(fixture)
        let checkpoint = helper.checkpoint(fixture, request: request)
        try RuntimeTurnSettlementService.capture(checkpoint, task: fixture.task, run: run, modelContext: fixture.context)
        fixture.context.insert(TaskEvent(task: fixture.task, eventType: TaskEventTypes.System.runtimeSettlementStarted,
            payload: "Started before crash", run: run))
        try fixture.context.save()
        let (container, task) = try helper.reopen(fixture)
        let queue = TaskQueue(poolSize: 1)
        defer { queue.cancelAll() }
        await RuntimeTurnSettlementRecoveryService.resume(modelContext: container.mainContext, taskQueue: queue, autoExport: false)
        #expect(!FileManager.default.fileExists(atPath: counter.path))
        #expect(task.status == .pendingUser)
        #expect(try TaskTurnRequestRepository.request(id: request.id, in: container.mainContext)?.state == .failed)
    }

    @Test("Large mirrored checkpoints preserve context but require an independent receipt to settle", arguments: [false, true])
    func mirrorRoundTripRetainsRecovery(hasVerifiedReceipt: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let counter = fixture.root.appendingPathComponent("mirrored-validation-count.txt")
        fixture.task.validationStrategy = .runTests
        fixture.task.executionRootPath = fixture.root.path
        fixture.task.testCommand = "make test"
        try ".PHONY: test\ntest:\n\t@echo ran >> mirrored-validation-count.txt\n".write(
            to: fixture.root.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
        let (run, request) = try helper.runningTurn(fixture)
        var checkpoint = helper.checkpoint(fixture, request: request,
            result: AgentProcessResult(exitCode: 0, error: String(repeating: "large stderr ", count: 1000)))
        checkpoint.sessionMessage = "Mirrored original question"
        try RuntimeTurnSettlementService.capture(checkpoint, task: fixture.task, run: run, modelContext: fixture.context)
        let workspace = try #require(fixture.task.workspace)
        let config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: fixture.context))
        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(WorkspaceConfigManager.WorkspaceConfig.self, from: encoded)
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let imported = WorkspaceConfigManager.importWorkspace(from: decoded, modelContext: container.mainContext,
            taskRecoveryTrustPolicy: .trustedLocalRecovery)
        let task = try #require(imported.tasks.first)
        let importedRun = try #require(task.runs.first)
        let restored = try #require(try RuntimeTurnSettlementService.checkpoint(for: importedRun, task: task))
        #expect(restored.result.error == checkpoint.result.error)
        #expect(restored.sessionMessage == checkpoint.sessionMessage)
        #expect(try TaskTurnRequestRepository.request(id: request.id, in: container.mainContext)?.runID == run.id)
        #expect(try RuntimeExecutionOwner.existing(task: task, context: container.mainContext) == nil)
        if hasVerifiedReceipt {
            // Simulate a separately verified local receipt. A workspace mirror
            // preserves context but cannot establish execution ownership itself.
            try RuntimeRecoveryTestReceipt.install(task: task, run: importedRun, context: container.mainContext)
        }
        let queue = TaskQueue(poolSize: 1)
        defer { queue.cancelAll() }
        await RuntimeTurnSettlementRecoveryService.resume(modelContext: container.mainContext, taskQueue: queue, autoExport: false)
        #expect(task.runs.count == 1)
        #expect(importedRun.output == run.output)
        if hasVerifiedReceipt {
            #expect(task.status == .completed)
            #expect(try TaskTurnRequestRepository.request(id: request.id, in: container.mainContext)?.state == .completed)
            #expect(try String(contentsOf: counter, encoding: .utf8) == "ran\n")
        } else {
            #expect(task.status == .pendingUser)
            #expect(try TaskTurnRequestRepository.request(id: request.id, in: container.mainContext)?.state == .failed)
            #expect(!FileManager.default.fileExists(atPath: counter.path))
            #expect(task.events.contains { $0.type == TaskEventTypes.System.runtimeReconciliationRequired.rawValue })
        }
    }

    @Test("Settled checkpoints are pruned, while pending checkpoints remain recoverable")
    func settledCheckpointRetention() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let (run, request) = try helper.runningTurn(fixture)
        let checkpoint = helper.checkpoint(fixture, request: request,
            result: AgentProcessResult(exitCode: 0, error: String(repeating: "x", count: 100000)))
        try RuntimeTurnSettlementService.capture(checkpoint, task: fixture.task, run: run, modelContext: fixture.context)
        AgentEventCompactor.compactEvents(for: fixture.task, modelContext: fixture.context)
        #expect(try RuntimeTurnSettlementService.checkpoint(for: run, task: fixture.task) != nil)
        #expect(await RuntimeTurnSettlementService.settle(checkpoint: checkpoint, task: fixture.task, run: run,
            modelContext: fixture.context, autoExport: false))
        #expect(try RuntimeTurnSettlementService.checkpoint(for: run, task: fixture.task) == nil)
        #expect(RuntimeTurnSettlementService.verdict(for: run, task: fixture.task) != nil)
    }

    @Test("Deleting a dispatched child does not recreate it after restart")
    func deletedChildStaysDeleted() async throws {
        let fixture = try Fixture(runtime: .claudeCode, disk: true)
        defer { fixture.cleanup() }
        let (run, request) = try helper.runningTurn(fixture)
        let checkpoint = helper.checkpoint(fixture, request: request, chain: "Next ticket")
        try RuntimeTurnSettlementService.capture(checkpoint, task: fixture.task, run: run, modelContext: fixture.context)
        #expect(await RuntimeTurnSettlementService.settle(checkpoint: checkpoint, task: fixture.task, run: run,
            modelContext: fixture.context, autoExport: false))
        RuntimeTurnSettlementService.dispatchChainedTask(task: fixture.task, run: run, modelContext: fixture.context)
        let child = try #require(fixture.task.workspace?.tasks.first { $0.chainedFromID == fixture.task.id })
        fixture.context.delete(child)
        try fixture.context.save()
        let (container, task) = try helper.reopen(fixture)
        let queue = TaskQueue(poolSize: 1)
        defer { queue.cancelAll() }
        await RuntimeTurnSettlementRecoveryService.resume(modelContext: container.mainContext, taskQueue: queue, autoExport: false)
        #expect(task.workspace?.tasks.filter { $0.chainedFromID == task.id }.isEmpty == true)
        #expect(task.events.contains { $0.type == TaskEventTypes.System.runtimeChainedWorkDispatched.rawValue })
    }
    @Test("Mirrored request and checkpoint policies retain credential references without secret environment values")
    func mirrorPoliciesRedactEnvironmentValues() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let skill = Skill(name: "Fixture environment")
        skill.environmentKeys = ["PRIVATE_TOKEN"]
        skill.environmentValues = ["fixture-private-environment-value"]
        fixture.task.skillSnapshots = [SkillSnapshotConfig(skill: skill)]
        let (run, request) = try helper.runningTurn(fixture)
        let originalPolicy = request.executionPolicySnapshotJSON
        let checkpoint = helper.checkpoint(fixture, request: request)
        try RuntimeTurnSettlementService.capture(checkpoint, task: fixture.task, run: run, modelContext: fixture.context)
        let workspace = try #require(fixture.task.workspace)
        let config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: fixture.context))
        let json = String(data: try JSONEncoder().encode(config), encoding: .utf8) ?? ""
        #expect(json.contains("PRIVATE_TOKEN"))
        #expect(!json.contains("fixture-private-environment-value"))
        #expect(request.executionPolicySnapshotJSON == originalPolicy)
    }

}

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

    @Test("Failed verdict recovery does not rerun validation commands or completion transitions")
    func failedVerdictDoesNotRepeatValidation() async throws {
        let fixture = try Fixture(runtime: .claudeCode, disk: true)
        defer { fixture.cleanup() }
        let counter = fixture.root.appendingPathComponent("validation-count.txt")
        fixture.task.validationStrategy = .runTests
        try ".PHONY: test\ntest:\n\t@echo ran >> validation-count.txt\n".write(
            to: fixture.root.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
        fixture.task.executionRootPath = fixture.root.path
        fixture.task.testCommand = "make test"
        let (run, request) = try helper.runningTurn(fixture)
        let checkpoint = helper.checkpoint(fixture, request: request)
        try RuntimeTurnSettlementService.capture(checkpoint, task: fixture.task, run: run, modelContext: fixture.context)
        #expect(await RuntimeTurnSettlementService.settle(checkpoint: checkpoint, task: fixture.task, run: run,
            modelContext: fixture.context, verdictPersistence: { throw RuntimeTurnSettlementTests.SaveFailure.injected }, autoExport: false) == false)
        try fixture.context.save() // An unrelated save must not make validation replayable.
        let (container, task) = try helper.reopen(fixture)
        let queue = TaskQueue(poolSize: 1)
        defer { queue.cancelAll() }
        await RuntimeTurnSettlementRecoveryService.resume(modelContext: container.mainContext, taskQueue: queue, autoExport: false)
        #expect(task.status == .completed)
        #expect(try String(contentsOf: counter, encoding: .utf8) == "ran\n")
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

    @Test("Large mirrored checkpoints retain their request owners and settle in a fresh store")
    func mirrorRoundTripRetainsRecovery() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
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
        #expect(try TaskTurnRequestRepository.request(id: request.id, in: container.mainContext)?.runID == run.id)
        let queue = TaskQueue(poolSize: 1)
        defer { queue.cancelAll() }
        await RuntimeTurnSettlementRecoveryService.resume(modelContext: container.mainContext, taskQueue: queue, autoExport: false)
        #expect(task.status == .completed)
        #expect(try TaskTurnRequestRepository.request(id: request.id, in: container.mainContext)?.state == .completed)
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

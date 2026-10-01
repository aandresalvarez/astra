import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Runtime settlement review regressions", .serialized)
@MainActor
struct RuntimeSettlementReviewRegressionTests {
    let helper = RuntimeTurnSettlementTests()
    typealias Fixture = PermissionApprovalContinuationTests.Fixture

    @Test("Projection failure retries the validated outcome without rerunning validation")
    func projectionFailure() async throws {
        let fixture = try Fixture(runtime: .claudeCode, disk: true)
        defer { fixture.cleanup() }
        fixture.task.validationStrategy = .runTests
        fixture.task.executionRootPath = fixture.root.path
        fixture.task.testCommand = "make test"
        try ".PHONY: test\ntest:\n\t@echo ran >> validation-count.txt\n".write(
            to: fixture.root.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
        let (run, request) = try helper.runningTurn(fixture)
        let checkpoint = helper.checkpoint(fixture, request: request)
        try RuntimeTurnSettlementService.capture(checkpoint, task: fixture.task, run: run, modelContext: fixture.context)
        #expect(await RuntimeTurnSettlementService.settle(checkpoint: checkpoint, task: fixture.task, run: run,
            modelContext: fixture.context, sessionProjection: { false }, autoExport: false) == false)
        #expect(run.status == .completed)
        #expect(RuntimeTurnSettlementService.verdict(for: run, task: fixture.task) == nil)
        #expect(try RuntimeSettlementProgress.prepared(task: fixture.task, run: run)?.finalizationComplete == false)
        try fixture.context.save()
        let (container, task) = try helper.reopen(fixture)
        let queue = TaskQueue(poolSize: 1)
        defer { queue.cancelAll() }
        await RuntimeTurnSettlementRecoveryService.resume(modelContext: container.mainContext, taskQueue: queue, autoExport: false)
        #expect(task.status == .completed)
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("validation-count.txt"), encoding: .utf8) == "ran\n")
        #expect(task.events.filter { !$0.isDeleted && $0.type == TaskEventTypes.Task.completed.rawValue }.count == 1)
        let folder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        #expect(TaskContextStateManager.load(taskFolder: folder)?.turns.count == 1)
        #expect(RuntimeTurnSettlementService.verdict(for: try #require(task.runs.first), task: task)?.requestState == .completed)
    }

    @Test("Recovery persists checkpoint cleanup without downstream work")
    func recoveryCleanup() async throws {
        let fixture = try Fixture(disk: true)
        defer { fixture.cleanup() }
        let (run, request) = try helper.runningTurn(fixture)
        let checkpoint = helper.checkpoint(fixture, request: request)
        try RuntimeTurnSettlementService.capture(checkpoint, task: fixture.task, run: run, modelContext: fixture.context)
        #expect(await RuntimeTurnSettlementService.settle(checkpoint: checkpoint, task: fixture.task, run: run,
            modelContext: fixture.context, autoExport: false))
        // Recreate the durable state left when the first cleanup save fails.
        fixture.context.insert(TaskEvent.structuredPayloadEvent(task: fixture.task,
            type: TaskEventTypes.System.runtimeResultCaptured.rawValue, payload: checkpoint, run: run))
        try fixture.context.save()
        let (container, task) = try helper.reopen(fixture)
        let queue = TaskQueue(poolSize: 1)
        defer { queue.cancelAll() }
        await RuntimeTurnSettlementRecoveryService.resume(modelContext: container.mainContext, taskQueue: queue)
        let (reopenedContainer, reopenedTask) = try helper.reopen(fixture)
        defer { withExtendedLifetime(reopenedContainer) {} }
        #expect(try RuntimeTurnSettlementService.checkpoint(for: try #require(reopenedTask.runs.first), task: reopenedTask) == nil)
        let mirror = try WorkspaceConfigManager.loadConfig(from: URL(fileURLWithPath:
            WorkspaceFileLayout.workspaceConfigFile(for: fixture.root.path)))
        #expect(mirror.tasks?.flatMap(\.events).contains { $0.type == "runtime.result.captured" } == false)
        #expect(RuntimeTurnSettlementService.verdict(for: try #require(task.runs.first), task: task) != nil)
    }

    @Test("Ordinary imports cannot run captured results or replay active requests", arguments: [false, true])
    func ordinaryImportIsQuarantined(preserveSchedules: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let (run, request) = try helper.runningTurn(fixture)
        let checkpoint = helper.checkpoint(fixture, request: request)
        try RuntimeTurnSettlementService.capture(checkpoint, task: fixture.task, run: run, modelContext: fixture.context)
        let workspace = try #require(fixture.task.workspace)
        let config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: fixture.context))
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let imported = WorkspaceConfigManager.importWorkspace(from: config, modelContext: container.mainContext,
            scheduleTrustPolicy: preserveSchedules ? .preserveEnabledState : .quarantineEnabledSchedules)
        let task = try #require(imported.tasks.first)
        #expect(task.status == .pendingUser)
        #expect(try TaskTurnRequestRepository.allActiveRequests(in: container.mainContext).isEmpty)
        #expect(task.events.contains { $0.type == "imported.runtime.result.captured" })
        #expect(try RuntimeTurnSettlementService.checkpoint(for: try #require(task.runs.first), task: task) == nil)
        let queue = TaskQueue(poolSize: 1)
        defer { queue.cancelAll() }
        await RuntimeTurnSettlementRecoveryService.resume(modelContext: container.mainContext, taskQueue: queue, autoExport: false)
        queue.replayRecoveredTurns(modelContext: container.mainContext)
        #expect(task.status == .pendingUser)
        #expect(task.runs.count == 1)
        #expect(RuntimeTurnSettlementService.verdict(for: try #require(task.runs.first), task: task) == nil)
    }

    @Test("One malformed owner or checkpoint does not prevent other tasks from being mirrored",
        arguments: ["{broken", "{\"skillSnapshotsJSON\":\"{broken\"}"])
    func malformedRecordIsolation(policy: String) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let (run, request) = try helper.runningTurn(fixture)
        request.executionPolicySnapshotJSON = policy
        fixture.context.insert(TaskEvent(task: fixture.task, eventType: TaskEventTypes.System.runtimeResultCaptured,
            payload: "{broken", run: run))
        let other = AgentTask(title: "Unaffected", goal: "Other task", workspace: fixture.task.workspace)
        fixture.context.insert(other)
        let workspace = try #require(fixture.task.workspace)
        let config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: fixture.context))
        #expect(config.tasks?.count == 2)
        let taskConfig = try #require(config.tasks?.first { $0.id == fixture.task.id.uuidString })
        #expect(taskConfig.turnRequests?.isEmpty == true)
        #expect(!taskConfig.events.contains { $0.type == "runtime.result.captured" })
        #expect(config.tasks?.contains { $0.title == "Unaffected" } == true)
    }

    @Test("Obsolete terminal owners are excluded before policy decoding")
    func obsoleteOwnerExcluded() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let (_, request) = try helper.runningTurn(fixture)
        let old = TaskTurnRequest(task: fixture.task, messageEventID: UUID(), sequence: 0, kind: .initial, state: .completed)
        old.runID = UUID()
        old.executionPolicySnapshotJSON = "{broken-obsolete-policy"
        fixture.context.insert(old)
        let workspace = try #require(fixture.task.workspace)
        let config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: fixture.context))
        #expect(config.tasks?.first?.turnRequests?.map(\.id) == [request.id])
    }
}

import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@Suite("Runtime settlement review regressions", .serialized)
@MainActor
struct RuntimeSettlementReviewRegressionTests {
    let helper = RuntimeTurnSettlementTests()
    typealias Fixture = PermissionApprovalContinuationTests.Fixture

    @Test("Projection recovery respects cleanup proof without rerunning validation", arguments: [false, true])
    func projectionFailure(runsCommand: Bool) async throws {
        let fixture = try Fixture(runtime: .claudeCode, disk: true)
        defer { fixture.cleanup() }
        fixture.task.validationStrategy = runsCommand ? .runTests : .manual
        fixture.task.executionRootPath = fixture.root.path
        fixture.task.testCommand = "make test"
        try ".PHONY: test\ntest:\n\t@echo ran >> validation-count.txt\n".write(
            to: fixture.root.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
        let (run, request) = try helper.runningTurn(fixture)
        // Keep real workspace reservations on the provider's existing fixture
        // receipt so an uncertain validator cannot appear safe via empty claims.
        do {
            let lease = try RuntimeExecutionOwner.store(in: fixture.context).acquire(taskID: fixture.task.id)
            var providerReceipt = try #require(try lease.read())
            providerReceipt.resourceClaims = TaskExecutionResourceAdmissionPolicy.lockClaims(
                for: request, task: fixture.task, runMode: "settlement", sandboxEnforcement: .off)
            try lease.save(providerReceipt)
        }
        let checkpoint = helper.checkpoint(fixture, request: request)
        try RuntimeTurnSettlementService.capture(checkpoint, task: fixture.task, run: run, modelContext: fixture.context)
        #expect(await RuntimeTurnSettlementService.settle(checkpoint: checkpoint, task: fixture.task, run: run,
            modelContext: fixture.context, sessionProjection: { false }, autoExport: false) == false)
        #expect(run.status == .completed)
        #expect(RuntimeTurnSettlementService.verdict(for: run, task: fixture.task) == nil)
        #expect(try RuntimeSettlementProgress.prepared(task: fixture.task, run: run)?.taskStatus == .completed)
        #expect(try RuntimeSettlementProgress.prepared(task: fixture.task, run: run)?.finalizationComplete == false)
        let receipt = try #require(try RuntimeExecutionOwner.existing(task: fixture.task, context: fixture.context))
        #expect(receipt.settlementToolsStopped == !runsCommand)
        #expect(receipt.canReplace == !runsCommand)
        try fixture.context.save()
        let (container, task) = try helper.reopen(fixture)
        let queue = TaskQueue(poolSize: 1)
        defer { queue.cancelAll() }
        await RuntimeTurnSettlementRecoveryService.resume(modelContext: container.mainContext, taskQueue: queue, autoExport: false)
        await RuntimeTurnSettlementRecoveryService.resume(modelContext: container.mainContext, taskQueue: queue, autoExport: false)
        #expect(task.status == (runsCommand ? .pendingUser : .completed))
        let recoveredRun = try #require(task.runs.first)
        #expect(task.runs.count == 1)
        #expect(recoveredRun.id == run.id && recoveredRun.output == run.output)
        #expect(task.events.filter { !$0.isDeleted && $0.type == TaskEventTypes.Task.completed.rawValue }.count == 1)
        let folder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        let counter = fixture.root.appendingPathComponent("validation-count.txt")
        if runsCommand {
            // A prepared result is not a tool-stop receipt. The original run
            // output and validation event stay available, but recovery does
            // not enter finalization/projection or launch anything new.
            #expect(try String(contentsOf: counter, encoding: .utf8) == "ran\n")
            #expect(task.events.contains { $0.type == TaskEventTypes.Task.completed.rawValue
                && $0.payload.contains(ValidationOutcomeMarker.testsPassed.rawValue) })
            #expect(TaskContextStateManager.load(taskFolder: folder)?.turns.isEmpty != false)
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
            #expect(TaskContextStateManager.load(taskFolder: folder)?.turns.count == 1)
            #expect(try RuntimeExecutionOwner.existing(task: task, context: container.mainContext)?.canReplace == true)
        }
        #expect(RuntimeTurnSettlementService.verdict(for: recoveredRun, task: task)?.requestState == (runsCommand ? .failed : .completed))
        #expect(try TaskTurnRequestRepository.request(id: request.id, in: container.mainContext)?.state == (runsCommand ? .failed : .completed))
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
        // Recovery saves synchronously; its mirror has always been asynchronous.
        // Await the scheduled write before inspecting the same cleanup in JSON.
        await WorkspacePersistenceCoordinator.waitForPendingExport(workspaceID: try #require(task.workspace).id)
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

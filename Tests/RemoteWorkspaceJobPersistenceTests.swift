import Foundation
import SwiftData
import Testing
import os
import ASTRACore
import ASTRAModels
import ASTRAPersistence
import WorkspaceToolSupport
@testable import ASTRA

@Suite("Remote job owner and event persistence", .serialized)
@MainActor
struct RemoteWorkspaceJobPersistenceTests {
    @Test("Polling selects only current registered executions and discovers new registrations")
    func monitorDoesNotLoadUnrelatedTasks() throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        for index in 0..<200 {
            _ = h.makeTask(runtime: .claudeCode, goal: "Unrelated \(index)", model: "test")
        }
        let task = h.makeTask(runtime: .claudeCode, goal: "Registered", model: "test")
        let owner = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60))
        defer { owner.finish() }
        let run = TaskRun(task: task); h.context.insert(run)
        try owner.bind(run: run); try owner.prepareLaunch()
        try h.context.save()
        #expect(try RemoteWorkspaceJobMonitorSession.registeredTasks(context: h.context).isEmpty)
        // A prior execution's registration does not make this execution a
        // polling candidate. Registration is discovered afresh on each tick.
        let oldRoot = RemoteWorkspaceJobRegistration.directory(taskID: task.id,
            executionID: UUID(), context: h.context)
        try FileManager.default.createDirectory(at: oldRoot, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: oldRoot.appendingPathComponent("configuration.json"))
        #expect(try RemoteWorkspaceJobMonitorSession.registeredTasks(context: h.context).isEmpty)
        _ = try RemoteWorkspaceJobRegistration.prepare(task: task, runID: run.id,
            owner: owner, context: h.context, connections: [])
        #expect(try RemoteWorkspaceJobMonitorSession.registeredTasks(context: h.context).map(\.persistentModelID) == [task.persistentModelID])
    }

    @Test("SSH preparation follows a detached execution task's persistent source owner")
    func detachedExecutionKeepsItsOwner() throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Detached SSH", model: "test")
        let owner = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60))
        defer { owner.finish() }
        let run = TaskRun(task: task); h.context.insert(run)
        try owner.bind(run: run); try owner.prepareLaunch()
        let execution = AgentRuntimeExecutionContext.make(launchTask: task,
            executionPath: h.workspaceURL.path, shouldCleanupIsolation: false)
        #expect(execution.task.persistentModelID != task.persistentModelID)
        #expect(execution.task.launchSourceTaskOwnerID == task.persistentModelID)
        let config = try RemoteWorkspaceJobRegistration.prepare(task: execution.task, runID: run.id,
            owner: owner, context: h.context, connections: [])
        #expect(try RemoteWorkspaceJobRegistration.load(task: task, context: h.context) == config)

        let other = h.makeTask(runtime: .claudeCode, goal: "Imported copy", model: "test")
        other.id = task.id; try h.context.save()
        let foreign = AgentRuntimeExecutionContext.make(launchTask: other,
            executionPath: h.workspaceURL.path, shouldCleanupIsolation: false)
        #expect(throws: (any Error).self) {
            try RemoteWorkspaceJobRegistration.prepare(task: foreign.task, runID: run.id,
                owner: owner, context: h.context, connections: [])
        }
        #expect(try RemoteWorkspaceJobMonitorSession.registeredTasks(context: h.context).map(\.persistentModelID) == [task.persistentModelID])
    }

    @Test("Retained executions remain observable but their old helpers cannot launch")
    func retainedRegistrations() throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Retained jobs", model: "test")
        let owner = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60))
        let run = TaskRun(task: task); h.context.insert(run)
        try owner.bind(run: run); try owner.prepareLaunch()
        let config = try RemoteWorkspaceJobRegistration.prepare(task: task, runID: run.id,
            owner: owner, context: h.context, connections: [])
        owner.finish()
        let authority = RuntimeExecutionOwner.store(in: h.context)
        let previous = try #require(try authority.read(taskID: task.id, taskOwnerID: task.persistentModelID))
        do {
            let lease = try authority.acquire(taskID: task.id, taskOwnerID: task.persistentModelID)
            try authority.retain(previous)
            var next = previous; next.executionID = UUID(); next.runID = UUID()
            next.retainedExecutionHead = previous.executionID
            try lease.save(next)
        }
        #expect(try RemoteWorkspaceJobRegistration.load(task: task, context: h.context) == nil)
        #expect(try RemoteWorkspaceJobRegistration.loadAll(task: task, context: h.context) == [config])
        #expect(try RemoteWorkspaceJobMonitorSession.registeredTasks(context: h.context).map(\.id) == [task.id])
        #expect(throws: (any Error).self) { try config.ownerBinding?.validateLaunch() }
    }

    @Test("Registration follows the final execution ID and retains its time allowance")
    func finalExecutionIdentity() throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Synthetic remote job", model: "haiku", tokenBudget: 1000)
        let owner = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 45))
        defer { owner.finish() }
        let run = TaskRun(task: task); h.context.insert(run)
        try owner.bind(run: run)
        let preparingID = owner.record.executionID
        try owner.prepareLaunch()
        #expect(owner.record.executionID != preparingID)
        let config = try RemoteWorkspaceJobRegistration.prepare(task: task, runID: run.id, owner: owner, context: h.context, connections: [])
        #expect(config.ownerBinding?.receiptPath == owner.receiptURL?.path)
        #expect(FileManager.default.fileExists(atPath: try #require(config.ownerBinding?.receiptPath)))
        #expect(config.ownerBinding?.executionID == owner.record.executionID.uuidString)
        #expect(config.maximumJobSeconds == 45)
        #expect(try RemoteWorkspaceJobRegistration.load(task: task, context: h.context) == config)
        #expect(config.observationSSHOptions?.contains { $0.contains(".runtime-ssh/known_hosts") } == true)
        #expect(throws: (any Error).self) { try config.ownerBinding?.validateLaunch() }
        owner.requestCancellation()
        #expect(throws: (any Error).self) { try config.ownerBinding?.validateLaunch() }
        #expect(owner.record.limits.tokenCeiling == 1000)
    }

    @Test("Broker transitions reach durable history once even across an acknowledgement crash")
    func eventOutbox() throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Synthetic", model: "haiku")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RemoteWorkspaceJobStore(rootPath: root.path)
        let job = RemoteWorkspaceJobRecord(jobID: UUID().uuidString.lowercased(), taskID: task.id.uuidString,
            connection: .init(id: "qa", name: "QA", target: "qa", arguments: ["qa"]), command: "true", createdAt: Date())
        try store.create(job)
        try store.update(jobID: job.jobID) { $0.status = .running }
        let ended = try store.update(jobID: job.jobID) { $0.status = .succeeded }
        #expect(ended.pendingTransitions?.count == 3)
        try RemoteWorkspaceJobEventReconciler.reconcile(ended, task: task, context: h.context, store: store)
        #expect(task.events.filter { $0.hasType(TaskEventTypes.System.remoteJobObserved) }.count == 3)
        // Simulate a crash after saving events but before acknowledging them.
        try store.update(jobID: job.jobID) { $0.pendingTransitions = ended.pendingTransitions }
        try RemoteWorkspaceJobEventReconciler.reconcile(ended, task: task, context: h.context, store: store)
        #expect(task.events.filter { $0.hasType(TaskEventTypes.System.remoteJobObserved) }.count == 3)
        #expect(try store.load(jobID: job.jobID).pendingTransitions?.isEmpty == true)
        h.context.delete(task); try h.context.save()
        try RemoteWorkspaceJobEventReconciler.reconcile(ended, task: task, context: h.context, store: store)
        #expect(try h.context.fetch(FetchDescriptor<AgentTask>()).isEmpty)
    }
    @Test("Cancellation survives deletion, including late registration without widening a single-job stop", arguments: [0, 1, 2])
    func cancellationAfterDeletion(scenario: Int) async throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Synthetic", model: "haiku")
        let workspace = try #require(task.workspace)
        let connection = SSHConnection(name: "QA", host: "127.0.0.1", user: "qa", port: 22441)
        SSHConnectionManager.save([connection], workspacePath: workspace.primaryPath)
        let target = RemoteWorkspaceSSHRoute.connectTarget(for: connection)
        let connections = RemoteWorkspaceJobShim.offeredConnections(task: task, targets: [target])
        let owner = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60))
        defer { owner.finish() }
        let run = TaskRun(task: task); h.context.insert(run); try owner.bind(run: run); try owner.prepareLaunch()
        let config = try RemoteWorkspaceJobRegistration.prepare(task: task, runID: run.id, owner: owner, context: h.context, connections: connections)
        let trust = URL(fileURLWithPath: TaskWorkspaceAccess(task: task).taskFolder).appendingPathComponent(".runtime-ssh/known_hosts")
        try FileManager.default.createDirectory(at: trust.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("synthetic-public-host-key\n".utf8).write(to: trust)
        var job = RemoteWorkspaceJobRecord(jobID: UUID().uuidString.lowercased(), taskID: task.id.uuidString, runID: run.id.uuidString,
            connection: try #require(connections.first), command: "sleep 60", createdAt: Date())
        job.status = .running; job.ownerID = config.ownerBinding?.ownerID; job.executionID = config.ownerBinding?.executionID
        let store = RemoteWorkspaceJobStore(rootPath: config.recordRootPath)
        if scenario != 0 { try store.create(job) }
        let delivered = OSAllocatedUnfairLock(initialState: false)
        #expect(RemoteWorkspaceJobMonitor.shared.requestCancellation(task: task, jobID: scenario == 2 ? job.jobID : nil, context: h.context, deliver: { saved in
            delivered.withLock { $0 = saved.ownerBinding == config.ownerBinding }
        }))
        // Move the old registration into retained lineage before the outbox
        // reopens. Cancellation must survive both a new turn and task deletion.
        owner.finish()
        let authority = RuntimeExecutionOwner.store(in: h.context)
        let previous = try #require(try authority.read(taskID: task.id, taskOwnerID: task.persistentModelID))
        do {
            let lease = try authority.acquire(taskID: task.id, taskOwnerID: task.persistentModelID)
            try authority.retain(previous)
            var successor = previous; successor.executionID = UUID()
            successor.retainedExecutionHead = previous.executionID
            try lease.save(successor)
        }
        h.context.delete(task); try h.context.save(); try FileManager.default.removeItem(at: trust)
        if scenario == 0 { try store.create(job) }
        var lateJob = job
        lateJob.jobID = UUID().uuidString.lowercased()
        try store.create(lateJob)
        for _ in 0..<100 where !delivered.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(delivered.withLock { $0 })
        let reopened = try RemoteWorkspaceJobCancellationDelivery.pending(context: h.context)
        #expect(reopened.count == 1)
        #expect(reopened.first?.ownerBinding == config.ownerBinding)
        #expect(reopened.first?.observationSSHOptions?.contains { $0.contains("cancel-known_hosts") } == true)
        _ = try RemoteWorkspaceJobCancellationDelivery.preparePendingCancellation(try #require(reopened.first))
        #expect(try store.load(jobID: job.jobID).cancellationRequestedAt != nil)
        #expect((try store.load(jobID: lateJob.jobID).cancellationRequestedAt != nil) == (scenario != 2))
        // A worker's finalizer may run after deletion. It updates only the
        // durable owner and must neither fault nor resurrect deleted models.
        owner.finish()
        #expect(try RuntimeExecutionOwner.store(in: h.context).read(taskID: owner.record.taskID, taskOwnerID: owner.record.taskOwnerID)?.limits == owner.record.limits)
        #expect(owner.record.stopProof == nil)
        #expect(owner.record.resourcesReleased != true)
        #expect(try h.context.fetch(FetchDescriptor<AgentTask>()).isEmpty)
    }

}

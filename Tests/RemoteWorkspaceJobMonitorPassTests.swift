import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
import WorkspaceToolSupport
@testable import ASTRA

// The remote job monitor runs a pass every 15 seconds. It used to open every
// owner's receipt and every execution it retains on the main actor, and then
// walk the task table once per registered owner to find its task. On a store
// with history that was over a second of main-actor work per pass, and a
// stall of many seconds whenever the Mac was busy. A pass now reads the
// journal once on a worker thread and finds each task by its row.

@Suite("Remote job monitor pass", .serialized)
@MainActor
struct RemoteWorkspaceJobMonitorPassTests {
    /// A task whose execution registered remote jobs. The harness gives every
    /// task the same folder, and a folder holds one execution at a time, so
    /// these executions claim none: the monitor is what is under test. By
    /// default the execution is finished; its receipt stays the task's
    /// current one, which is what a pass selects.
    private func registeredTask(
        _ h: HeadlessChatHarness, goal: String, finished: Bool = true
    ) throws -> (task: AgentTask, owner: RuntimeExecutionOwner, configuration: RemoteWorkspaceJobConfiguration) {
        let task = h.makeTask(runtime: .claudeCode, goal: goal, model: "test")
        let owner = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60, resourceClaims: []))
        let run = TaskRun(task: task)
        h.context.insert(run)
        try owner.bind(run: run)
        try owner.prepareLaunch()
        try h.context.save()
        let configuration = try RemoteWorkspaceJobRegistration.prepare(
            task: task, runID: run.id, owner: owner, context: h.context, connections: [])
        if finished { owner.finish() }
        return (task, owner, configuration)
    }

    private func summary(_ journal: RemoteWorkspaceJobMonitorSession.Journal) -> [String] {
        journal.owners.map { owner in
            "\(owner.record.taskID) \(owner.record.executionID) \(owner.executions.map(\.executionID)) \(owner.isRegistered)"
        }.sorted()
    }

    @Test("The journal read on a worker thread is the journal the main actor reads")
    func journalReadsTheSameOffTheMainActor() async throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let registered = try registeredTask(h, goal: "Registered")
        // An execution with no registration is in the journal and not registered.
        let plain = h.makeTask(runtime: .claudeCode, goal: "No remote jobs", model: "test")
        let plainOwner = try #require(RuntimeExecutionOwner.acquire(task: plain, context: h.context, maxRunSeconds: 60, resourceClaims: []))
        plainOwner.finish()

        let root = RuntimeExecutionOwner.store(in: h.context).root
        let onMain = try RemoteWorkspaceJobMonitorSession.readJournal(ownersRoot: root)
        // A detached task runs off the main actor: the read needs no isolation.
        let offMain = try await Task.detached {
            try RemoteWorkspaceJobMonitorSession.readJournal(ownersRoot: root)
        }.value
        let pass = try await RemoteWorkspaceJobMonitorSession.journal(context: h.context)

        #expect(summary(onMain).count == 2)
        #expect(summary(offMain) == summary(onMain))
        #expect(summary(pass) == summary(onMain))
        let byTask = Dictionary(uniqueKeysWithValues: onMain.owners.map { ($0.record.taskID, $0) })
        #expect(byTask[registered.task.id]?.isRegistered == true)
        #expect(byTask[plain.id]?.isRegistered == false)
        // Each owner's own execution comes first in its list.
        #expect(onMain.owners.allSatisfy { $0.executions.first?.executionID == $0.record.executionID })
    }

    @Test("A pass finds a bound receipt's task by its row, and no other task that shares its ID")
    func boundReceiptsResolveByRow() async throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        for index in 0..<40 { _ = h.makeTask(runtime: .claudeCode, goal: "Unrelated \(index)", model: "test") }
        let first = try registeredTask(h, goal: "First")
        let second = try registeredTask(h, goal: "Second")
        // An imported copy carrying the first task's portable ID.
        let twin = h.makeTask(runtime: .claudeCode, goal: "Imported copy", model: "test")
        twin.id = first.task.id
        try h.context.save()

        let journal = try await RemoteWorkspaceJobMonitorSession.journal(context: h.context)
        #expect(journal.owners.filter(\.isRegistered).allSatisfy { $0.record.taskOwnerID != nil })
        let found = try RemoteWorkspaceJobMonitorSession.registeredTasks(journal: journal, context: h.context)
        #expect(Set(found.map(\.persistentModelID)) == [first.task.persistentModelID, second.task.persistentModelID])
        #expect(found.count == 2)
        // The synchronous entry point, which reads the journal itself, agrees.
        let direct = try RemoteWorkspaceJobMonitorSession.registeredTasks(context: h.context)
        #expect(Set(direct.map(\.persistentModelID)) == Set(found.map(\.persistentModelID)))
    }

    @Test("A receipt that names no row is matched by the task's ID, once for all such receipts, and still only to its own task")
    func unboundReceiptsResolveByTaskID() async throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let first = try registeredTask(h, goal: "First")
        let second = try registeredTask(h, goal: "Second")
        let twin = h.makeTask(runtime: .claudeCode, goal: "Imported copy", model: "test")
        twin.id = first.task.id
        try h.context.save()

        // The same journal as an older build wrote it: receipts without a row.
        let read = try await RemoteWorkspaceJobMonitorSession.journal(context: h.context)
        let unbound = RemoteWorkspaceJobMonitorSession.Journal(owners: read.owners.map { owner in
            var record = owner.record
            record.taskOwnerID = nil
            return .init(record: record, executions: owner.executions, isRegistered: owner.isRegistered)
        })
        let found = try RemoteWorkspaceJobMonitorSession.registeredTasks(journal: unbound, context: h.context)
        #expect(Set(found.map(\.persistentModelID)) == [first.task.persistentModelID, second.task.persistentModelID])
        #expect(!found.contains { $0 === twin })
    }

    @Test("An unbound receipt on disk is attributed from the tasks already fetched, by the same audit and one-owner rule")
    func unboundReceiptOnDiskIsAttributedFromFetchedTasks() async throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let registered = try registeredTask(h, goal: "Receipt from an older build")
        let task = registered.task
        let twin = h.makeTask(runtime: .claudeCode, goal: "Imported copy", model: "test")
        twin.id = task.id
        let authority = RuntimeExecutionOwner.store(in: h.context)
        var record = try #require(try authority.read(taskID: task.id, taskOwnerID: task.persistentModelID))
        // The task's own audit of this execution, which attribution reads.
        let audit = try #require(String(data: try JSONEncoder().encode(record), encoding: .utf8))
        h.context.insert(TaskEvent(task: task, eventType: TaskEventTypes.System.runtimeExecutionOwnership, payload: audit))
        try h.context.save()

        // Put the receipt where an older build kept it: under the task's ID
        // alone, naming no row.
        record.taskOwnerID = nil
        do {
            let lease = try authority.acquire(taskID: task.id)
            try lease.save(record)
        }
        let bound = try FileManager.default.contentsOfDirectory(atPath: authority.root.path)
            .filter { $0.hasPrefix(task.id.uuidString + "-") && $0.hasSuffix(".json") }
        #expect(bound.count == 1)
        for name in bound { try FileManager.default.removeItem(at: authority.root.appendingPathComponent(name)) }
        #expect(try authority.read(taskID: task.id, taskOwnerID: task.persistentModelID) == nil)
        let legacy = try #require(try authority.read(taskID: task.id))
        #expect(legacy.taskOwnerID == nil)

        // The pass reads it unbound, and still selects the task and not its copy.
        let journal = try await RemoteWorkspaceJobMonitorSession.journal(context: h.context)
        #expect(journal.owners.filter(\.isRegistered).map(\.record.taskOwnerID) == [nil])
        let found = try RemoteWorkspaceJobMonitorSession.registeredTasks(journal: journal, context: h.context)
        #expect(found.map(\.persistentModelID) == [task.persistentModelID])

        // Attribution over supplied tasks is attribution over its own fetch.
        let own = try RuntimeTaskOwnerJournal.legacyOwner(legacy, context: h.context)
        #expect(own == task.persistentModelID)
        #expect(try RuntimeTaskOwnerJournal.legacyOwner(legacy, context: h.context, sharingID: [twin, task]) == own)
        #expect(try RuntimeExecutionOwner.existing(task: task, context: h.context, sharingID: [task, twin])?.executionID == legacy.executionID)
        #expect(try RuntimeExecutionOwner.existing(task: twin, context: h.context, sharingID: [task, twin]) == nil)
        // A row with another ID is not a candidate, and without the audited
        // task there is no owner: the receipt stays unreadable, never guessed.
        let other = h.makeTask(runtime: .claudeCode, goal: "Other", model: "test")
        #expect(try RuntimeTaskOwnerJournal.legacyOwner(legacy, context: h.context, sharingID: [other, task]) == own)
        #expect(throws: (any Error).self) {
            try RuntimeTaskOwnerJournal.legacyOwner(legacy, context: h.context, sharingID: [twin])
        }
        #expect(throws: (any Error).self) {
            try RuntimeTaskOwnerJournal.legacyOwner(legacy, context: h.context, sharingID: [other])
        }
    }

    @Test("A receipt whose row is gone, or whose execution is no longer the task's current one, selects nothing")
    func staleReceiptsSelectNothing() async throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let registered = try registeredTask(h, goal: "Registered")
        let journal = try await RemoteWorkspaceJobMonitorSession.journal(context: h.context)
        // As read, the journal selects the task.
        #expect(try RemoteWorkspaceJobMonitorSession.registeredTasks(journal: journal, context: h.context)
            .map(\.persistentModelID) == [registered.task.persistentModelID])

        // The journal as read, but naming another execution as the owner's.
        let moved = RemoteWorkspaceJobMonitorSession.Journal(owners: journal.owners.map { owner in
            var record = owner.record
            record.executionID = UUID()
            return .init(record: record, executions: owner.executions, isRegistered: owner.isRegistered)
        })
        #expect(try RemoteWorkspaceJobMonitorSession.registeredTasks(journal: moved, context: h.context).isEmpty)

        // The journal as read, but its row is another task's.
        let other = h.makeTask(runtime: .claudeCode, goal: "Other", model: "test")
        try h.context.save()
        let misbound = RemoteWorkspaceJobMonitorSession.Journal(owners: journal.owners.map { owner in
            var record = owner.record
            record.taskOwnerID = other.persistentModelID
            return .init(record: record, executions: owner.executions, isRegistered: owner.isRegistered)
        })
        #expect(try RemoteWorkspaceJobMonitorSession.registeredTasks(journal: misbound, context: h.context).isEmpty)
        #expect(try RemoteWorkspaceJobMonitorSession.registeredTasks(journal: .init(owners: []), context: h.context).isEmpty)
    }

    @Test("The cancellation outbox finds the same deliveries from executions the pass read")
    func pendingDeliveriesFromTheJournal() async throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let registered = try registeredTask(h, goal: "To cancel", finished: false)
        defer { registered.owner.finish() }
        // A saved cancellation pins the task's host trust file.
        let trust = URL(fileURLWithPath: TaskWorkspaceAccess(task: registered.task).taskFolder)
            .appendingPathComponent(".runtime-ssh/known_hosts")
        try FileManager.default.createDirectory(at: trust.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("synthetic-public-host-key\n".utf8).write(to: trust)
        let delivery = try RemoteWorkspaceJobCancellationDelivery.persist(
            configuration: registered.configuration, task: registered.task, cancelExecution: true)

        let executions = try await RemoteWorkspaceJobMonitorSession.journal(context: h.context).owners.flatMap(\.executions)
        let fromJournal = try RemoteWorkspaceJobCancellationDelivery.pending(executions: executions, context: h.context)
        #expect(fromJournal == [delivery])
        #expect(try RemoteWorkspaceJobCancellationDelivery.pending(context: h.context) == fromJournal)
        #expect(try RemoteWorkspaceJobCancellationDelivery.pending(executions: [], context: h.context).isEmpty)
    }

    @Test("The pass reads the journal on a worker thread and never walks the task table once per owner")
    func passStaysOffThePerOwnerWalk() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Astra/Services/Runtime/RemoteWorkspaceJobMonitor.swift"), encoding: .utf8)
        let loopStart = try #require(source.range(of: "loop = Task { @MainActor in"))
        let loopEnd = try #require(source.range(of: "do { try await Task.sleep(for: .seconds(15)) }", range: loopStart.upperBound..<source.endIndex))
        let loop = String(source[loopStart.lowerBound..<loopEnd.lowerBound])
        // The pass awaits the journal for its tasks and again for its deliveries.
        #expect(loop.components(separatedBy: "try await Self.journal(context: context)").count == 3)
        #expect(!loop.contains("registeredTasks(context:"))
        #expect(!loop.contains("pending(context:"))
        // The journal is read through the worker, with the main actor as the fallback.
        #expect(source.contains("await BlockingWork.run(qos: .utility) { Result { try readJournal(ownersRoot: root) } }"))
        // No lookup by a single task's portable ID is left in the monitor,
        // and an unbound receipt's attribution is handed the fetched tasks.
        #expect(!source.contains("#Predicate { $0.id == taskID }"))
        #expect(source.contains("RuntimeExecutionOwner.existing(task: task, context: context, sharingID: sharingID)"))
    }
}

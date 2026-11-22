import Testing
import Foundation
import SwiftData
import ASTRAModels
@testable import ASTRA
@testable import ASTRAPersistence

// A workspace's mirror export used to look up the owner of each task's turn
// requests with one walk of the task table per task, and to order each task's
// events with a comparator that read the store's rows on every comparison.
// Both made rewriting a mirror cost seconds on the main actor. The export now
// asks for the owners once and orders on keys read once, and must write the
// same mirror.

@Suite("Workspace mirror export lookups")
@MainActor
struct WorkspaceMirrorExportLookupTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    private func identities(_ tasks: [AgentTask]) -> [PersistentIdentifier: Int] {
        tasks.reduce(into: [:]) { counts, task in counts[task.persistentModelID, default: 0] += 1 }
    }

    @Test("One lookup for many tasks returns what a lookup per task returns: twins, unsaved and deleted rows included")
    func batchedCandidatesMatchSingleLookups() throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.autosaveEnabled = false
        let home = Workspace(name: "Home", primaryPath: "/tmp/astra-mirror-lookup-home")
        let other = Workspace(name: "Other", primaryPath: "/tmp/astra-mirror-lookup-other")
        context.insert(home)
        context.insert(other)
        let first = AgentTask(title: "first", goal: "g", workspace: home)
        let second = AgentTask(title: "second", goal: "g", workspace: home)
        let removed = AgentTask(title: "removed", goal: "g", workspace: home)
        // Another task that carries the first one's portable ID, as an import can leave.
        let twin = AgentTask(title: "twin", goal: "g", workspace: other)
        twin.id = first.id
        for task in [first, second, removed, twin] { context.insert(task) }
        try context.save()
        let unsaved = AgentTask(title: "unsaved", goal: "g", workspace: home)
        context.insert(unsaved)
        context.delete(removed)

        let ids = [first.id, second.id, removed.id, unsaved.id, UUID()]
        var expected: [AgentTask] = []
        for id in ids { expected += try TaskTurnRequestOwnership.candidates(taskID: id, in: context) }
        #expect(expected.contains { $0 === twin })

        for batch in [1, 2, TaskTurnRequestOwnership.candidateLookupBatch] {
            let found = try TaskTurnRequestOwnership.candidates(taskIDs: ids + [first.id], in: context, batch: batch)
            #expect(identities(found) == identities(expected), "batch \(batch)")
        }
        #expect(try TaskTurnRequestOwnership.candidates(taskIDs: [], in: context).isEmpty)
    }

    private struct Row: Equatable {
        let time: Date
        let id: UUID
    }

    @Test("Ordering on keys read once gives the order the per-comparison sort gave, ties included")
    func chronologicalMatchesTheOriginalComparator() {
        var generator = SystemRandomNumberGenerator()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        // Few distinct times, so most comparisons are ties broken by ID.
        let rows = (0..<400).map { _ in
            Row(time: base.addingTimeInterval(Double(Int.random(in: 0..<6, using: &generator))), id: UUID())
        }
        let original = rows.sorted {
            $0.time == $1.time ? $0.id.uuidString < $1.id.uuidString : $0.time < $1.time
        }
        #expect(WorkspaceConfigManager.chronological(rows, time: \.time, id: \.id) == original)
        #expect(WorkspaceConfigManager.chronological([Row](), time: \.time, id: \.id).isEmpty)
    }

    @Test("Each exported task carries only its own requests, also when a task in another workspace shares its ID")
    func exportKeepsRequestsWithTheirOwnTask() throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.autosaveEnabled = false
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-mirror-lookup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = Workspace(name: "Home", primaryPath: root.appendingPathComponent("home").path)
        let other = Workspace(name: "Other", primaryPath: root.appendingPathComponent("other").path)
        context.insert(home)
        context.insert(other)
        let first = AgentTask(title: "first", goal: "g", workspace: home)
        let second = AgentTask(title: "second", goal: "g", workspace: home)
        let idle = AgentTask(title: "idle", goal: "g", workspace: home)
        let twin = AgentTask(title: "twin", goal: "g", workspace: other)
        twin.id = first.id
        for task in [first, second, idle, twin] { context.insert(task) }
        // Saved first: a request binds to its task's durable identity.
        try context.save()

        var requests: [String: TaskTurnRequest] = [:]
        for (name, task) in [("first", first), ("second", second), ("twin", twin)] {
            let message = TaskEvent(task: task, type: "user.message", payload: name)
            context.insert(message)
            let request = TaskTurnRequest(task: task, messageEventID: message.id, sequence: 1)
            context.insert(request)
            requests[name] = request
        }
        try context.save()

        let homeConfig = try #require(WorkspaceConfigManager.export(workspace: home, modelContext: context))
        func requestIDs(_ config: WorkspaceConfigManager.WorkspaceConfig, title: String) -> [UUID] {
            ((config.tasks ?? []).first { $0.title == title }?.turnRequests ?? []).map(\.id)
        }
        #expect(homeConfig.tasks?.count == 3)
        #expect(requestIDs(homeConfig, title: "first") == [try #require(requests["first"]).id])
        #expect(requestIDs(homeConfig, title: "second") == [try #require(requests["second"]).id])
        #expect(requestIDs(homeConfig, title: "idle").isEmpty)

        let otherConfig = try #require(WorkspaceConfigManager.export(workspace: other, modelContext: context))
        #expect(requestIDs(otherConfig, title: "twin") == [try #require(requests["twin"]).id])
    }

    @Test("The export asks for request owners once, and reads each task's rows once")
    func exportDoesNotLookUpOwnersPerTask() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let manager = try String(
            contentsOf: root.appendingPathComponent("Astra/Services/Persistence/WorkspaceConfigManager.swift"), encoding: .utf8)
        let start = try #require(manager.range(of: "private static func taskConfig(\n"))
        let end = try #require(manager.range(of: "\n    private static func ", range: start.upperBound..<manager.endIndex))
        let taskConfig = String(manager[start.lowerBound..<end.lowerBound])
        // The per-task body gets its owners from the caller and never asks the store for them.
        #expect(taskConfig.contains("owners: &owners"))
        #expect(!taskConfig.contains("TaskTurnRequestOwnership.candidates("))
        #expect(!taskConfig.contains("taskRecoveryMirror(task: task, modelContext:"))
        // It reads the task's events and runs from the store once each.
        #expect(taskConfig.components(separatedBy: "task.events").count == 2)
        #expect(taskConfig.components(separatedBy: "task.runs").count == 2)
        // The one lookup is the batched one, made for all the workspace's tasks.
        #expect(manager.components(separatedBy: "TaskTurnRequestOwnership.candidates(").count == 2)
        #expect(manager.contains("TaskTurnRequestOwnership.candidates(taskIDs: tasks.map(\\.id), in: modelContext)"))
    }
}

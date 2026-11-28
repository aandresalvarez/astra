import Testing
import Foundation
import SwiftData
import ASTRACore
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

    /// A history whose mirror needs rows from every part of it: more events
    /// than the mirror keeps, a timestamp tie across the cut, an old recovery
    /// event of each kind, a pending run older than the kept runs, an old
    /// message an active request points at, Codex usage evidence complete on
    /// one task and marked incomplete on another, and a task in another
    /// workspace that shares the first one's ID.
    private struct LongHistory {
        let home: Workspace
        let long: AgentTask
        let pendingRunID: UUID
        /// Old tool output only the full relationship read loads.
        let oldOutputIDs: [PersistentIdentifier]
    }

    private func makeLongHistory(in context: ModelContext, root: URL) throws -> LongHistory {
        let home = Workspace(name: "Home", primaryPath: root.appendingPathComponent("home").path)
        let other = Workspace(name: "Other", primaryPath: root.appendingPathComponent("other").path)
        context.insert(home)
        context.insert(other)
        let long = AgentTask(title: "long", goal: "g", workspace: home)
        let complete = AgentTask(title: "codex complete", goal: "g", workspace: home)
        let incomplete = AgentTask(title: "codex incomplete", goal: "g", workspace: home)
        let twin = AgentTask(title: "twin", goal: "g", workspace: other)
        twin.id = long.id
        for task in [long, complete, incomplete, twin] { context.insert(task) }
        try context.save()

        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var clock = 0.0
        func event(_ task: AgentTask, _ type: String, run: TaskRun? = nil, at time: Date? = nil) -> TaskEvent {
            clock += 1
            // A captured result's payload is a checkpoint; the mirror drops one it cannot parse.
            let payload = type == "runtime.result.captured" ? #"{"sequence":\#(clock)}"# : "\(type) \(clock)"
            let row = TaskEvent(task: task, type: type, payload: payload, run: run)
            row.timestamp = time ?? base.addingTimeInterval(clock)
            context.insert(row)
            return row
        }
        func run(_ task: AgentTask, codex: Bool = false) -> TaskRun {
            clock += 1
            let row = TaskRun(task: task)
            row.startedAt = base.addingTimeInterval(clock)
            if codex {
                row.runtimeID = AgentRuntimeID.codexCLI.rawValue
                row.providerSessionId = "session-\(Int(clock))"
            }
            context.insert(row)
            return row
        }

        let settledRun = run(long)
        let pendingRun = run(long)
        let message = event(long, "user.message")
        _ = event(long, "runtime.turn.settled", run: settledRun)
        _ = event(long, "runtime.result.captured", run: settledRun)
        _ = event(long, "runtime.result.captured", run: pendingRun)
        for type in ["execution.request.created", "permission.approval.requested", "plan.updated",
                     "validation.contract.created", "task.worktree.prepared", "astra.provider_session_usage_recorded"] {
            _ = event(long, type)
        }
        var oldOutput: [TaskEvent] = []
        for _ in 0..<40 { oldOutput.append(event(long, "tool.result")) }
        for _ in 0..<12 { _ = run(long) }
        // The newest ten end inside a group of six that share one time, so
        // which four of them the mirror keeps is decided by ID.
        let tie = base.addingTimeInterval(clock + 1)
        for _ in 0..<6 { _ = event(long, "tool.use", at: tie) }
        clock += 1
        for _ in 0..<6 { _ = event(long, "agent.response") }
        context.insert(TaskTurnRequest(task: long, messageEventID: message.id, sequence: 1))
        let twinMessage = event(twin, "user.message")
        twinMessage.id = message.id
        for _ in 0..<20 { _ = event(twin, "tool.result") }

        for (task, marked) in [(complete, false), (incomplete, true)] {
            let codexRun = run(task, codex: true)
            if marked { _ = event(task, CodexUsageHistory.incompleteEventType) }
            for _ in 0..<20 { _ = event(task, "tool.result", run: codexRun) }
            _ = event(task, "astra.provider_session_usage_recorded", run: codexRun)
            _ = event(task, "task.stats", run: codexRun)
        }
        try context.save()
        return LongHistory(home: home, long: long, pendingRunID: pendingRun.id, oldOutputIDs: oldOutput.map(\.persistentModelID))
    }

    /// The workspace's tasks as the mirror writes them, exported from a fresh
    /// context, which then reports which old rows the export loaded.
    private func exportTasks(_ fixture: LongHistory, container: ModelContainer,
                             boundedAbove threshold: Int) throws -> (tasks: [String: Data], loadedOldOutput: Int) {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let homeID = fixture.home.id
        let home = try #require(try context.fetch(FetchDescriptor<Workspace>(predicate: #Predicate { $0.id == homeID })).first)
        let config = try WorkspaceConfigManager.TaskMirrorHistory.$boundedReadMinimumEventCount.withValue(threshold) {
            try #require(WorkspaceConfigManager.export(workspace: home, modelContext: context))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let loaded = fixture.oldOutputIDs.filter { (context.registeredModel(for: $0) as TaskEvent?) != nil }.count
        // Keyed by title: the mirror lists tasks in relationship order, which no context promises.
        var tasks: [String: Data] = [:]
        for var task in config.tasks ?? [] {
            task.turnRequests = task.turnRequests?.map { request in
                var request = request
                request.executionPolicySnapshotJSON = canonical(request.executionPolicySnapshotJSON)
                return request
            }
            tasks[task.title] = try encoder.encode(task)
        }
        return (tasks, loaded)
    }

    /// The same JSON with sorted keys. The mirror serializes a request's
    /// policy without them, so two exports of one row can order keys differently.
    private func canonical(_ json: String?) -> String? {
        guard let json, let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return json }
        return String(decoding: data, as: UTF8.self)
    }

    @Test("A large task's mirror reads only the events it keeps, and writes what reading every event wrote")
    func boundedHistoryWritesTheSameMirror() throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.autosaveEnabled = false
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-mirror-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeLongHistory(in: context, root: root)
        let indexed = TaskOwnerPredicate.usesRelationshipIndex(for: fixture.long.persistentModelID, in: context)

        let full = try exportTasks(fixture, container: container, boundedAbove: .max)
        let bounded = try exportTasks(fixture, container: container, boundedAbove: 0)
        let differing = Set(full.tasks.keys).union(bounded.tasks.keys).filter { full.tasks[$0] != bounded.tasks[$0] }
        #expect(full.tasks.count == 3)
        #expect(differing.isEmpty, "mirrors differ for \(differing.sorted())")
        #expect(full.loadedOldOutput == fixture.oldOutputIDs.count)
        // Where SwiftData cannot run the indexed predicates both reads are the relationship.
        #expect(bounded.loadedOldOutput == (indexed ? 0 : fixture.oldOutputIDs.count))

        let tasks = try full.tasks.values.map { try JSONDecoder().decode(WorkspaceConfigManager.TaskConfig.self, from: $0) }
        let long = try #require(tasks.first { $0.title == "long" })
        let types = long.events.map(\.type)
        #expect(types.contains("user.message"), "the active request's old message")
        #expect(types.filter { $0 == "runtime.result.captured" }.count == 2)
        #expect(long.runs.map(\.id).contains(fixture.pendingRunID.uuidString), "a pending run older than the kept runs")
        #expect(long.events.filter { $0.type == "tool.use" || $0.type == "agent.response" }.count
            == WorkspaceConfigManager.MirrorLimits.maxEventsPerTask)
        #expect(!long.events.contains { $0.type == "tool.result" })
        #expect(tasks.first { $0.title == "codex complete" }?.codexUsageHistoryComplete == true)
        #expect(tasks.first { $0.title == "codex incomplete" }?.codexUsageHistoryComplete == false)
    }

    @Test("A context with unsaved changes, or a small task, reads the relationship")
    func boundedHistoryOnlyForSavedLargeTasks() throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.autosaveEnabled = false
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-mirror-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeLongHistory(in: context, root: root)
        let indexed = TaskOwnerPredicate.usesRelationshipIndex(for: fixture.long.persistentModelID, in: context)
        typealias History = WorkspaceConfigManager.TaskMirrorHistory

        History.$boundedReadMinimumEventCount.withValue(0) {
            #expect(History(task: fixture.long, modelContext: context).isBounded == indexed)
        }
        #expect(!History(task: fixture.long, modelContext: context).isBounded, "far fewer events than the default")
        context.insert(TaskEvent(task: fixture.long, type: "user.message", payload: "unsaved"))
        History.$boundedReadMinimumEventCount.withValue(0) {
            #expect(!History(task: fixture.long, modelContext: context).isBounded)
        }
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
        // It reads the task's events and runs from the store once each, the
        // events through the reader that bounds a large task's history.
        #expect(!taskConfig.contains("task.events"))
        #expect(taskConfig.components(separatedBy: "TaskMirrorHistory(").count == 2)
        #expect(taskConfig.components(separatedBy: "task.runs").count == 2)
        // The one lookup is the batched one, made for all the workspace's tasks.
        #expect(manager.components(separatedBy: "TaskTurnRequestOwnership.candidates(").count == 2)
        #expect(manager.contains("TaskTurnRequestOwnership.candidates(taskIDs: tasks.map(\\.id), in: modelContext)"))
    }
}

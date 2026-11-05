import Foundation
import SwiftData
import SQLite3
import Testing
import ASTRAModels
@testable import ASTRA

@Suite("Publication evidence commit boundaries")
@MainActor
struct TaskPublicationDecisionEvidenceCommitTests {
    @Test("A read between willSave and the SQLite commit cannot stay cached")
    func readDuringCommitIsInvalidated() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        #expect(try fixture.read().isEmpty)
        let before = fixture.cache.mutations.revision
        var database: OpaquePointer?
        try #require(sqlite3_open_v2(fixture.file.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        defer { sqlite3_close(database) }
        try #require(sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        defer { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }
        let container = fixture.container
        let editedID = fixture.editedID
        let writer = Task.detached {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let event = try #require(context.fetch(FetchDescriptor<TaskEvent>(predicate: #Predicate { $0.id == editedID })).first)
            event.payload = "gh pr create: permission denied"
            try context.save()
        }
        // The lock holds the real writer before commit, after its real willSave.
        for _ in 0..<2_000 {
            if fixture.cache.mutations.revision != before { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(fixture.cache.mutations.revision != before)
        let duringRevision = fixture.cache.mutations.revision
        #expect(try fixture.read().isEmpty)
        try #require(sqlite3_exec(database, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
        try await writer.value
        #expect(fixture.cache.mutations.revision != duringRevision)
        let after = try fixture.read()
        #expect(after.contains { $0.id == editedID })
        #expect(after == (try fixture.read(cached: false)))
        let durable = ModelContext(container)
        let ownerID = fixture.ownerID
        let task = try #require(durable.fetch(FetchDescriptor<AgentTask>(predicate: #Predicate { $0.persistentModelID == ownerID })).first)
        #expect(TaskExternalOutcomeRequirementResolver.pendingGitHubPullRequest(task: task) != nil)
        let work = fixture.cache.work
        #expect(try fixture.read() == after)
        #expect(fixture.cache.work.failureRowsScanned == work.failureRowsScanned)
        #expect(fixture.cache.work.cacheHits == work.cacheHits + 1)
    }

    @Test("Aborted and superseded save scopes never block or disable ordinary cache hits")
    func abandonedSaveScopeDoesNotWait() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        #expect(try fixture.read().isEmpty)
        let context = ModelContext(fixture.container)
        context.autosaveEnabled = false
        let editedID = fixture.editedID
        let edited = try #require(context.fetch(FetchDescriptor<TaskEvent>(predicate: #Predicate { $0.id == editedID })).first)
        edited.payload = "gh pr create: permission denied"
        // A failed save emits willSave without didSave. Exercise that boundary
        // directly, then abandon its changes; readers must keep making progress.
        NotificationCenter.default.post(name: ModelContext.willSave, object: context)
        context.rollback()
        #expect(try fixture.read().isEmpty)
        let work = fixture.cache.work
        #expect(try fixture.read().isEmpty)
        #expect(fixture.cache.work.cacheHits == work.cacheHits + 1)
        // A later ordinary save supersedes the abandoned relevant save scope.
        let ownerID = fixture.ownerID
        let task = try #require(context.fetch(FetchDescriptor<AgentTask>(predicate: #Predicate { $0.persistentModelID == ownerID })).first)
        context.insert(TaskEvent(task: task, type: "user.message", payload: "ordinary"))
        try context.save()
        #expect(try fixture.read().isEmpty)
        #expect(fixture.cache.work.failureRowsScanned == work.failureRowsScanned)
        // Missing willSave (observer installed mid-save) is conservative.
        let before = fixture.cache.mutations.revision
        NotificationCenter.default.post(name: ModelContext.didSave, object: context)
        #expect(fixture.cache.mutations.revision != before)
        #expect(try fixture.read().isEmpty)
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let file: URL
        let container: ModelContainer
        let cache: TaskPublicationDecisionEvidenceReader.Cache
        let taskID: UUID
        let ownerID: PersistentIdentifier
        let editedID: UUID
        let cursor: TaskThreadEventCursor

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            file = root.appendingPathComponent("history.store")
            container = try ModelContainer(for: Workspace.self, AgentTask.self, TaskRun.self, TaskEvent.self,
                                           configurations: ModelConfiguration(url: file))
            let context = container.mainContext
            context.autosaveEnabled = false
            let task = AgentTask(title: "Synthetic publication", goal: "Fix the bug and create a pull request")
            let run = TaskRun(task: task)
            context.insert(task)
            context.insert(run)
            var events: [TaskEvent] = []
            for index in 0..<343 {
                let event = TaskEvent(task: task, type: index < 2 ? "tool.result.failed" : "user.message",
                                      payload: "unrelated command failure", run: run)
                event.timestamp = Date(timeIntervalSince1970: Double(index))
                context.insert(event)
                events.append(event)
            }
            try context.save()
            taskID = task.id
            ownerID = task.persistentModelID
            editedID = events[0].id
            cursor = TaskThreadEventCursor(timestamp: events.last!.timestamp, id: events.last!.id, ownerID: ownerID)
            cache = TaskPublicationDecisionEvidenceReader.Cache(container: container)
        }

        func read(cached: Bool = true) throws -> [TaskEventSnapshot] {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            return try TaskThreadHistoryReader.tailPage(taskID: taskID, ownerID: ownerID, since: cursor,
                modelContext: context, publicationCache: cached ? cache : nil).publicationEvents
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
}

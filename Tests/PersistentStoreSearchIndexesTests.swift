import CoreData
import Foundation
import SQLite3
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

/// The event-type index lives in the store file, not in the SwiftData model,
/// because SwiftData cannot declare one below macOS 15. These pin that it is
/// created once, that SQLite uses it for the fetch the app makes, and that it
/// changes nothing SwiftData or an older build checks: the model digest, the
/// rows, a later migration, and a store that is busy when the app opens.
@Suite("The event-type index is created in the store file", .serialized)
@MainActor
struct PersistentStoreSearchIndexesTests {
    private static let index = PersistentStoreSearchIndexes.taskEventType

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("astra-search-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func open(_ url: URL) throws -> ModelContainer {
        try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
                           configurations: [ModelConfiguration(url: url)])
    }

    private func withDatabase<T>(_ url: URL, creating: Bool = false, _ body: (OpaquePointer) throws -> T) throws -> T {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | (creating ? SQLITE_OPEN_CREATE : 0)
        try #require(sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK)
        let db = try #require(database)
        defer { sqlite3_close(db) }
        return try body(db)
    }

    private func rows(_ db: OpaquePointer, _ sql: String) -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        var found: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let columns = sqlite3_column_count(statement)
            found.append((0..<columns).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            }.joined(separator: "|"))
        }
        return found
    }

    private func indexes(_ url: URL) throws -> Set<String> {
        try withDatabase(url) { Set(rows($0, "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZTASKEVENT'")) }
    }

    private func digest(_ url: URL) throws -> String {
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: url, options: nil)
        if let digest = metadata["NSStoreModelVersionHashesDigest"] as? String { return digest }
        return try #require(metadata["NSStoreModelVersionHashesDigest"] as? Data).base64EncodedString()
    }

    @Test("A store gets the index once, SQLite uses it for a fetch by type, and SwiftData sees the same store")
    func createdOnceAndUsed() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("default.store")
        // Open, as the app has its container when it asks.
        let container = try open(url)
        let context = container.mainContext
        let workspace = Workspace(name: "Index", primaryPath: "/tmp")
        let task = AgentTask(title: "Index", goal: "Find by type", workspace: workspace)
        context.insert(workspace); context.insert(task)
        for index in 0..<6 {
            context.insert(TaskEvent(task: task, type: index.isMultiple(of: 2) ? "runtime.execution_ownership" : "user.message",
                                     payload: "\(index)"))
        }
        try context.save()
        let before = try digest(url)
        #expect(!(try indexes(url)).contains(Self.index.name))

        #expect(PersistentStoreSearchIndexes.ensure(at: url) == [Self.index.name: .created])
        // The open container still reads and writes through it.
        context.insert(TaskEvent(task: task, type: "runtime.execution_ownership", payload: "6"))
        try context.save()
        #expect(PersistentStoreSearchIndexes.ensure(at: url) == [Self.index.name: .present])
        #expect(try indexes(url).contains(Self.index.name))
        // The shape SwiftData sends for `$0.type == type`.
        let plan = try withDatabase(url) { rows($0, "EXPLAIN QUERY PLAN SELECT 0, t0.Z_PK FROM ZTASKEVENT t0 WHERE t0.ZTYPE = ?") }
        #expect(plan.contains { $0.contains(Self.index.name) })
        #expect(try digest(url) == before)

        // The store opens as the same V21 store and answers as before.
        let reopened = try open(url)
        let type = "runtime.execution_ownership"
        let events = try reopened.mainContext.fetch(FetchDescriptor<TaskEvent>(predicate: #Predicate { $0.type == type }))
        #expect(events.map { $0.payload }.sorted() == ["0", "2", "4", "6"])
        #expect(WorkspaceRecoveryService.sqliteIntegrityIsValid(at: url))
        // Opening the store again leaves the index in place: the next launch has nothing to build.
        #expect(PersistentStoreSearchIndexes.ensure(at: url) == [Self.index.name: .present])
    }

    @Test("A busy store is left as it is, and the next open creates the index")
    func busyStoreIsSkipped() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("default.store")
        do { _ = try open(url) }
        try withDatabase(url) { holder in
            _ = sqlite3_busy_timeout(holder, 5_000)
            #expect(sqlite3_exec(holder, "BEGIN EXCLUSIVE", nil, nil, nil) == SQLITE_OK)
            #expect(PersistentStoreSearchIndexes.ensure(at: url, busyTimeoutMilliseconds: 0) == [Self.index.name: .busy])
            #expect(sqlite3_exec(holder, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
        }
        #expect(!(try indexes(url)).contains(Self.index.name))
        #expect(PersistentStoreSearchIndexes.ensure(at: url) == [Self.index.name: .created])
    }

    @Test("A store that cannot be written reports a failure, not a missing table")
    func readOnlyStoreFails() throws {
        let root = try folder()
        let url = root.appendingPathComponent("default.store")
        do { _ = try open(url) }
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path).map { root.appendingPathComponent($0).path }
        for path in files { try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            for path in files { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path) }
            try? FileManager.default.removeItem(at: root)
        }
        let outcome = try #require(PersistentStoreSearchIndexes.ensure(at: url)[Self.index.name])
        #expect(outcome.isFailure)
    }

    @Test("A store whose catalog cannot be read reports a failure, not a missing table")
    func unreadableStoreFails() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("default.store")
        try Data(repeating: 0x5A, count: 8_192).write(to: url)
        let outcome = try #require(PersistentStoreSearchIndexes.ensure(at: url)[Self.index.name])
        #expect(outcome.isFailure)
        #expect(!PersistentStoreSearchIndexes.drop(at: url))
    }

    @Test("Before a migration the index is dropped, and the open after creates it again")
    func droppedBeforeMigration() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("default.store")
        do { _ = try open(url) }
        #expect(PersistentStoreSearchIndexes.ensure(at: url) == [Self.index.name: .created])
        #expect(PersistentStoreSearchIndexes.drop(at: url))
        #expect(!(try indexes(url)).contains(Self.index.name))
        // Dropping twice, or on a store that is not there, is not a failure.
        #expect(PersistentStoreSearchIndexes.drop(at: url))
        #expect(PersistentStoreSearchIndexes.drop(at: root.appendingPathComponent("missing.store")))
        do { _ = try open(url) }
        #expect(PersistentStoreSearchIndexes.ensure(at: url) == [Self.index.name: .created])
    }

    @Test("Nothing is created where there is no store or no event table")
    func notApplicable() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("missing.store")
        #expect(PersistentStoreSearchIndexes.ensure(at: missing).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: missing.path))

        let other = root.appendingPathComponent("other.sqlite")
        try withDatabase(other, creating: true) { _ = sqlite3_exec($0, "CREATE TABLE T (A TEXT)", nil, nil, nil) }
        #expect(PersistentStoreSearchIndexes.ensure(at: other) == [Self.index.name: .notApplicable])
    }

    @Test("A store carrying the index still migrates, and keeps or regains it")
    func indexedStoreMigrates() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("default.store")
        let eventID: UUID
        do {
            let container = try ModelContainer(for: Schema(versionedSchema: ASTRASchemaV20.self),
                                               configurations: [ModelConfiguration(url: url)])
            let context = container.mainContext
            let workspace = ASTRASchemaV20Models.Workspace()
            workspace.name = "Older"; workspace.primaryPath = "/tmp/older"
            context.insert(workspace)
            let task = ASTRASchemaV20Models.AgentTask()
            task.title = "Older"; task.goal = "Migrate"; task.workspace = workspace
            context.insert(task)
            let event = ASTRASchemaV20Models.TaskEvent()
            event.task = task; event.type = "runtime.execution_ownership"; event.payload = "{}"
            context.insert(event)
            try context.save()
            eventID = event.id
        }
        #expect(PersistentStoreSearchIndexes.ensure(at: url) == [Self.index.name: .created])

        let migrated = try open(url)
        let type = "runtime.execution_ownership"
        let events = try migrated.mainContext.fetch(FetchDescriptor<TaskEvent>(predicate: #Predicate { $0.type == type }))
        #expect(events.map { $0.id } == [eventID])
        // Whether the migration kept the index or rebuilt the table without
        // it, the next open leaves the store with it.
        let outcome = PersistentStoreSearchIndexes.ensure(at: url)[Self.index.name]
        #expect(outcome == .present || outcome == .created)
        #expect(try indexes(url).contains(Self.index.name))
    }
}

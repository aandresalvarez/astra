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

    /// A store in a folder nobody may write, as on a read-only volume. Call the result to undo it.
    private func readOnlyStore(in root: URL) throws -> (url: URL, restore: () -> Void) {
        let url = root.appendingPathComponent("default.store")
        do { _ = try open(url) }
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path).map { root.appendingPathComponent($0).path }
        for path in files { try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        return (url, {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            for path in files { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path) }
            try? FileManager.default.removeItem(at: root)
        })
    }

    @Test("A store that cannot be written reports a failure, not a missing table")
    func readOnlyStoreFails() throws {
        let store = try readOnlyStore(in: try folder()); defer { store.restore() }
        let outcome = try #require(PersistentStoreSearchIndexes.ensure(at: store.url)[Self.index.name])
        #expect(outcome.isFailure)
    }

    @Test("A store whose catalog cannot be read reports a failure, not a missing table, and its drop stops the open as corruption")
    func unreadableStoreFails() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("default.store")
        try Data(repeating: 0x5A, count: 8_192).write(to: url)
        let outcome = try #require(PersistentStoreSearchIndexes.ensure(at: url)[Self.index.name])
        #expect(outcome.isFailure)
        // The same answer the open itself would give, so a damaged store still reaches recovery.
        var dropError: Error?
        do { try PersistentStoreSearchIndexes.drop(at: url) } catch { dropError = error }
        let error = try #require(dropError)
        #expect(PersistentStoreOpenFailurePolicy.decision(for: error) == .verifiedCorruption)
    }

    @Test("A drop that cannot run stops the open: busy is retried as contention, and the open never runs past it")
    func blockedDropStopsTheOpen() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("default.store")
        do { _ = try open(url) }
        #expect(PersistentStoreSearchIndexes.ensure(at: url) == [Self.index.name: .created])
        let configuration = ModelConfiguration(url: url)
        var tries = 0
        let held: Error? = try withDatabase(url) { holder in
            #expect(sqlite3_exec(holder, "BEGIN EXCLUSIVE", nil, nil, nil) == SQLITE_OK)
            defer { _ = sqlite3_exec(holder, "ROLLBACK", nil, nil, nil) }
            do {
                _ = try AstraStoreStartupCoordinator.makePersistentContainerWithContentionRetry(configuration: configuration) {
                    tries += 1
                    try PersistentStoreSearchIndexes.drop(at: url, busyTimeoutMilliseconds: 0)
                }
                return nil
            } catch { return error }
        }
        let error = try #require(held)
        #expect(PersistentStoreOpenFailurePolicy.decision(for: error) == .transientContention)
        // The first try and every contention retry, each stopped by its drop.
        #expect(tries == 1 + PersistentStoreRetryPolicy.contentionDelays.count)
        #expect(try indexes(url).contains(Self.index.name))

        // A store that is not a database is not opened past its drop either.
        let junk = root.appendingPathComponent("junk.store")
        try Data(repeating: 0x5A, count: 8_192).write(to: junk)
        var junkTries = 0
        var junkError: Error?
        do {
            _ = try AstraStoreStartupCoordinator.makePersistentContainerWithContentionRetry(configuration: ModelConfiguration(url: junk)) {
                junkTries += 1
                try PersistentStoreSearchIndexes.drop(at: junk)
            }
        } catch { junkError = error }
        #expect(PersistentStoreOpenFailurePolicy.decision(for: try #require(junkError)) == .verifiedCorruption)
        #expect(junkTries == 1)

        // No try opens past a failed preflight: a store the open would create is never created.
        let unopened = root.appendingPathComponent("unopened.store")
        var unopenedTries = 0
        var unopenedError: Error?
        do {
            _ = try AstraStoreStartupCoordinator.makePersistentContainerWithContentionRetry(configuration: ModelConfiguration(url: unopened)) {
                unopenedTries += 1
                throw NSError(domain: "NSSQLiteErrorDomain", code: Int(SQLITE_BUSY))
            }
        } catch { unopenedError = error }
        #expect(PersistentStoreOpenFailurePolicy.decision(for: try #require(unopenedError)) == .transientContention)
        #expect(unopenedTries == 1 + PersistentStoreRetryPolicy.contentionDelays.count)
        #expect(!FileManager.default.fileExists(atPath: unopened.path))

        // Once the holder is gone, the drop runs and the store opens without the index.
        tries = 0
        _ = try AstraStoreStartupCoordinator.makePersistentContainerWithContentionRetry(configuration: configuration) {
            tries += 1
            try PersistentStoreSearchIndexes.drop(at: url)
        }
        #expect(tries == 1)
        #expect(!(try indexes(url)).contains(Self.index.name))
    }

    @Test("A failed store is not asked again by the same build, but another store and the next build are")
    func failureMemoNamesTheStore() throws {
        let defaults = InMemoryDefaults()
        let failing = try readOnlyStore(in: try folder()); defer { failing.restore() }

        let first = try #require(PersistentStoreSearchIndexes.ensureAtLaunch(at: failing.url, build: "1", defaults: defaults))
        #expect(first[Self.index.name]?.isFailure == true)
        #expect(PersistentStoreSearchIndexes.ensureAtLaunch(at: failing.url, build: "1", defaults: defaults) == nil)

        // A fresh recovery store, or another selected store, opened by the same build.
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let healthy = root.appendingPathComponent("default.store")
        do { _ = try open(healthy) }
        #expect(PersistentStoreSearchIndexes.ensureAtLaunch(at: healthy, build: "1", defaults: defaults) == [Self.index.name: .created])

        // The next build asks the failed store again.
        let next = try #require(PersistentStoreSearchIndexes.ensureAtLaunch(at: failing.url, build: "2", defaults: defaults))
        #expect(next[Self.index.name]?.isFailure == true)
    }

    @Test("Before a migration the index is dropped, and the open after creates it again")
    func droppedBeforeMigration() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("default.store")
        do { _ = try open(url) }
        #expect(PersistentStoreSearchIndexes.ensure(at: url) == [Self.index.name: .created])
        try PersistentStoreSearchIndexes.drop(at: url)
        #expect(!(try indexes(url)).contains(Self.index.name))
        // Dropping twice, or on a store that is not there, is not a failure.
        try PersistentStoreSearchIndexes.drop(at: url)
        try PersistentStoreSearchIndexes.drop(at: root.appendingPathComponent("missing.store"))
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

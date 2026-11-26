import Foundation
import SQLite3
import ASTRACore

/// SQLite indexes the store needs for speed that SwiftData cannot declare.
///
/// SwiftData's `#Index` exists only from macOS 15, and ASTRA supports macOS
/// 14, so the model declares none. Without one, a fetch by event type reads
/// every row of the event table: about 190,000 rows and 200 MB in a store
/// with a year of history. Who holds which workspace is read that way at
/// every send, launch and turn end, on the main actor.
///
/// An index changes no row and no answer, only how SQLite finds the rows, so
/// it is not a schema change: the store's model version and digest stay the
/// same, a build that does not know the index opens the store unchanged, and
/// going back to one needs no restore. SQLite keeps the index current on every
/// write.
///
/// Core Data does not know the index, so it is dropped before a store opens
/// for a migration (`drop(at:)`): a migration that alters the event table
/// must not meet an index it did not create. The launch after creates it
/// again.
///
/// Created after the container opens and before anything else uses the
/// store, on a connection of its own. A store that is busy is left as it is
/// and asked again at the next launch; one that cannot take the index at all
/// is reported, and the app works exactly as before without it.
public enum PersistentStoreSearchIndexes {
    public struct Index: Equatable, Sendable {
        public let name: String
        public let table: String
        public let column: String

        /// Never `Z…`: that prefix is Core Data's, which names its own
        /// indexes `Z<ENTITY>_Z<ATTRIBUTE>_INDEX`.
        var createSQL: String { "CREATE INDEX IF NOT EXISTS \(name) ON \(table) (\(column))" }
        var dropSQL: String { "DROP INDEX IF EXISTS \(name)" }
    }

    /// `TaskEvent.type`. SwiftData stores the `type` attribute as `ZTYPE` in `ZTASKEVENT`.
    public static let taskEventType = Index(name: "ASTRA_TASKEVENT_TYPE_INDEX", table: "ZTASKEVENT", column: "ZTYPE")
    public static let all = [taskEventType]

    public enum Outcome: Equatable, Sendable {
        case present
        case created
        /// The table or column is not in this store, as in a store SwiftData has not finished creating.
        case notApplicable
        /// Another connection held the store; nothing changed, and the next launch asks again.
        case busy
        /// The store could not take the index: read-only, full, damaged or unreadable. Nothing changed.
        case failed(String)

        public var isFailure: Bool { if case .failed = self { return true } else { return false } }
    }

    /// How long to wait for a writer before giving up for this launch.
    public static let defaultBusyTimeoutMilliseconds: Int32 = 2_000

    @discardableResult
    public static func ensure(at url: URL, indexes: [Index] = all,
                              busyTimeoutMilliseconds: Int32 = defaultBusyTimeoutMilliseconds) -> [String: Outcome] {
        let started = DispatchTime.now().uptimeNanoseconds
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let outcomes: [String: Outcome]
        switch open(url, busyTimeoutMilliseconds: busyTimeoutMilliseconds) {
        case .failure(let failed):
            outcomes = Dictionary(uniqueKeysWithValues: indexes.map { ($0.name, failed.outcome) })
        case .success(let database):
            defer { sqlite3_close_v2(database) }
            outcomes = Dictionary(uniqueKeysWithValues: indexes.map { ($0.name, ensure($0, in: database)) })
        }
        report(outcomes, operation: "ensure_search_indexes", started: started)
        return outcomes
    }

    /// Removes the indexes before a store opens for a migration. Returns
    /// whether the store is left without them; a missing file has none.
    @discardableResult
    public static func drop(at url: URL, indexes: [Index] = all,
                            busyTimeoutMilliseconds: Int32 = defaultBusyTimeoutMilliseconds) -> Bool {
        let started = DispatchTime.now().uptimeNanoseconds
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        var outcomes: [String: Outcome] = [:]
        switch open(url, busyTimeoutMilliseconds: busyTimeoutMilliseconds) {
        case .failure(let failed):
            for index in indexes { outcomes[index.name] = failed.outcome }
        case .success(let database):
            defer { sqlite3_close_v2(database) }
            for index in indexes {
                let result = sqlite3_exec(database, index.dropSQL, nil, nil, nil)
                if result != SQLITE_OK { outcomes[index.name] = failure(result, database) }
            }
        }
        report(outcomes, operation: "drop_search_indexes", started: started)
        return outcomes.isEmpty
    }

    private static func open(_ url: URL, busyTimeoutMilliseconds: Int32) -> Result<OpaquePointer, OpenFailure> {
        var database: OpaquePointer?
        let opened = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard opened == SQLITE_OK, let database else {
            let outcome = failure(opened, database)
            if let database { sqlite3_close_v2(database) }
            return .failure(OpenFailure(outcome: outcome))
        }
        _ = sqlite3_busy_timeout(database, busyTimeoutMilliseconds)
        return .success(database)
    }

    private struct OpenFailure: Error { let outcome: Outcome }

    static func ensure(_ index: Index, in database: OpaquePointer) -> Outcome {
        switch hasRow(database, "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ? AND tbl_name = ?",
                      [index.name, index.table]) {
        case .failure(let failed): return failed.outcome
        case .success(true): return .present
        case .success(false): break
        }
        switch hasRow(database, "SELECT 1 FROM pragma_table_info(?) WHERE name = ?", [index.table, index.column]) {
        case .failure(let failed): return failed.outcome
        case .success(false): return .notApplicable
        case .success(true): break
        }
        let result = sqlite3_exec(database, index.createSQL, nil, nil, nil)
        return result == SQLITE_OK ? .created : failure(result, database)
    }

    /// A probe that cannot run is not an answer: it is reported, never read as "no row".
    private static func hasRow(_ database: OpaquePointer, _ sql: String, _ bindings: [String]) -> Result<Bool, OpenFailure> {
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else { return .failure(OpenFailure(outcome: failure(prepared, database))) }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in bindings.enumerated() {
            let bound = sqlite3_bind_text(statement, Int32(offset + 1), value, -1, transient)
            guard bound == SQLITE_OK else { return .failure(OpenFailure(outcome: failure(bound, database))) }
        }
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return .success(true)
        case SQLITE_DONE: return .success(false)
        case let stepped: return .failure(OpenFailure(outcome: failure(stepped, database)))
        }
    }

    private static func failure(_ code: Int32, _ database: OpaquePointer?) -> Outcome {
        let primary = code & 0xFF
        if primary == SQLITE_BUSY || primary == SQLITE_LOCKED { return .busy }
        let message = database.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:)) ?? String(cString: sqlite3_errstr(code))
        return .failed(message)
    }

    private static func report(_ outcomes: [String: Outcome], operation: String, started: UInt64) {
        // At most one line per call, and only when something changed or failed.
        let changed = outcomes.values.contains { $0 != .present && $0 != .notApplicable }
        guard changed else { return }
        let failed = outcomes.values.contains { $0 == .busy || $0.isFailure }
        var fields = ["operation": operation,
                      "duration_ms": String(format: "%.1f", Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)]
        for (name, outcome) in outcomes {
            switch outcome {
            case .present: fields[name] = "present"
            case .created: fields[name] = "created"
            case .notApplicable: fields[name] = "not_applicable"
            case .busy: fields[name] = "busy"
            case .failed(let reason): fields[name] = "failed"; fields["\(name)_error"] = reason
            }
        }
        AuditLoggingSeam.required.audit(.dataStoreSelected, category: "App", fields: fields, level: failed ? .warning : .info)
    }
}

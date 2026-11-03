import Foundation
import SQLite3
import SwiftData

/// A cleanup-only fence, registered before reading scope or copying the store.
/// data_version belongs to this connection: it detects commits by *any* other
/// context/connection, including saves that never request an auto-export.
final class WorkspaceCleanupStoreGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private let source: WorkspaceSavedExportSource
    private var database: OpaquePointer?
    private var version: Int64 = 0
    private var observer: NSObjectProtocol?
    private var invalidated = false

    init(container: ModelContainer) throws {
        source = WorkspaceSavedExportSource(container)
        guard source.resolve() != nil else { throw CocoaError(.fileReadUnknown) }
        if container.configurations.allSatisfy(\.isStoredInMemoryOnly) {
            // No SQLite generation exists for previews/tests. Hold cleanup
            // before any save to this container while the batch exists. A
            // failed memory save conservatively holds this cleanup pass too.
            observer = NotificationCenter.default.addObserver(forName: ModelContext.willSave,
                object: nil, queue: nil) { [weak self, weak container] notification in
                guard let self, let saved = notification.object as? ModelContext,
                      saved.container === container else { return }
                self.lock.withLock { self.invalidated = true }
            }
            return
        }
        guard container.configurations.count == 1, let configuration = container.configurations.first else {
            throw WorkspaceSavedExportSnapshot.SnapshotError.unsupportedStoreConfiguration
        }
        var opened: OpaquePointer?
        let result = sqlite3_open_v2(configuration.url.path, &opened,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let opened else {
            if let opened { sqlite3_close(opened) }
            throw CocoaError(.fileReadUnknown)
        }
        database = opened
        guard let current = dataVersion(opened) else {
            sqlite3_close(opened)
            database = nil
            throw CocoaError(.fileReadUnknown)
        }
        version = current
    }

    var isCurrent: Bool {
        lock.withLock { current() }
    }

    private func current() -> Bool {
        !invalidated && source.resolve() != nil && database.map { dataVersion($0) == version } != false
    }

    /// Staging/encoding have already finished. Acquire the SQLite writer slot
    /// without waiting, then verify and rename under the existing publication
    /// gate. A commit cannot slip between generation validation and rename.
    /// Never hold this transaction across projection, an await, or slow staging.
    func withCurrent<T>(_ publish: () throws -> T?) rethrows -> T? {
        try lock.withLock {
            guard !Task.isCancelled else { return nil }
            guard let database else { return current() ? try publish() : nil }
            guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }
            guard current() else { return nil }
            return try publish()
        }
    }

    private func dataVersion(_ database: OpaquePointer) -> Int64? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA data_version", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let database { sqlite3_close(database) }
    }
}

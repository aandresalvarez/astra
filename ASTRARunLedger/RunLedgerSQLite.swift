import Foundation
import SQLite3

let runLedgerSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum RunLedgerSQLiteValue {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

enum RunLedgerSQLiteStep {
    case row
    case done
}

final class RunLedgerSQLiteConnection: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var database: OpaquePointer?

    init(path: String, flags: Int32, busyTimeoutMilliseconds: Int32) throws {
        var opened: OpaquePointer?
        let result = sqlite3_open_v2(path, &opened, flags, nil)
        guard result == SQLITE_OK, let opened else {
            let message = opened.flatMap(sqlite3_errmsg).map(String.init(cString:)) ?? "unknown"
            if let opened { sqlite3_close_v2(opened) }
            throw RunLedgerError.sqlite(operation: "open", code: result, message: message)
        }
        database = opened
        sqlite3_extended_result_codes(opened, 1)
        let timeoutResult = sqlite3_busy_timeout(opened, busyTimeoutMilliseconds)
        guard timeoutResult == SQLITE_OK else {
            let message = sqlite3_errmsg(opened).map(String.init(cString:)) ?? "unknown"
            sqlite3_close_v2(opened)
            database = nil
            throw RunLedgerError.sqlite(
                operation: "configure busy timeout",
                code: timeoutResult,
                message: message
            )
        }
    }

    deinit {
        try? close()
    }

    func withLock<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let database else { throw RunLedgerError.closed }
        return try body(database)
    }

    func close() throws {
        lock.lock()
        defer { lock.unlock() }
        guard let database else { return }
        let result = sqlite3_close_v2(database)
        guard result == SQLITE_OK else {
            throw sqliteError(database, operation: "close", code: result)
        }
        self.database = nil
    }

    func execute(_ sql: String, database: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? sqlite3_errmsg(database).map(String.init(cString:))
                ?? "unknown"
            sqlite3_free(errorMessage)
            throw RunLedgerError.sqlite(operation: "execute", code: result, message: message)
        }
    }

    func statement(
        _ sql: String,
        bindings: [RunLedgerSQLiteValue] = [],
        database: OpaquePointer
    ) throws -> RunLedgerSQLiteStatement {
        try RunLedgerSQLiteStatement(database: database, sql: sql, bindings: bindings)
    }

    func scalarInt64(
        _ sql: String,
        bindings: [RunLedgerSQLiteValue] = [],
        database: OpaquePointer
    ) throws -> Int64? {
        let statement = try statement(sql, bindings: bindings, database: database)
        defer { statement.finalize() }
        switch try statement.step() {
        case .done:
            return nil
        case .row:
            return statement.isNull(at: 0) ? nil : statement.int64(at: 0)
        }
    }

    func scalarText(
        _ sql: String,
        bindings: [RunLedgerSQLiteValue] = [],
        database: OpaquePointer
    ) throws -> String? {
        let statement = try statement(sql, bindings: bindings, database: database)
        defer { statement.finalize() }
        switch try statement.step() {
        case .done:
            return nil
        case .row:
            return try statement.optionalText(at: 0)
        }
    }

    func withImmediateTransaction<T>(
        database: OpaquePointer,
        _ body: () throws -> T
    ) throws -> T {
        try execute("BEGIN IMMEDIATE", database: database)
        do {
            let value = try body()
            try execute("COMMIT", database: database)
            return value
        } catch {
            // Preserve the domain/statement error that caused the rollback.
            // A failed rollback means the connection is unusable, but replacing
            // the original error would hide the violated invariant.
            try? execute("ROLLBACK", database: database)
            throw error
        }
    }

    func lastInsertRowID(database: OpaquePointer) -> Int64 {
        sqlite3_last_insert_rowid(database)
    }

    func changes(database: OpaquePointer) -> Int32 {
        sqlite3_changes(database)
    }

    func sqliteError(
        _ database: OpaquePointer,
        operation: String,
        code: Int32? = nil
    ) -> RunLedgerError {
        let resolvedCode = code ?? sqlite3_extended_errcode(database)
        let message = sqlite3_errmsg(database).map(String.init(cString:)) ?? "unknown"
        return .sqlite(operation: operation, code: resolvedCode, message: message)
    }
}

final class RunLedgerSQLiteStatement {
    private let database: OpaquePointer
    private var statement: OpaquePointer?

    init(
        database: OpaquePointer,
        sql: String,
        bindings: [RunLedgerSQLiteValue]
    ) throws {
        self.database = database
        var prepared: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &prepared, nil)
        guard result == SQLITE_OK, let prepared else {
            if let prepared { sqlite3_finalize(prepared) }
            let message = sqlite3_errmsg(database).map(String.init(cString:)) ?? "unknown"
            throw RunLedgerError.sqlite(operation: "prepare", code: result, message: message)
        }
        statement = prepared
        do {
            try bind(bindings)
        } catch {
            finalize()
            throw error
        }
    }

    deinit {
        finalize()
    }

    func finalize() {
        guard let statement else { return }
        sqlite3_finalize(statement)
        self.statement = nil
    }

    func step() throws -> RunLedgerSQLiteStep {
        guard let statement else { throw RunLedgerError.closed }
        let result = sqlite3_step(statement)
        switch result {
        case SQLITE_ROW:
            return .row
        case SQLITE_DONE:
            return .done
        default:
            let message = sqlite3_errmsg(database).map(String.init(cString:)) ?? "unknown"
            throw RunLedgerError.sqlite(operation: "step", code: result, message: message)
        }
    }

    func int64(at index: Int32) -> Int64 {
        guard let statement else { return 0 }
        return sqlite3_column_int64(statement, index)
    }

    func double(at index: Int32) -> Double {
        guard let statement else { return 0 }
        return sqlite3_column_double(statement, index)
    }

    func isNull(at index: Int32) -> Bool {
        guard let statement else { return true }
        return sqlite3_column_type(statement, index) == SQLITE_NULL
    }

    func text(at index: Int32) throws -> String {
        guard let value = try optionalText(at: index) else {
            throw RunLedgerError.corrupt("Unexpected NULL text column at index \(index)")
        }
        return value
    }

    func optionalText(at index: Int32) throws -> String? {
        guard let statement else { throw RunLedgerError.closed }
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        guard let pointer = sqlite3_column_text(statement, index) else {
            throw RunLedgerError.corrupt("SQLite returned a missing text pointer at index \(index)")
        }
        let count = Int(sqlite3_column_bytes(statement, index))
        let data = Data(bytes: pointer, count: count)
        guard let value = String(data: data, encoding: .utf8) else {
            throw RunLedgerError.corrupt("SQLite text at index \(index) is not UTF-8")
        }
        return value
    }

    func blob(at index: Int32) throws -> Data {
        guard let statement else { throw RunLedgerError.closed }
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            throw RunLedgerError.corrupt("Unexpected NULL blob column at index \(index)")
        }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0 else { return Data() }
        guard let pointer = sqlite3_column_blob(statement, index) else {
            throw RunLedgerError.corrupt("SQLite returned a missing blob pointer at index \(index)")
        }
        return Data(bytes: pointer, count: count)
    }

    private func bind(_ values: [RunLedgerSQLiteValue]) throws {
        guard let statement else { throw RunLedgerError.closed }
        let expectedCount = Int(sqlite3_bind_parameter_count(statement))
        guard expectedCount == values.count else {
            throw RunLedgerError.invalidEvent(
                "SQLite binding count mismatch: expected \(expectedCount), received \(values.count)"
            )
        }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .null:
                result = sqlite3_bind_null(statement, index)
            case .integer(let value):
                result = sqlite3_bind_int64(statement, index, value)
            case .real(let value):
                result = sqlite3_bind_double(statement, index, value)
            case .text(let value):
                guard value.utf8.count <= Int(Int32.max) else {
                    throw RunLedgerError.invalidEvent("SQLite text binding exceeds Int32 length")
                }
                result = value.withCString { pointer in
                    sqlite3_bind_text(
                        statement,
                        index,
                        pointer,
                        Int32(value.utf8.count),
                        runLedgerSQLiteTransient
                    )
                }
            case .blob(let value):
                guard value.count <= Int(Int32.max) else {
                    throw RunLedgerError.invalidEvent("SQLite blob binding exceeds Int32 length")
                }
                if value.isEmpty {
                    result = sqlite3_bind_zeroblob(statement, index, 0)
                } else {
                    result = value.withUnsafeBytes { bytes in
                        sqlite3_bind_blob(
                            statement,
                            index,
                            bytes.baseAddress,
                            Int32(value.count),
                            runLedgerSQLiteTransient
                        )
                    }
                }
            }
            guard result == SQLITE_OK else {
                let message = sqlite3_errmsg(database).map(String.init(cString:)) ?? "unknown"
                throw RunLedgerError.sqlite(operation: "bind", code: result, message: message)
            }
        }
    }
}

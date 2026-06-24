import Foundation
import SQLite3

private let workspaceAppSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum WorkspaceAppStorageError: LocalizedError, Equatable {
    case invalidIdentifier(String)
    case unsupportedColumnType(String)
    case openFailed(String)
    case prepareFailed(String)
    case executeFailed(String)
    case bindFailed(String)
    case missingRecordValues
    case missingPrimaryKeyValue(String)
    case recordNotFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidIdentifier(let value):
            "Invalid app storage identifier: \(value)"
        case .unsupportedColumnType(let value):
            "Unsupported app storage column type: \(value)"
        case .openFailed(let message):
            "Could not open app storage database: \(message)"
        case .prepareFailed(let message):
            "Could not prepare app storage SQL: \(message)"
        case .executeFailed(let message):
            "Could not execute app storage SQL: \(message)"
        case .bindFailed(let message):
            "Could not bind app storage value: \(message)"
        case .missingRecordValues:
            "Record must contain at least one value."
        case .missingPrimaryKeyValue(let key):
            "Record must contain primary key '\(key)'."
        case .recordNotFound(let key):
            "No app storage record matched primary key '\(key)'."
        }
    }
}

enum WorkspaceAppStorageMigrationRisk: String, Codable, Sendable, Equatable {
    case additive
    case reviewRequired
}

struct WorkspaceAppStorageMigrationStep: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable, Equatable {
        case createTable
        case addColumn
        case dropTable
        case dropColumn
        case changeColumnType
        case changePrimaryKey
        case changeRequiredConstraint
    }

    var kind: Kind
    var table: String
    var column: String?
    var previousValue: String?
    var nextValue: String?
    var risk: WorkspaceAppStorageMigrationRisk
    var summary: String
}

struct WorkspaceAppStorageMigrationPlan: Codable, Sendable, Equatable {
    var steps: [WorkspaceAppStorageMigrationStep]

    var requiresReview: Bool {
        steps.contains { $0.risk == .reviewRequired }
    }

    var isEmpty: Bool {
        steps.isEmpty
    }
}

struct WorkspaceAppStorageService {
    var fileManager: FileManager = .default

    func planMigration(
        from current: WorkspaceAppStorageSchema?,
        to target: WorkspaceAppStorageSchema
    ) -> WorkspaceAppStorageMigrationPlan {
        let currentTables = tableMap(current?.tables ?? [])
        let targetTables = tableMap(target.tables)
        var steps: [WorkspaceAppStorageMigrationStep] = []

        for table in current?.tables ?? [] where targetTables[table.name] == nil {
            steps.append(WorkspaceAppStorageMigrationStep(
                kind: .dropTable,
                table: table.name,
                column: nil,
                previousValue: table.name,
                nextValue: nil,
                risk: .reviewRequired,
                summary: "Drop storage table '\(table.name)'."
            ))
        }

        for table in target.tables {
            guard let currentTable = currentTables[table.name] else {
                steps.append(WorkspaceAppStorageMigrationStep(
                    kind: .createTable,
                    table: table.name,
                    column: nil,
                    previousValue: nil,
                    nextValue: table.name,
                    risk: .additive,
                    summary: "Create storage table '\(table.name)'."
                ))
                continue
            }

            steps.append(contentsOf: planColumnMigration(from: currentTable, to: table))
        }

        return WorkspaceAppStorageMigrationPlan(steps: steps)
    }

    func applySchema(_ schema: WorkspaceAppStorageSchema, databaseURL: URL) throws {
        try fileManager.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try withDatabase(at: databaseURL) { database in
            try execute("PRAGMA foreign_keys = ON;", database: database)
            try execute("PRAGMA journal_mode = WAL;", database: database)
            try execute("""
            CREATE TABLE IF NOT EXISTS "__astra_storage_metadata" (
              "key" TEXT PRIMARY KEY,
              "value" TEXT NOT NULL
            );
            """, database: database)
            for table in schema.tables {
                try execute(try createTableSQL(for: table), database: database)
                // Additive migration for an EXISTING table (version-in-place edits): add any manifest
                // column the live table lacks. ADD COLUMN is nullable + no PK (SQLite can't add either
                // via ALTER) so it always succeeds even with existing rows — required-ness/PK are
                // enforced at the manifest/validator layer, not the raw column. A freshly created
                // table already has every column, so this is a no-op on create.
                let live = try existingColumnNames(of: table.name, database: database)
                for column in table.columns where !live.contains(column.name) {
                    let sql = "ALTER TABLE \(try quotedIdentifier(table.name)) "
                        + "ADD COLUMN \(try quotedIdentifier(column.name)) \(try sqliteType(for: column.type));"
                    try execute(sql, database: database)
                }
            }
        }
    }

    /// The column names of a live table via `PRAGMA table_info` (empty if the table doesn't exist).
    private func existingColumnNames(of table: String, database: OpaquePointer) throws -> Set<String> {
        let sql = "PRAGMA table_info(\(try quotedIdentifier(table)));"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw WorkspaceAppStorageError.prepareFailed(lastError(database))
        }
        defer { sqlite3_finalize(statement) }
        var names: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let cString = sqlite3_column_text(statement, 1) {   // column 1 = name
                names.insert(String(cString: cString))
            }
        }
        return names
    }

    func insertRecord(
        _ record: [String: WorkspaceAppStorageValue],
        into table: String,
        databaseURL: URL
    ) throws {
        guard !record.isEmpty else { throw WorkspaceAppStorageError.missingRecordValues }
        let tableName = try quotedIdentifier(table)
        let columns = try record.keys.sorted().map(quotedIdentifier)
        let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
        let sql = "INSERT INTO \(tableName) (\(columns.joined(separator: ", "))) VALUES (\(placeholders));"
        try withDatabase(at: databaseURL) { database in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw WorkspaceAppStorageError.prepareFailed(lastError(database))
            }
            defer { sqlite3_finalize(statement) }

            for (index, key) in record.keys.sorted().enumerated() {
                try bind(record[key] ?? .null, to: Int32(index + 1), statement: statement, database: database)
            }
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw WorkspaceAppStorageError.executeFailed(lastError(database))
            }
        }
    }

    func updateRecord(
        _ record: [String: WorkspaceAppStorageValue],
        in table: String,
        primaryKey: String,
        databaseURL: URL
    ) throws {
        guard !record.isEmpty else { throw WorkspaceAppStorageError.missingRecordValues }
        guard let primaryKeyValue = record[primaryKey] else {
            throw WorkspaceAppStorageError.missingPrimaryKeyValue(primaryKey)
        }
        let updateKeys = record.keys.sorted().filter { $0 != primaryKey }
        guard !updateKeys.isEmpty else { throw WorkspaceAppStorageError.missingRecordValues }

        let tableName = try quotedIdentifier(table)
        let assignments = try updateKeys.map { "\(try quotedIdentifier($0)) = ?" }.joined(separator: ", ")
        let primaryKeyName = try quotedIdentifier(primaryKey)
        let sql = "UPDATE \(tableName) SET \(assignments) WHERE \(primaryKeyName) = ?;"
        try withDatabase(at: databaseURL) { database in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw WorkspaceAppStorageError.prepareFailed(lastError(database))
            }
            defer { sqlite3_finalize(statement) }

            for (index, key) in updateKeys.enumerated() {
                try bind(record[key] ?? .null, to: Int32(index + 1), statement: statement, database: database)
            }
            try bind(primaryKeyValue, to: Int32(updateKeys.count + 1), statement: statement, database: database)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw WorkspaceAppStorageError.executeFailed(lastError(database))
            }
            guard sqlite3_changes(database) > 0 else {
                throw WorkspaceAppStorageError.recordNotFound(primaryKey)
            }
        }
    }

    func deleteRecord(
        from table: String,
        primaryKey: String,
        value primaryKeyValue: WorkspaceAppStorageValue,
        databaseURL: URL
    ) throws {
        let tableName = try quotedIdentifier(table)
        let primaryKeyName = try quotedIdentifier(primaryKey)
        let sql = "DELETE FROM \(tableName) WHERE \(primaryKeyName) = ?;"
        try withDatabase(at: databaseURL) { database in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw WorkspaceAppStorageError.prepareFailed(lastError(database))
            }
            defer { sqlite3_finalize(statement) }

            try bind(primaryKeyValue, to: 1, statement: statement, database: database)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw WorkspaceAppStorageError.executeFailed(lastError(database))
            }
            guard sqlite3_changes(database) > 0 else {
                throw WorkspaceAppStorageError.recordNotFound(primaryKey)
            }
        }
    }

    func records(
        in table: String,
        databaseURL: URL,
        limit: Int = 100
    ) throws -> [[String: WorkspaceAppStorageValue]] {
        let tableName = try quotedIdentifier(table)
        let safeLimit = max(1, min(limit, 10_000))
        let sql = "SELECT * FROM \(tableName) ORDER BY rowid ASC LIMIT \(safeLimit);"
        return try withDatabase(at: databaseURL) { database in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw WorkspaceAppStorageError.prepareFailed(lastError(database))
            }
            defer { sqlite3_finalize(statement) }

            var rows: [[String: WorkspaceAppStorageValue]] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                var row: [String: WorkspaceAppStorageValue] = [:]
                for index in 0..<sqlite3_column_count(statement) {
                    let name = sqlite3_column_name(statement, index).map { String(cString: $0) } ?? ""
                    row[name] = value(at: index, statement: statement)
                }
                rows.append(row)
            }
            return rows
        }
    }

    private func planColumnMigration(
        from current: WorkspaceAppStorageTable,
        to target: WorkspaceAppStorageTable
    ) -> [WorkspaceAppStorageMigrationStep] {
        let currentColumns = columnMap(current.columns)
        let targetColumns = columnMap(target.columns)
        var steps: [WorkspaceAppStorageMigrationStep] = []

        for column in current.columns where targetColumns[column.name] == nil {
            steps.append(WorkspaceAppStorageMigrationStep(
                kind: .dropColumn,
                table: current.name,
                column: column.name,
                previousValue: column.name,
                nextValue: nil,
                risk: .reviewRequired,
                summary: "Drop column '\(column.name)' from storage table '\(current.name)'."
            ))
        }

        for column in target.columns {
            guard let currentColumn = currentColumns[column.name] else {
                steps.append(WorkspaceAppStorageMigrationStep(
                    kind: .addColumn,
                    table: target.name,
                    column: column.name,
                    previousValue: nil,
                    nextValue: column.name,
                    risk: column.required ? .reviewRequired : .additive,
                    summary: "Add \(column.required ? "required " : "")column '\(column.name)' to storage table '\(target.name)'."
                ))
                continue
            }

            if currentColumn.type != column.type {
                steps.append(WorkspaceAppStorageMigrationStep(
                    kind: .changeColumnType,
                    table: target.name,
                    column: column.name,
                    previousValue: currentColumn.type,
                    nextValue: column.type,
                    risk: .reviewRequired,
                    summary: "Change column '\(column.name)' type from '\(currentColumn.type)' to '\(column.type)' in storage table '\(target.name)'."
                ))
            }
            if currentColumn.primaryKey != column.primaryKey {
                steps.append(WorkspaceAppStorageMigrationStep(
                    kind: .changePrimaryKey,
                    table: target.name,
                    column: column.name,
                    previousValue: String(currentColumn.primaryKey),
                    nextValue: String(column.primaryKey),
                    risk: .reviewRequired,
                    summary: "Change primary-key status for column '\(column.name)' in storage table '\(target.name)'."
                ))
            }
            if currentColumn.required != column.required {
                let risk: WorkspaceAppStorageMigrationRisk = column.required ? .reviewRequired : .additive
                steps.append(WorkspaceAppStorageMigrationStep(
                    kind: .changeRequiredConstraint,
                    table: target.name,
                    column: column.name,
                    previousValue: String(currentColumn.required),
                    nextValue: String(column.required),
                    risk: risk,
                    summary: "Change required constraint for column '\(column.name)' in storage table '\(target.name)'."
                ))
            }
        }

        return steps
    }

    private func tableMap(_ tables: [WorkspaceAppStorageTable]) -> [String: WorkspaceAppStorageTable] {
        var result: [String: WorkspaceAppStorageTable] = [:]
        for table in tables {
            result[table.name] = table
        }
        return result
    }

    private func columnMap(_ columns: [WorkspaceAppStorageColumn]) -> [String: WorkspaceAppStorageColumn] {
        var result: [String: WorkspaceAppStorageColumn] = [:]
        for column in columns {
            result[column.name] = column
        }
        return result
    }

    private func createTableSQL(for table: WorkspaceAppStorageTable) throws -> String {
        let tableName = try quotedIdentifier(table.name)
        let columns = try table.columns.map { column in
            var parts = [
                try quotedIdentifier(column.name),
                try sqliteType(for: column.type)
            ]
            if column.primaryKey {
                parts.append("PRIMARY KEY")
            }
            if column.required {
                parts.append("NOT NULL")
            }
            return parts.joined(separator: " ")
        }
        return "CREATE TABLE IF NOT EXISTS \(tableName) (\(columns.joined(separator: ", ")));"
    }

    private func sqliteType(for type: String) throws -> String {
        switch type {
        case "bool":
            "INTEGER"
        case "date", "datetime", "json", "text", "uuid":
            "TEXT"
        case "integer":
            "INTEGER"
        case "double", "real":
            "REAL"
        default:
            throw WorkspaceAppStorageError.unsupportedColumnType(type)
        }
    }

    private func quotedIdentifier(_ value: String) throws -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !value.isEmpty,
              value.rangeOfCharacter(from: allowed.inverted) == nil else {
            throw WorkspaceAppStorageError.invalidIdentifier(value)
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func withDatabase<T>(at url: URL, body: (OpaquePointer) throws -> T) throws -> T {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            let message = database.map(lastError) ?? "unknown"
            if let database { sqlite3_close(database) }
            throw WorkspaceAppStorageError.openFailed(message)
        }
        defer { sqlite3_close(database) }
        return try body(database)
    }

    private func execute(_ sql: String, database: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? lastError(database)
            sqlite3_free(errorMessage)
            throw WorkspaceAppStorageError.executeFailed(message)
        }
    }

    private func bind(
        _ value: WorkspaceAppStorageValue,
        to index: Int32,
        statement: OpaquePointer,
        database: OpaquePointer
    ) throws {
        let result: Int32
        switch value {
        case .null:
            result = sqlite3_bind_null(statement, index)
        case .text(let value):
            result = sqlite3_bind_text(statement, index, value, -1, workspaceAppSQLiteTransient)
        case .integer(let value):
            result = sqlite3_bind_int64(statement, index, value)
        case .real(let value):
            result = sqlite3_bind_double(statement, index, value)
        case .bool(let value):
            result = sqlite3_bind_int64(statement, index, value ? 1 : 0)
        }
        guard result == SQLITE_OK else {
            throw WorkspaceAppStorageError.bindFailed(lastError(database))
        }
    }

    private func value(at index: Int32, statement: OpaquePointer) -> WorkspaceAppStorageValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_NULL:
            .null
        case SQLITE_INTEGER:
            .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            .text(sqlite3_column_text(statement, index).map { String(cString: $0) } ?? "")
        default:
            .null
        }
    }

    private func lastError(_ database: OpaquePointer) -> String {
        sqlite3_errmsg(database).map { String(cString: $0) } ?? "unknown"
    }
}

import Foundation
import SQLite3
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Workspace Store Repair")
struct WorkspaceStoreRepairTests {
    @Test("Repairs legacy enum raw values before SwiftData opens store")
    func repairsLegacyEnumRawValues() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-store-repair-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storeURL = root.appendingPathComponent("default.store")
        try executeSQL(
            """
            CREATE TABLE ZAGENTTASK (
                Z_PK INTEGER PRIMARY KEY,
                ZVALIDATIONSTRATEGY VARCHAR,
                ZISOLATIONSTRATEGY VARCHAR,
                ZSTATUS VARCHAR
            );
            CREATE TABLE ZTASKRUN (
                Z_PK INTEGER PRIMARY KEY,
                ZSTATUS VARCHAR
            );
            CREATE TABLE ZTASKSCHEDULE (
                Z_PK INTEGER PRIMARY KEY,
                ZSCHEDULETYPE VARCHAR,
                ZRESULTMODE VARCHAR
            );
            INSERT INTO ZAGENTTASK VALUES (1, 'goal_check', 'not_valid', 'stale_status');
            INSERT INTO ZAGENTTASK VALUES (2, 'surprise', 'same_directory', 'completed');
            INSERT INTO ZAGENTTASK VALUES (3, NULL, NULL, NULL);
            INSERT INTO ZTASKRUN VALUES (1, 'not_valid');
            INSERT INTO ZTASKRUN VALUES (2, 'completed');
            INSERT INTO ZTASKSCHEDULE VALUES (1, 'later', 'return_here');
            """,
            at: storeURL
        )

        let result = WorkspaceRecoveryService.repairLegacyStoreValues(at: storeURL)

        #expect(result.validationStrategyGoalCheckRows == 1)
        #expect(result.validationStrategyDefaultedRows == 2)
        #expect(result.isolationStrategyDefaultedRows == 2)
        #expect(result.taskStatusDefaultedRows == 2)
        #expect(result.runStatusDefaultedRows == 1)
        #expect(result.scheduleTypeDefaultedRows == 1)
        #expect(result.scheduleResultModeDefaultedRows == 1)

        #expect(try scalarInt(
            "SELECT COUNT(*) FROM ZAGENTTASK WHERE ZVALIDATIONSTRATEGY = 'ai_check'",
            at: storeURL
        ) == 1)
        #expect(try scalarInt(
            "SELECT COUNT(*) FROM ZAGENTTASK WHERE ZVALIDATIONSTRATEGY = 'manual'",
            at: storeURL
        ) == 2)
        #expect(try scalarInt(
            "SELECT COUNT(*) FROM ZAGENTTASK WHERE ZISOLATIONSTRATEGY = 'same_directory'",
            at: storeURL
        ) == 3)
        #expect(try scalarInt(
            "SELECT COUNT(*) FROM ZAGENTTASK WHERE ZSTATUS = 'draft'",
            at: storeURL
        ) == 2)
        #expect(try scalarInt(
            "SELECT COUNT(*) FROM ZTASKRUN WHERE ZSTATUS = 'failed'",
            at: storeURL
        ) == 1)
        #expect(try scalarInt(
            "SELECT COUNT(*) FROM ZTASKSCHEDULE WHERE ZSCHEDULETYPE = 'once'",
            at: storeURL
        ) == 1)
        #expect(try scalarInt(
            "SELECT COUNT(*) FROM ZTASKSCHEDULE WHERE ZRESULTMODE = 'same_thread'",
            at: storeURL
        ) == 1)
    }

    @Test("read-only pre-reset recovery exports workspace configs before backup")
    @MainActor
    func readOnlyPreResetRecoveryExportsWorkspaceConfigs() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-store-export-\(UUID().uuidString)", isDirectory: true)
        let workspaceRoot = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storeURL = root.appendingPathComponent("default.store")
        var container: ModelContainer? = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(url: storeURL)]
        )
        let context = try #require(container?.mainContext)
        let workspace = Workspace(name: "Recoverable", primaryPath: workspaceRoot.path)
        context.insert(workspace)
        try context.save()
        let workspaceID = workspace.id
        container = nil

        let backupRoot = root.appendingPathComponent("Backups", isDirectory: true)
        let results = try WorkspaceRecoveryService.preserveReadableStoreBeforeRecovery(
            at: storeURL,
            backupRoot: backupRoot
        )
        let configURL = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: workspaceRoot.path))
        let config = try WorkspaceConfigManager.loadConfig(from: configURL)
        let backupFiles = FileManager.default.enumerator(at: backupRoot, includingPropertiesForKeys: nil)?
            .compactMap { ($0 as? URL)?.lastPathComponent } ?? []

        #expect(results.count == 1)
        #expect(results.first?.didExport == true)
        #expect(config.id == workspaceID.uuidString)
        #expect(config.name == "Recoverable")
        #expect(backupFiles.contains("default.store"))
    }
}

private enum SQLiteTestError: Error {
    case open
    case execute(String)
    case prepare(String)
    case missingRow
}

private func executeSQL(_ sql: String, at url: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
        throw SQLiteTestError.open
    }
    defer { sqlite3_close(database) }

    var errorMessage: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
    guard result == SQLITE_OK else {
        let message = errorMessage.map { String(cString: $0) } ?? "unknown"
        sqlite3_free(errorMessage)
        throw SQLiteTestError.execute(message)
    }
}

private func scalarInt(_ sql: String, at url: URL) throws -> Int {
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
        throw SQLiteTestError.open
    }
    defer { sqlite3_close(database) }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
        let message = sqlite3_errmsg(database).map { String(cString: $0) } ?? "unknown"
        throw SQLiteTestError.prepare(message)
    }
    defer { sqlite3_finalize(statement) }

    guard sqlite3_step(statement) == SQLITE_ROW else {
        throw SQLiteTestError.missingRow
    }
    return Int(sqlite3_column_int(statement, 0))
}

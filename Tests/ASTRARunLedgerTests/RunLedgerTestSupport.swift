import ASTRACore
@testable import ASTRARunLedger
import Foundation
import SQLite3
import Testing

enum ClaimAttempt: Sendable {
    case admitted
    case conflictDenied
    case unexpected
}

final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func withValue(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&storage)
    }
}

final class LedgerFixture {
    let root: URL
    let configuration: RunLedgerConfiguration

    init(createLedgerDirectory: Bool = false) throws {
        root = temporaryRoot()
        let directory = root.appendingPathComponent("ledger", isDirectory: true)
        if createLedgerDirectory {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        }
        configuration = .init(
            ledgerDirectoryURL: directory,
            installationID: installationID(999)
        )
    }

    func open(expectedStoreID: RunBrokerStoreID? = nil) throws -> RunLedger {
        try RunLedger(configuration: .init(
            ledgerDirectoryURL: configuration.ledgerDirectoryURL,
            installationID: configuration.installationID,
            expectedStoreID: expectedStoreID,
            busyTimeoutMilliseconds: 10_000
        ))
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func manifest(
        ledger: RunLedger,
        execution: Int,
        authority: RunBrokerAuthority,
        effects: [ExecutionEffectClaim]
    ) -> ExecutionLaunchManifest {
        .init(
            installationID: configuration.installationID,
            storeID: ledger.identity.storeID,
            executionID: executionID(execution),
            taskID: fixedUUID(10_000 + execution),
            authority: authority,
            configuration: .init(
                runtimeID: .codexCLI,
                executablePath: "/usr/local/bin/codex",
                workingDirectory: "/workspace/repo",
                configurationRevision: "sha256:test"
            ),
            declaredEffects: effects,
            createdAt: date(offset: 0)
        )
    }

    func envelope(
        id: Int,
        offset: TimeInterval,
        event: RunLedgerEvent
    ) -> RunLedgerEventEnvelope {
        .init(eventID: eventID(id), occurredAt: date(offset: offset), event: event)
    }

    func authority(_ value: Int, epoch: UInt64) -> RunBrokerAuthority {
        .init(
            id: .init(rawValue: fixedUUID(value)),
            epoch: .init(rawValue: epoch)
        )
    }

    func operationID(_ value: Int) -> RunBrokerOperationID {
        .init(rawValue: fixedUUID(value))
    }

    func eventID(_ value: Int) -> RunLedgerEventID {
        .init(rawValue: fixedUUID(value))
    }

    func date(offset: TimeInterval) -> Date {
        fixedDate.addingTimeInterval(offset)
    }
}

let workspaceEffect = ExecutionEffectClaim(
    scope: .workspaceRepository(workspaceID: "workspace", repositoryID: "repo"),
    access: .exclusive
)

let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

func temporaryRoot() -> URL {
    let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        .appendingPathComponent("astra-run-ledger-tests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    return root
}

func fixedUUID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
}

func installationID(_ value: Int) -> RunBrokerInstallationID {
    .init(rawValue: fixedUUID(value))
}

func executionID(_ value: Int) -> RunBrokerExecutionID {
    .init(rawValue: fixedUUID(value))
}

func ledgerError(_ body: () throws -> Void) -> RunLedgerError? {
    do {
        try body()
        return nil
    } catch let error as RunLedgerError {
        return error
    } catch {
        Issue.record("Unexpected non-ledger error: \(error)")
        return nil
    }
}

func permissions(_ url: URL) -> Int {
    let attributes = try! FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

func executeSQLite(_ url: URL, _ sql: String) throws {
    var database: OpaquePointer?
    let openResult = sqlite3_open_v2(
        url.path,
        &database,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW,
        nil
    )
    guard openResult == SQLITE_OK, let database else {
        if let database { sqlite3_close_v2(database) }
        throw TestSQLiteError.open(openResult)
    }
    defer { sqlite3_close_v2(database) }
    var message: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(database, sql, nil, nil, &message)
    guard result == SQLITE_OK else {
        let detail = message.map { String(cString: $0) } ?? "unknown"
        sqlite3_free(message)
        throw TestSQLiteError.execute(result, detail)
    }
}

func sqliteInt(_ url: URL, sql: String) -> Int64? {
    var database: OpaquePointer?
    guard sqlite3_open_v2(
        url.path,
        &database,
        SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW,
        nil
    ) == SQLITE_OK, let database else {
        if let database { sqlite3_close_v2(database) }
        return nil
    }
    defer { sqlite3_close_v2(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else {
        if let statement { sqlite3_finalize(statement) }
        return nil
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    return sqlite3_column_int64(statement, 0)
}

enum TestSQLiteError: Error {
    case open(Int32)
    case execute(Int32, String)
}

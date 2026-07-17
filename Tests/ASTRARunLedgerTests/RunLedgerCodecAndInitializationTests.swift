import ASTRACore
@testable import ASTRARunLedger
import Foundation
import Testing

@Suite("RunLedger strict durable codec")
struct RunLedgerStrictCodecTests {
    @Test("Persisted payload rejects unknown top-level keys")
    func unknownTopLevelKey() throws {
        let payload = RunLedgerPersistedEventPayload(
            occurredAt: monitorTestDate,
            event: .monitorDeadlineRemoved(expected: codecDeadline(seed: 10))
        )
        let mutated = try addingJSONValue(
            to: RunLedgerCodec.encode(payload),
            path: [],
            key: "futureTopLevelField",
            value: true
        )

        guard case .corrupt = monitorLedgerError({
            _ = try RunLedgerCodec.decode(RunLedgerPersistedEventPayload.self, from: mutated)
        }) else {
            Issue.record("Expected unknown top-level payload key to fail closed")
            return
        }
    }

    @Test("Event kind rejects a field belonging to another kind")
    func crossKindExtraField() throws {
        let payload = RunLedgerPersistedEventPayload(
            occurredAt: monitorTestDate,
            event: .monitorDeadlineRemoved(expected: codecDeadline(seed: 20))
        )
        let mutated = try addingJSONValue(
            to: RunLedgerCodec.encode(payload),
            path: ["event"],
            key: "effects",
            value: []
        )

        guard case .corrupt = monitorLedgerError({
            _ = try RunLedgerCodec.decode(RunLedgerPersistedEventPayload.self, from: mutated)
        }) else {
            Issue.record("Expected cross-kind event field to fail closed")
            return
        }
    }

    @Test("Execution control event has stable versioned tags and strict keys")
    func stableExecutionControlWireFormat() throws {
        let event = RunLedgerExecutionControlEvent.requestCancellation(.immediate)
        let data = try RunLedgerCodec.encode(event)
        #expect(String(decoding: data, as: UTF8.self) ==
            #"{"intent":"immediate","kind":"request_cancellation","schemaVersion":1}"#)
        #expect(try RunLedgerCodec.decode(
            RunLedgerExecutionControlEvent.self,
            from: data
        ) == event)

        let invalid = Data(
            #"{"intent":"graceful","kind":"execution_started","schemaVersion":1}"#.utf8
        )
        guard case .corrupt = monitorLedgerError({
            _ = try RunLedgerCodec.decode(RunLedgerExecutionControlEvent.self, from: invalid)
        }) else {
            Issue.record("Expected unrelated control-event field to fail closed")
            return
        }
    }

    @Test("Legacy control wire without authority is rejected")
    func controlWireRequiresAuthority() throws {
        let event: RunLedgerEvent = .executionControlTransitioned(
            executionID: .init(rawValue: monitorUUID(30)),
            authority: .init(
                id: .init(rawValue: monitorUUID(31)),
                epoch: .init(rawValue: 1)
            ),
            transition: .executionStarted,
            backendCapabilities: .monitoringOnly
        )
        var object = try #require(
            JSONSerialization.jsonObject(
                with: RunLedgerCodec.encode(event)
            ) as? [String: Any]
        )
        object.removeValue(forKey: "authority")
        let oldWire = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )

        guard case .corrupt = monitorLedgerError({
            _ = try RunLedgerCodec.decode(RunLedgerEvent.self, from: oldWire)
        }) else {
            Issue.record("Expected authority-less execution control wire to fail closed")
            return
        }
    }
}

@Suite("RunLedger concurrent first initialization")
struct RunLedgerInitializationTests {
    @Test(
        "Every initialization crash boundary is marker-owned and recoverable",
        arguments: [
            "after-initialization-marker-created",
            "after-main-file-created",
            "before-schema-commit",
            "after-schema-commit-before-marker-removal",
        ]
    )
    func crashBoundaryRecovery(crashPoint: String) throws {
        let fixture = try MonitorLedgerFixture()
        defer { fixture.cleanup() }
        let executable = try #require(runLedgerHarnessURL())
        let output = fixture.root.appendingPathComponent("crashed-store-id.txt")
        let process = Process()
        process.executableURL = executable
        process.arguments = [
            fixture.configuration.ledgerDirectoryURL.path,
            fixture.configuration.installationID.rawValue.uuidString,
            output.path,
            crashPoint,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == 86)
        #expect(!FileManager.default.fileExists(atPath: output.path))
        let marker = RunLedgerStorageSecurity.initializationMarkerURL(
            for: fixture.configuration.databaseURL
        )
        let markerBytes = try Data(contentsOf: marker)
        let markerMode = permissions(marker)
        let inspection = RunLedger.inspect(fixture.configuration)
        if crashPoint == "after-initialization-marker-created" {
            #expect(inspection.status == .missing)
        } else if crashPoint == "after-schema-commit-before-marker-removal" {
            #expect(inspection.status == .healthy)
        } else {
            #expect(inspection.status == .corrupt)
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(try Data(contentsOf: marker) == markerBytes)
        #expect(permissions(marker) == markerMode)

        let recovered = try fixture.open()
        let identity = recovered.identity
        #expect(recovered.verifyHealth().status == .healthy)
        #expect(try recovered.events().isEmpty)
        try recovered.close()
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(sqliteInt(
            fixture.configuration.databaseURL,
            sql: "PRAGMA application_id"
        ) == Int64(RunLedgerSchema.applicationID))
        #expect(sqliteInt(
            fixture.configuration.databaseURL,
            sql: "PRAGMA user_version"
        ) == Int64(RunLedgerSchema.version))

        let reopened = try fixture.open(expectedStoreID: identity.storeID)
        defer { try? reopened.close() }
        #expect(reopened.identity == identity)
        #expect(reopened.verifyHealth().status == .healthy)
    }

    @Test("An unmarked foreign SQLite database is never adopted as a ledger")
    func foreignSQLiteIsRejected() throws {
        let fixture = try MonitorLedgerFixture(precreateDirectory: true)
        defer { fixture.cleanup() }
        try Data().write(to: fixture.configuration.databaseURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fixture.configuration.databaseURL.path
        )
        try executeSQLite(
            fixture.configuration.databaseURL,
            """
            CREATE TABLE foreign_owner (value TEXT NOT NULL);
            DROP TABLE foreign_owner;
            VACUUM;
            """
        )

        #expect(sqliteInt(
            fixture.configuration.databaseURL,
            sql: "SELECT COUNT(*) FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%'"
        ) == 0)
        #expect(RunLedger.inspect(fixture.configuration).status == .incompatibleSchema)
        #expect(monitorLedgerError { _ = try fixture.open() }
            == .applicationIdentityMismatch(expected: RunLedgerSchema.applicationID, found: 0))
        #expect(sqliteInt(fixture.configuration.databaseURL, sql: "PRAGMA application_id") == 0)
        #expect(sqliteInt(fixture.configuration.databaseURL, sql: "PRAGMA user_version") == 0)
    }

    @Test("An unmarked zero-byte database is corruption, not resumable initialization")
    func unmarkedEmptyFileIsRejected() throws {
        let fixture = try MonitorLedgerFixture(precreateDirectory: true)
        defer { fixture.cleanup() }
        try Data().write(to: fixture.configuration.databaseURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fixture.configuration.databaseURL.path
        )

        #expect(RunLedger.inspect(fixture.configuration).status == .corrupt)
        #expect(monitorLedgerError { _ = try fixture.open() }
            == .corrupt("Unclaimed empty ledger file cannot be adopted"))
        #expect((try Data(contentsOf: fixture.configuration.databaseURL)).isEmpty)
    }

    @Test("An initialization marker cannot authorize a partially branded database")
    func markerDoesNotAuthorizePartialDatabase() throws {
        let fixture = try MonitorLedgerFixture()
        defer { fixture.cleanup() }
        let executable = try #require(runLedgerHarnessURL())
        let process = Process()
        process.executableURL = executable
        process.arguments = [
            fixture.configuration.ledgerDirectoryURL.path,
            fixture.configuration.installationID.rawValue.uuidString,
            fixture.root.appendingPathComponent("unused-output").path,
            "after-initialization-marker-created",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 86)

        try Data().write(to: fixture.configuration.databaseURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fixture.configuration.databaseURL.path
        )
        try executeSQLite(
            fixture.configuration.databaseURL,
            """
            PRAGMA application_id = \(RunLedgerSchema.applicationID);
            PRAGMA user_version = \(RunLedgerSchema.version);
            CREATE TABLE foreign_partial (value TEXT NOT NULL);
            """
        )

        #expect(RunLedger.inspect(fixture.configuration).status == .corrupt)
        #expect(monitorLedgerError { _ = try fixture.open() } != nil)
        #expect(sqliteInt(
            fixture.configuration.databaseURL,
            sql: "SELECT COUNT(*) FROM sqlite_schema WHERE name = 'foreign_partial'"
        ) == 1)
        #expect(FileManager.default.fileExists(
            atPath: RunLedgerStorageSecurity.initializationMarkerURL(
                for: fixture.configuration.databaseURL
            ).path
        ))
    }

    @Test("Concurrent first openers publish exactly one initialized store")
    func concurrentFirstOpen() throws {
        let fixture = try MonitorLedgerFixture()
        defer { fixture.cleanup() }
        let identities = AdvancedLockedBox<[RunLedgerIdentity]>([])
        let errors = AdvancedLockedBox<[RunLedgerError]>([])

        DispatchQueue.concurrentPerform(iterations: 12) { _ in
            do {
                let ledger = try fixture.open()
                identities.withValue { $0.append(ledger.identity) }
                try ledger.close()
            } catch let error as RunLedgerError {
                errors.withValue { $0.append(error) }
            } catch {
                errors.withValue { $0.append(.corrupt(String(describing: error))) }
            }
        }

        #expect(errors.value.isEmpty)
        #expect(identities.value.count == 12)
        #expect(Set(identities.value.map(\.storeID)).count == 1)
        #expect(Set(identities.value.map(\.installationID)).count == 1)
        #expect(RunLedger.inspect(fixture.configuration).status == .healthy)
    }

    @Test("Independent processes serialize first open and observe one store identity")
    func crossProcessFirstOpen() throws {
        let fixture = try MonitorLedgerFixture()
        defer { fixture.cleanup() }
        let executable = try #require(runLedgerHarnessURL())
        let outputs = (0..<2).map {
            fixture.root.appendingPathComponent("process-\($0)-store-id.txt")
        }
        let processes = outputs.map { output -> Process in
            let process = Process()
            process.executableURL = executable
            process.arguments = [
                fixture.configuration.ledgerDirectoryURL.path,
                fixture.configuration.installationID.rawValue.uuidString,
                output.path,
            ]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            return process
        }
        for process in processes { try process.run() }
        for process in processes { process.waitUntilExit() }

        #expect(processes.allSatisfy { $0.terminationStatus == 0 })
        let storeIDs = try outputs.map {
            String(decoding: try Data(contentsOf: $0), as: UTF8.self)
        }
        #expect(Set(storeIDs).count == 1)
        #expect(RunLedger.inspect(fixture.configuration).status == .healthy)
    }
}

private func runLedgerHarnessURL() -> URL? {
    let starts = [
        Bundle(for: RunLedgerHarnessLocatorToken.self).bundleURL,
        URL(fileURLWithPath: CommandLine.arguments[0]),
    ]
    for start in starts {
        var directory = start.deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent("run-ledger-open-harness")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
    }
    return nil
}

private final class RunLedgerHarnessLocatorToken {}

private func codecDeadline(seed: Int) -> RunLedgerMonitorDeadline {
    .init(
        operationID: .init(rawValue: monitorUUID(seed)),
        authority: .init(
            id: .init(rawValue: monitorUUID(seed + 1)),
            epoch: .init(rawValue: 1)
        ),
        dueAt: monitorTestDate.addingTimeInterval(10),
        recordedAt: monitorTestDate,
        attempt: 0,
        generation: monitorUUID(seed + 2)
    )
}

private func addingJSONValue(
    to data: Data,
    path: [String],
    key: String,
    value: Any
) throws -> Data {
    guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw RunLedgerError.corrupt("Test payload is not an object")
    }
    if path.isEmpty {
        root[key] = value
    } else if path.count == 1, var nested = root[path[0]] as? [String: Any] {
        nested[key] = value
        root[path[0]] = nested
    } else {
        throw RunLedgerError.corrupt("Unsupported test JSON path")
    }
    return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
}

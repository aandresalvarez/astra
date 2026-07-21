import ASTRACore
@_spi(RunLedgerTesting) @testable import ASTRARunLedger
import CryptoKit
import Foundation
import SQLite3
import Testing

@Suite("RunLedger schema v1 to v2 migration", .serialized)
struct RunLedgerMigrationTests {
    @Test("Frozen v1 schema manifest matches the shipped raw-outbox database")
    func frozenV1SchemaManifest() throws {
        let fixture = try LedgerFixture()
        defer { fixture.cleanup() }
        _ = try seedLegacyStore(fixture: fixture, acknowledgedCount: 0)
        let connection = try RunLedgerSQLiteConnection(
            path: fixture.configuration.databaseURL.path,
            flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW,
            busyTimeoutMilliseconds: 1_000
        )
        defer { try? connection.close() }
        let digest = try connection.withLock { database in
            return try RunLedgerV1ToV2Migration.schemaManifestSHA256(
                connection: connection,
                database: database
            )
        }
        #expect(digest == RunLedgerV1ToV2Migration.legacySchemaManifestSHA256)
        #expect(digest == "740c753cfc8603a8f5f8b1df1cbe2369a842b9d0dd4aa936e115863a06f80796")
    }

    @Test(
        "Migration preserves unacked and partially acked typed delivery state",
        arguments: [0, 5]
    )
    func preservesDeliveryAndExecutionState(acknowledgedCount: Int) throws {
        let fixture = try LedgerFixture()
        defer { fixture.cleanup() }
        let seed = try seedLegacyStore(
            fixture: fixture,
            acknowledgedCount: acknowledgedCount
        )

        #expect(sqliteInt(fixture.configuration.databaseURL, sql: "PRAGMA user_version") == 1)
        let migrated = try fixture.open(expectedStoreID: seed.identity.storeID)
        defer { try? migrated.close() }

        try assertMigrationResult(migrated, seed: seed)
        #expect(try migrated.outboxAcknowledgedThrough() == seed.acknowledgedThrough)
        #expect(try migrated.outbox() == seed.outbox)

        let projection = try migrated.projection()
        #expect(projection.executions[seed.activeExecutionID]?.control.desiredCancellation == .graceful)
        #expect(projection.executions[seed.terminalExecutionID]?.control.observedExecution == .completed)
        #expect(projection.monitorDeadlines[seed.monitoredOperationID]?.attempt == 1)
        #expect(projection.operations[seed.tombstonedOperationID]?.record.holdsEffects == false)

        let streams = try migrated.outbox().compactMap { message -> RunLedgerOutboxStreamV1? in
            guard case .supervisor(let value) = message.projection else { return nil }
            return value.stream
        }
        #expect(streams.count == 3)
        #expect(streams[0].startsLogicalLine)
        #expect(!streams[0].endsLogicalLine)
        #expect(!streams[1].startsLogicalLine)
        #expect(!streams[1].endsLogicalLine)
        #expect(streams[1].trailingFragmentByteCount == 4)

        let terminals: [RunLedgerOutboxTerminalEvidenceV1] = try migrated.outbox().compactMap { message in
            guard case .execution(let value) = message.projection,
                  value.executionID == seed.terminalExecutionID,
                  value.state == .terminal else { return nil }
            return value.terminalEvidence
        }
        let terminal = try #require(terminals.last)
        #expect(terminal.outcome == .completed)
        #expect(terminal.exitCode == 0)
    }

    @Test(
        "Every migration crash boundary reopens as complete v1 or complete v2",
        arguments: RunLedgerMigrationCrashPoint.allCases
    )
    func crashBoundaryRecovery(crashPoint: RunLedgerMigrationCrashPoint) throws {
        let fixture = try LedgerFixture()
        defer { fixture.cleanup() }
        let seed = try seedLegacyStore(fixture: fixture, acknowledgedCount: 4)
        let executable = try #require(migrationHarnessURL())
        let output = fixture.root.appendingPathComponent("migration-output.txt")
        let process = Process()
        process.executableURL = executable
        process.arguments = [
            fixture.configuration.ledgerDirectoryURL.path,
            fixture.configuration.installationID.rawValue.uuidString,
            output.path,
            crashPoint.rawValue,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == 87)
        #expect(!FileManager.default.fileExists(atPath: output.path))
        let committed = crashPoint == .afterCommit
        #expect(sqliteInt(
            fixture.configuration.databaseURL,
            sql: "PRAGMA user_version"
        ) == (committed ? 2 : 1))
        #expect(sqliteInt(
            fixture.configuration.databaseURL,
            sql: "SELECT COUNT(*) FROM sqlite_schema WHERE name = 'outbox_v1_migration_source'"
        ) == 0)

        let recovered = try fixture.open(expectedStoreID: seed.identity.storeID)
        defer { try? recovered.close() }
        try assertMigrationResult(recovered, seed: seed)
    }

    @Test("Migration restores immutable metadata, outbox, and cursor triggers")
    func restoresProtectionTriggers() throws {
        let fixture = try LedgerFixture()
        defer { fixture.cleanup() }
        let seed = try seedLegacyStore(fixture: fixture, acknowledgedCount: 3)
        let ledger = try fixture.open(expectedStoreID: seed.identity.storeID)
        try ledger.close()

        #expect(sqliteInt(
            fixture.configuration.databaseURL,
            sql: "SELECT COUNT(*) FROM sqlite_schema WHERE type = 'trigger' AND name IN ("
                + "'ledger_metadata_no_update','outbox_no_update','outbox_no_delete',"
                + "'outbox_state_monotonic')"
        ) == 4)
        #expect(throws: (any Error).self) {
            try executeSQLite(
                fixture.configuration.databaseURL,
                "UPDATE ledger_metadata SET schema_fingerprint = 'forged' WHERE singleton_id = 1"
            )
        }
        #expect(throws: (any Error).self) {
            try executeSQLite(
                fixture.configuration.databaseURL,
                "UPDATE outbox SET occurred_at = occurred_at + 1 WHERE sequence = 1"
            )
        }
        #expect(throws: (any Error).self) {
            try executeSQLite(
                fixture.configuration.databaseURL,
                "UPDATE outbox_state SET last_acknowledged_sequence = 5 WHERE singleton_id = 1"
            )
        }
    }

    @Test("Drifted v1 schema and corrupt v1 event mirror fail before DDL")
    func legacyDriftFailsClosed() throws {
        let schemaFixture = try LedgerFixture()
        defer { schemaFixture.cleanup() }
        _ = try seedLegacyStore(fixture: schemaFixture, acknowledgedCount: 0)
        try executeSQLite(
            schemaFixture.configuration.databaseURL,
            "ALTER TABLE outbox ADD COLUMN forged TEXT"
        )
        #expect(ledgerError { _ = try schemaFixture.open() } != nil)
        #expect(sqliteInt(schemaFixture.configuration.databaseURL, sql: "PRAGMA user_version") == 1)
        #expect(sqliteInt(
            schemaFixture.configuration.databaseURL,
            sql: "SELECT COUNT(*) FROM pragma_table_info('outbox') WHERE name = 'forged'"
        ) == 1)
        #expect(sqliteInt(
            schemaFixture.configuration.databaseURL,
            sql: "SELECT COUNT(*) FROM sqlite_schema WHERE name = 'outbox_v1_migration_source'"
        ) == 0)

        let dataFixture = try LedgerFixture()
        defer { dataFixture.cleanup() }
        _ = try seedLegacyStore(fixture: dataFixture, acknowledgedCount: 0)
        try executeSQLite(
            dataFixture.configuration.databaseURL,
            """
            DROP TRIGGER outbox_no_update;
            UPDATE outbox SET message_id = '00000000-0000-0000-0000-999999999999'
            WHERE sequence = 1;
            \(outboxUpdateTrigger)
            """
        )
        #expect(ledgerError { _ = try dataFixture.open() } != nil)
        #expect(sqliteInt(dataFixture.configuration.databaseURL, sql: "PRAGMA user_version") == 1)
        #expect(sqliteInt(
            dataFixture.configuration.databaseURL,
            sql: "SELECT COUNT(*) FROM sqlite_schema WHERE name = 'outbox_v1_migration_source'"
        ) == 0)
    }

    @Test(
        "Every PR10-only event kind is rejected from a forged v1 store",
        arguments: postV1EventKinds
    )
    func postV1EventKindFailsClosed(eventKind: String) throws {
        let fixture = try LedgerFixture()
        defer { fixture.cleanup() }
        _ = try seedLegacyStore(fixture: fixture, acknowledgedCount: 0)
        try executeSQLite(
            fixture.configuration.databaseURL,
            """
            DROP TRIGGER events_no_update;
            DROP TRIGGER outbox_no_update;
            UPDATE events SET event_kind = '\(eventKind)' WHERE sequence = 1;
            UPDATE outbox SET event_kind = '\(eventKind)' WHERE sequence = 1;
            \(eventsUpdateTrigger)
            \(outboxUpdateTrigger)
            """
        )

        guard case .incompatibleSchema(expected: 2, found: 1) = ledgerError({
            _ = try fixture.open()
        }) else {
            Issue.record("Expected a frozen-v1 event-kind rejection")
            return
        }
        #expect(sqliteInt(fixture.configuration.databaseURL, sql: "PRAGMA user_version") == 1)
    }

    @Test("Golden v1 fixture produces stable typed projection digests")
    func goldenTypedProjectionDigests() throws {
        let fixture = try LedgerFixture()
        defer { fixture.cleanup() }
        let seed = try seedLegacyStore(fixture: fixture, acknowledgedCount: 4)
        let ledger = try fixture.open(expectedStoreID: seed.identity.storeID)
        defer { try? ledger.close() }
        let summaries = try ledger.outbox().map(migrationGoldenSummary)
        let digest = Data(SHA256.hash(data: try ASTRACanonicalJSON.encode(summaries))).hexString
        #expect(
            Set(seed.events.map(\.envelope.event.kind))
                == RunLedgerV1ToV2Migration.legacyEventKinds
        )
        #expect(summaries == migrationGoldenProjectionSummaries)
        #expect(digest == migrationGoldenProjectionSummaryDigest)
    }

    @Test("Migration handles a bounded large v1 backlog")
    func boundedLargeBacklog() throws {
        let fixture = try LedgerFixture()
        defer { fixture.cleanup() }
        let seed = try seedLegacyStore(
            fixture: fixture,
            acknowledgedCount: 8,
            extraSupervisorObservations: 512
        )
        let started = Date()
        let ledger = try fixture.open(expectedStoreID: seed.identity.storeID)
        defer { try? ledger.close() }
        let duration = Date().timeIntervalSince(started)

        try assertMigrationResult(ledger, seed: seed)
        #expect(try ledger.outbox().count == seed.outbox.count)
        #expect(duration < 20)
    }
}

private struct MigrationSeed {
    let identity: RunLedgerIdentity
    let events: [StoredRunLedgerEvent]
    let outbox: [RunLedgerOutboxMessage]
    let projection: RunLedgerProjection
    let acknowledgedThrough: Int64
    let activeExecutionID: RunBrokerExecutionID
    let terminalExecutionID: RunBrokerExecutionID
    let monitoredOperationID: RunBrokerOperationID
    let tombstonedOperationID: RunBrokerOperationID
}

private func seedLegacyStore(
    fixture: LedgerFixture,
    acknowledgedCount: Int,
    extraSupervisorObservations: Int = 0
) throws -> MigrationSeed {
    let ledger = try fixture.open()
    let identity = ledger.identity
    let activeAuthority = fixture.authority(2_001, epoch: 1)
    let activeOperationID = fixture.operationID(2_003)
    let tombstonedOperationID = fixture.operationID(2_012)
    let activeManifest = ExecutionLaunchManifest(
        installationID: fixture.configuration.installationID,
        storeID: ledger.identity.storeID,
        executionID: executionID(2_002),
        taskID: fixedUUID(2_020),
        authority: activeAuthority,
        configuration: .init(
            runtimeID: .claudeCode,
            executablePath: "/usr/bin/true",
            workingDirectory: "/tmp",
            configurationRevision: "migration-source"
        ),
        declaredEffects: [workspaceEffect, .computeOnly],
        supervisionPolicy: try .init(
            hardTimeoutSeconds: 3_600,
            idleProgressTimeoutSeconds: 300
        ),
        createdAt: fixedDate
    )
    _ = try ledger.admitExecution(
        manifest: activeManifest,
        primaryOperationID: activeOperationID,
        admittedAt: fixedDate,
        idempotencyKey: fixedUUID(2_004)
    )
    _ = try ledger.append(fixture.envelope(
        id: 2_005,
        offset: 1,
        event: .executionControlTransitioned(
            executionID: activeManifest.executionID,
            authority: activeAuthority,
            transition: .executionStarted,
            backendCapabilities: [.observe, .cancel]
        )
    ))
    _ = try appendObservation(
        ledger: ledger,
        fixture: fixture,
        eventID: 2_006,
        supervisorEventID: 2_007,
        executionID: activeManifest.executionID,
        authority: activeAuthority,
        sequence: 1,
        offset: 2,
        kind: .standardOutput,
        output: Data("hel".utf8)
    )
    _ = try appendObservation(
        ledger: ledger,
        fixture: fixture,
        eventID: 2_008,
        supervisorEventID: 2_009,
        executionID: activeManifest.executionID,
        authority: activeAuthority,
        sequence: 2,
        offset: 3,
        kind: .standardOutput,
        output: Data("lo\nnext".utf8)
    )
    for offset in 0..<extraSupervisorObservations {
        _ = try appendObservation(
            ledger: ledger,
            fixture: fixture,
            eventID: 10_000 + offset,
            supervisorEventID: 20_000 + offset,
            executionID: activeManifest.executionID,
            authority: activeAuthority,
            sequence: UInt64(3 + offset),
            offset: TimeInterval(4 + offset),
            kind: .standardInputAccepted
        )
    }

    let nextOffset = Double(4 + extraSupervisorObservations)
    _ = try ledger.upsertMonitorDeadline(
        operationID: activeOperationID,
        authority: activeAuthority,
        dueAt: fixedDate.addingTimeInterval(nextOffset + 1),
        attempt: 0,
        scheduledAt: fixedDate.addingTimeInterval(nextOffset),
        replacing: nil,
        idempotencyKey: fixedUUID(2_010)
    )
    let firstDeadline = try #require(
        ledger.monitorDeadlines().first { $0.operationID == activeOperationID }
    )
    #expect(try ledger.recordMonitorAttempt(
        expected: firstDeadline,
        attemptedAt: fixedDate.addingTimeInterval(nextOffset + 1),
        disposition: .retryableFailure,
        nextDueAt: fixedDate.addingTimeInterval(nextOffset + 30),
        idempotencyKey: fixedUUID(2_011)
    ) == .applied)
    _ = try ledger.append(fixture.envelope(
        id: 2_013,
        offset: nextOffset + 2,
        event: .operationClaimed(
            operationID: tombstonedOperationID,
            executionID: activeManifest.executionID,
            authority: activeAuthority,
            effects: [.computeOnly]
        )
    ))
    _ = try ledger.upsertMonitorDeadline(
        operationID: tombstonedOperationID,
        authority: activeAuthority,
        dueAt: fixedDate.addingTimeInterval(nextOffset + 20),
        attempt: 0,
        scheduledAt: fixedDate.addingTimeInterval(nextOffset + 3),
        replacing: nil,
        idempotencyKey: fixedUUID(2_014)
    )
    let removableDeadline = try #require(
        ledger.monitorDeadlines().first { $0.operationID == tombstonedOperationID }
    )
    _ = try ledger.removeMonitorDeadline(
        expected: removableDeadline,
        occurredAt: fixedDate.addingTimeInterval(nextOffset + 4),
        idempotencyKey: fixedUUID(2_015)
    )
    let replacementAuthority = fixture.authority(2_016, epoch: 2)
    _ = try ledger.append(fixture.envelope(
        id: 2_017,
        offset: nextOffset + 5,
        event: .executionAuthorityTransferred(
            executionID: activeManifest.executionID,
            expectedAuthority: activeAuthority,
            newAuthority: replacementAuthority
        )
    ))
    _ = try ledger.append(fixture.envelope(
        id: 2_018,
        offset: nextOffset + 6,
        event: .operationTombstoned(
            operationID: tombstonedOperationID,
            authority: replacementAuthority,
            reason: .administrativelyReleased
        )
    ))
    _ = try ledger.append(fixture.envelope(
        id: 2_019,
        offset: nextOffset + 7,
        event: .executionControlTransitioned(
            executionID: activeManifest.executionID,
            authority: replacementAuthority,
            transition: .requestCancellation(.graceful),
            backendCapabilities: [.observe, .cancel]
        )
    ))

    let terminalAuthority = fixture.authority(2_101, epoch: 1)
    let terminalManifest = fixture.manifest(
        ledger: ledger,
        execution: 2_102,
        authority: terminalAuthority,
        effects: [.computeOnly]
    )
    _ = try ledger.admitExecution(
        manifest: terminalManifest,
        primaryOperationID: fixture.operationID(2_103),
        admittedAt: fixedDate.addingTimeInterval(nextOffset + 8),
        idempotencyKey: fixedUUID(2_104)
    )
    _ = try ledger.append(fixture.envelope(
        id: 2_105,
        offset: nextOffset + 9,
        event: .executionControlTransitioned(
            executionID: terminalManifest.executionID,
            authority: terminalAuthority,
            transition: .executionStarted,
            backendCapabilities: [.observe, .cancel]
        )
    ))
    _ = try appendObservation(
        ledger: ledger,
        fixture: fixture,
        eventID: 2_106,
        supervisorEventID: 2_107,
        executionID: terminalManifest.executionID,
        authority: terminalAuthority,
        sequence: 1,
        offset: nextOffset + 10,
        kind: .standardError,
        output: Data("warning\n".utf8)
    )
    _ = try appendObservation(
        ledger: ledger,
        fixture: fixture,
        eventID: 2_108,
        supervisorEventID: 2_109,
        executionID: terminalManifest.executionID,
        authority: terminalAuthority,
        sequence: 2,
        offset: nextOffset + 11,
        kind: .providerExited,
        exitCode: 0,
        terminationReason: .exited
    )
    _ = try ledger.append(fixture.envelope(
        id: 2_110,
        offset: nextOffset + 12,
        event: .executionControlTransitioned(
            executionID: terminalManifest.executionID,
            authority: terminalAuthority,
            transition: .executionCompleted,
            backendCapabilities: [.observe, .cancel]
        )
    ))

    let beforeAcknowledgement = try ledger.outbox()
    guard acknowledgedCount >= 0, acknowledgedCount <= beforeAcknowledgement.count else {
        throw RunLedgerError.invalidEvent("Invalid migration test acknowledgement count")
    }
    for message in beforeAcknowledgement.prefix(acknowledgedCount) {
        _ = try ledger.acknowledgeOutbox(
            sequence: message.sequence,
            messageID: message.messageID
        )
    }
    let seed = MigrationSeed(
        identity: identity,
        events: try ledger.events(limit: 10_000),
        outbox: try ledger.outbox(limit: 10_000),
        projection: try ledger.projection(),
        acknowledgedThrough: try ledger.outboxAcknowledgedThrough(),
        activeExecutionID: activeManifest.executionID,
        terminalExecutionID: terminalManifest.executionID,
        monitoredOperationID: activeOperationID,
        tombstonedOperationID: tombstonedOperationID
    )
    try ledger.close()
    try downgradeToLegacyV1(fixture.configuration.databaseURL)
    return seed
}

@discardableResult
private func appendObservation(
    ledger: RunLedger,
    fixture: LedgerFixture,
    eventID: Int,
    supervisorEventID: Int,
    executionID: RunBrokerExecutionID,
    authority: RunBrokerAuthority,
    sequence: UInt64,
    offset: TimeInterval,
    kind: RunBrokerSupervisorObservation.Kind,
    output: Data? = nil,
    exitCode: Int32? = nil,
    terminationReason: RunBrokerTerminationReason? = nil
) throws -> RunLedgerAppendResult {
    let observation = RunBrokerSupervisorObservation(
        executionID: executionID,
        authority: authority,
        supervisorSequence: sequence,
        supervisorEventID: fixedUUID(supervisorEventID),
        occurredAt: fixture.date(offset: offset),
        kind: kind,
        output: output,
        exitCode: exitCode,
        terminationReason: terminationReason
    )
    return try ledger.append(fixture.envelope(
        id: eventID,
        offset: offset,
        event: .supervisorObservationRecorded(observation)
    ))
}

private func downgradeToLegacyV1(_ databaseURL: URL) throws {
    try executeSQLite(
        databaseURL,
        """
        PRAGMA foreign_keys = ON;
        BEGIN IMMEDIATE;
        DROP TRIGGER outbox_no_update;
        DROP TRIGGER outbox_no_delete;
        DROP TRIGGER outbox_state_monotonic;
        ALTER TABLE outbox RENAME TO outbox_v2_seed;
        \(RunLedgerSchemaSQL.outboxV1)
        INSERT INTO outbox (sequence, message_id, event_kind, payload, occurred_at)
        SELECT sequence, message_id, event_kind, payload, occurred_at
        FROM outbox_v2_seed ORDER BY sequence;
        DROP TABLE outbox_v2_seed;
        \(outboxUpdateTrigger)
        \(outboxDeleteTrigger)
        \(outboxStateTrigger)
        DROP TRIGGER ledger_metadata_no_update;
        UPDATE ledger_metadata
        SET schema_version = \(RunLedgerSchema.legacyVersion),
            schema_fingerprint = '\(RunLedgerSchema.legacyFingerprint)'
        WHERE singleton_id = 1;
        \(metadataUpdateTrigger)
        PRAGMA user_version = \(RunLedgerSchema.legacyVersion);
        COMMIT;
        """
    )
}

private func assertMigrationResult(
    _ ledger: RunLedger,
    seed: MigrationSeed
) throws {
    #expect(ledger.identity.storeID == seed.identity.storeID)
    #expect(ledger.identity.installationID == seed.identity.installationID)
    #expect(ledger.identity.createdAt == seed.identity.createdAt)
    #expect(ledger.identity.schemaVersion == RunLedgerSchema.version)
    #expect(try ledger.events(limit: 10_000) == seed.events)
    #expect(try ledger.outbox(limit: 10_000) == seed.outbox)
    #expect(try ledger.projection() == seed.projection)
    #expect(try ledger.replayedProjection() == seed.projection)
    #expect(ledger.verifyHealth().status == .healthy)
    #expect(sqliteInt(ledger.configuration.databaseURL, sql: "PRAGMA user_version") == 2)
    #expect(sqliteInt(
        ledger.configuration.databaseURL,
        sql: "SELECT schema_version FROM ledger_metadata WHERE singleton_id = 1"
    ) == 2)
}

private func migrationHarnessURL() -> URL? {
    let starts = [
        Bundle(for: MigrationHarnessLocatorToken.self).bundleURL,
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

private final class MigrationHarnessLocatorToken {}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private let postV1EventKinds = [
    "runtime_switch.target_reserved",
    "runtime_switch.admitted",
    "runtime_switch.policy_transitioned",
    "runtime_switch.completion_archived",
    "execution.force_challenge_recorded",
    "execution.force_challenge_consumed",
]

private let migrationGoldenProjectionSummaries = [
    "1|execution.admitted|execution|00000000-0000-0000-0000-000000002002|1|admitted|0|migration-source|-",
    "2|execution.control_transitioned|execution|00000000-0000-0000-0000-000000002002|1|running|0|migration-source|-",
    "3|execution.supervisor_observation_recorded|supervisor|00000000-0000-0000-0000-000000002002|1|stdout|stdout,true,false,3,false,aGVs|-",
    "4|execution.supervisor_observation_recorded|supervisor|00000000-0000-0000-0000-000000002002|2|stdout|stdout,false,false,4,false,bG8KbmV4dA==|-",
    "5|monitor.deadline_upserted|monitor|00000000-0000-0000-0000-000000002003|1|false|false",
    "6|monitor.attempt_recorded|monitor|00000000-0000-0000-0000-000000002003|1|false|false",
    "7|operation.claimed|operation|00000000-0000-0000-0000-000000002012|00000000-0000-0000-0000-000000002002|1|1|true",
    "8|monitor.deadline_upserted|monitor|00000000-0000-0000-0000-000000002012|1|false|false",
    "9|monitor.deadline_removed|monitor|00000000-0000-0000-0000-000000002012|1|true|true",
    "10|execution.authority_transferred|execution|00000000-0000-0000-0000-000000002002|2|running|2|migration-source|-",
    "11|operation.tombstoned|operation|00000000-0000-0000-0000-000000002012|00000000-0000-0000-0000-000000002002|2|1|false",
    "12|execution.control_transitioned|execution|00000000-0000-0000-0000-000000002002|2|running|2|migration-source|-",
    "13|execution.admitted|execution|00000000-0000-0000-0000-000000002102|1|admitted|0|sha256:test|-",
    "14|execution.control_transitioned|execution|00000000-0000-0000-0000-000000002102|1|running|0|sha256:test|-",
    "15|execution.supervisor_observation_recorded|supervisor|00000000-0000-0000-0000-000000002102|1|stderr|stderr,true,true,0,false,d2FybmluZwo=|-",
    "16|execution.supervisor_observation_recorded|supervisor|00000000-0000-0000-0000-000000002102|2|provider_exited|-|completed",
    "17|execution.control_transitioned|execution|00000000-0000-0000-0000-000000002102|1|terminal|2|sha256:test|completed",
]
private let migrationGoldenProjectionSummaryDigest =
    "871f5281ccf163165167b19873940818af9e8d3fc441bb19e76e4c500d50a2b2"

private func migrationGoldenSummary(_ message: RunLedgerOutboxMessage) -> String {
    let prefix = "\(message.sequence)|\(message.eventKind)"
    switch message.projection {
    case .execution(let value):
        return prefix + "|execution|\(migrationUUID(value.executionID.rawValue))"
            + "|\(value.authority.epoch.rawValue)|\(value.state.rawValue)"
            + "|\(value.lastSupervisorSequence)|\(value.configurationRevision)"
            + "|\(value.terminalEvidence?.outcome.rawValue ?? "-")"
    case .supervisor(let value):
        let stream = value.stream.map {
            "\($0.channel.rawValue),\($0.startsLogicalLine),\($0.endsLogicalLine),"
                + "\($0.trailingFragmentByteCount),\($0.fragmentTruncated),"
                + $0.bytes.base64EncodedString()
        } ?? "-"
        return prefix + "|supervisor|\(migrationUUID(value.observation.executionID.rawValue))"
            + "|\(value.observation.supervisorSequence)|\(value.observation.kind.rawValue)"
            + "|\(stream)|\(value.terminal?.outcome.rawValue ?? "-")"
    case .operation(let value):
        return prefix + "|operation|\(migrationUUID(value.operationID.rawValue))"
            + "|\(migrationUUID(value.executionID.rawValue))|\(value.authority.epoch.rawValue)"
            + "|\(value.effects.count)|\(value.holdsEffects)"
    case .monitor(let value):
        return prefix + "|monitor|\(migrationUUID(value.operationID.rawValue))"
            + "|\(value.authority.epoch.rawValue)|\(value.stopped)|\(value.deadline == nil)"
    case .runtimeSwitch(let value):
        return prefix + "|runtime-switch|\(migrationUUID(value.requestID.rawValue))"
            + "|\(migrationUUID(value.source.executionID.rawValue))"
            + "|\(migrationUUID(value.targetExecutionID.rawValue))|\(value.progress.rawValue)"
            + "|\(value.recordedControlEffectID == nil)|\(value.recordedReplacementEffectID == nil)"
    case .runtimeSwitchReservation(let value):
        return prefix + "|runtime-reservation|\(migrationUUID(value.requestID.rawValue))"
            + "|\(migrationUUID(value.reservationID.rawValue))"
            + "|\(migrationUUID(value.targetExecutionID.rawValue))|\(value.ledgerSequence)"
    case .executionControl(let value):
        return prefix + "|execution-control|\(migrationUUID(value.executionID.rawValue))"
            + "|\(value.authority.epoch.rawValue)|\(value.expectedSupervisorSequence)"
            + "|\(value.acceptedSupervisorSequence)|\(value.cancellationIntent?.rawValue ?? "-")"
    }
}

private func migrationUUID(_ value: UUID) -> String {
    value.uuidString.lowercased()
}

private let metadataUpdateTrigger = """
CREATE TRIGGER ledger_metadata_no_update BEFORE UPDATE ON ledger_metadata
BEGIN SELECT RAISE(ABORT, 'ledger metadata is immutable'); END;
"""

private let eventsUpdateTrigger = """
CREATE TRIGGER events_no_update BEFORE UPDATE ON events
BEGIN SELECT RAISE(ABORT, 'event journal is append-only'); END;
"""

private let outboxUpdateTrigger = """
CREATE TRIGGER outbox_no_update BEFORE UPDATE ON outbox
BEGIN SELECT RAISE(ABORT, 'outbox messages are immutable'); END;
"""

private let outboxDeleteTrigger = """
CREATE TRIGGER outbox_no_delete BEFORE DELETE ON outbox
BEGIN SELECT RAISE(ABORT, 'outbox messages are durable'); END;
"""

private let outboxStateTrigger = """
CREATE TRIGGER outbox_state_monotonic BEFORE UPDATE ON outbox_state
WHEN NEW.last_acknowledged_sequence != OLD.last_acknowledged_sequence
  AND NEW.last_acknowledged_sequence != COALESCE(
      (SELECT MIN(sequence) FROM outbox WHERE sequence > OLD.last_acknowledged_sequence),
      -1
  )
BEGIN SELECT RAISE(ABORT, 'outbox acknowledgement cannot skip or regress'); END;
"""

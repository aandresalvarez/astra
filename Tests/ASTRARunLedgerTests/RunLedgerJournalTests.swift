import ASTRACore
@testable import ASTRARunLedger
import Foundation
import Testing

@Suite("RunLedger journal, projections, and cursors")
struct RunLedgerJournalTests {
    @Test("Reopen preserves identity, journal, projections, and private file modes")
    func reopenDurability() throws {
        let fixture = try LedgerFixture()
        defer { fixture.cleanup() }
        let ledger = try fixture.open()
        let effect = workspaceEffect
        let manifest = fixture.manifest(
            ledger: ledger,
            execution: 1,
            authority: fixture.authority(2, epoch: 1),
            effects: [effect]
        )
        let admitted = fixture.envelope(
            id: 3,
            offset: 1,
            event: .executionAdmitted(
                manifest: manifest,
                primaryOperationID: fixture.operationID(6)
            )
        )
        let started = fixture.envelope(
            id: 4,
            offset: 2,
            event: .executionControlTransitioned(
                executionID: manifest.executionID,
                authority: manifest.authority,
                transition: .executionStarted,
                backendCapabilities: .monitoringOnly
            )
        )
        try ledger.append(admitted)
        try ledger.append(started)
        let identity = ledger.identity
        let projection = try ledger.projection()
        try ledger.close()

        let reopened = try fixture.open(expectedStoreID: identity.storeID)
        defer { try? reopened.close() }
        #expect(reopened.identity == identity)
        #expect(try reopened.events().count == 2)
        #expect(try reopened.outbox().count == 2)
        #expect(try reopened.projection() == projection)
        #expect(reopened.verifyHealth().status == .healthy)
        #expect(permissions(fixture.configuration.ledgerDirectoryURL) == 0o700)
        #expect(permissions(fixture.configuration.databaseURL) == 0o600)
    }

    @Test("Exact event replay is idempotent and creates no duplicate outbox row")
    func exactReplay() throws {
        let fixture = try LedgerFixture()
        defer { fixture.cleanup() }
        let ledger = try fixture.open()
        defer { try? ledger.close() }
        let manifest = fixture.manifest(
            ledger: ledger,
            execution: 10,
            authority: fixture.authority(11, epoch: 1),
            effects: [.computeOnly]
        )
        let event = fixture.envelope(
            id: 12,
            offset: 1,
            event: .executionAdmitted(
                manifest: manifest,
                primaryOperationID: fixture.operationID(13)
            )
        )

        let first = try ledger.append(event)
        let replay = try ledger.append(event)

        #expect(first == .init(sequence: 1, disposition: .appended))
        #expect(replay == .init(sequence: 1, disposition: .exactReplay))
        #expect(try ledger.events().count == 1)
        #expect(try ledger.outbox().count == 1)
    }

    @Test("Reusing an event ID with a different payload is rejected")
    func mismatchedEventReuse() throws {
        let fixture = try LedgerFixture()
        defer { fixture.cleanup() }
        let ledger = try fixture.open()
        defer { try? ledger.close() }
        let eventID = fixture.eventID(20)
        let firstManifest = fixture.manifest(
            ledger: ledger,
            execution: 21,
            authority: fixture.authority(22, epoch: 1),
            effects: [.computeOnly]
        )
        let secondManifest = fixture.manifest(
            ledger: ledger,
            execution: 23,
            authority: fixture.authority(24, epoch: 1),
            effects: [.computeOnly]
        )
        try ledger.append(.init(
            eventID: eventID,
            occurredAt: fixture.date(offset: 1),
            event: .executionAdmitted(
                manifest: firstManifest,
                primaryOperationID: fixture.operationID(25)
            )
        ))

        let error = ledgerError {
            try ledger.append(.init(
                eventID: eventID,
                occurredAt: fixture.date(offset: 1),
                event: .executionAdmitted(
                    manifest: secondManifest,
                    primaryOperationID: fixture.operationID(26)
                )
            ))
        }
        #expect(error == .eventIDReuse(eventID))
        #expect(try ledger.events().count == 1)
        #expect(try ledger.projection().executions.count == 1)
    }

    @Test("Outbox failure rolls back journal sequence and every projection write")
    func transactionRollbackHasNoHalfState() throws {
        let fixture = try LedgerFixture()
        defer { fixture.cleanup() }
        let ledger = try fixture.open()
        defer { try? ledger.close() }
        try executeSQLite(
            fixture.configuration.databaseURL,
            """
            CREATE TRIGGER test_fail_outbox BEFORE INSERT ON outbox
            BEGIN SELECT RAISE(ABORT, 'forced outbox failure'); END;
            """
        )
        let manifest = fixture.manifest(
            ledger: ledger,
            execution: 30,
            authority: fixture.authority(31, epoch: 1),
            effects: [.computeOnly]
        )
        let event = fixture.envelope(
            id: 32,
            offset: 1,
            event: .executionAdmitted(
                manifest: manifest,
                primaryOperationID: fixture.operationID(33)
            )
        )

        #expect(ledgerError { try ledger.append(event) } != nil)
        try executeSQLite(fixture.configuration.databaseURL, "DROP TRIGGER test_fail_outbox")
        #expect(try ledger.events().isEmpty)
        #expect(try ledger.outbox().isEmpty)
        #expect(try ledger.projection() == .init())

        let appended = try ledger.append(event)
        #expect(appended.sequence == 1)
        #expect(try ledger.events().count == 1)
        #expect(try ledger.outbox().count == 1)
    }

    @Test("Outbox acknowledgements and consumer checkpoints cannot skip or regress")
    func cursorOrdering() throws {
        let fixture = try LedgerFixture()
        defer { fixture.cleanup() }
        let ledger = try fixture.open()
        defer { try? ledger.close() }
        let manifest = fixture.manifest(
            ledger: ledger,
            execution: 70,
            authority: fixture.authority(71, epoch: 1),
            effects: [.computeOnly]
        )
        try ledger.append(fixture.envelope(
            id: 72,
            offset: 1,
            event: .executionAdmitted(
                manifest: manifest,
                primaryOperationID: fixture.operationID(74)
            )
        ))
        try ledger.append(fixture.envelope(
            id: 73,
            offset: 2,
            event: .executionControlTransitioned(
                executionID: manifest.executionID,
                authority: manifest.authority,
                transition: .executionStarted,
                backendCapabilities: .monitoringOnly
            )
        ))
        let messages = try ledger.outbox()
        #expect(messages.map(\.sequence) == [1, 2])
        #expect(ledgerError {
            try ledger.acknowledgeOutbox(sequence: 2, messageID: messages[1].messageID)
        } == .outboxAcknowledgementWouldSkip(current: 0, requested: 2, next: 1))
        guard case .outboxMessageIdentityMismatch = ledgerError({
            try ledger.acknowledgeOutbox(sequence: 1, messageID: messages[1].messageID)
        }) else {
            Issue.record("Expected outbox message identity mismatch")
            return
        }
        #expect(try ledger.acknowledgeOutbox(
            sequence: 1,
            messageID: messages[0].messageID
        ) == .applied)
        #expect(try ledger.acknowledgeOutbox(
            sequence: 1,
            messageID: messages[0].messageID
        ) == .idempotent)
        #expect(try ledger.acknowledgeOutbox(
            sequence: 2,
            messageID: messages[1].messageID
        ) == .applied)
        #expect(ledgerError {
            try ledger.acknowledgeOutbox(sequence: 1, messageID: messages[0].messageID)
        } == .outboxAcknowledgementWouldRegress(current: 2, requested: 1))

        let consumer = try RunLedgerConsumerID(rawValue: "test-consumer")
        #expect(ledgerError {
            try ledger.advanceCheckpoint(for: consumer, through: 2)
        } == .checkpointWouldSkip(current: 0, requested: 2, next: 1))
        #expect(try ledger.advanceCheckpoint(for: consumer, through: 1) == .applied)
        #expect(try ledger.advanceCheckpoint(for: consumer, through: 1) == .idempotent)
        #expect(try ledger.advanceCheckpoint(for: consumer, through: 2) == .applied)
        #expect(ledgerError {
            try ledger.advanceCheckpoint(for: consumer, through: 1)
        } == .checkpointWouldRegress(current: 2, requested: 1))
    }

    @Test("Journal replay deterministically equals transactional projections")
    func projectorEquivalence() throws {
        let fixture = try LedgerFixture()
        defer { fixture.cleanup() }
        let ledger = try fixture.open()
        defer { try? ledger.close() }
        let authority = fixture.authority(80, epoch: 1)
        let manifest = fixture.manifest(
            ledger: ledger,
            execution: 81,
            authority: authority,
            effects: [.computeOnly]
        )
        let operationID = fixture.operationID(82)
        let events: [RunLedgerEvent] = [
            .executionAdmitted(
                manifest: manifest,
                primaryOperationID: operationID
            ),
            .executionControlTransitioned(
                executionID: manifest.executionID,
                authority: authority,
                transition: .executionStarted,
                backendCapabilities: [.observe, .cancel]
            ),
            .executionControlTransitioned(
                executionID: manifest.executionID,
                authority: authority,
                transition: .requestCancellation(.graceful),
                backendCapabilities: [.observe, .cancel]
            ),
            .executionControlTransitioned(
                executionID: manifest.executionID,
                authority: authority,
                transition: .backendAcceptedCancellation,
                backendCapabilities: [.observe, .cancel]
            ),
            .supervisorObservationRecorded(.init(
                executionID: manifest.executionID,
                authority: authority,
                supervisorSequence: 1,
                supervisorEventID: fixedUUID(190),
                occurredAt: fixture.date(offset: 5),
                kind: .providerExited,
                exitCode: 0,
                terminationReason: .exited
            )),
            .executionControlTransitioned(
                executionID: manifest.executionID,
                authority: authority,
                transition: .executionCompleted,
                backendCapabilities: [.observe, .cancel]
            ),
        ]
        for (index, event) in events.enumerated() {
            try ledger.append(fixture.envelope(
                id: 83 + index,
                offset: TimeInterval(index + 1),
                event: event
            ))
        }

        #expect(try ledger.projection() == ledger.replayedProjection())
        let report = ledger.verifyHealth()
        #expect(report.status == .healthy)
        #expect(report.lastEventSequence == Int64(events.count))
    }

    @Test("Schema mismatch is reported without reset or migration")
    func schemaMismatchFailsClosed() throws {
        let fixture = try LedgerFixture()
        defer { fixture.cleanup() }
        let ledger = try fixture.open()
        try ledger.close()
        try executeSQLite(fixture.configuration.databaseURL, "PRAGMA user_version = 99")

        let report = RunLedger.inspect(fixture.configuration)
        #expect(report.status == .incompatibleSchema)
        #expect(sqliteInt(fixture.configuration.databaseURL, sql: "PRAGMA user_version") == 99)
        guard case .incompatibleSchema(let expected, found: 99) = ledgerError({
            _ = try fixture.open()
        }), expected == RunLedgerSchema.version else {
            Issue.record("Expected typed incompatible schema error")
            return
        }
        #expect(sqliteInt(fixture.configuration.databaseURL, sql: "PRAGMA user_version") == 99)
    }

    @Test("Missing required outbox index fails health closed")
    func missingOutboxIndexFailsClosed() throws {
        let fixture = try LedgerFixture()
        defer { fixture.cleanup() }
        let ledger = try fixture.open()
        #expect(ledger.verifyHealth().status == .healthy)
        try ledger.close()

        try executeSQLite(
            fixture.configuration.databaseURL,
            "DROP INDEX outbox_execution_stream"
        )

        #expect(RunLedger.inspect(fixture.configuration).status == .incompatibleSchema)
        guard case .incompatibleSchema = ledgerError({ _ = try fixture.open() }) else {
            Issue.record("Expected missing outbox index to fail schema verification")
            return
        }
    }

    @Test("Outbox index column direction drift fails health closed")
    func changedOutboxIndexDefinitionFailsClosed() throws {
        let fixture = try LedgerFixture()
        defer { fixture.cleanup() }
        let ledger = try fixture.open()
        #expect(ledger.verifyHealth().status == .healthy)
        try ledger.close()

        try executeSQLite(
            fixture.configuration.databaseURL,
            """
            DROP INDEX outbox_execution_terminal;
            CREATE INDEX outbox_execution_terminal
            ON outbox (execution_id, has_terminal, sequence ASC);
            """
        )

        #expect(RunLedger.inspect(fixture.configuration).status == .incompatibleSchema)
        guard case .incompatibleSchema = ledgerError({ _ = try fixture.open() }) else {
            Issue.record("Expected changed outbox index definition to fail schema verification")
            return
        }
    }

    @Test("Non-SQLite corruption is reported without modifying the file")
    func corruptionFailsClosed() throws {
        let fixture = try LedgerFixture(createLedgerDirectory: true)
        defer { fixture.cleanup() }
        let bytes = Data("not a sqlite ledger".utf8)
        try bytes.write(to: fixture.configuration.databaseURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fixture.configuration.databaseURL.path
        )
        let before = try Data(contentsOf: fixture.configuration.databaseURL)

        #expect(RunLedger.inspect(fixture.configuration).status == .corrupt)
        guard case .corrupt = ledgerError({ _ = try fixture.open() }) else {
            Issue.record("Expected typed corruption error")
            return
        }
        #expect(try Data(contentsOf: fixture.configuration.databaseURL) == before)
    }
}

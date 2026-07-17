import ASTRACore
@testable import ASTRARunLedger
import Foundation
import Testing

@Suite("RunLedger atomic launch admission")
struct RunLedgerAtomicAdmissionTests {
    @Test("Lone registration wire and a primary claim without atomic admission are rejected")
    func noPublicHalfAdmissionPath() throws {
        let fixture = try LedgerFixture()
        defer { fixture.cleanup() }
        let ledger = try fixture.open()
        defer { try? ledger.close() }
        let manifest = fixture.manifest(
            ledger: ledger,
            execution: 890,
            authority: fixture.authority(891, epoch: 1),
            effects: [workspaceEffect]
        )
        let validPayload = RunLedgerPersistedEventPayload(
            occurredAt: fixture.date(offset: 1),
            event: .executionAdmitted(
                manifest: manifest,
                primaryOperationID: fixture.operationID(892)
            )
        )
        var object = try #require(
            JSONSerialization.jsonObject(with: RunLedgerCodec.encode(validPayload)) as? [String: Any]
        )
        var event = try #require(object["event"] as? [String: Any])
        event["kind"] = "execution.registered"
        event.removeValue(forKey: "primaryOperationID")
        object["event"] = event
        let legacyRegistration = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )

        guard case .corrupt = ledgerError({
            _ = try RunLedgerCodec.decode(
                RunLedgerPersistedEventPayload.self,
                from: legacyRegistration
            )
        }) else {
            Issue.record("Expected removed lone-registration wire kind to fail closed")
            return
        }
        #expect(ledgerError {
            try ledger.append(fixture.envelope(
                id: 893,
                offset: 1,
                event: .operationClaimed(
                    operationID: fixture.operationID(894),
                    executionID: manifest.executionID,
                    authority: manifest.authority,
                    effects: manifest.declaredEffects
                )
            ))
        } == .missingExecution(manifest.executionID))
        #expect(try ledger.events().isEmpty)
        #expect(try ledger.projection() == .init())
    }

    @Test("Exact replay publishes one execution, one primary claim, and one outbox message")
    func exactReplayHasOneAtomicProjection() throws {
        let fixture = try LedgerFixture()
        defer { fixture.cleanup() }
        let ledger = try fixture.open()
        defer { try? ledger.close() }
        let manifest = fixture.manifest(
            ledger: ledger,
            execution: 900,
            authority: fixture.authority(901, epoch: 1),
            effects: [workspaceEffect]
        )
        let operationID = fixture.operationID(902)
        let key = fixedUUID(903)

        let first = try ledger.admitExecution(
            manifest: manifest,
            primaryOperationID: operationID,
            admittedAt: fixture.date(offset: 1),
            idempotencyKey: key
        )
        let replay = try ledger.admitExecution(
            manifest: manifest,
            primaryOperationID: operationID,
            admittedAt: fixture.date(offset: 1),
            idempotencyKey: key
        )

        #expect(first == .init(sequence: 1, disposition: .appended))
        #expect(replay == .init(sequence: 1, disposition: .exactReplay))
        let projection = try ledger.projection()
        #expect(projection.executions.count == 1)
        #expect(projection.operations.count == 1)
        #expect(projection.executions[manifest.executionID]?.createdSequence == 1)
        #expect(projection.operations[operationID]?.createdSequence == 1)
        #expect(projection.operations[operationID]?.record.effects == manifest.declaredEffects)
        #expect(try ledger.events().count == 1)
        #expect(try ledger.events().first?.envelope.event == .executionAdmitted(
            manifest: manifest,
            primaryOperationID: operationID
        ))
        #expect(try ledger.outbox().count == 1)
        #expect(ledger.verifyHealth().status == .healthy)
    }

    @Test("A late transaction failure leaves neither half of launch admission")
    func outboxFailureRollsBackBothRows() throws {
        let fixture = try LedgerFixture()
        defer { fixture.cleanup() }
        let ledger = try fixture.open()
        defer { try? ledger.close() }
        let manifest = fixture.manifest(
            ledger: ledger,
            execution: 910,
            authority: fixture.authority(911, epoch: 1),
            effects: [workspaceEffect]
        )
        let operationID = fixture.operationID(912)
        let key = fixedUUID(913)
        try executeSQLite(
            fixture.configuration.databaseURL,
            """
            CREATE TRIGGER test_fail_atomic_outbox BEFORE INSERT ON outbox
            BEGIN SELECT RAISE(ABORT, 'forced atomic outbox failure'); END;
            """
        )

        #expect(ledgerError {
            try ledger.admitExecution(
                manifest: manifest,
                primaryOperationID: operationID,
                admittedAt: fixture.date(offset: 1),
                idempotencyKey: key
            )
        } != nil)
        #expect(try ledger.events().isEmpty)
        #expect(try ledger.outbox().isEmpty)
        #expect(try ledger.projection() == .init())

        try executeSQLite(
            fixture.configuration.databaseURL,
            "DROP TRIGGER test_fail_atomic_outbox"
        )
        #expect(try ledger.admitExecution(
            manifest: manifest,
            primaryOperationID: operationID,
            admittedAt: fixture.date(offset: 1),
            idempotencyKey: key
        ).sequence == 1)
        #expect(try ledger.projection().executions.count == 1)
        #expect(try ledger.projection().operations.count == 1)
    }

    @Test("Concurrent conflicting launches admit one complete pair and no losing execution")
    func concurrentConflictHasNoHalfAdmission() throws {
        let fixture = try LedgerFixture()
        defer { fixture.cleanup() }
        let first = try fixture.open()
        defer { try? first.close() }
        let second = try fixture.open(expectedStoreID: first.identity.storeID)
        defer { try? second.close() }
        let manifests = [
            fixture.manifest(
                ledger: first,
                execution: 920,
                authority: fixture.authority(921, epoch: 1),
                effects: [workspaceEffect]
            ),
            fixture.manifest(
                ledger: first,
                execution: 922,
                authority: fixture.authority(923, epoch: 1),
                effects: [workspaceEffect]
            ),
        ]
        let operationIDs = [fixture.operationID(924), fixture.operationID(925)]
        let ledgers = [first, second]
        let results = LockedBox<[ClaimAttempt]>([])

        DispatchQueue.concurrentPerform(iterations: 2) { index in
            do {
                try ledgers[index].admitExecution(
                    manifest: manifests[index],
                    primaryOperationID: operationIDs[index],
                    admittedAt: fixture.date(offset: 1),
                    idempotencyKey: fixedUUID(926 + index)
                )
                results.withValue { $0.append(.admitted) }
            } catch let error as RunLedgerError {
                if case .admissionDenied = error {
                    results.withValue { $0.append(.conflictDenied) }
                } else {
                    results.withValue { $0.append(.unexpected) }
                }
            } catch {
                results.withValue { $0.append(.unexpected) }
            }
        }

        #expect(results.value.filter { $0 == .admitted }.count == 1)
        #expect(results.value.filter { $0 == .conflictDenied }.count == 1)
        let projection = try first.projection()
        #expect(projection.executions.count == 1)
        #expect(projection.operations.count == 1)
        #expect(Set(projection.operations.values.map(\.record.executionID)) == Set(projection.executions.keys))
        #expect(try first.events().count == 1)
        #expect(try first.outbox().count == 1)
        #expect(first.verifyHealth().status == .healthy)
    }
}

import ASTRACore
@testable import ASTRARunLedger
import Foundation
import Testing

@Suite("RunLedger terminal projection parity")
struct RunLedgerTerminalProjectionParityTests {
    @Test("Supervisor observation lookup is execution-indexed rather than journal-wide")
    func supervisorObservationLookupUsesExecutionIndex() throws {
        let fixture = try LedgerFixture()
        defer { fixture.cleanup() }
        let ledger = try fixture.open()
        defer { try? ledger.close() }
        let authority = fixture.authority(160, epoch: 1)
        let manifest = fixture.manifest(
            ledger: ledger,
            execution: 161,
            authority: authority,
            effects: [.computeOnly]
        )
        _ = try ledger.admitExecution(
            manifest: manifest,
            primaryOperationID: fixture.operationID(162),
            admittedAt: manifest.createdAt,
            idempotencyKey: fixedUUID(163)
        )
        let observation = RunBrokerSupervisorObservation(
            executionID: manifest.executionID,
            authority: authority,
            supervisorSequence: 1,
            supervisorEventID: fixedUUID(164),
            occurredAt: fixture.date(offset: 1),
            kind: .supervisorReady
        )
        _ = try ledger.append(fixture.envelope(
            id: 165,
            offset: 1,
            event: .supervisorObservationRecorded(observation)
        ))

        #expect(try ledger.supervisorObservations(for: manifest.executionID) == [observation])
        let plan = try ledger.connection.withLock { database in
            let statement = try ledger.connection.statement(
                """
                EXPLAIN QUERY PLAN
                SELECT event_kind FROM outbox
                WHERE execution_id = ?
                  AND event_kind = 'execution.supervisor_observation_recorded'
                  AND sequence <= ?
                ORDER BY supervisor_sequence
                """,
                bindings: [
                    .text(manifest.executionID.rawValue.uuidString.lowercased()),
                    .integer(Int64.max),
                ],
                database: database
            )
            defer { statement.finalize() }
            var details: [String] = []
            while try statement.step() == .row {
                details.append(try statement.text(at: 3))
            }
            return details.joined(separator: " ")
        }
        #expect(plan.contains("outbox_execution_supervisor"))
    }

    @Test("Terminal execution atomically releases every effect claim for later admission")
    func terminalExecutionReleasesEffectClaims() throws {
        let fixture = try LedgerFixture()
        defer { fixture.cleanup() }
        let ledger = try fixture.open()
        defer { try? ledger.close() }
        let authority = fixture.authority(170, epoch: 1)
        let operationID = fixture.operationID(171)
        let manifest = fixture.manifest(
            ledger: ledger,
            execution: 172,
            authority: authority,
            effects: [workspaceEffect]
        )
        _ = try ledger.admitExecution(
            manifest: manifest,
            primaryOperationID: operationID,
            admittedAt: manifest.createdAt,
            idempotencyKey: fixedUUID(173)
        )
        _ = try ledger.append(fixture.envelope(
            id: 174,
            offset: 1,
            event: .executionControlTransitioned(
                executionID: manifest.executionID,
                authority: authority,
                transition: .executionStarted,
                backendCapabilities: [.observe, .cancel]
            )
        ))
        _ = try ledger.append(fixture.envelope(
            id: 175,
            offset: 2,
            event: .supervisorObservationRecorded(.init(
                executionID: manifest.executionID,
                authority: authority,
                supervisorSequence: 1,
                supervisorEventID: fixedUUID(176),
                occurredAt: fixture.date(offset: 2),
                kind: .providerExited,
                exitCode: 0,
                terminationReason: .exited
            ))
        ))
        _ = try ledger.append(fixture.envelope(
            id: 177,
            offset: 3,
            event: .executionControlTransitioned(
                executionID: manifest.executionID,
                authority: authority,
                transition: .executionCompleted,
                backendCapabilities: [.observe, .cancel]
            )
        ))

        let released = try #require(ledger.projection().operations[operationID])
        #expect(!released.record.holdsEffects)
        #expect(released.record.state == .tombstoned(.init(
            reason: .completed,
            recordedAt: fixture.date(offset: 3)
        )))

        let nextAuthority = fixture.authority(178, epoch: 1)
        let nextManifest = fixture.manifest(
            ledger: ledger,
            execution: 179,
            authority: nextAuthority,
            effects: [workspaceEffect]
        )
        #expect(try ledger.admitExecution(
            manifest: nextManifest,
            primaryOperationID: fixture.operationID(180),
            admittedAt: fixture.date(offset: 4),
            idempotencyKey: fixedUUID(181)
        ).disposition == .appended)
    }

    @Test("Terminal control cannot commit before matching supervisor evidence")
    func terminalControlRequiresDurableEvidence() throws {
        let fixture = try LedgerFixture()
        defer { fixture.cleanup() }
        let ledger = try fixture.open()
        defer { try? ledger.close() }
        let authority = fixture.authority(180, epoch: 1)
        let manifest = fixture.manifest(
            ledger: ledger,
            execution: 181,
            authority: authority,
            effects: [.computeOnly]
        )
        _ = try ledger.admitExecution(
            manifest: manifest,
            primaryOperationID: fixture.operationID(182),
            admittedAt: manifest.createdAt,
            idempotencyKey: fixedUUID(183)
        )
        _ = try ledger.append(fixture.envelope(
            id: 184,
            offset: 1,
            event: .executionControlTransitioned(
                executionID: manifest.executionID,
                authority: authority,
                transition: .executionStarted,
                backendCapabilities: [.observe, .cancel]
            )
        ))
        let beforeEvents = try ledger.events().count
        let beforeOutbox = try ledger.outbox().count

        #expect(throws: (any Error).self) {
            _ = try ledger.append(fixture.envelope(
                id: 185,
                offset: 2,
                event: .executionControlTransitioned(
                    executionID: manifest.executionID,
                    authority: authority,
                    transition: .executionCompleted,
                    backendCapabilities: [.observe, .cancel]
                )
            ))
        }
        #expect(try ledger.events().count == beforeEvents)
        #expect(try ledger.outbox().count == beforeOutbox)
        #expect(try ledger.projection().executions[manifest.executionID]?.control.observedExecution == .running)

        let terminal = RunBrokerSupervisorObservation(
            executionID: manifest.executionID,
            authority: authority,
            supervisorSequence: 1,
            supervisorEventID: fixedUUID(186),
            occurredAt: fixture.date(offset: 2),
            kind: .providerExited,
            exitCode: 0,
            terminationReason: .exited
        )
        _ = try ledger.append(fixture.envelope(
            id: 187,
            offset: 2,
            event: .supervisorObservationRecorded(terminal)
        ))
        _ = try ledger.append(fixture.envelope(
            id: 188,
            offset: 3,
            event: .executionControlTransitioned(
                executionID: manifest.executionID,
                authority: authority,
                transition: .executionCompleted,
                backendCapabilities: [.observe, .cancel]
            )
        ))

        guard case .execution(let projected) = try #require(ledger.outbox().last).projection else {
            Issue.record("Expected terminal execution projection")
            return
        }
        #expect(projected.state == .terminal)
        #expect(projected.terminalEvidence?.supervisorEventID == terminal.supervisorEventID)
        try ledger.outbox().last?.projection.validate()
    }
}

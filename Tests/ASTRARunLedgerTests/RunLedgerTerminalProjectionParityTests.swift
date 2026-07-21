import ASTRACore
@testable import ASTRARunLedger
import Foundation
import Testing

@Suite("RunLedger terminal projection parity")
struct RunLedgerTerminalProjectionParityTests {
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

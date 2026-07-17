import ASTRACore
@testable import ASTRARunLedger
import Foundation
import Testing

@Suite("RunLedger admission and authority fencing")
struct RunLedgerAdmissionTests {
    @Test("Authority transfer is expected-current CAS and fences execution control")
    func authorityTransferCASAndControlFence() throws {
        let fixture = try LedgerFixture()
        defer { fixture.cleanup() }
        let first = try fixture.open()
        defer { try? first.close() }
        let original = fixture.authority(100, epoch: 1)
        let winner = fixture.authority(101, epoch: 2)
        let contender = fixture.authority(102, epoch: 2)
        let manifest = fixture.manifest(
            ledger: first,
            execution: 103,
            authority: original,
            effects: [.computeOnly]
        )
        try first.admitExecution(
            manifest: manifest,
            primaryOperationID: fixture.operationID(104),
            admittedAt: fixture.date(offset: 1),
            idempotencyKey: fixedUUID(105)
        )
        let second = try fixture.open(expectedStoreID: first.identity.storeID)
        defer { try? second.close() }
        let winningTransfer = fixture.envelope(
            id: 106,
            offset: 2,
            event: .executionAuthorityTransferred(
                executionID: manifest.executionID,
                expectedAuthority: original,
                newAuthority: winner
            )
        )
        #expect(try first.append(winningTransfer).disposition == .appended)
        let eventCount = try first.events().count
        let outboxCount = try first.outbox().count

        #expect(ledgerError {
            try second.append(fixture.envelope(
                id: 107,
                offset: 3,
                event: .executionAuthorityTransferred(
                    executionID: manifest.executionID,
                    expectedAuthority: original,
                    newAuthority: contender
                )
            ))
        } == .claimTransitionRejected(.staleEpochRejected))
        #expect(ledgerError {
            try second.append(fixture.envelope(
                id: 108,
                offset: 3,
                event: .executionAuthorityTransferred(
                    executionID: manifest.executionID,
                    expectedAuthority: winner,
                    newAuthority: fixture.authority(109, epoch: 4)
                )
            ))
        } == .invalidEvent("Authority transfer must advance exactly one epoch"))
        #expect(try first.events().count == eventCount)
        #expect(try first.outbox().count == outboxCount)
        #expect(try first.projection().executions[manifest.executionID]?.authority == winner)

        #expect(ledgerError {
            try second.append(fixture.envelope(
                id: 110,
                offset: 3,
                event: .executionControlTransitioned(
                    executionID: manifest.executionID,
                    authority: original,
                    transition: .executionStarted,
                    backendCapabilities: .monitoringOnly
                )
            ))
        } == .claimTransitionRejected(.staleEpochRejected))
        #expect(ledgerError {
            try second.append(fixture.envelope(
                id: 111,
                offset: 1.5,
                event: .executionControlTransitioned(
                    executionID: manifest.executionID,
                    authority: winner,
                    transition: .executionStarted,
                    backendCapabilities: .monitoringOnly
                )
            ))
        } == .invalidEvent("Execution control transition predates the current execution state"))
        #expect(try first.events().count == eventCount)
        #expect(try first.outbox().count == outboxCount)

        #expect(try second.append(fixture.envelope(
            id: 112,
            offset: 3,
            event: .executionControlTransitioned(
                executionID: manifest.executionID,
                authority: winner,
                transition: .executionStarted,
                backendCapabilities: .monitoringOnly
            )
        )).disposition == .appended)
        #expect(try first.append(winningTransfer).disposition == .exactReplay)
        #expect(try first.events().count == eventCount + 1)
        #expect(try first.outbox().count == outboxCount + 1)
        #expect(first.verifyHealth().status == .healthy)
    }

    @Test("Additional operation claims can only extend an atomically admitted execution")
    func additionalOperationExtendsAtomicAdmission() throws {
        let fixture = try LedgerFixture()
        defer { fixture.cleanup() }
        let ledger = try fixture.open()
        defer { try? ledger.close() }
        let effect = workspaceEffect
        let manifest = fixture.manifest(
            ledger: ledger,
            execution: 40,
            authority: fixture.authority(41, epoch: 1),
            effects: [effect]
        )
        try ledger.admitExecution(
            manifest: manifest,
            primaryOperationID: fixture.operationID(42),
            admittedAt: fixture.date(offset: 1),
            idempotencyKey: fixedUUID(43)
        )
        try ledger.append(fixture.envelope(
            id: 44,
            offset: 2,
            event: .operationClaimed(
                operationID: fixture.operationID(45),
                executionID: manifest.executionID,
                authority: manifest.authority,
                effects: [effect]
            )
        ))

        #expect(try ledger.projection().executions.count == 1)
        #expect(try ledger.projection().operations.count == 2)
        #expect(try ledger.events().count == 2)
    }

    @Test("Authority transfer fences stale writers and updates all active claims atomically")
    func staleAuthorityRejected() throws {
        let fixture = try LedgerFixture()
        defer { fixture.cleanup() }
        let ledger = try fixture.open()
        defer { try? ledger.close() }
        let oldAuthority = fixture.authority(50, epoch: 2)
        let newAuthority = fixture.authority(51, epoch: 3)
        let manifest = fixture.manifest(
            ledger: ledger,
            execution: 52,
            authority: oldAuthority,
            effects: [.computeOnly]
        )
        let operationID = fixture.operationID(53)
        try ledger.admitExecution(
            manifest: manifest,
            primaryOperationID: operationID,
            admittedAt: fixture.date(offset: 2),
            idempotencyKey: fixedUUID(54)
        )
        try ledger.append(fixture.envelope(
            id: 56,
            offset: 3,
            event: .executionAuthorityTransferred(
                executionID: manifest.executionID,
                expectedAuthority: oldAuthority,
                newAuthority: newAuthority
            )
        ))
        let projection = try ledger.projection()
        #expect(projection.executions[manifest.executionID]?.authority == newAuthority)
        #expect(projection.operations[operationID]?.record.authority == newAuthority)

        let staleError = ledgerError {
            try ledger.append(fixture.envelope(
                id: 57,
                offset: 4,
                event: .operationTombstoned(
                    operationID: operationID,
                    authority: oldAuthority,
                    reason: .completed
                )
            ))
        }
        #expect(staleError == .claimTransitionRejected(.staleEpochRejected))
        #expect(try ledger.events().count == 2)
    }

    @Test("Tombstones are absorbing and operation identities cannot be reused")
    func tombstoneAbsorption() throws {
        let fixture = try LedgerFixture()
        defer { fixture.cleanup() }
        let ledger = try fixture.open()
        defer { try? ledger.close() }
        let authority = fixture.authority(60, epoch: 1)
        let manifest = fixture.manifest(
            ledger: ledger,
            execution: 61,
            authority: authority,
            effects: [.computeOnly]
        )
        let operationID = fixture.operationID(62)
        try ledger.admitExecution(
            manifest: manifest,
            primaryOperationID: operationID,
            admittedAt: fixture.date(offset: 2),
            idempotencyKey: fixedUUID(63)
        )
        try ledger.append(fixture.envelope(
            id: 65,
            offset: 3,
            event: .operationTombstoned(
                operationID: operationID,
                authority: authority,
                reason: .completed
            )
        ))

        let reuseError = ledgerError {
            try ledger.append(fixture.envelope(
                id: 66,
                offset: 4,
                event: .operationClaimed(
                    operationID: operationID,
                    executionID: manifest.executionID,
                    authority: authority,
                    effects: [.computeOnly]
                )
            ))
        }
        guard case .admissionDenied(let denials) = reuseError else {
            Issue.record("Expected tombstoned operation admission denial")
            return
        }
        #expect(denials.contains(.operationTombstoned(operationID)))

        let secondTombstone = ledgerError {
            try ledger.append(fixture.envelope(
                id: 67,
                offset: 4,
                event: .operationTombstoned(
                    operationID: operationID,
                    authority: authority,
                    reason: .completed
                )
            ))
        }
        #expect(secondTombstone == .claimTransitionRejected(.tombstoneIsFinal))
        #expect(try ledger.events().count == 2)
    }
}

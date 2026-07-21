import ASTRACore
@testable import ASTRARunLedger
import Foundation
import Testing

/// The broker daemon must be the only live writer process over a ledger:
/// `.supervisorObservationRecorded` ordering and output limits are serialized
/// by the orchestrator's in-process lock, so appends from a second broker
/// (launchd relaunch racing a hung instance, or misconfigured channels sharing
/// a support directory) would interleave in ways the schema accepts but
/// reconcile can never repair. `flock` scopes to the open file description, so
/// two claimants conflict identically whether they live in one process or two;
/// the kernel drops the lock on process death, so a crashed broker never
/// strands the ledger.
@Suite("RunLedger exclusive writer lock")
struct RunLedgerExclusiveWriterTests {
    @Test("A second exclusive writer is rejected while the first holds the ledger")
    func secondExclusiveWriterRejected() throws {
        let fixture = try LedgerFixture()
        defer { fixture.cleanup() }
        let first = try RunLedger(configuration: exclusive(fixture.configuration))
        defer { try? first.close() }

        #expect(throws: RunLedgerError.exclusiveWriterConflict(
            "Another process already holds the exclusive ledger writer lock"
        )) {
            try RunLedger(configuration: exclusive(fixture.configuration))
        }
    }

    @Test("Secondary non-exclusive connections stay usable beside the exclusive writer")
    func secondaryConnectionsUnaffected() throws {
        let fixture = try LedgerFixture()
        defer { fixture.cleanup() }
        let broker = try RunLedger(configuration: exclusive(fixture.configuration))
        defer { try? broker.close() }

        let observer = try fixture.open()
        defer { try? observer.close() }
        #expect(observer.identity == broker.identity)
    }

    @Test("Closing the exclusive writer releases the lock for a successor")
    func closeReleasesLock() throws {
        let fixture = try LedgerFixture()
        defer { fixture.cleanup() }
        let first = try RunLedger(configuration: exclusive(fixture.configuration))
        try first.close()

        let successor = try RunLedger(configuration: exclusive(fixture.configuration))
        try successor.close()
    }

    @Test("A failed exclusive claim leaves the ledger openable")
    func failedClaimDoesNotStrandStorage() throws {
        let fixture = try LedgerFixture()
        defer { fixture.cleanup() }
        let holder = try RunLedger(configuration: exclusive(fixture.configuration))
        #expect(throws: RunLedgerError.self) {
            try RunLedger(configuration: exclusive(fixture.configuration))
        }
        try holder.close()

        let reopened = try RunLedger(configuration: exclusive(fixture.configuration))
        try reopened.close()
    }

    private func exclusive(_ base: RunLedgerConfiguration) -> RunLedgerConfiguration {
        .init(
            ledgerDirectoryURL: base.ledgerDirectoryURL,
            installationID: base.installationID,
            exclusiveWriter: true
        )
    }
}

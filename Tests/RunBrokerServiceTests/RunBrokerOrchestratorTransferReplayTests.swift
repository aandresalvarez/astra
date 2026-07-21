import ASTRACore
import ASTRARunLedger
import Foundation
import RunSupervisorSupport
import Testing
@_spi(RunBrokerServiceTesting) @testable import RunBrokerService

/// Regression coverage for reconcile replay after a journaled
/// `executionAuthorityTransferred`. A derived control event is a fact derived
/// exactly once from its source observation. Replay used to re-derive every
/// historical observation's control event under the projection's CURRENT
/// authority: after a transfer the same deterministic event ID carried a
/// different payload, every reconcile threw `RunLedgerError.eventIDReuse`
/// raw, and the execution became permanently unreconcilable without even
/// reaching in-doubt.
@Suite("RunBroker orchestrator authority-transfer replay", .serialized)
struct RunBrokerOrchestratorTransferReplayTests {
    @discardableResult
    private func transferAuthority(
        _ fixture: BrokerFixture,
        newAuthorityID: UInt8 = 50,
        eventID: UInt8 = 51,
        at offset: TimeInterval = 10
    ) throws -> RunBrokerAuthority {
        let successor = RunBrokerAuthority(
            id: .init(rawValue: brokerUUID(newAuthorityID)),
            epoch: .init(rawValue: 2)
        )
        _ = try fixture.ledger.append(.init(
            eventID: .init(rawValue: brokerUUID(eventID)),
            occurredAt: brokerTestDate.addingTimeInterval(offset),
            event: .executionAuthorityTransferred(
                executionID: fixture.manifest.executionID,
                expectedAuthority: fixture.manifest.authority,
                newAuthority: successor
            )
        ))
        return successor
    }

    @Test("reconcile after an authority transfer accepts recorded derived control")
    func reconcileAfterTransferAcceptsRecordedDerivedControl() throws {
        let fixture = try BrokerFixture()
        fixture.transport.events = [
            fixture.event(1, .supervisorReady),
            fixture.event(2, .providerStarted),
        ]
        _ = try fixture.orchestrator().start(fixture.request())
        let before = try fixture.ledger.events(limit: 100)
        try transferAuthority(fixture)

        let outcome = try fixture.orchestrator().reconcile(
            executionID: fixture.manifest.executionID
        )
        #expect(outcome.state == .running)
        #expect(outcome.lastSupervisorSequence == 2)
        // Replay recognized the journaled epoch-1 facts: no rewritten control
        // events, no duplicates, no in-doubt mark. Only the transfer itself
        // was added to the journal.
        let after = try fixture.ledger.events(limit: 100)
        #expect(after.count == before.count + 1)
        #expect(try fixture.ledger.projection().executions[fixture.manifest.executionID]?
            .control.observedExecution == .running)

        // Reconcile stays repeatable under the successor authority.
        let again = try fixture.orchestrator().reconcile(
            executionID: fixture.manifest.executionID
        )
        #expect(again.state == .running)
        #expect(try fixture.ledger.events(limit: 100).count == after.count)
    }

    @Test("terminal evidence after a transfer derives fresh control under the successor")
    func terminalEvidenceAfterTransferDerivesSuccessorControl() throws {
        let fixture = try BrokerFixture()
        fixture.transport.events = [
            fixture.event(1, .supervisorReady),
            fixture.event(2, .providerStarted),
        ]
        _ = try fixture.orchestrator().start(fixture.request())
        let successor = try transferAuthority(fixture)
        fixture.transport.events.append(fixture.event(3, .providerExited, exitCode: 0))

        let outcome = try fixture.orchestrator().reconcile(
            executionID: fixture.manifest.executionID
        )
        #expect(outcome.state == .terminal)
        #expect(try fixture.ledger.projection().executions[fixture.manifest.executionID]?
            .control.observedExecution == .completed)
        let exits = try fixture.ledger.events(limit: 100)
            .compactMap { stored -> (RunBrokerAuthority, Date)? in
                guard case .executionControlTransitioned(
                    _, let authority, .executionCompleted, _
                ) = stored.envelope.event else { return nil }
                return (authority, stored.envelope.occurredAt)
            }
        #expect(exits.count == 1)
        #expect(exits.first?.0 == successor)
        // The supervisor clock (createdAt+3) is behind the durable transfer
        // (createdAt+10). The derived fact is clamped forward onto the
        // ledger's monotonic execution timeline, never rejected.
        #expect(exits.first?.1 == brokerTestDate.addingTimeInterval(10))
        #expect(fixture.transport.acknowledgements.last == 3)
    }

    @Test("crash-repair after a transfer derives the missing control under the successor")
    func crashRepairAfterTransferDerivesMissingControl() throws {
        let fixture = try BrokerFixture()
        fixture.transport.events = [
            fixture.event(1, .supervisorReady),
            fixture.event(2, .providerStarted),
        ]
        #expect(throws: InjectedStartCrash.self) {
            _ = try fixture.orchestrator(
                fault: PointFaultInjector(point: .afterProviderStartedObservation)
            ).start(fixture.request())
        }
        #expect(try fixture.ledger.projection().executions[fixture.manifest.executionID]?
            .control.observedExecution == .registered)
        let successor = try transferAuthority(fixture)

        let outcome = try fixture.orchestrator().reconcile(
            executionID: fixture.manifest.executionID
        )
        #expect(outcome.state == .running)
        let started = try fixture.ledger.events(limit: 100)
            .compactMap { stored -> RunBrokerAuthority? in
                guard case .executionControlTransitioned(
                    _, let authority, .executionStarted, _
                ) = stored.envelope.event else { return nil }
                return authority
            }
        // Never-derived control is a fresh fact and must carry the authority
        // that is current when it is first journaled.
        #expect(started == [successor])
    }

    @Test("supervisor event-ID collision routes to in-doubt instead of a raw ledger error")
    func supervisorEventIDCollisionMarksInDoubt() throws {
        let fixture = try BrokerFixture()
        fixture.transport.events = [
            fixture.event(1, .supervisorReady),
            fixture.event(2, .providerStarted),
        ]
        _ = try fixture.orchestrator().start(fixture.request())
        // A corrupt or forged spool re-uses event 2's supervisor event ID for
        // different content at sequence 3. The deterministic durable event ID
        // collides with recorded evidence of different content.
        fixture.transport.events.append(.init(
            sequence: 3,
            id: brokerUUID(22),
            timestamp: brokerTestDate.addingTimeInterval(3),
            kind: .standardOutput,
            payload: .init(data: Data("x".utf8))
        ))

        let outcome = try fixture.orchestrator().reconcile(
            executionID: fixture.manifest.executionID
        )
        #expect(outcome.state == .inDoubt)
        #expect(try fixture.ledger.projection().executions[fixture.manifest.executionID]?
            .control.observedExecution == .inDoubt)
        #expect(fixture.transport.acknowledgements.last != 3)
    }

    @Test("supervisor clock behind admission clamps observations instead of wedging")
    func supervisorClockRegressionClampsInsteadOfWedging() throws {
        let fixture = try BrokerFixture()
        fixture.transport.events = [
            .init(
                sequence: 1,
                id: brokerUUID(21),
                timestamp: brokerTestDate.addingTimeInterval(-10),
                kind: .supervisorReady,
                payload: .init()
            ),
            .init(
                sequence: 2,
                id: brokerUUID(22),
                timestamp: brokerTestDate.addingTimeInterval(-9),
                kind: .providerStarted,
                payload: .init()
            ),
        ]
        let outcome = try fixture.orchestrator().start(fixture.request())
        #expect(outcome.state == .running)
        let observed = try fixture.ledger.events(limit: 100)
            .compactMap { stored -> Date? in
                guard case .supervisorObservationRecorded(let observation)
                    = stored.envelope.event else { return nil }
                return observation.occurredAt
            }
        // Clamped to the manifest's creation instant, the earliest durable
        // time the ledger accepts for this execution's evidence.
        #expect(observed == [brokerTestDate, brokerTestDate])
        #expect(try fixture.ledger.projection().executions[fixture.manifest.executionID]?
            .control.observedExecution == .running)

        // A later reconcile replays the clamped journal deterministically.
        let again = try fixture.orchestrator().reconcile(
            executionID: fixture.manifest.executionID
        )
        #expect(again.state == .running)
    }

    @Test("overlapping authenticated replay after a transfer is recognized, not in-doubt")
    func overlappingReplayAfterTransferIsRecognized() throws {
        let fixture = try BrokerFixture()
        fixture.transport.events = [
            fixture.event(1, .supervisorReady),
            fixture.event(2, .providerStarted),
        ]
        _ = try fixture.orchestrator().start(fixture.request())
        try transferAuthority(fixture)

        // A spool re-read after a lost acknowledgement re-sends evidence that
        // is already journaled (recorded under epoch 1). Identical supervisor
        // content must be recognized, not misread as a conflict because the
        // broker-side recording authority has since advanced.
        let overlapping = OverlappingReplayTransport(events: fixture.transport.events)
        let orchestrator = RunBrokerOrchestrator(
            ledger: fixture.ledger,
            vault: fixture.vault,
            spawner: fixture.spawner,
            transport: overlapping,
            installedBrokerExecutableURL: URL(fileURLWithPath: "/tmp/astra-run-broker")
        )
        let outcome = try orchestrator.reconcile(executionID: fixture.manifest.executionID)
        #expect(outcome.state == .running)
        #expect(try fixture.ledger.projection().executions[fixture.manifest.executionID]?
            .control.observedExecution == .running)
    }
}

/// Replays the full spool once regardless of the durable cursor, as a spool
/// re-read after a lost acknowledgement may, then honors the cursor.
private final class OverlappingReplayTransport: RunBrokerSupervisorTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private let events: [RunSupervisorEvent]
    private var replayedOnce = false

    init(events: [RunSupervisorEvent]) {
        self.events = events
    }

    func presence(
        identity: RunSupervisorIdentity,
        capability: RunSupervisorCapability
    ) throws -> RunBrokerSupervisorPresence {
        .authenticated
    }

    func replay(
        identity: RunSupervisorIdentity,
        capability: RunSupervisorCapability,
        after sequence: UInt64
    ) throws -> RunBrokerSupervisorReplayBatch {
        lock.lock()
        defer { lock.unlock() }
        let batch = replayedOnce ? events.filter { $0.sequence > sequence } : events
        replayedOnce = true
        return .init(
            identity: identity,
            source: .offlineAuthenticatedSpool,
            events: batch,
            lastSequence: events.last?.sequence ?? sequence
        )
    }

    func acknowledge(
        identity: RunSupervisorIdentity,
        capability: RunSupervisorCapability,
        source: RunBrokerSupervisorReplaySource,
        through sequence: UInt64
    ) throws {}

    func requestImmediateTermination(
        identity: RunSupervisorIdentity,
        capability: RunSupervisorCapability
    ) throws {}
}

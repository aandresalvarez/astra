import ASTRACore
import ASTRARunLedger
import Foundation
import RunSupervisorSupport
import Testing
@_spi(RunBrokerServiceTesting) @testable import RunBrokerService

@Suite("Durable RunBroker orchestration", .serialized)
struct RunBrokerOrchestratorTests {
    @Test("every atomic-start crash boundary leaves only durable predecessor state", arguments: RunBrokerStartCrashPoint.allCases)
    func atomicStartCrashBoundaries(point: RunBrokerStartCrashPoint) throws {
        let fixture = try BrokerFixture()
        fixture.transport.events = [
            fixture.event(1, .supervisorReady),
            fixture.event(2, .providerStarted),
        ]
        if point == .afterTerminalObservation {
            fixture.transport.events.append(fixture.event(3, .providerExited, exitCode: 0))
        }
        let service = fixture.orchestrator(fault: PointFaultInjector(point: point))
        #expect(throws: InjectedStartCrash.self) {
            _ = try service.start(fixture.request())
        }

        let events = try fixture.ledger.events(limit: 100)
        let expectedEventCount: Int = switch point {
        case .afterValidation, .afterCapabilitySync: 0
        case .afterLedgerAdmission, .afterSupervisorSpawn: 1
        case .afterReadyEvidence: 2
        case .afterProviderStartedObservation: 3
        case .afterProviderStartedEvidence: 4
        case .afterTerminalObservation: 5
        }
        #expect(events.count == expectedEventCount)
        #expect(fixture.vault.persistCount == (point == .afterValidation ? 0 : 1))
        #expect(fixture.spawner.payloads.count == ([
            .afterSupervisorSpawn, .afterReadyEvidence, .afterProviderStartedObservation,
            .afterProviderStartedEvidence, .afterTerminalObservation,
        ].contains(point) ? 1 : 0))
        #expect(fixture.transport.acknowledgements.isEmpty)
    }

    @Test("replay repairs provider-start control after crash between observation and transition")
    func replayRepairsProviderStartedDerivedControl() throws {
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
        let outcome = try fixture.orchestrator().reconcile(executionID: fixture.manifest.executionID)
        #expect(outcome.state == .running)
        #expect(fixture.transport.acknowledgements == [2])
    }

    @Test("replay repairs terminal exit control after crash between observation and transition")
    func replayRepairsExitDerivedControl() throws {
        let fixture = try BrokerFixture()
        fixture.transport.events = [
            fixture.event(1, .supervisorReady),
            fixture.event(2, .providerStarted),
            fixture.event(3, .providerExited, exitCode: 0),
        ]
        #expect(throws: InjectedStartCrash.self) {
            _ = try fixture.orchestrator(
                fault: PointFaultInjector(point: .afterTerminalObservation)
            ).start(fixture.request())
        }
        #expect(try fixture.ledger.projection().executions[fixture.manifest.executionID]?
            .control.observedExecution == .running)
        let outcome = try fixture.orchestrator().reconcile(executionID: fixture.manifest.executionID)
        #expect(outcome.state == .terminal)
        #expect(try fixture.ledger.projection().executions[fixture.manifest.executionID]?
            .control.observedExecution == .completed)
        #expect(fixture.transport.acknowledgements == [3])
    }

    @Test("replay repairs cancellation control after crash between observation and transition")
    func replayRepairsCancellationDerivedControl() throws {
        let fixture = try BrokerFixture()
        fixture.transport.events = [
            fixture.event(1, .supervisorReady),
            fixture.event(2, .providerStarted),
        ]
        let service = fixture.orchestrator(
            fault: PointFaultInjector(point: .afterTerminalObservation),
            authorizer: AllowExactRunBrokerImmediateTerminationAuthorizer()
        )
        _ = try service.start(fixture.request())
        try service.requestImmediateTermination(
            .init(executionID: fixture.manifest.executionID, intent: .immediate),
            requestedAt: brokerTestDate.addingTimeInterval(2.5),
            auditID: brokerUUID(92)
        )
        fixture.transport.events = [
            fixture.event(1, .supervisorReady),
            fixture.event(2, .providerStarted),
            fixture.event(3, .terminationStarted, cancellationIntent: .immediate),
            fixture.event(4, .cancellationConfirmed, cancellationIntent: .immediate),
        ]
        #expect(throws: InjectedStartCrash.self) {
            _ = try service.reconcile(executionID: fixture.manifest.executionID)
        }
        #expect(try fixture.ledger.projection().executions[fixture.manifest.executionID]?
            .control.observedExecution == .running)
        let outcome = try fixture.orchestrator().reconcile(executionID: fixture.manifest.executionID)
        #expect(outcome.state == .terminal)
        #expect(try fixture.ledger.projection().executions[fixture.manifest.executionID]?
            .control.observedExecution == .cancelled)
        #expect(fixture.transport.acknowledgements.last == 4)
    }

    @Test("ready and provider-start evidence become durable before started and acknowledgement")
    func evidenceBeforeStartedBeforeAck() throws {
        let fixture = try BrokerFixture()
        fixture.transport.events = [
            fixture.event(1, .supervisorReady),
            fixture.event(2, .providerStarted),
        ]
        fixture.transport.onImmediateTermination = nil
        let outcome = try fixture.orchestrator().start(fixture.request())
        #expect(outcome.state == .running)
        #expect(outcome.lastSupervisorSequence == 2)
        #expect(fixture.transport.acknowledgements == [2])

        let events = try fixture.ledger.events(limit: 100)
        #expect(events.map(\.envelope.event.kind) == [
            "execution.admitted",
            "execution.supervisor_observation_recorded",
            "execution.supervisor_observation_recorded",
            "execution.control_transitioned",
        ])
        #expect(try fixture.ledger.projection().executions[fixture.manifest.executionID]?
            .control.observedExecution == .running)
    }

    @Test("empty authenticated replay remains admitted and never publishes running")
    func emptyReplayStaysAdmitted() throws {
        let fixture = try BrokerFixture()
        fixture.transport.events = []
        let outcome = try fixture.orchestrator().start(fixture.request())
        #expect(outcome.state == .admitted)
        #expect(outcome.lastSupervisorSequence == 0)
        #expect(try fixture.ledger.projection().executions[fixture.manifest.executionID]?
            .control.observedExecution == .registered)
        #expect(fixture.transport.acknowledgements.isEmpty)
    }

    @Test("broker crash after durable evidence replays exactly and acknowledges without duplicate records")
    func brokerCrashAfterDurabilityIsIdempotent() throws {
        let fixture = try BrokerFixture()
        fixture.transport.events = [
            fixture.event(1, .supervisorReady),
            fixture.event(2, .providerStarted),
        ]
        #expect(throws: InjectedStartCrash.self) {
            _ = try fixture.orchestrator(
                fault: PointFaultInjector(point: .afterProviderStartedEvidence)
            ).start(fixture.request())
        }
        let before = try fixture.ledger.events(limit: 100)
        #expect(before.count == 4)
        #expect(fixture.transport.acknowledgements.isEmpty)

        let outcome = try fixture.orchestrator().reconcile(
            executionID: fixture.manifest.executionID
        )
        #expect(outcome.lastSupervisorSequence == 2)
        #expect(fixture.transport.replayCursors.last == 2)
        #expect(fixture.transport.acknowledgements == [2])
        #expect(try fixture.ledger.events(limit: 100) == before)
    }

    @Test("offline spool recovery survives app absence and a new broker instance")
    func offlineSpoolAndRestart() throws {
        let fixture = try BrokerFixture()
        try fixture.admitOnly()
        let capability = try RunSupervisorCapability(bytes: Data(repeating: 7, count: 32))
        try fixture.vault.persistAndSynchronize(.init(
            identity: .init(manifest: fixture.manifest),
            manifestSHA256: RunSupervisorDigests.manifest(fixture.manifest),
            capability: capability
        ))
        fixture.transport.source = .offlineAuthenticatedSpool
        fixture.transport.events = [
            fixture.event(1, .supervisorReady),
            fixture.event(2, .providerStarted),
            fixture.event(3, .standardOutput, output: Data("hello".utf8)),
            fixture.event(4, .providerExited, exitCode: 0),
        ]

        let first = try fixture.orchestrator().reconcile(executionID: fixture.manifest.executionID)
        #expect(first.state == .terminal)
        #expect(first.replaySource == .offlineAuthenticatedSpool)
        #expect(fixture.transport.acknowledgements == [4])
        let count = try fixture.ledger.events(limit: 100).count

        let second = try fixture.orchestrator().reconcile(executionID: fixture.manifest.executionID)
        #expect(second.state == .terminal)
        #expect(fixture.transport.replayCursors.last == 4)
        #expect(fixture.transport.acknowledgements == [4, 4])
        #expect(try fixture.ledger.events(limit: 100).count == count)
    }

    @Test("identity mismatch is in-doubt and never falls back to PID or local execution")
    func identityMismatchIsInDoubt() throws {
        let fixture = try BrokerFixture()
        try fixture.admitOnly()
        try fixture.vault.persistAndSynchronize(.init(
            identity: .init(manifest: fixture.manifest),
            manifestSHA256: RunSupervisorDigests.manifest(fixture.manifest),
            capability: try .init(bytes: Data(repeating: 8, count: 32))
        ))
        fixture.transport.identityOverride = .init(
            installationID: fixture.manifest.installationID,
            storeID: fixture.manifest.storeID,
            executionID: .init(rawValue: brokerUUID(99)),
            authority: fixture.manifest.authority
        )
        fixture.transport.events = [fixture.event(1, .supervisorReady)]

        let outcome = try fixture.orchestrator().reconcile(executionID: fixture.manifest.executionID)
        #expect(outcome.state == .inDoubt)
        #expect(try fixture.ledger.projection().executions[fixture.manifest.executionID]?
            .control.observedExecution == .inDoubt)
        #expect(fixture.spawner.payloads.isEmpty)
        #expect(fixture.transport.acknowledgements.isEmpty)
    }

    @Test("missing supervisor after ledger admission is an explicit in-doubt boundary")
    func crashBeforeSpawnRecoversInDoubt() throws {
        let fixture = try BrokerFixture()
        fixture.transport.replayError = RunBrokerServiceError.supervisorUnavailable
        #expect(throws: InjectedStartCrash.self) {
            _ = try fixture.orchestrator(
                fault: PointFaultInjector(point: .afterLedgerAdmission)
            ).start(fixture.request())
        }
        let outcome = try fixture.orchestrator().reconcile(executionID: fixture.manifest.executionID)
        #expect(outcome.state == .inDoubt)
        #expect(fixture.spawner.payloads.isEmpty)
    }

    @Test("sequence gaps and provider-before-ready fail closed without acknowledgement")
    func orderingFailuresAreInDoubt() throws {
        let gap = try BrokerFixture()
        gap.transport.events = [gap.event(2, .supervisorReady)]
        let gapOutcome = try gap.orchestrator().start(gap.request())
        #expect(gapOutcome.state == .inDoubt)
        #expect(gap.transport.acknowledgements.isEmpty)

        let semantic = try BrokerFixture()
        semantic.transport.events = [semantic.event(1, .providerStarted)]
        let semanticOutcome = try semantic.orchestrator().start(semantic.request())
        #expect(semanticOutcome.state == .inDoubt)
        #expect(semantic.transport.acknowledgements.isEmpty)
    }

    @Test("output policy applies backpressure before journal or acknowledgement and logs stay redacted")
    func outputBoundsAndRedaction() throws {
        let fixture = try BrokerFixture(
            maximumOutputEventBytes: 4,
            maximumPersistedOutputBytes: 4
        )
        fixture.transport.events = [
            fixture.event(1, .supervisorReady),
            fixture.event(2, .providerStarted),
            fixture.event(3, .standardOutput, output: Data("secret".utf8)),
        ]
        #expect(throws: RunBrokerServiceError.outputLimitExceeded(limit: 4)) {
            _ = try fixture.orchestrator().start(fixture.request())
        }
        let observations = try fixture.ledger.events(limit: 100).filter {
            if case .supervisorObservationRecorded = $0.envelope.event { true } else { false }
        }
        #expect(observations.count == 2)
        #expect(fixture.transport.acknowledgements.isEmpty)
        #expect(!fixture.logger.rendered.contains("secret"))
        #expect(!fixture.logger.rendered.contains(
            try fixture.vault.load(executionID: fixture.manifest.executionID)!.capability.base64
        ))
    }

    @Test("local authority is rejected before capability, ledger, spawn, or transport effects")
    func noLocalFallback() throws {
        let fixture = try BrokerFixture()
        let base = fixture.request()
        let local = RunBrokerStartRequest(
            authorityMode: .appLocal,
            manifest: base.manifest,
            primaryOperationID: base.primaryOperationID,
            admissionID: base.admissionID,
            arguments: base.arguments,
            environment: base.environment
        )
        #expect(throws: RunBrokerServiceError.localAuthorityForbidden) {
            _ = try fixture.orchestrator().start(local)
        }
        #expect(try fixture.ledger.events().isEmpty)
        #expect(fixture.vault.persistCount == 0)
        #expect(fixture.spawner.payloads.isEmpty)
    }

    @Test("immediate termination audit is durable before the authenticated effect")
    func terminationAuditPrecedesEffect() throws {
        let fixture = try BrokerFixture()
        fixture.transport.events = [
            fixture.event(1, .supervisorReady),
            fixture.event(2, .providerStarted),
        ]
        let service = fixture.orchestrator(authorizer: AllowExactRunBrokerImmediateTerminationAuthorizer())
        _ = try service.start(fixture.request())
        fixture.transport.onImmediateTermination = {
            let state = try? fixture.ledger.projection().executions[fixture.manifest.executionID]?.control
            #expect(state?.desiredCancellation == .immediate)
            #expect(state?.observedCancellation == .requestPending)
        }
        try service.requestImmediateTermination(
            .init(executionID: fixture.manifest.executionID, intent: .immediate),
            requestedAt: brokerTestDate.addingTimeInterval(10),
            auditID: brokerUUID(90)
        )
        #expect(fixture.transport.immediateTerminationCount == 1)
    }

    @Test("default authorizer denies immediate termination without an audit or effect")
    func terminationIsFailClosed() throws {
        let fixture = try BrokerFixture()
        fixture.transport.events = [
            fixture.event(1, .supervisorReady),
            fixture.event(2, .providerStarted),
        ]
        let service = fixture.orchestrator()
        _ = try service.start(fixture.request())
        let count = try fixture.ledger.events(limit: 100).count
        #expect(throws: RunBrokerServiceError.immediateTerminationUnauthorized) {
            try service.requestImmediateTermination(
                .init(executionID: fixture.manifest.executionID, intent: .immediate),
                requestedAt: brokerTestDate.addingTimeInterval(10),
                auditID: brokerUUID(91)
            )
        }
        #expect(try fixture.ledger.events(limit: 100).count == count)
        #expect(fixture.transport.immediateTerminationCount == 0)
    }
}

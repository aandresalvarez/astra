import ASTRACore
@testable import ASTRARunLedger
import Foundation
import RunBrokerPolicy
import Testing

@Suite("Canonical runtime-switch ledger")
struct RunLedgerRuntimeSwitchTests {
    @Test("runtime-switch reservation and policy admission commit as one exact event")
    func atomicAdmissionHasNoOrphanCrashWindow() throws {
        let fixture = try LedgerFixture()
        defer { fixture.cleanup() }
        let ledger = try fixture.open()
        let values = try makeValues(ledger: ledger, fixture: fixture)
        _ = try ledger.admitExecution(
            manifest: values.sourceManifest,
            primaryOperationID: fixture.operationID(200),
            admittedAt: fixedDate,
            idempotencyKey: fixedUUID(201)
        )
        let eventID = RunLedgerEventID(rawValue: fixedUUID(202))
        let first = try ledger.admitRuntimeSwitch(
            request: values.request,
            requestDigest: values.requestDigest,
            reservationID: values.reservationID,
            forceChallenge: nil,
            eventID: eventID,
            occurredAt: fixedDate.addingTimeInterval(1)
        )
        let replay = try ledger.admitRuntimeSwitch(
            request: values.request,
            requestDigest: values.requestDigest,
            reservationID: values.reservationID,
            forceChallenge: nil,
            eventID: eventID,
            occurredAt: fixedDate.addingTimeInterval(1)
        )
        #expect(first.disposition == .appended)
        #expect(replay.disposition == .exactReplay)
        let projection = try ledger.projection()
        #expect(projection.runtimeSwitchPolicyState.record?.request == values.request)
        #expect(projection.runtimeSwitchPolicyState.record?.targetReservation
            == projection.runtimeSwitchReservations[values.reservationID])
        #expect(try ledger.events().filter {
            $0.envelope.event.kind.hasPrefix("runtime_switch.")
        }.map(\.envelope.event.kind) == ["runtime_switch.admitted"])
        try ledger.close()

        let reopened = try fixture.open(expectedStoreID: values.storeID)
        defer { try? reopened.close() }
        #expect(try reopened.projection() == projection)
        #expect(try reopened.replayedProjection() == projection)
    }

    @Test("atomic admission recomputes request, source, and target digests before mutation")
    func atomicAdmissionRejectsUntrustedDigests() throws {
        let fixture = try LedgerFixture()
        defer { fixture.cleanup() }
        let ledger = try fixture.open()
        defer { try? ledger.close() }
        let values = try makeValues(ledger: ledger, fixture: fixture)
        _ = try ledger.admitExecution(
            manifest: values.sourceManifest,
            primaryOperationID: fixture.operationID(210),
            admittedAt: fixedDate,
            idempotencyKey: fixedUUID(211)
        )
        let baselineEvents = try ledger.events().count

        #expect(throws: RunLedgerError.self) {
            _ = try ledger.admitRuntimeSwitch(
                request: values.request,
                requestDigest: .init(value: try digest(999)),
                reservationID: values.reservationID,
                forceChallenge: nil,
                eventID: .init(rawValue: fixedUUID(212)),
                occurredAt: fixedDate.addingTimeInterval(1)
            )
        }

        let wrongSource = try RuntimeSwitchSourceFence(
            installationID: values.source.installationID,
            storeID: values.source.storeID,
            executionID: values.source.executionID,
            taskID: values.source.taskID,
            authority: values.source.authority,
            manifestSHA256: try digest(998),
            configurationRevision: values.source.configurationRevision
        )
        let wrongSourceRequest = try ActiveRuntimeSwitchRequest.defaultHandoff(intent: .init(
            requestID: .init(rawValue: fixedUUID(213)),
            mode: .graceful,
            expectedSource: wrongSource,
            target: values.request.intent.target,
            requestedAt: fixedDate
        ))
        #expect(throws: RunLedgerError.self) {
            _ = try ledger.admitRuntimeSwitch(
                request: wrongSourceRequest,
                requestDigest: try RuntimeSwitchDigests.request(wrongSourceRequest),
                reservationID: .init(rawValue: fixedUUID(214)),
                forceChallenge: nil,
                eventID: .init(rawValue: fixedUUID(215)),
                occurredAt: fixedDate.addingTimeInterval(1)
            )
        }

        let wrongTarget = try RuntimeSwitchResolvedTarget(
            manifest: values.request.intent.target.manifest,
            manifestSHA256: try digest(997)
        )
        let wrongTargetRequest = try ActiveRuntimeSwitchRequest.defaultHandoff(intent: .init(
            requestID: .init(rawValue: fixedUUID(216)),
            mode: .graceful,
            expectedSource: values.source,
            target: wrongTarget,
            requestedAt: fixedDate
        ))
        #expect(throws: RunLedgerError.self) {
            _ = try ledger.admitRuntimeSwitch(
                request: wrongTargetRequest,
                requestDigest: try RuntimeSwitchDigests.request(wrongTargetRequest),
                reservationID: .init(rawValue: fixedUUID(217)),
                forceChallenge: nil,
                eventID: .init(rawValue: fixedUUID(218)),
                occurredAt: fixedDate.addingTimeInterval(1)
            )
        }

        let validTargetManifest = values.request.intent.target.manifest
        let clientAuthorityTargetManifest = ExecutionLaunchManifest(
            installationID: validTargetManifest.installationID,
            storeID: validTargetManifest.storeID,
            executionID: validTargetManifest.executionID,
            taskID: validTargetManifest.taskID,
            authority: values.source.authority,
            configuration: validTargetManifest.configuration,
            declaredEffects: validTargetManifest.declaredEffects,
            supervisionPolicy: validTargetManifest.supervisionPolicy,
            createdAt: validTargetManifest.createdAt
        )
        let clientAuthorityTarget = try RuntimeSwitchResolvedTarget(
            manifest: clientAuthorityTargetManifest,
            manifestSHA256: RuntimeSwitchDigests.manifest(clientAuthorityTargetManifest)
        )
        let clientAuthorityRequest = try ActiveRuntimeSwitchRequest.defaultHandoff(intent: .init(
            requestID: .init(rawValue: fixedUUID(219)),
            mode: .graceful,
            expectedSource: values.source,
            target: clientAuthorityTarget,
            requestedAt: fixedDate
        ))
        #expect(throws: RunLedgerError.self) {
            _ = try ledger.admitRuntimeSwitch(
                request: clientAuthorityRequest,
                requestDigest: RuntimeSwitchDigests.request(clientAuthorityRequest),
                reservationID: .init(rawValue: fixedUUID(219)),
                forceChallenge: nil,
                eventID: .init(rawValue: fixedUUID(219)),
                occurredAt: fixedDate.addingTimeInterval(1)
            )
        }
        #expect(try ledger.events().count == baselineEvents)
        #expect(try ledger.projection().runtimeSwitchReservations.isEmpty)
        #expect(try ledger.projection().runtimeSwitchPolicyState == .empty)
    }

    @Test("legacy force admission replay retains challenge identity globally")
    func legacyForceChallengeCannotBeReusedByExecutionControl() throws {
        let fixture = try LedgerFixture()
        defer { fixture.cleanup() }
        let ledger = try fixture.open()
        let values = try makeValues(ledger: ledger, fixture: fixture)
        _ = try ledger.admitExecution(
            manifest: values.sourceManifest,
            primaryOperationID: fixture.operationID(220),
            admittedAt: fixedDate,
            idempotencyKey: fixedUUID(221)
        )
        let intent = try RuntimeSwitchIntent(
            requestID: values.request.intent.requestID,
            mode: .immediate,
            expectedSource: values.source,
            target: values.request.intent.target,
            requestedAt: fixedDate
        )
        let audit = RuntimeForceSwitchAudit(
            auditID: .init(rawValue: fixedUUID(222)),
            source: .diagnostics,
            reasonCode: .operatorEmergencyStop
        )
        let request = ActiveRuntimeSwitchRequest.forceTermination(
            try .init(intent: intent, audit: audit)
        )
        let requestDigest = try RuntimeSwitchDigests.request(request)
        let reservation = try ledger.reserveRuntimeSwitchTarget(
            request: request,
            requestDigest: requestDigest,
            reservationID: values.reservationID,
            occurredAt: fixedDate.addingTimeInterval(1)
        )
        let challengeID = RuntimeForceChallengeID(rawValue: fixedUUID(223))
        let actor = try RuntimeSwitchActorID(rawValue: "legacy-operator")
        let sessionID = fixedUUID(224)
        let challenge = try RuntimeForceSwitchChallenge(
            challengeID: challengeID,
            requestID: intent.requestID,
            requestDigest: requestDigest,
            actorID: actor,
            sessionID: sessionID,
            issuedAt: fixedDate.addingTimeInterval(2),
            expiresAt: fixedDate.addingTimeInterval(302)
        )
        let sourceSequence = UInt64(try #require(
            ledger.projection().executions[values.source.executionID]?.updatedSequence
        ))
        let verified = try VerifiedRuntimeSwitchAdmission(
            request: request,
            requestDigest: requestDigest,
            source: values.source,
            targetReservation: reservation,
            sourceLedgerSequence: sourceSequence,
            lifecycle: .registered,
            observedCancellation: .notRequested,
            forceChallenge: challenge
        )
        let admitted = RuntimeSwitchPolicy.admit(.empty, request: request, verified: verified)
        _ = try ledger.transitionRuntimeSwitchPolicy(
            expected: .empty,
            next: admitted.state,
            effectID: nil,
            eventID: .init(rawValue: fixedUUID(225)),
            occurredAt: fixedDate.addingTimeInterval(2)
        )
        #expect(try ledger.projection().runtimeSwitchForceChallenges[challengeID] == challenge)
        try ledger.close()

        let reopened = try fixture.open(expectedStoreID: values.storeID)
        defer { try? reopened.close() }
        #expect(try reopened.projection().runtimeSwitchForceChallenges[challengeID] == challenge)
        let direct = try ExecutionForceChallenge(
            challengeID: challengeID,
            requestDigest: .init(value: try digest(226)),
            requestID: fixedUUID(226),
            executionID: values.source.executionID,
            authority: values.source.authority,
            expectedSupervisorSequence: 0,
            actorID: actor,
            sessionID: sessionID,
            audit: audit,
            issuedAt: fixedDate.addingTimeInterval(3),
            expiresAt: fixedDate.addingTimeInterval(303)
        )
        #expect(throws: RunLedgerError.self) {
            _ = try reopened.recordExecutionForceChallenge(
                direct,
                eventID: .init(rawValue: fixedUUID(227)),
                occurredAt: fixedDate.addingTimeInterval(3)
            )
        }
    }

    @Test("reservation and policy CAS survive restart and exact replay")
    func reservationAndPolicyCASRecover() throws {
        let fixture = try LedgerFixture()
        defer { fixture.cleanup() }
        let ledger = try fixture.open()
        let values = try makeValues(ledger: ledger, fixture: fixture)

        _ = try ledger.admitExecution(
            manifest: values.sourceManifest,
            primaryOperationID: fixture.operationID(910),
            admittedAt: fixedDate,
            idempotencyKey: fixedUUID(911)
        )
        let sourceSequence = try #require(
            ledger.projection().executions[values.sourceManifest.executionID]?.updatedSequence
        )
        let reservation = try ledger.reserveRuntimeSwitchTarget(
            request: values.request,
            requestDigest: values.requestDigest,
            reservationID: values.reservationID,
            occurredAt: fixedDate.addingTimeInterval(1)
        )
        #expect(reservation.ledgerSequence > UInt64(sourceSequence))

        let admission = try VerifiedRuntimeSwitchAdmission(
            request: values.request,
            requestDigest: values.requestDigest,
            source: values.source,
            targetReservation: reservation,
            sourceLedgerSequence: UInt64(sourceSequence),
            lifecycle: .registered,
            observedCancellation: .notRequested
        )
        let reduction = RuntimeSwitchPolicy.admit(
            .empty,
            request: values.request,
            verified: admission
        )
        #expect(reduction.disposition == .admitted)
        let transitionID = RunLedgerEventID(rawValue: fixedUUID(912))
        let first = try ledger.transitionRuntimeSwitchPolicy(
            expected: .empty,
            next: reduction.state,
            effectID: nil,
            eventID: transitionID,
            occurredAt: fixedDate.addingTimeInterval(2)
        )
        let replay = try ledger.transitionRuntimeSwitchPolicy(
            expected: .empty,
            next: reduction.state,
            effectID: nil,
            eventID: transitionID,
            occurredAt: fixedDate.addingTimeInterval(2)
        )
        #expect(first.disposition == .appended)
        #expect(replay.disposition == .exactReplay)
        try ledger.close()

        let reopened = try fixture.open(expectedStoreID: values.storeID)
        defer { try? reopened.close() }
        let projection = try reopened.projection()
        #expect(projection.runtimeSwitchPolicyState == reduction.state)
        #expect(projection.runtimeSwitchReservations[values.reservationID] == reservation)
        #expect(try reopened.replayedProjection() == projection)
    }

    @Test("request, reservation, target, and policy CAS conflicts fail closed")
    func globalBindingsAndCASFailClosed() throws {
        let fixture = try LedgerFixture()
        defer { fixture.cleanup() }
        let ledger = try fixture.open()
        defer { try? ledger.close() }
        let values = try makeValues(ledger: ledger, fixture: fixture)
        _ = try ledger.admitExecution(
            manifest: values.sourceManifest,
            primaryOperationID: fixture.operationID(920),
            admittedAt: fixedDate,
            idempotencyKey: fixedUUID(921)
        )
        _ = try ledger.reserveRuntimeSwitchTarget(
            request: values.request,
            requestDigest: values.requestDigest,
            reservationID: values.reservationID,
            occurredAt: fixedDate.addingTimeInterval(1)
        )

        let conflictingTargetManifest = try makeManifest(
            fixture: fixture,
            storeID: ledger.identity.storeID,
            executionID: executionID(904),
            taskID: values.sourceManifest.taskID,
            authority: values.sourceManifest.authority,
            runtimeID: .copilotCLI,
            revision: "other-target"
        )
        let conflictingTarget = try RuntimeSwitchResolvedTarget(
            manifest: conflictingTargetManifest,
            manifestSHA256: try digest(904)
        )
        let conflictingIntent = try RuntimeSwitchIntent(
            requestID: values.request.intent.requestID,
            mode: .graceful,
            expectedSource: values.source,
            target: conflictingTarget,
            requestedAt: fixedDate
        )
        let conflictingRequest = try ActiveRuntimeSwitchRequest.defaultHandoff(intent: conflictingIntent)
        #expect(throws: RunLedgerError.self) {
            try ledger.reserveRuntimeSwitchTarget(
                request: conflictingRequest,
                requestDigest: values.requestDigest,
                reservationID: .init(rawValue: fixedUUID(905)),
                occurredAt: fixedDate.addingTimeInterval(2)
            )
        }

        #expect(throws: RunLedgerError.self) {
            try ledger.transitionRuntimeSwitchPolicy(
                expected: .empty,
                next: .empty,
                effectID: nil,
                eventID: .init(rawValue: fixedUUID(906)),
                occurredAt: fixedDate.addingTimeInterval(3)
            )
        }
    }

    @Test("completion archive uses the inserted sequence and replays across both crash windows")
    func completionArchiveUsesActualSequence() throws {
        let fixture = try LedgerFixture()
        defer { fixture.cleanup() }
        let ledger = try fixture.open()
        let values = try makeValues(ledger: ledger, fixture: fixture)
        _ = try ledger.admitExecution(
            manifest: values.sourceManifest,
            primaryOperationID: fixture.operationID(930),
            admittedAt: fixedDate,
            idempotencyKey: fixedUUID(931)
        )
        let sourceSequence = UInt64(try #require(
            ledger.projection().executions[values.sourceManifest.executionID]?.updatedSequence
        ))
        let reservation = try ledger.reserveRuntimeSwitchTarget(
            request: values.request,
            requestDigest: values.requestDigest,
            reservationID: values.reservationID,
            occurredAt: fixedDate.addingTimeInterval(1)
        )
        let completed = try commitCompletedSwitch(
            ledger: ledger,
            values: values,
            reservation: reservation,
            sourceSequence: sourceSequence
        )
        #expect(completed.record?.progress == .completed)

        // Crash before archive: restart must recover the completed singleton.
        try ledger.close()
        let restarted = try fixture.open(expectedStoreID: values.storeID)
        #expect(try restarted.projection().runtimeSwitchPolicyState == completed)

        // An unrelated durable write can interleave before archive. The
        // archive projector must use its actual inserted event sequence.
        _ = try restarted.upsertMonitorDeadline(
            operationID: fixture.operationID(930),
            authority: values.source.authority,
            dueAt: fixedDate.addingTimeInterval(25),
            attempt: 0,
            scheduledAt: fixedDate.addingTimeInterval(20),
            replacing: nil,
            idempotencyKey: fixedUUID(933)
        )
        let archiveEventID = RunLedgerEventID(rawValue: fixedUUID(934))
        let archiveEvidenceID = RuntimeSwitchEvidenceID(rawValue: fixedUUID(935))
        let first = try restarted.archiveRuntimeSwitchCompletion(
            expected: completed,
            archiveEvidenceID: archiveEvidenceID,
            eventID: archiveEventID,
            occurredAt: fixedDate.addingTimeInterval(21)
        )
        let archived = try restarted.projection().runtimeSwitchPolicyState
        let storedArchive = try #require(try restarted.event(eventID: archiveEventID))
        #expect(archived.record == nil)
        #expect(archived.lastArchivedCompletion?.ledgerSequence == UInt64(storedArchive.sequence))
        #expect(archived.lastArchivedCompletion?.archiveEvidenceID == archiveEvidenceID)
        #expect(archived.lastArchivedCompletion?.controlEffectID == completed.record?.controlEffect?.effectID)
        #expect(archived.lastArchivedCompletion?.replacementEffectID == completed.record?.replacementEffect?.effectID)
        guard case .runtimeSwitch(let archiveMessage) = try #require(restarted.outbox().last).projection else {
            Issue.record("Expected archived runtime-switch outbox projection")
            return
        }
        #expect(archiveMessage.progress == .archived)
        #expect(archiveMessage.recordedControlEffectID == completed.record?.controlEffect?.effectID)
        #expect(archiveMessage.recordedReplacementEffectID == completed.record?.replacementEffect?.effectID)
        #expect(first.disposition == .appended)
        #expect(try restarted.archiveRuntimeSwitchCompletion(
            expected: completed,
            archiveEvidenceID: archiveEvidenceID,
            eventID: archiveEventID,
            occurredAt: fixedDate.addingTimeInterval(21)
        ).disposition == .exactReplay)

        // Crash after archive: the free active slot and exact rollover survive.
        try restarted.close()
        let afterArchive = try fixture.open(expectedStoreID: values.storeID)
        defer { try? afterArchive.close() }
        #expect(try afterArchive.projection().runtimeSwitchPolicyState == archived)
        #expect(try afterArchive.replayedProjection().runtimeSwitchPolicyState == archived)
    }
}

private func commitCompletedSwitch(
    ledger: RunLedger,
    values: RuntimeSwitchLedgerValues,
    reservation: RuntimeSwitchTargetReservation,
    sourceSequence: UInt64
) throws -> RuntimeSwitchPolicyState {
    let admission = try VerifiedRuntimeSwitchAdmission(
        request: values.request,
        requestDigest: values.requestDigest,
        source: values.source,
        targetReservation: reservation,
        sourceLedgerSequence: sourceSequence,
        lifecycle: .registered,
        observedCancellation: .notRequested
    )
    var state = RuntimeSwitchPolicy.admit(
        .empty,
        request: values.request,
        verified: admission
    ).state
    _ = try ledger.transitionRuntimeSwitchPolicy(
        expected: .empty,
        next: state,
        effectID: nil,
        eventID: .init(rawValue: fixedUUID(936)),
        occurredAt: fixedDate.addingTimeInterval(2)
    )

    let controlEffectID = RuntimeSwitchEffectID(rawValue: fixedUUID(937))
    let supervisor = try RuntimeSwitchSupervisorFence(
        installationID: values.source.installationID,
        storeID: values.source.storeID,
        executionID: values.source.executionID,
        authority: values.source.authority,
        cohortID: "archive-test-cohort",
        protocolIdentity: .init(adapterID: "archive-test-supervisor", protocolVersion: 1)
    )
    let checkpoint = try VerifiedRuntimeSwitchCheckpointAttestation(
        request: values.request,
        requestDigest: values.requestDigest,
        effectID: controlEffectID,
        checkpointID: .init(rawValue: "archive-checkpoint"),
        checkpointGeneration: 1,
        ledgerSequence: reservation.ledgerSequence + 1,
        effectWatermark: 0,
        toolOperationWatermark: 0,
        inFlightEffectCount: 0,
        inFlightToolOperationCount: 0,
        providerContinuation: .init(adapterID: "archive-test-provider", protocolVersion: 1),
        supervisor: supervisor
    )
    var next = RuntimeSwitchPolicy.observeSafeCheckpoint(state, attestation: checkpoint).state
    _ = try ledger.transitionRuntimeSwitchPolicy(
        expected: state,
        next: next,
        effectID: controlEffectID,
        eventID: .init(rawValue: fixedUUID(938)),
        occurredAt: fixedDate.addingTimeInterval(3)
    )
    state = next

    let controlAcceptance = VerifiedRuntimeSwitchControlAcceptance(
        evidenceID: .init(rawValue: fixedUUID(939)),
        effectID: controlEffectID,
        source: values.source,
        ledgerSequence: checkpoint.fence.ledgerSequence + 1
    )
    next = RuntimeSwitchPolicy.acknowledgeControl(state, acceptance: controlAcceptance).state
    _ = try ledger.transitionRuntimeSwitchPolicy(
        expected: state,
        next: next,
        effectID: nil,
        eventID: .init(rawValue: fixedUUID(940)),
        occurredAt: fixedDate.addingTimeInterval(4)
    )
    state = next

    let replacementEffectID = RuntimeSwitchEffectID(rawValue: fixedUUID(941))
    let terminal = try VerifiedRuntimeSwitchTerminalAttestation(
        evidenceID: .init(rawValue: fixedUUID(942)),
        source: values.source,
        observedState: .cancelled,
        ledgerSequence: controlAcceptance.ledgerSequence + 1,
        replacementEffectID: replacementEffectID
    )
    next = RuntimeSwitchPolicy.observeSourceTerminal(state, attestation: terminal).state
    _ = try ledger.transitionRuntimeSwitchPolicy(
        expected: state,
        next: next,
        effectID: replacementEffectID,
        eventID: .init(rawValue: fixedUUID(943)),
        occurredAt: fixedDate.addingTimeInterval(5)
    )
    state = next

    let replacementAcceptance = VerifiedRuntimeSwitchReplacementAcceptance(
        evidenceID: .init(rawValue: fixedUUID(944)),
        effectID: replacementEffectID,
        targetReservationID: reservation.reservationID,
        targetExecutionID: values.request.intent.target.manifest.executionID,
        targetManifestSHA256: values.request.intent.target.manifestSHA256,
        ledgerSequence: terminal.terminalFence.ledgerSequence + 1
    )
    next = RuntimeSwitchPolicy.acknowledgeReplacement(
        state,
        acceptance: replacementAcceptance
    ).state
    _ = try ledger.transitionRuntimeSwitchPolicy(
        expected: state,
        next: next,
        effectID: nil,
        eventID: .init(rawValue: fixedUUID(945)),
        occurredAt: fixedDate.addingTimeInterval(6)
    )
    state = next

    let running = VerifiedRuntimeSwitchReplacementRunningAttestation(
        evidenceID: .init(rawValue: fixedUUID(946)),
        targetReservationID: reservation.reservationID,
        targetExecutionID: values.request.intent.target.manifest.executionID,
        targetManifestSHA256: values.request.intent.target.manifestSHA256,
        ledgerSequence: replacementAcceptance.ledgerSequence + 1
    )
    next = RuntimeSwitchPolicy.observeReplacementRunning(state, attestation: running).state
    _ = try ledger.transitionRuntimeSwitchPolicy(
        expected: state,
        next: next,
        effectID: nil,
        eventID: .init(rawValue: fixedUUID(947)),
        occurredAt: fixedDate.addingTimeInterval(7)
    )
    return next
}

private struct RuntimeSwitchLedgerValues {
    let storeID: RunBrokerStoreID
    let sourceManifest: ExecutionLaunchManifest
    let source: RuntimeSwitchSourceFence
    let request: ActiveRuntimeSwitchRequest
    let requestDigest: RuntimeSwitchRequestDigest
    let reservationID: RuntimeSwitchEvidenceID
}

private func makeValues(
    ledger: RunLedger,
    fixture: LedgerFixture
) throws -> RuntimeSwitchLedgerValues {
    let authority = fixture.authority(901, epoch: 1)
    let taskID = fixedUUID(902)
    let sourceManifest = try makeManifest(
        fixture: fixture,
        storeID: ledger.identity.storeID,
        executionID: executionID(901),
        taskID: taskID,
        authority: authority,
        runtimeID: .claudeCode,
        revision: "source"
    )
    let source = try RuntimeSwitchSourceFence(
        manifest: sourceManifest,
        manifestSHA256: try RuntimeSwitchDigests.manifest(sourceManifest)
    )
    let requestID = RuntimeSwitchRequestID(rawValue: fixedUUID(907))
    let targetTemplate = try makeManifest(
        fixture: fixture,
        storeID: ledger.identity.storeID,
        executionID: executionID(903),
        taskID: taskID,
        authority: authority,
        runtimeID: .codexCLI,
        revision: "target"
    )
    let targetAuthority = try RunBrokerAuthorityDerivation.runtimeSwitchTarget(
        installationID: targetTemplate.installationID,
        storeID: targetTemplate.storeID,
        requestID: requestID,
        executionID: targetTemplate.executionID,
        taskID: targetTemplate.taskID,
        configuration: targetTemplate.configuration,
        declaredEffects: targetTemplate.declaredEffects,
        supervisionPolicy: targetTemplate.supervisionPolicy!,
        createdAt: targetTemplate.createdAt
    )
    let targetManifest = ExecutionLaunchManifest(
        installationID: targetTemplate.installationID,
        storeID: targetTemplate.storeID,
        executionID: targetTemplate.executionID,
        taskID: targetTemplate.taskID,
        authority: targetAuthority,
        configuration: targetTemplate.configuration,
        declaredEffects: targetTemplate.declaredEffects,
        supervisionPolicy: targetTemplate.supervisionPolicy,
        createdAt: targetTemplate.createdAt
    )
    let target = try RuntimeSwitchResolvedTarget(
        manifest: targetManifest,
        manifestSHA256: try RuntimeSwitchDigests.manifest(targetManifest)
    )
    let request = try ActiveRuntimeSwitchRequest.defaultHandoff(intent: .init(
        requestID: requestID,
        mode: .graceful,
        expectedSource: source,
        target: target,
        requestedAt: fixedDate
    ))
    return .init(
        storeID: ledger.identity.storeID,
        sourceManifest: sourceManifest,
        source: source,
        request: request,
        requestDigest: try RuntimeSwitchDigests.request(request),
        reservationID: .init(rawValue: fixedUUID(909))
    )
}

private func makeManifest(
    fixture: LedgerFixture,
    storeID: RunBrokerStoreID,
    executionID: RunBrokerExecutionID,
    taskID: UUID,
    authority: RunBrokerAuthority,
    runtimeID: AgentRuntimeID,
    revision: String
) throws -> ExecutionLaunchManifest {
    .init(
        installationID: fixture.configuration.installationID,
        storeID: storeID,
        executionID: executionID,
        taskID: taskID,
        authority: authority,
        configuration: .init(
            runtimeID: runtimeID,
            executablePath: "/usr/bin/true",
            workingDirectory: "/tmp",
            configurationRevision: revision
        ),
        declaredEffects: [workspaceEffect],
        supervisionPolicy: try .init(
            hardTimeoutSeconds: 3_600,
            idleProgressTimeoutSeconds: 300
        ),
        createdAt: fixedDate
    )
}

private func digest(_ value: Int) throws -> ExecutionLaunchArgumentsSHA256 {
    try .init(hexValue: String(format: "%064x", value))
}

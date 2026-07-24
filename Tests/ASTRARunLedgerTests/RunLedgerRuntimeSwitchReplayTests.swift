import ASTRACore
@testable import ASTRARunLedger
import Foundation
import RunBrokerPolicy
import Testing

/// Regression coverage for replaying runtime-switch journal events against
/// the execution state AS OF each event's journal position. Legal later
/// events (authority transfer, admission of the reserved replacement,
/// execution control transitions) must never retroactively invalidate
/// recorded runtime-switch facts and brick `projection()`.
@Suite("Runtime-switch replay against historical execution state")
struct RunLedgerRuntimeSwitchReplayTests {
    @Test("authority transfer after switch admission keeps the projection loadable")
    func authorityTransferDoesNotInvalidateHistoricalSwitchEvents() throws {
        let fixture = try LedgerFixture()
        defer { fixture.cleanup() }
        let ledger = try fixture.open()
        let values = try makeReplayValues(ledger: ledger, fixture: fixture)
        _ = try ledger.admitExecution(
            manifest: values.sourceManifest,
            primaryOperationID: fixture.operationID(1_200),
            admittedAt: fixedDate,
            idempotencyKey: fixedUUID(1_201)
        )
        _ = try ledger.admitRuntimeSwitch(
            request: values.request,
            requestDigest: values.requestDigest,
            reservationID: values.reservationID,
            forceChallenge: nil,
            eventID: .init(rawValue: fixedUUID(1_202)),
            occurredAt: fixedDate.addingTimeInterval(1)
        )
        let admitted = try ledger.projection().runtimeSwitchPolicyState
        #expect(admitted.record?.request == values.request)

        // A direct execution-force challenge recorded under the original
        // authority is a durable historical fact as well.
        let challengeID = RuntimeForceChallengeID(rawValue: fixedUUID(1_203))
        let challenge = try ExecutionForceChallenge(
            challengeID: challengeID,
            requestDigest: .init(value: try replayDigest(1_204)),
            requestID: fixedUUID(1_204),
            executionID: values.source.executionID,
            authority: values.source.authority,
            expectedSupervisorSequence: 0,
            actorID: try RuntimeSwitchActorID(rawValue: "replay-operator"),
            sessionID: fixedUUID(1_205),
            audit: RuntimeForceSwitchAudit(
                auditID: .init(rawValue: fixedUUID(1_206)),
                source: .diagnostics,
                reasonCode: .operatorEmergencyStop
            ),
            issuedAt: fixedDate.addingTimeInterval(2),
            expiresAt: fixedDate.addingTimeInterval(302)
        )
        _ = try ledger.recordExecutionForceChallenge(
            challenge,
            eventID: .init(rawValue: fixedUUID(1_207)),
            occurredAt: fixedDate.addingTimeInterval(2)
        )

        // A perfectly legal crash-recovery authority transfer follows the
        // admitted switch. Historical runtime-switch facts must survive it.
        let successor = fixture.authority(1_208, epoch: 2)
        _ = try ledger.append(fixture.envelope(
            id: 1_209,
            offset: 3,
            event: .executionAuthorityTransferred(
                executionID: values.source.executionID,
                expectedAuthority: values.source.authority,
                newAuthority: successor
            )
        ))

        let projection = try ledger.projection()
        #expect(projection.runtimeSwitchPolicyState == admitted)
        #expect(
            projection.runtimeSwitchPolicyState.record?.request.intent
                .expectedSource.authority == values.source.authority
        )
        #expect(projection.executions[values.source.executionID]?.authority == successor)
        #expect(projection.executionForceChallenges[challengeID] == challenge)
        #expect(try ledger.replayedProjection() == projection)
        #expect(ledger.verifyHealth().status == .healthy)
        try ledger.close()

        let reopened = try fixture.open(expectedStoreID: values.storeID)
        defer { try? reopened.close() }
        #expect(try reopened.projection() == projection)
    }

    @Test("replacement admission after switch admission keeps the projection loadable")
    func replacementAdmissionDoesNotInvalidateHistoricalSwitchEvents() throws {
        let fixture = try LedgerFixture()
        defer { fixture.cleanup() }
        let ledger = try fixture.open()
        let values = try makeReplayValues(ledger: ledger, fixture: fixture)
        _ = try ledger.admitExecution(
            manifest: values.sourceManifest,
            primaryOperationID: fixture.operationID(1_300),
            admittedAt: fixedDate,
            idempotencyKey: fixedUUID(1_301)
        )
        _ = try ledger.admitRuntimeSwitch(
            request: values.request,
            requestDigest: values.requestDigest,
            reservationID: values.reservationID,
            forceChallenge: nil,
            eventID: .init(rawValue: fixedUUID(1_302)),
            occurredAt: fixedDate.addingTimeInterval(1)
        )
        let admitted = try ledger.projection().runtimeSwitchPolicyState

        // The source releases its exclusive effect claim before the reserved
        // replacement launches, then the replacement is admitted durably.
        _ = try ledger.append(fixture.envelope(
            id: 1_303,
            offset: 2,
            event: .operationTombstoned(
                operationID: fixture.operationID(1_300),
                authority: values.source.authority,
                reason: .cancelled
            )
        ))
        let targetManifest = values.request.intent.target.manifest
        _ = try ledger.admitExecution(
            manifest: targetManifest,
            primaryOperationID: fixture.operationID(1_304),
            admittedAt: fixedDate.addingTimeInterval(3),
            idempotencyKey: fixedUUID(1_305)
        )

        let projection = try ledger.projection()
        #expect(projection.runtimeSwitchPolicyState == admitted)
        #expect(
            projection.runtimeSwitchReservations[values.reservationID]?.targetExecutionID
                == targetManifest.executionID
        )
        #expect(projection.executions[targetManifest.executionID] != nil)
        #expect(try ledger.replayedProjection() == projection)
        #expect(ledger.verifyHealth().status == .healthy)
        try ledger.close()

        let reopened = try fixture.open(expectedStoreID: values.storeID)
        defer { try? reopened.close() }
        #expect(try reopened.projection() == projection)
    }

    @Test("control transitions after admission preserve the exact admitted record")
    func controlTransitionKeepsAdmittedRecordExact() throws {
        let fixture = try LedgerFixture()
        defer { fixture.cleanup() }
        let ledger = try fixture.open()
        defer { try? ledger.close() }
        let values = try makeReplayValues(ledger: ledger, fixture: fixture)
        _ = try ledger.admitExecution(
            manifest: values.sourceManifest,
            primaryOperationID: fixture.operationID(1_400),
            admittedAt: fixedDate,
            idempotencyKey: fixedUUID(1_401)
        )
        let sourceSequence = try #require(
            ledger.projection().executions[values.source.executionID]?.updatedSequence
        )
        _ = try ledger.admitRuntimeSwitch(
            request: values.request,
            requestDigest: values.requestDigest,
            reservationID: values.reservationID,
            forceChallenge: nil,
            eventID: .init(rawValue: fixedUUID(1_402)),
            occurredAt: fixedDate.addingTimeInterval(1)
        )
        let admitted = try ledger.projection().runtimeSwitchPolicyState

        // An ordinary later control transition advances the execution's
        // updated sequence. The admitted record's source fence sequence is a
        // historical fact and must not be recomputed from final state.
        _ = try ledger.append(fixture.envelope(
            id: 1_403,
            offset: 2,
            event: .executionControlTransitioned(
                executionID: values.source.executionID,
                authority: values.source.authority,
                transition: .executionStarted,
                backendCapabilities: .monitoringOnly
            )
        ))

        let projection = try ledger.projection()
        #expect(projection.runtimeSwitchPolicyState == admitted)
        #expect(
            projection.runtimeSwitchPolicyState.record?.sourceLedgerSequence
                == UInt64(sourceSequence)
        )
        #expect(try ledger.replayedProjection() == projection)
        #expect(ledger.verifyHealth().status == .healthy)
    }
}

private struct ReplayLedgerValues {
    let storeID: RunBrokerStoreID
    let sourceManifest: ExecutionLaunchManifest
    let source: RuntimeSwitchSourceFence
    let request: ActiveRuntimeSwitchRequest
    let requestDigest: RuntimeSwitchRequestDigest
    let reservationID: RuntimeSwitchEvidenceID
}

private func makeReplayValues(
    ledger: RunLedger,
    fixture: LedgerFixture
) throws -> ReplayLedgerValues {
    let authority = fixture.authority(1_101, epoch: 1)
    let taskID = fixedUUID(1_102)
    let sourceManifest = try makeReplayManifest(
        fixture: fixture,
        storeID: ledger.identity.storeID,
        executionID: executionID(1_103),
        taskID: taskID,
        authority: authority,
        runtimeID: .claudeCode,
        revision: "replay-source"
    )
    let source = try RuntimeSwitchSourceFence(
        manifest: sourceManifest,
        manifestSHA256: try RuntimeSwitchDigests.manifest(sourceManifest)
    )
    let requestID = RuntimeSwitchRequestID(rawValue: fixedUUID(1_104))
    let targetTemplate = try makeReplayManifest(
        fixture: fixture,
        storeID: ledger.identity.storeID,
        executionID: executionID(1_105),
        taskID: taskID,
        authority: authority,
        runtimeID: .codexCLI,
        revision: "replay-target"
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
        reservationID: .init(rawValue: fixedUUID(1_106))
    )
}

private func makeReplayManifest(
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

private func replayDigest(_ value: Int) throws -> ExecutionLaunchArgumentsSHA256 {
    try .init(hexValue: String(format: "%064x", value))
}

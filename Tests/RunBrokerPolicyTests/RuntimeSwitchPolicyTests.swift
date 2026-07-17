import ASTRACore
import Foundation
@testable import RunBrokerPolicy
import Testing

@Suite("Runtime picker ownership")
struct RuntimePickerOwnershipTests {
    @Test("Existing PR3 runtime intent remains the only picker state owner")
    func pickerChangesOnlyNextRuntime() {
        let active = ActiveExecutionRuntime(executionID: executionID(1), runtimeID: .claudeCode)
        let initial = ExecutionRuntimeIntentState(active: active, nextRuntimeID: .claudeCode)
        let changed = ExecutionRuntimeIntentReducer.reduce(initial, event: .selectNextRuntime(.codexCLI))

        #expect(changed.disposition == .applied)
        #expect(changed.state.active == active)
        #expect(changed.state.nextRuntimeID == .codexCLI)
    }
}

@Suite("Durable graceful runtime switching")
struct DurableGracefulRuntimeSwitchTests {
    @Test("Graceful request is admitted pending and client replay is observation-only")
    func admissionAndReplay() throws {
        let fixture = try Fixture()
        let request = try fixture.gracefulRequest()
        let admitted = RuntimeSwitchPolicy.admit(
            .empty,
            request: request,
            verified: try fixture.admission(for: request, lifecycle: .starting)
        )

        #expect(admitted.disposition == .admitted)
        #expect(admitted.recordedEffectID == nil)
        #expect(admitted.state.record?.progress == .waitingForCheckpoint)

        let replay = RuntimeSwitchPolicy.admit(admitted.state, request: request, verified: nil)
        #expect(replay.disposition == .idempotent)
        #expect(replay.recordedEffectID == nil)
        #expect(replay.state == admitted.state)
    }

    @Test("Same request ID with changed payload conflicts and another request cannot steal pending ownership")
    func requestConflicts() throws {
        let fixture = try Fixture()
        let first = try fixture.gracefulRequest()
        let state = RuntimeSwitchPolicy.admit(
            .empty,
            request: first,
            verified: try fixture.admission(for: first)
        ).state

        let changedTarget = try fixture.gracefulRequest(
            requestID: first.intent.requestID,
            target: fixture.alternateTarget
        )
        #expect(RuntimeSwitchPolicy.admit(state, request: changedTarget, verified: nil).blockedReason == .requestIDConflict)

        let other = try fixture.gracefulRequest(requestID: requestID(999))
        #expect(RuntimeSwitchPolicy.admit(state, request: other, verified: nil).blockedReason == .switchAlreadyPending)
    }

    @Test("Admission requires a fresh reservation bound to the exact target and later ledger sequence")
    func targetReservationBinding() throws {
        let fixture = try Fixture()
        let request = try fixture.gracefulRequest()
        let wrongTarget = fixture.targetReservation(
            for: request,
            targetExecutionID: fixture.alternateTarget.manifest.executionID
        )
        #expect(throws: RuntimeSwitchTrustedAttestationError.targetBindingMismatch) {
            try fixture.admission(for: request, reservation: wrongTarget)
        }

        let stale = fixture.targetReservation(for: request, ledgerSequence: 5)
        #expect(throws: RuntimeSwitchTrustedAttestationError.staleReservation) {
            try fixture.admission(
                for: request,
                reservation: stale,
                sourceLedgerSequence: 5
            )
        }
    }

    @Test("Unsafe time does not reject graceful intent; authenticated checkpoint records one durable effect")
    func nextSafeCheckpointCreatesEffect() throws {
        let fixture = try Fixture()
        let request = try fixture.gracefulRequest()
        let waiting = RuntimeSwitchPolicy.admit(
            .empty,
            request: request,
            verified: try fixture.admission(for: request, lifecycle: .registered)
        ).state
        let checkpoint = try fixture.checkpoint(for: request, effectID: effectID(10))

        let ready = RuntimeSwitchPolicy.observeSafeCheckpoint(waiting, attestation: checkpoint)
        #expect(ready.disposition == .effectRecorded)
        #expect(ready.recordedEffectID == effectID(10))
        #expect(ready.state.record?.progress == .controlDispatchPending)
        #expect(ready.state.record?.controlEffect?.cancellationIntent == .graceful)

        let replay = RuntimeSwitchPolicy.observeSafeCheckpoint(ready.state, attestation: checkpoint)
        #expect(replay.disposition == .idempotent)
        #expect(replay.recordedEffectID == nil)
        let alteredSameEffect = try fixture.checkpoint(
            for: request,
            effectID: checkpoint.effectID,
            checkpointGeneration: 11
        )
        #expect(RuntimeSwitchPolicy.observeSafeCheckpoint(
            ready.state,
            attestation: alteredSameEffect
        ).blockedReason == .effectIDConflict)
    }

    @Test("Checkpoint attestation requires zero effects and exact supervisor installation store execution authority")
    func checkpointTrustBoundary() throws {
        let fixture = try Fixture()
        let request = try fixture.gracefulRequest()

        #expect(throws: RuntimeSwitchTrustedAttestationError.checkpointNotSafe) {
            try fixture.checkpoint(for: request, inFlightEffectCount: 1)
        }
        #expect(throws: RuntimeSwitchTrustedAttestationError.checkpointNotSafe) {
            try fixture.checkpoint(for: request, inFlightToolOperationCount: 1)
        }

        let foreignSupervisor = try fixture.supervisor(installationID: installationID(90))
        #expect(throws: RuntimeSwitchTrustedAttestationError.supervisorBindingMismatch) {
            try fixture.checkpoint(for: request, supervisor: foreignSupervisor)
        }
        let foreignStore = try fixture.supervisor(storeID: storeID(91))
        #expect(throws: RuntimeSwitchTrustedAttestationError.supervisorBindingMismatch) {
            try fixture.checkpoint(for: request, supervisor: foreignStore)
        }
        let staleAuthority = try fixture.supervisor(
            authority: .init(id: fixture.source.authority.id, epoch: .init(rawValue: 99))
        )
        #expect(throws: RuntimeSwitchTrustedAttestationError.supervisorBindingMismatch) {
            try fixture.checkpoint(for: request, supervisor: staleAuthority)
        }
    }

    @Test("Dispatch re-fences exact generation adapter cohort source and cancellation state")
    func dispatchFenceIsExact() throws {
        let fixture = try Fixture()
        let prepared = try fixture.preparedGracefulState(effectID: effectID(20))
        let effect = try #require(prepared.record?.controlEffect)
        let capability = try fixture.capability(for: effect, intent: .graceful)

        let exact = RuntimeSwitchPolicy.prepareControlDispatch(
            prepared,
            effectID: effect.effectID,
            snapshot: fixture.dispatchSnapshot(for: effect),
            capability: capability
        )
        #expect(exact.directive?.effectID == effect.effectID)
        #expect(exact.directive?.cancellationIntent == .graceful)

        let wrongSource = try fixture.sourceFence(installationID: installationID(88))
        #expect(RuntimeSwitchPolicy.prepareControlDispatch(
            prepared,
            effectID: effect.effectID,
            snapshot: fixture.dispatchSnapshot(for: effect, source: wrongSource),
            capability: capability
        ).blockedReason == .dispatchFenceMismatch)

        let generation = try fixture.checkpointFence(
            source: effect.source,
            targetDigest: effect.target.manifestSHA256,
            generation: 99
        )
        #expect(RuntimeSwitchPolicy.prepareControlDispatch(
            prepared,
            effectID: effect.effectID,
            snapshot: fixture.dispatchSnapshot(for: effect, checkpoint: generation),
            capability: capability
        ).blockedReason == .checkpointMismatch)

        let adapter = try fixture.checkpointFence(
            source: effect.source,
            targetDigest: effect.target.manifestSHA256,
            providerAdapter: "other-provider"
        )
        #expect(RuntimeSwitchPolicy.prepareControlDispatch(
            prepared,
            effectID: effect.effectID,
            snapshot: fixture.dispatchSnapshot(for: effect, checkpoint: adapter),
            capability: capability
        ).blockedReason == .checkpointMismatch)

        let cohort = try fixture.checkpointFence(
            source: effect.source,
            targetDigest: effect.target.manifestSHA256,
            cohortID: "other-cohort"
        )
        #expect(RuntimeSwitchPolicy.prepareControlDispatch(
            prepared,
            effectID: effect.effectID,
            snapshot: fixture.dispatchSnapshot(for: effect, checkpoint: cohort),
            capability: capability
        ).blockedReason == .checkpointMismatch)

        #expect(RuntimeSwitchPolicy.prepareControlDispatch(
            prepared,
            effectID: effect.effectID,
            snapshot: fixture.dispatchSnapshot(for: effect, cancellation: .requestPending),
            capability: capability
        ).blockedReason == .concurrentCancellation)
    }

    @Test("Crash before or after send retries the exact same effect ID and directive")
    func dispatchRetryIsIdempotent() throws {
        let fixture = try Fixture()
        let prepared = try fixture.preparedGracefulState(effectID: effectID(30))
        let effect = try #require(prepared.record?.controlEffect)
        let snapshot = fixture.dispatchSnapshot(for: effect)
        let capability = try fixture.capability(for: effect, intent: .graceful)

        let beforeSend = RuntimeSwitchPolicy.prepareControlDispatch(
            prepared,
            effectID: effect.effectID,
            snapshot: snapshot,
            capability: capability
        )
        let afterSendBeforeAck = RuntimeSwitchPolicy.prepareControlDispatch(
            prepared,
            effectID: effect.effectID,
            snapshot: snapshot,
            capability: capability
        )

        #expect(beforeSend.directive == afterSendBeforeAck.directive)
        #expect(beforeSend.directive?.effectID == effectID(30))
        #expect(prepared.record?.progress == .controlDispatchPending)
    }

    @Test("Offline and in-doubt observations fail closed and never create replacement launch")
    func offlineAndInDoubtFailClosed() throws {
        let fixture = try Fixture()
        let request = try fixture.gracefulRequest()
        #expect(RuntimeSwitchPolicy.admit(
            .empty,
            request: request,
            verified: try fixture.admission(for: request, lifecycle: .offline)
        ).blockedReason == .offline)

        let pending = RuntimeSwitchPolicy.admit(
            .empty,
            request: request,
            verified: try fixture.admission(for: request)
        ).state
        let uncertain = RuntimeSwitchPolicy.markSourceInDoubt(pending, source: fixture.source)
        #expect(uncertain.disposition == .inDoubt)
        #expect(uncertain.state.record?.replacementEffect == nil)
        #expect(RuntimeSwitchPolicy.observeSourceTerminal(
            uncertain.state,
            attestation: try fixture.terminal(replacementEffectID: effectID(41))
        ).blockedReason == .terminalEvidenceRequired)
    }

    @Test("Every execution lifecycle is classified explicitly at admission")
    func admissionLifecycleMatrix() throws {
        let fixture = try Fixture()
        let request = try fixture.gracefulRequest()

        for lifecycle in [
            RuntimeSwitchExecutionLifecycle.registered,
            .starting,
            .running
        ] {
            #expect(RuntimeSwitchPolicy.admit(
                .empty,
                request: request,
                verified: try fixture.admission(for: request, lifecycle: lifecycle)
            ).disposition == .admitted)
        }
        for (lifecycle, reason) in [
            (RuntimeSwitchExecutionLifecycle.cancellationPending, RuntimeSwitchBlockedReason.concurrentCancellation),
            (.terminating, .concurrentCancellation),
            (.offline, .offline),
            (.inDoubt, .inDoubt),
            (.terminal, .executionNotControllable)
        ] {
            #expect(RuntimeSwitchPolicy.admit(
                .empty,
                request: request,
                verified: try fixture.admission(for: request, lifecycle: lifecycle)
            ).blockedReason == reason)
        }
    }

    @Test("Replacement launch requires exact authoritative terminal evidence and completes only when target runs")
    func terminalThenReplacementThenRunning() throws {
        let fixture = try Fixture()
        let prepared = try fixture.preparedGracefulState(effectID: effectID(50))
        let effect = try #require(prepared.record?.controlEffect)

        #expect(RuntimeSwitchPolicy.prepareReplacementDispatch(
            prepared,
            effectID: effectID(51),
            snapshot: try fixture.replacementSnapshot(effectID: effectID(51))
        ).blockedReason == .invalidTransition)

        let controlAcceptance = VerifiedRuntimeSwitchControlAcceptance(
            evidenceID: evidenceID(52),
            effectID: effect.effectID,
            source: fixture.source,
            ledgerSequence: 60
        )
        #expect(RuntimeSwitchPolicy.acknowledgeControl(
            prepared,
            acceptance: .init(
                evidenceID: evidenceID(51),
                effectID: effect.effectID,
                source: fixture.source,
                ledgerSequence: 10
            )
        ).blockedReason == .dispatchFenceMismatch)
        #expect(RuntimeSwitchPolicy.acknowledgeControl(
            prepared,
            acceptance: .init(
                evidenceID: evidenceID(51),
                effectID: effect.effectID,
                source: fixture.source,
                ledgerSequence: 15
            )
        ).blockedReason == .dispatchFenceMismatch)
        let acceptedControl = RuntimeSwitchPolicy.acknowledgeControl(
            prepared,
            acceptance: controlAcceptance
        ).state
        #expect(RuntimeSwitchPolicy.acknowledgeControl(
            acceptedControl,
            acceptance: controlAcceptance
        ).disposition == .idempotent)
        #expect(RuntimeSwitchPolicy.acknowledgeControl(
            acceptedControl,
            acceptance: .init(
                evidenceID: controlAcceptance.evidenceID,
                effectID: controlAcceptance.effectID,
                source: try fixture.sourceFence(installationID: installationID(92)),
                ledgerSequence: controlAcceptance.ledgerSequence
            )
        ).blockedReason == .dispatchFenceMismatch)
        #expect(RuntimeSwitchPolicy.observeSourceTerminal(
            acceptedControl,
            attestation: try fixture.terminal(
                ledgerSequence: controlAcceptance.ledgerSequence,
                replacementEffectID: effectID(53)
            )
        ).blockedReason == .terminalEvidenceMismatch)
        let terminal = try fixture.terminal(replacementEffectID: effectID(53))
        let replacementReady = RuntimeSwitchPolicy.observeSourceTerminal(acceptedControl, attestation: terminal)
        #expect(replacementReady.recordedEffectID == effectID(53))
        #expect(replacementReady.state.record?.progress == .replacementDispatchPending)
        #expect(RuntimeSwitchPolicy.markSourceInDoubt(
            replacementReady.state,
            source: fixture.source
        ).blockedReason == .invalidTransition)
        #expect(replacementReady.state.record?.progress == .replacementDispatchPending)

        let replacement = try #require(replacementReady.state.record?.replacementEffect)
        let snapshot = try fixture.replacementSnapshot(
            effectID: replacement.effectID,
            terminal: replacement.sourceTerminal,
            targetReservation: try #require(replacementReady.state.record?.targetReservation)
        )
        let wrongReservation = fixture.targetReservation(
            for: try #require(replacementReady.state.record?.request),
            reservationID: evidenceID(999)
        )
        #expect(RuntimeSwitchPolicy.prepareReplacementDispatch(
            replacementReady.state,
            effectID: replacement.effectID,
            snapshot: try fixture.replacementSnapshot(
                effectID: replacement.effectID,
                terminal: replacement.sourceTerminal,
                targetReservation: wrongReservation
            )
        ).blockedReason == .replacementEvidenceMismatch)
        let firstSend = RuntimeSwitchPolicy.prepareReplacementDispatch(
            replacementReady.state,
            effectID: replacement.effectID,
            snapshot: snapshot
        )
        let retry = RuntimeSwitchPolicy.prepareReplacementDispatch(
            replacementReady.state,
            effectID: replacement.effectID,
            snapshot: snapshot
        )
        #expect(firstSend.directive == retry.directive)
        #expect(firstSend.directive?.target.manifest.executionID == fixture.target.manifest.executionID)
        #expect(firstSend.directive?.target.manifest.executionID != fixture.source.executionID)

        let launchAccepted = RuntimeSwitchPolicy.acknowledgeReplacement(
            replacementReady.state,
            acceptance: .init(
                evidenceID: evidenceID(54),
                effectID: replacement.effectID,
                targetReservationID: fixture.targetReservationID,
                targetExecutionID: fixture.target.manifest.executionID,
                targetManifestSHA256: fixture.target.manifestSHA256,
                ledgerSequence: 120
            )
        )
        #expect(RuntimeSwitchPolicy.acknowledgeReplacement(
            replacementReady.state,
            acceptance: .init(
                evidenceID: evidenceID(53),
                effectID: replacement.effectID,
                targetReservationID: fixture.targetReservationID,
                targetExecutionID: fixture.target.manifest.executionID,
                targetManifestSHA256: fixture.target.manifestSHA256,
                ledgerSequence: replacement.sourceTerminal.ledgerSequence
            )
        ).blockedReason == .replacementEvidenceMismatch)
        #expect(launchAccepted.state.record?.progress == .awaitingReplacementRunning)
        #expect(launchAccepted.disposition == .awaitingReplacementRunning)
        #expect(RuntimeSwitchPolicy.acknowledgeReplacement(
            launchAccepted.state,
            acceptance: .init(
                evidenceID: evidenceID(54),
                effectID: replacement.effectID,
                targetReservationID: evidenceID(999),
                targetExecutionID: fixture.target.manifest.executionID,
                targetManifestSHA256: fixture.target.manifestSHA256,
                ledgerSequence: 120
            )
        ).blockedReason == .replacementEvidenceMismatch)
        #expect(RuntimeSwitchPolicy.acknowledgeReplacement(
            launchAccepted.state,
            acceptance: .init(
                evidenceID: evidenceID(54),
                effectID: replacement.effectID,
                targetReservationID: fixture.targetReservationID,
                targetExecutionID: executionID(999),
                targetManifestSHA256: fixture.target.manifestSHA256,
                ledgerSequence: 120
            )
        ).blockedReason == .replacementEvidenceMismatch)
        #expect(RuntimeSwitchPolicy.acknowledgeReplacement(
            launchAccepted.state,
            acceptance: .init(
                evidenceID: evidenceID(54),
                effectID: replacement.effectID,
                targetReservationID: fixture.targetReservationID,
                targetExecutionID: fixture.target.manifest.executionID,
                targetManifestSHA256: fixture.target.manifestSHA256,
                ledgerSequence: 121
            )
        ).blockedReason == .replacementEvidenceMismatch)

        let running = RuntimeSwitchPolicy.observeReplacementRunning(
            launchAccepted.state,
            attestation: .init(
                evidenceID: evidenceID(55),
                targetReservationID: fixture.targetReservationID,
                targetExecutionID: fixture.target.manifest.executionID,
                targetManifestSHA256: fixture.target.manifestSHA256,
                ledgerSequence: 130
            )
        )
        #expect(RuntimeSwitchPolicy.observeReplacementRunning(
            launchAccepted.state,
            attestation: .init(
                evidenceID: evidenceID(56),
                targetReservationID: fixture.targetReservationID,
                targetExecutionID: fixture.target.manifest.executionID,
                targetManifestSHA256: fixture.target.manifestSHA256,
                ledgerSequence: 120
            )
        ).blockedReason == .replacementEvidenceMismatch)
        #expect(running.disposition == .completed)
        #expect(running.state.record?.progress == .completed)
        #expect(RuntimeSwitchPolicy.observeReplacementRunning(
            running.state,
            attestation: .init(
                evidenceID: evidenceID(55),
                targetReservationID: fixture.targetReservationID,
                targetExecutionID: fixture.target.manifest.executionID,
                targetManifestSHA256: fixture.target.manifestSHA256,
                ledgerSequence: 130
            )
        ).disposition == .idempotent)
        #expect(RuntimeSwitchPolicy.observeReplacementRunning(
            running.state,
            attestation: .init(
                evidenceID: evidenceID(55),
                targetReservationID: evidenceID(999),
                targetExecutionID: fixture.target.manifest.executionID,
                targetManifestSHA256: fixture.target.manifestSHA256,
                ledgerSequence: 130
            )
        ).blockedReason == .replacementEvidenceMismatch)
        #expect(RuntimeSwitchPolicy.observeReplacementRunning(
            running.state,
            attestation: .init(
                evidenceID: evidenceID(55),
                targetReservationID: fixture.targetReservationID,
                targetExecutionID: executionID(998),
                targetManifestSHA256: fixture.target.manifestSHA256,
                ledgerSequence: 130
            )
        ).blockedReason == .replacementEvidenceMismatch)
        #expect(RuntimeSwitchPolicy.observeReplacementRunning(
            running.state,
            attestation: .init(
                evidenceID: evidenceID(55),
                targetReservationID: fixture.targetReservationID,
                targetExecutionID: fixture.target.manifest.executionID,
                targetManifestSHA256: fixture.target.manifestSHA256,
                ledgerSequence: 131
            )
        ).blockedReason == .replacementEvidenceMismatch)
    }

    @Test("Natural completed failed or cancelled terminal before accepted control never launches replacement")
    func naturalTerminalBeforeControlDoesNotResume() throws {
        let fixture = try Fixture()
        let request = try fixture.gracefulRequest()
        let waiting = RuntimeSwitchPolicy.admit(
            .empty,
            request: request,
            verified: try fixture.admission(for: request)
        ).state
        for observedState in [
            ExecutionObservedState.completed,
            .failed,
            .cancelled
        ] {
            let result = RuntimeSwitchPolicy.observeSourceTerminal(
                waiting,
                attestation: try fixture.terminal(
                    observedState: observedState,
                    replacementEffectID: effectID(60)
                )
            )
            #expect(result.blockedReason == .terminalEvidenceRequired)
            #expect(result.recordedEffectID == nil)
            #expect(result.state.record?.replacementEffect == nil)
        }
    }

    @Test("Completed record rolls over durably before a second switch can succeed")
    func sequentialCompletedSwitches() throws {
        let first = try Fixture()
        let firstCompleted = try first.completedGracefulState(
            controlEffectID: effectID(120),
            replacementEffectID: effectID(121)
        )
        let firstRecord = try #require(firstCompleted.record)
        let firstCompletion = try #require(firstRecord.completionEvidenceID)

        let premature = RuntimeSwitchPolicy.archiveCompleted(
            try first.preparedGracefulState(effectID: effectID(122)),
            rollover: .init(
                archiveEvidenceID: evidenceID(123),
                requestID: firstRecord.request.intent.requestID,
                completionEvidenceID: firstCompletion,
                targetReservationID: firstRecord.targetReservation.reservationID,
                targetExecutionID: first.target.manifest.executionID,
                targetManifestSHA256: first.target.manifestSHA256,
                ledgerSequence: 200
            )
        )
        #expect(premature.blockedReason == .completionRolloverMismatch)

        #expect(RuntimeSwitchPolicy.archiveCompleted(
            firstCompleted,
            rollover: .init(
                archiveEvidenceID: evidenceID(129),
                requestID: firstRecord.request.intent.requestID,
                completionEvidenceID: firstCompletion,
                targetReservationID: firstRecord.targetReservation.reservationID,
                targetExecutionID: first.target.manifest.executionID,
                targetManifestSHA256: first.target.manifestSHA256,
                ledgerSequence: try #require(firstRecord.completionLedgerSequence)
            )
        ).blockedReason == .completionRolloverMismatch)

        let rollover = VerifiedRuntimeSwitchCompletionRollover(
            archiveEvidenceID: evidenceID(124),
            requestID: firstRecord.request.intent.requestID,
            completionEvidenceID: firstCompletion,
            targetReservationID: firstRecord.targetReservation.reservationID,
            targetExecutionID: first.target.manifest.executionID,
            targetManifestSHA256: first.target.manifestSHA256,
            ledgerSequence: 200
        )
        let archived = RuntimeSwitchPolicy.archiveCompleted(firstCompleted, rollover: rollover)
        #expect(archived.disposition == .archived)
        #expect(archived.state.record == nil)
        #expect(archived.state.lastArchivedCompletion?.targetExecutionID == first.target.manifest.executionID)
        #expect(RuntimeSwitchPolicy.archiveCompleted(
            archived.state,
            rollover: rollover
        ).disposition == .idempotent)
        #expect(RuntimeSwitchPolicy.admit(
            archived.state,
            request: firstRecord.request,
            verified: nil
        ).disposition == .idempotent)
        let changedArchivedRequest = try first.gracefulRequest(
            requestID: firstRecord.request.intent.requestID,
            target: first.alternateTarget
        )
        #expect(RuntimeSwitchPolicy.admit(
            archived.state,
            request: changedArchivedRequest,
            verified: nil
        ).blockedReason == .requestIDConflict)

        let second = try Fixture(
            sourceManifest: first.target.manifest,
            sourceDigest: first.target.manifestSHA256,
            target: first.alternateTarget,
            requestDigest: .init(value: digest(125))
        )
        let secondRequest = try second.gracefulRequest(requestID: requestID(126))
        let reusedReservation = second.targetReservation(
            for: secondRequest,
            reservationID: firstRecord.targetReservation.reservationID
        )
        #expect(RuntimeSwitchPolicy.admit(
            archived.state,
            request: secondRequest,
            verified: try second.admission(for: secondRequest, reservation: reusedReservation)
        ).blockedReason == .staleReservation)
        let distinctStaleReservation = second.targetReservation(
            for: secondRequest,
            reservationID: evidenceID(130),
            ledgerSequence: 199
        )
        #expect(RuntimeSwitchPolicy.admit(
            archived.state,
            request: secondRequest,
            verified: try second.admission(
                for: secondRequest,
                reservation: distinctStaleReservation,
                sourceLedgerSequence: 198
            )
        ).blockedReason == .staleReservation)
        let secondCompleted = try second.completedGracefulState(
            initial: archived.state,
            requestID: requestID(126),
            controlEffectID: effectID(127),
            replacementEffectID: effectID(128),
            sequenceOffset: 200
        )
        #expect(secondCompleted.record?.progress == .completed)
        #expect(secondCompleted.record?.replacementEffect?.target.manifest.executionID == first.alternateTarget.manifest.executionID)
        #expect(secondCompleted.record?.targetReservation.reservationID != firstRecord.targetReservation.reservationID)
        #expect(secondCompleted.lastArchivedCompletion == archived.state.lastArchivedCompletion)

        var recovered = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(secondCompleted)) as? [String: Any]
        )
        var recoveredRecord = try #require(recovered["record"] as? [String: Any])
        var recoveredReservation = try #require(
            recoveredRecord["targetReservation"] as? [String: Any]
        )
        recoveredReservation["ledgerSequence"] = 200
        recoveredRecord["targetReservation"] = recoveredReservation
        recovered["record"] = recoveredRecord
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                RuntimeSwitchPolicyState.self,
                from: JSONSerialization.data(withJSONObject: recovered)
            )
        }
    }
}

@Suite("Verified immediate runtime switching")
struct VerifiedImmediateRuntimeSwitchTests {
    @Test("Force submit is only a confirmation challenge and effect is explicitly immediate")
    func forceRequiresVerifiedConfirmation() throws {
        let fixture = try Fixture()
        let request = try fixture.forceRequest()
        let admission = try fixture.admission(for: request)
        let pending = RuntimeSwitchPolicy.admit(.empty, request: request, verified: admission)
        #expect(pending.state.record?.progress == .confirmationRequired)
        #expect(pending.recordedEffectID == nil)

        let confirmation = try fixture.confirmation(for: request, challenge: try #require(admission.forceChallenge))
        let wrongCapability = try fixture.capability(
            requestDigest: admission.requestDigest,
            source: fixture.source,
            intent: .graceful
        )
        #expect(RuntimeSwitchPolicy.confirmImmediate(
            pending.state,
            confirmation: confirmation,
            capability: wrongCapability
        ).blockedReason == .forceCapabilityRequired)

        let accepted = RuntimeSwitchPolicy.confirmImmediate(
            pending.state,
            confirmation: confirmation,
            capability: try fixture.capability(
                requestDigest: admission.requestDigest,
                source: fixture.source,
                intent: .immediate
            )
        )
        #expect(accepted.state.record?.controlEffect?.cancellationIntent == .immediate)
        #expect(accepted.state.record?.controlEffect?.confirmationID == confirmation.confirmationID)
        #expect(accepted.recordedEffectID == confirmation.effectID)
        #expect(RuntimeSwitchPolicy.confirmImmediate(
            accepted.state,
            confirmation: confirmation,
            capability: wrongCapability
        ).blockedReason == .effectIDConflict)
    }

    @Test("Stale future and altered confirmation evidence fail closed")
    func confirmationFreshnessAndBinding() throws {
        let fixture = try Fixture()
        let request = try fixture.forceRequest()
        let admission = try fixture.admission(for: request)
        let challenge = try #require(admission.forceChallenge)

        #expect(throws: RuntimeSwitchTrustedAttestationError.challengeExpired) {
            try fixture.confirmation(
                for: request,
                challenge: challenge,
                confirmedAt: challenge.expiresAt,
                serverNow: challenge.expiresAt.addingTimeInterval(1)
            )
        }
        #expect(throws: RuntimeSwitchTrustedAttestationError.confirmationBindingMismatch) {
            try fixture.confirmation(
                for: request,
                challenge: challenge,
                confirmedAt: fixture.now.addingTimeInterval(1),
                serverNow: fixture.now
            )
        }
        #expect(throws: RuntimeSwitchTrustedAttestationError.confirmationBindingMismatch) {
            try fixture.confirmation(
                for: request,
                challenge: challenge,
                actorID: try .init(rawValue: "different-actor")
            )
        }

        let otherRequest = try fixture.forceRequest(requestID: requestID(707))
        #expect(throws: RuntimeSwitchTrustedAttestationError.confirmationBindingMismatch) {
            try fixture.confirmation(for: otherRequest, challenge: challenge)
        }

        let futureChallenge = try RuntimeForceSwitchChallenge(
            challengeID: .init(rawValue: uuid(708)),
            requestID: request.intent.requestID,
            requestDigest: admission.requestDigest,
            actorID: challenge.actorID,
            sessionID: challenge.sessionID,
            issuedAt: fixture.now.addingTimeInterval(5),
            expiresAt: fixture.now.addingTimeInterval(60)
        )
        #expect(throws: RuntimeSwitchTrustedAttestationError.challengeNotYetValid) {
            try fixture.confirmation(
                for: request,
                challenge: futureChallenge,
                confirmedAt: futureChallenge.issuedAt,
                serverNow: fixture.now
            )
        }
    }

    @Test("A force challenge is single use and a changed confirmation cannot alias its effect ID")
    func confirmationSingleUse() throws {
        let fixture = try Fixture()
        let request = try fixture.forceRequest()
        let admission = try fixture.admission(for: request)
        let pending = RuntimeSwitchPolicy.admit(.empty, request: request, verified: admission).state
        let challenge = try #require(admission.forceChallenge)
        let confirmation = try fixture.confirmation(for: request, challenge: challenge, effectID: effectID(709))
        let capability = try fixture.capability(
            requestDigest: admission.requestDigest,
            source: fixture.source,
            intent: .immediate
        )
        let recorded = RuntimeSwitchPolicy.confirmImmediate(
            pending,
            confirmation: confirmation,
            capability: capability
        ).state
        guard case .forceTermination(let force) = request else {
            Issue.record("Fixture force request changed variant")
            return
        }

        let changed = try VerifiedRuntimeForceConfirmation(
            confirmationID: evidenceID(710),
            challenge: challenge,
            request: force,
            requestDigest: admission.requestDigest,
            actorID: challenge.actorID,
            sessionID: challenge.sessionID,
            confirmedAt: fixture.now,
            serverNow: fixture.now,
            effectID: confirmation.effectID
        )
        #expect(RuntimeSwitchPolicy.confirmImmediate(
            recorded,
            confirmation: changed,
            capability: capability
        ).blockedReason == .effectIDConflict)
        let changedCapability = try fixture.capability(
            capabilityID: evidenceID(711),
            requestDigest: admission.requestDigest,
            source: fixture.source,
            intent: .immediate
        )
        #expect(RuntimeSwitchPolicy.confirmImmediate(
            recorded,
            confirmation: confirmation,
            capability: changedCapability
        ).blockedReason == .effectIDConflict)
    }

    @Test("Force dispatch still rechecks lifecycle authority cancellation and exact immediate capability")
    func forceDispatchRefences() throws {
        let fixture = try Fixture()
        let prepared = try fixture.preparedImmediateState(effectID: effectID(70))
        let effect = try #require(prepared.record?.controlEffect)
        let capability = try fixture.capability(for: effect, intent: .immediate)

        let exact = RuntimeSwitchPolicy.prepareControlDispatch(
            prepared,
            effectID: effect.effectID,
            snapshot: fixture.dispatchSnapshot(for: effect, checkpoint: nil),
            capability: capability
        )
        #expect(exact.directive?.cancellationIntent == .immediate)
        #expect(exact.directive?.checkpointFence == nil)

        #expect(RuntimeSwitchPolicy.prepareControlDispatch(
            prepared,
            effectID: effect.effectID,
            snapshot: fixture.dispatchSnapshot(for: effect, lifecycle: .terminating, checkpoint: nil),
            capability: capability
        ).blockedReason == .concurrentCancellation)

        #expect(RuntimeSwitchPolicy.prepareControlDispatch(
            prepared,
            effectID: effect.effectID,
            snapshot: fixture.dispatchSnapshot(for: effect, lifecycle: .inDoubt, checkpoint: nil),
            capability: capability
        ).blockedReason == .inDoubt)
    }

    @Test("Terminal before force confirmation cannot launch a replacement")
    func forceTerminalBeforeConfirmationFailsClosed() throws {
        let fixture = try Fixture()
        let request = try fixture.forceRequest()
        let pending = RuntimeSwitchPolicy.admit(
            .empty,
            request: request,
            verified: try fixture.admission(for: request)
        ).state
        #expect(RuntimeSwitchPolicy.observeSourceTerminal(
            pending,
            attestation: try fixture.terminal(replacementEffectID: effectID(72))
        ).blockedReason == .terminalEvidenceRequired)
    }
}

@Suite("Runtime switch strict durable contracts")
struct RuntimeSwitchStrictDurableContractTests {
    @Test("Request and progressed state round trip with strict versions")
    func roundTrips() throws {
        let fixture = try Fixture()
        let request = try fixture.forceRequest()
        let requestData = try JSONEncoder().encode(request)
        #expect(try JSONDecoder().decode(ActiveRuntimeSwitchRequest.self, from: requestData) == request)

        let state = try fixture.preparedImmediateState(effectID: effectID(80))
        let stateData = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(RuntimeSwitchPolicyState.self, from: stateData) == state)
    }

    @Test("Unknown nested fields incompatible versions and impossible progress fail closed")
    func strictDecoding() throws {
        let fixture = try Fixture()
        let request = try fixture.gracefulRequest()
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        var graceful = try #require(object["gracefulHandoff"] as? [String: Any])
        graceful["callerClaimsCheckpointSafe"] = true
        object["gracefulHandoff"] = graceful
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                ActiveRuntimeSwitchRequest.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        }

        object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        object["schemaVersion"] = 99
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                ActiveRuntimeSwitchRequest.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        }

        object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        graceful = try #require(object["gracefulHandoff"] as? [String: Any])
        var intent = try #require(graceful["intent"] as? [String: Any])
        var target = try #require(intent["target"] as? [String: Any])
        var manifest = try #require(target["manifest"] as? [String: Any])
        manifest["untrustedManifestExtension"] = true
        target["manifest"] = manifest
        intent["target"] = target
        graceful["intent"] = intent
        object["gracefulHandoff"] = graceful
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                ActiveRuntimeSwitchRequest.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        }

        object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        graceful = try #require(object["gracefulHandoff"] as? [String: Any])
        intent = try #require(graceful["intent"] as? [String: Any])
        target = try #require(intent["target"] as? [String: Any])
        manifest = try #require(target["manifest"] as? [String: Any])
        var configuration = try #require(manifest["configuration"] as? [String: Any])
        configuration["untrustedConfigurationExtension"] = true
        manifest["configuration"] = configuration
        target["manifest"] = manifest
        intent["target"] = target
        graceful["intent"] = intent
        object["gracefulHandoff"] = graceful
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                ActiveRuntimeSwitchRequest.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        }

        let state = RuntimeSwitchPolicy.admit(
            .empty,
            request: request,
            verified: try fixture.admission(for: request)
        ).state
        var stateObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        var record = try #require(stateObject["record"] as? [String: Any])
        record["progress"] = RuntimeSwitchProgress.completed.rawValue
        stateObject["record"] = record
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                RuntimeSwitchPolicyState.self,
                from: JSONSerialization.data(withJSONObject: stateObject)
            )
        }

        let completed = try fixture.completedGracefulState(
            controlEffectID: effectID(810),
            replacementEffectID: effectID(811)
        )
        var skipped = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(completed)) as? [String: Any]
        )
        var skippedRecord = try #require(skipped["record"] as? [String: Any])
        skippedRecord["progress"] = RuntimeSwitchProgress.replacementDispatchPending.rawValue
        skippedRecord.removeValue(forKey: "controlEffect")
        skippedRecord.removeValue(forKey: "controlAcceptanceID")
        skippedRecord.removeValue(forKey: "controlAcceptanceLedgerSequence")
        skippedRecord.removeValue(forKey: "replacementAcceptanceID")
        skippedRecord.removeValue(forKey: "completionEvidenceID")
        skipped["record"] = skippedRecord
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                RuntimeSwitchPolicyState.self,
                from: JSONSerialization.data(withJSONObject: skipped)
            )
        }

        let immediate = try fixture.preparedImmediateState(effectID: effectID(812))
        var missingChallenge = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(immediate)) as? [String: Any]
        )
        var immediateRecord = try #require(missingChallenge["record"] as? [String: Any])
        immediateRecord.removeValue(forKey: "forceChallenge")
        missingChallenge["record"] = immediateRecord
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                RuntimeSwitchPolicyState.self,
                from: JSONSerialization.data(withJSONObject: missingChallenge)
            )
        }
    }

    @Test("Recovered records reject every causal inversion and unpaired evidence field")
    func causalChainStrictDecoding() throws {
        let fixture = try Fixture()
        let completed = try fixture.completedGracefulState(
            controlEffectID: effectID(820),
            replacementEffectID: effectID(821)
        )

        func expectRecordDecodeFailure(
            _ mutation: (inout [String: Any]) throws -> Void
        ) throws {
            var object = try #require(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(completed)) as? [String: Any]
            )
            var record = try #require(object["record"] as? [String: Any])
            try mutation(&record)
            object["record"] = record
            let data = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(RuntimeSwitchPolicyState.self, from: data)
            }
        }

        func encodedJSONValue<Value: Encodable>(_ value: Value) throws -> Any {
            let array = try #require(
                JSONSerialization.jsonObject(with: JSONEncoder().encode([value])) as? [Any]
            )
            return try #require(array.first)
        }

        try expectRecordDecodeFailure { record in
            var reservation = try #require(record["targetReservation"] as? [String: Any])
            reservation["ledgerSequence"] = record["sourceLedgerSequence"]
            record["targetReservation"] = reservation
        }
        try expectRecordDecodeFailure { record in
            let reservation = try #require(record["targetReservation"] as? [String: Any])
            var effect = try #require(record["controlEffect"] as? [String: Any])
            var checkpoint = try #require(effect["checkpointFence"] as? [String: Any])
            checkpoint["ledgerSequence"] = reservation["ledgerSequence"]
            effect["checkpointFence"] = checkpoint
            record["controlEffect"] = effect
        }
        try expectRecordDecodeFailure { record in
            var effect = try #require(record["controlEffect"] as? [String: Any])
            var checkpoint = try #require(effect["checkpointFence"] as? [String: Any])
            checkpoint["source"] = try encodedJSONValue(
                fixture.sourceFence(installationID: installationID(999))
            )
            effect["checkpointFence"] = checkpoint
            record["controlEffect"] = effect
        }
        try expectRecordDecodeFailure { record in
            var effect = try #require(record["controlEffect"] as? [String: Any])
            var checkpoint = try #require(effect["checkpointFence"] as? [String: Any])
            checkpoint["targetManifestSHA256"] = try encodedJSONValue(digest(999))
            effect["checkpointFence"] = checkpoint
            record["controlEffect"] = effect
        }
        try expectRecordDecodeFailure { record in
            var effect = try #require(record["controlEffect"] as? [String: Any])
            var checkpoint = try #require(effect["checkpointFence"] as? [String: Any])
            var supervisor = try #require(checkpoint["supervisor"] as? [String: Any])
            supervisor["executionID"] = try encodedJSONValue(executionID(999))
            checkpoint["supervisor"] = supervisor
            effect["checkpointFence"] = checkpoint
            record["controlEffect"] = effect
        }
        try expectRecordDecodeFailure { record in
            var effect = try #require(record["controlEffect"] as? [String: Any])
            var checkpoint = try #require(effect["checkpointFence"] as? [String: Any])
            var supervisor = try #require(checkpoint["supervisor"] as? [String: Any])
            let foreignAuthority = RunBrokerAuthority(
                id: .init(rawValue: uuid(998)),
                epoch: .init(rawValue: 999)
            )
            supervisor["authority"] = try encodedJSONValue(foreignAuthority)
            checkpoint["supervisor"] = supervisor
            effect["checkpointFence"] = checkpoint
            record["controlEffect"] = effect
        }
        try expectRecordDecodeFailure { record in
            let effect = try #require(record["controlEffect"] as? [String: Any])
            let checkpoint = try #require(effect["checkpointFence"] as? [String: Any])
            record["controlAcceptanceLedgerSequence"] = checkpoint["ledgerSequence"]
        }
        try expectRecordDecodeFailure { record in
            var effect = try #require(record["replacementEffect"] as? [String: Any])
            var terminal = try #require(effect["sourceTerminal"] as? [String: Any])
            terminal["ledgerSequence"] = record["controlAcceptanceLedgerSequence"]
            effect["sourceTerminal"] = terminal
            record["replacementEffect"] = effect
        }
        try expectRecordDecodeFailure { record in
            let effect = try #require(record["replacementEffect"] as? [String: Any])
            let terminal = try #require(effect["sourceTerminal"] as? [String: Any])
            record["replacementAcceptanceLedgerSequence"] = terminal["ledgerSequence"]
        }
        try expectRecordDecodeFailure { record in
            record["completionLedgerSequence"] = record["replacementAcceptanceLedgerSequence"]
        }
        try expectRecordDecodeFailure { record in
            record.removeValue(forKey: "controlAcceptanceLedgerSequence")
        }
        try expectRecordDecodeFailure { record in
            record.removeValue(forKey: "replacementAcceptanceID")
        }
        try expectRecordDecodeFailure { record in
            record.removeValue(forKey: "completionEvidenceID")
        }

        let completedRecord = try #require(completed.record)
        let archived = RuntimeSwitchPolicy.archiveCompleted(
            completed,
            rollover: .init(
                archiveEvidenceID: evidenceID(822),
                requestID: completedRecord.request.intent.requestID,
                completionEvidenceID: try #require(completedRecord.completionEvidenceID),
                targetReservationID: completedRecord.targetReservation.reservationID,
                targetExecutionID: completedRecord.request.intent.target.manifest.executionID,
                targetManifestSHA256: completedRecord.request.intent.target.manifestSHA256,
                ledgerSequence: 200
            )
        ).state
        var archivedObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(archived)) as? [String: Any]
        )
        var archive = try #require(archivedObject["lastArchivedCompletion"] as? [String: Any])
        archive["ledgerSequence"] = archive["completionLedgerSequence"]
        archivedObject["lastArchivedCompletion"] = archive
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                RuntimeSwitchPolicyState.self,
                from: JSONSerialization.data(withJSONObject: archivedObject)
            )
        }
    }

    @Test("Identifiers and resolved launch fields are bounded")
    func bounds() throws {
        #expect(throws: RuntimeSwitchContractError.self) {
            try RuntimeSwitchCheckpointID(rawValue: String(repeating: "x", count: 257))
        }
        #expect(throws: RuntimeSwitchContractError.self) {
            try RuntimeSwitchActorID(rawValue: String(repeating: "x", count: 257))
        }

        let fixture = try Fixture()
        let oversized = fixture.manifest(
            executionID: executionID(500),
            runtimeID: AgentRuntimeID(rawValue: String(repeating: "r", count: 129))!,
            configurationRevision: "oversized-runtime"
        )
        #expect(throws: RuntimeSwitchContractError.invalidTargetManifest) {
            try RuntimeSwitchResolvedTarget(manifest: oversized, manifestSHA256: digest(5))
        }

        let oversizedScope = fixture.manifest(
            executionID: executionID(501),
            runtimeID: .codexCLI,
            configurationRevision: "oversized-effect-scope",
            declaredEffects: [.init(
                scope: .remotePath(hostID: "remote-1", path: "/" + String(repeating: "p", count: 4_097)),
                access: .exclusive
            )]
        )
        #expect(throws: RuntimeSwitchContractError.invalidTargetManifest) {
            try RuntimeSwitchResolvedTarget(manifest: oversizedScope, manifestSHA256: digest(6))
        }

        let unknownScope = fixture.manifest(
            executionID: executionID(503),
            runtimeID: .codexCLI,
            configurationRevision: "unknown-effect-scope",
            declaredEffects: [.init(scope: .unknown, access: .exclusive)]
        )
        #expect(throws: RuntimeSwitchContractError.invalidTargetManifest) {
            try RuntimeSwitchResolvedTarget(manifest: unknownScope, manifestSHA256: digest(8))
        }

        let largeClaim = ExecutionEffectClaim(
            scope: .remotePath(hostID: "remote-1", path: "/" + String(repeating: "p", count: 4_000)),
            access: .exclusive
        )
        let oversizedManifest = fixture.manifest(
            executionID: executionID(502),
            runtimeID: .codexCLI,
            configurationRevision: "oversized-total-manifest",
            declaredEffects: Array(repeating: largeClaim, count: 1_024)
        )
        #expect(throws: RuntimeSwitchContractError.invalidTargetManifest) {
            try RuntimeSwitchResolvedTarget(manifest: oversizedManifest, manifestSHA256: digest(7))
        }
    }

    @Test("Trusted attestations are deliberately not Codable")
    func attestationsAreNotWireValues() {
        #expect(!(VerifiedRuntimeSwitchAdmission.self is any Codable.Type))
        #expect(!(VerifiedRuntimeSwitchCheckpointAttestation.self is any Codable.Type))
        #expect(!(VerifiedRuntimeSwitchBackendCapability.self is any Codable.Type))
        #expect(!(VerifiedRuntimeForceConfirmation.self is any Codable.Type))
        #expect(!(VerifiedRuntimeSwitchDispatchSnapshot.self is any Codable.Type))
        #expect(!(VerifiedRuntimeSwitchControlAcceptance.self is any Codable.Type))
        #expect(!(VerifiedRuntimeSwitchTerminalAttestation.self is any Codable.Type))
        #expect(!(VerifiedRuntimeSwitchReplacementDispatchSnapshot.self is any Codable.Type))
        #expect(!(VerifiedRuntimeSwitchReplacementAcceptance.self is any Codable.Type))
        #expect(!(VerifiedRuntimeSwitchReplacementRunningAttestation.self is any Codable.Type))
        #expect(!(VerifiedRuntimeSwitchCompletionRollover.self is any Codable.Type))
    }

    @Test(
        "Resolved manifest policy is provider neutral and never chooses a fallback",
        arguments: [
            AgentRuntimeID.claudeCode,
            AgentRuntimeID.copilotCLI,
            AgentRuntimeID.antigravityCLI,
            AgentRuntimeID.codexCLI,
            AgentRuntimeID.cursorCLI,
            AgentRuntimeID.openCodeCLI,
            AgentRuntimeID(rawValue: "future_remote_provider")!
        ]
    )
    func providerNeutral(runtimeID: AgentRuntimeID) throws {
        let fixture = try Fixture()
        let target = try RuntimeSwitchResolvedTarget(
            manifest: fixture.manifest(
                executionID: executionID(800),
                runtimeID: runtimeID,
                configurationRevision: "target-\(runtimeID.rawValue)"
            ),
            manifestSHA256: digest(800)
        )
        let request = try fixture.gracefulRequest(target: target)
        let admitted = RuntimeSwitchPolicy.admit(
            .empty,
            request: request,
            verified: try fixture.admission(for: request)
        )
        #expect(admitted.disposition == .admitted)
        #expect(admitted.state.record?.request.intent.target.manifest.configuration.runtimeID == runtimeID)
    }
}

private struct Fixture {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let sourceManifest: ExecutionLaunchManifest
    let source: RuntimeSwitchSourceFence
    let target: RuntimeSwitchResolvedTarget
    let alternateTarget: RuntimeSwitchResolvedTarget
    let requestDigest: RuntimeSwitchRequestDigest
    let targetReservationID: RuntimeSwitchEvidenceID

    init() throws {
        requestDigest = .init(value: digest(90))
        targetReservationID = evidenceID(76)
        sourceManifest = Self.makeManifest(
            executionID: executionID(1),
            runtimeID: .claudeCode,
            configurationRevision: "source-revision",
            createdAt: now
        )
        source = try .init(manifest: sourceManifest, manifestSHA256: digest(1))
        target = try .init(
            manifest: Self.makeManifest(
                executionID: executionID(2),
                runtimeID: .codexCLI,
                configurationRevision: "target-revision",
                createdAt: now
            ),
            manifestSHA256: digest(2)
        )
        alternateTarget = try .init(
            manifest: Self.makeManifest(
                executionID: executionID(3),
                runtimeID: .copilotCLI,
                configurationRevision: "alternate-revision",
                createdAt: now
            ),
            manifestSHA256: digest(3)
        )
    }

    init(
        sourceManifest: ExecutionLaunchManifest,
        sourceDigest: ExecutionLaunchArgumentsSHA256,
        target: RuntimeSwitchResolvedTarget,
        requestDigest: RuntimeSwitchRequestDigest,
        targetReservationID: RuntimeSwitchEvidenceID = evidenceID(176)
    ) throws {
        self.requestDigest = requestDigest
        self.targetReservationID = targetReservationID
        self.sourceManifest = sourceManifest
        source = try .init(manifest: sourceManifest, manifestSHA256: sourceDigest)
        self.target = target
        alternateTarget = target
    }

    func gracefulRequest(
        requestID: RuntimeSwitchRequestID = requestID(5),
        target: RuntimeSwitchResolvedTarget? = nil
    ) throws -> ActiveRuntimeSwitchRequest {
        try .defaultHandoff(intent: .init(
            requestID: requestID,
            mode: .graceful,
            expectedSource: source,
            target: target ?? self.target,
            requestedAt: now
        ))
    }

    func forceRequest(requestID: RuntimeSwitchRequestID = requestID(6)) throws -> ActiveRuntimeSwitchRequest {
        let intent = try RuntimeSwitchIntent(
            requestID: requestID,
            mode: .immediate,
            expectedSource: source,
            target: target,
            requestedAt: now
        )
        return .forceTermination(try .init(
            intent: intent,
            audit: .init(
                auditID: .init(rawValue: uuid(7)),
                source: .diagnostics,
                reasonCode: .providerUnresponsive
            )
        ))
    }

    func admission(
        for request: ActiveRuntimeSwitchRequest,
        lifecycle: RuntimeSwitchExecutionLifecycle = .running,
        cancellation: ExecutionCancellationObservedState = .notRequested,
        reservation: RuntimeSwitchTargetReservation? = nil,
        sourceLedgerSequence: UInt64 = 5
    ) throws -> VerifiedRuntimeSwitchAdmission {
        let challenge: RuntimeForceSwitchChallenge?
        switch request {
        case .gracefulHandoff:
            challenge = nil
        case .forceTermination:
            challenge = try .init(
                challengeID: .init(rawValue: uuid(8)),
                requestID: request.intent.requestID,
                requestDigest: requestDigest,
                actorID: .init(rawValue: "operator-1"),
                sessionID: uuid(9),
                issuedAt: now.addingTimeInterval(-10),
                expiresAt: now.addingTimeInterval(120)
            )
        }
        return try .init(
            request: request,
            requestDigest: requestDigest,
            source: source,
            targetReservation: reservation ?? targetReservation(for: request),
            sourceLedgerSequence: sourceLedgerSequence,
            lifecycle: lifecycle,
            observedCancellation: cancellation,
            forceChallenge: challenge
        )
    }

    func targetReservation(
        for request: ActiveRuntimeSwitchRequest,
        reservationID: RuntimeSwitchEvidenceID? = nil,
        targetExecutionID: RunBrokerExecutionID? = nil,
        targetManifestSHA256: ExecutionLaunchArgumentsSHA256? = nil,
        ledgerSequence: UInt64 = 10
    ) -> RuntimeSwitchTargetReservation {
        .init(
            reservationID: reservationID ?? targetReservationID,
            requestID: request.intent.requestID,
            requestDigest: requestDigest,
            installationID: source.installationID,
            storeID: source.storeID,
            taskID: source.taskID,
            targetExecutionID: targetExecutionID ?? request.intent.target.manifest.executionID,
            targetManifestSHA256: targetManifestSHA256 ?? request.intent.target.manifestSHA256,
            ledgerSequence: ledgerSequence
        )
    }

    func checkpoint(
        for request: ActiveRuntimeSwitchRequest,
        effectID: RuntimeSwitchEffectID = effectID(10),
        checkpointGeneration: UInt64 = 10,
        ledgerSequence: UInt64 = 20,
        inFlightEffectCount: UInt = 0,
        inFlightToolOperationCount: UInt = 0,
        supervisor: RuntimeSwitchSupervisorFence? = nil
    ) throws -> VerifiedRuntimeSwitchCheckpointAttestation {
        try .init(
            request: request,
            requestDigest: requestDigest,
            effectID: effectID,
            checkpointID: .init(rawValue: "checkpoint-1"),
            checkpointGeneration: checkpointGeneration,
            ledgerSequence: ledgerSequence,
            effectWatermark: 30,
            toolOperationWatermark: 40,
            inFlightEffectCount: inFlightEffectCount,
            inFlightToolOperationCount: inFlightToolOperationCount,
            providerContinuation: .init(adapterID: "provider-handoff-v1", protocolVersion: 1),
            supervisor: supervisor ?? self.supervisor()
        )
    }

    func supervisor(
        installationID: RunBrokerInstallationID? = nil,
        storeID: RunBrokerStoreID? = nil,
        authority: RunBrokerAuthority? = nil,
        cohortID: String = "cohort-v1"
    ) throws -> RuntimeSwitchSupervisorFence {
        try .init(
            installationID: installationID ?? source.installationID,
            storeID: storeID ?? source.storeID,
            executionID: source.executionID,
            authority: authority ?? source.authority,
            cohortID: cohortID,
            protocolIdentity: .init(adapterID: "supervisor-handoff-v1", protocolVersion: 1)
        )
    }

    func checkpointFence(
        source: RuntimeSwitchSourceFence,
        targetDigest: ExecutionLaunchArgumentsSHA256,
        generation: UInt64 = 10,
        providerAdapter: String = "provider-handoff-v1",
        cohortID: String = "cohort-v1"
    ) throws -> RuntimeSwitchCheckpointFence {
        .init(
            checkpointID: try .init(rawValue: "checkpoint-1"),
            checkpointGeneration: generation,
            ledgerSequence: 20,
            effectWatermark: 30,
            toolOperationWatermark: 40,
            source: source,
            targetManifestSHA256: targetDigest,
            providerContinuation: try .init(adapterID: providerAdapter, protocolVersion: 1),
            supervisor: try supervisor(cohortID: cohortID)
        )
    }

    func preparedGracefulState(effectID: RuntimeSwitchEffectID) throws -> RuntimeSwitchPolicyState {
        let request = try gracefulRequest()
        let waiting = RuntimeSwitchPolicy.admit(
            .empty,
            request: request,
            verified: try admission(for: request)
        ).state
        return RuntimeSwitchPolicy.observeSafeCheckpoint(
            waiting,
            attestation: try checkpoint(for: request, effectID: effectID)
        ).state
    }

    func preparedImmediateState(effectID: RuntimeSwitchEffectID) throws -> RuntimeSwitchPolicyState {
        let request = try forceRequest()
        let verifiedAdmission = try admission(for: request)
        let pending = RuntimeSwitchPolicy.admit(.empty, request: request, verified: verifiedAdmission).state
        let confirmation = try self.confirmation(
            for: request,
            challenge: try #require(verifiedAdmission.forceChallenge),
            effectID: effectID
        )
        return RuntimeSwitchPolicy.confirmImmediate(
            pending,
            confirmation: confirmation,
            capability: try capability(
                requestDigest: verifiedAdmission.requestDigest,
                source: source,
                intent: .immediate
            )
        ).state
    }

    func completedGracefulState(
        initial: RuntimeSwitchPolicyState = .empty,
        requestID: RuntimeSwitchRequestID = requestID(5),
        controlEffectID: RuntimeSwitchEffectID,
        replacementEffectID: RuntimeSwitchEffectID,
        sequenceOffset: UInt64 = 0
    ) throws -> RuntimeSwitchPolicyState {
        let request = try gracefulRequest(requestID: requestID)
        let reservation = targetReservation(for: request, ledgerSequence: 10 + sequenceOffset)
        let waiting = RuntimeSwitchPolicy.admit(
            initial,
            request: request,
            verified: try admission(
                for: request,
                reservation: reservation,
                sourceLedgerSequence: 5 + sequenceOffset
            )
        ).state
        let prepared = RuntimeSwitchPolicy.observeSafeCheckpoint(
            waiting,
            attestation: try checkpoint(
                for: request,
                effectID: controlEffectID,
                ledgerSequence: 20 + sequenceOffset
            )
        ).state
        let awaitingTerminal = RuntimeSwitchPolicy.acknowledgeControl(
            prepared,
            acceptance: .init(
                evidenceID: evidenceID(700),
                effectID: controlEffectID,
                source: source,
                ledgerSequence: 60 + sequenceOffset
            )
        ).state
        let replacementReady = RuntimeSwitchPolicy.observeSourceTerminal(
            awaitingTerminal,
            attestation: try terminal(
                ledgerSequence: 100 + sequenceOffset,
                replacementEffectID: replacementEffectID
            )
        ).state
        let replacementAccepted = RuntimeSwitchPolicy.acknowledgeReplacement(
            replacementReady,
            acceptance: .init(
                evidenceID: evidenceID(800),
                effectID: replacementEffectID,
                targetReservationID: reservation.reservationID,
                targetExecutionID: target.manifest.executionID,
                targetManifestSHA256: target.manifestSHA256,
                ledgerSequence: 120 + sequenceOffset
            )
        ).state
        return RuntimeSwitchPolicy.observeReplacementRunning(
            replacementAccepted,
            attestation: .init(
                evidenceID: evidenceID(900),
                targetReservationID: reservation.reservationID,
                targetExecutionID: target.manifest.executionID,
                targetManifestSHA256: target.manifestSHA256,
                ledgerSequence: 130 + sequenceOffset
            )
        ).state
    }

    func confirmation(
        for request: ActiveRuntimeSwitchRequest,
        challenge: RuntimeForceSwitchChallenge,
        actorID: RuntimeSwitchActorID? = nil,
        confirmedAt: Date? = nil,
        serverNow: Date? = nil,
        effectID: RuntimeSwitchEffectID = effectID(70)
    ) throws -> VerifiedRuntimeForceConfirmation {
        guard case .forceTermination(let force) = request else {
            throw RuntimeSwitchTrustedAttestationError.requestBindingMismatch
        }
        return try .init(
            confirmationID: evidenceID(71),
            challenge: challenge,
            request: force,
            requestDigest: requestDigest,
            actorID: actorID ?? challenge.actorID,
            sessionID: challenge.sessionID,
            confirmedAt: confirmedAt ?? now,
            serverNow: serverNow ?? now,
            effectID: effectID
        )
    }

    func capability(
        for effect: RuntimeSwitchControlEffect,
        intent: ExecutionCancellationIntent
    ) throws -> VerifiedRuntimeSwitchBackendCapability {
        try capability(requestDigest: effect.requestDigest, source: effect.source, intent: intent)
    }

    func capability(
        capabilityID: RuntimeSwitchEvidenceID = evidenceID(75),
        requestDigest: RuntimeSwitchRequestDigest,
        source: RuntimeSwitchSourceFence,
        intent: ExecutionCancellationIntent
    ) throws -> VerifiedRuntimeSwitchBackendCapability {
        try .init(
            capabilityID: capabilityID,
            requestDigest: requestDigest,
            source: source,
            cancellationIntent: intent
        )
    }

    func dispatchSnapshot(
        for effect: RuntimeSwitchControlEffect,
        source: RuntimeSwitchSourceFence? = nil,
        lifecycle: RuntimeSwitchExecutionLifecycle = .running,
        cancellation: ExecutionCancellationObservedState = .notRequested,
        checkpoint: RuntimeSwitchCheckpointFence?? = nil
    ) -> VerifiedRuntimeSwitchDispatchSnapshot {
        .init(
            effectID: effect.effectID,
            requestDigest: effect.requestDigest,
            source: source ?? effect.source,
            lifecycle: lifecycle,
            observedCancellation: cancellation,
            checkpointFence: checkpoint ?? effect.checkpointFence
        )
    }

    func terminal(
        source: RuntimeSwitchSourceFence? = nil,
        observedState: ExecutionObservedState = .cancelled,
        ledgerSequence: UInt64 = 100,
        replacementEffectID: RuntimeSwitchEffectID
    ) throws -> VerifiedRuntimeSwitchTerminalAttestation {
        try .init(
            evidenceID: evidenceID(81),
            source: source ?? self.source,
            observedState: observedState,
            ledgerSequence: ledgerSequence,
            replacementEffectID: replacementEffectID
        )
    }

    func replacementSnapshot(
        effectID: RuntimeSwitchEffectID,
        terminal: RuntimeSwitchTerminalFence? = nil,
        targetReservation: RuntimeSwitchTargetReservation? = nil
    ) throws -> VerifiedRuntimeSwitchReplacementDispatchSnapshot {
        let terminal = try terminal ?? self.terminal(replacementEffectID: effectID).terminalFence
        let reservation: RuntimeSwitchTargetReservation
        if let targetReservation {
            reservation = targetReservation
        } else {
            reservation = self.targetReservation(for: try gracefulRequest())
        }
        return .init(
            effectID: effectID,
            sourceTerminal: terminal,
            targetReservation: reservation,
            targetManifestSHA256: target.manifestSHA256
        )
    }

    func sourceFence(installationID: RunBrokerInstallationID) throws -> RuntimeSwitchSourceFence {
        try .init(
            installationID: installationID,
            storeID: source.storeID,
            executionID: source.executionID,
            taskID: source.taskID,
            authority: source.authority,
            manifestSHA256: source.manifestSHA256,
            configurationRevision: source.configurationRevision
        )
    }

    func manifest(
        executionID: RunBrokerExecutionID,
        runtimeID: AgentRuntimeID,
        configurationRevision: String,
        declaredEffects: [ExecutionEffectClaim] = []
    ) -> ExecutionLaunchManifest {
        Self.makeManifest(
            executionID: executionID,
            runtimeID: runtimeID,
            configurationRevision: configurationRevision,
            declaredEffects: declaredEffects,
            createdAt: now
        )
    }

    private static func makeManifest(
        executionID: RunBrokerExecutionID,
        runtimeID: AgentRuntimeID,
        configurationRevision: String,
        declaredEffects: [ExecutionEffectClaim] = [],
        createdAt: Date
    ) -> ExecutionLaunchManifest {
        .init(
            installationID: installationID(1),
            storeID: storeID(1),
            executionID: executionID,
            taskID: uuid(4),
            authority: .init(id: .init(rawValue: uuid(5)), epoch: .init(rawValue: 2)),
            configuration: .init(
                runtimeID: runtimeID,
                modelID: "model",
                executablePath: "/usr/bin/runtime",
                workingDirectory: "/tmp/workspace",
                environmentVariableNames: ["PATH"],
                configurationRevision: configurationRevision
            ),
            declaredEffects: declaredEffects,
            createdAt: createdAt
        )
    }
}

private func uuid(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
}

private func installationID(_ value: Int) -> RunBrokerInstallationID { .init(rawValue: uuid(10_000 + value)) }
private func storeID(_ value: Int) -> RunBrokerStoreID { .init(rawValue: uuid(20_000 + value)) }
private func executionID(_ value: Int) -> RunBrokerExecutionID { .init(rawValue: uuid(30_000 + value)) }
private func requestID(_ value: Int) -> RuntimeSwitchRequestID { .init(rawValue: uuid(40_000 + value)) }
private func effectID(_ value: Int) -> RuntimeSwitchEffectID { .init(rawValue: uuid(50_000 + value)) }
private func evidenceID(_ value: Int) -> RuntimeSwitchEvidenceID { .init(rawValue: uuid(60_000 + value)) }

private func digest(_ value: Int) -> ExecutionLaunchArgumentsSHA256 {
    try! .init(hexValue: String(format: "%064x", value))
}

import ASTRACore
import Foundation
import RunBrokerPolicy

extension RunLedger {
    /// Atomically verifies and admits one runtime switch. Reservation, force
    /// challenge binding, and policy admission share the append transaction;
    /// no crash can expose an orphan target reservation.
    @discardableResult
    package func admitRuntimeSwitch(
        request: ActiveRuntimeSwitchRequest,
        requestDigest: RuntimeSwitchRequestDigest,
        reservationID: RuntimeSwitchEvidenceID,
        forceChallenge: RuntimeForceSwitchChallenge?,
        eventID: RunLedgerEventID,
        occurredAt: Date
    ) throws -> RunLedgerAppendResult {
        try append(.init(
            eventID: eventID,
            occurredAt: occurredAt,
            event: .runtimeSwitchAdmitted(
                request: request,
                requestDigest: requestDigest,
                reservationID: reservationID,
                forceChallenge: forceChallenge
            )
        ))
    }

    /// Atomically reserves the exact target execution. Reusing the reservation
    /// event is an exact replay; reusing a request, reservation, or execution
    /// identity for different input is rejected by the canonical projector.
    @discardableResult
    package func reserveRuntimeSwitchTarget(
        request: ActiveRuntimeSwitchRequest,
        requestDigest: RuntimeSwitchRequestDigest,
        reservationID: RuntimeSwitchEvidenceID,
        occurredAt: Date
    ) throws -> RuntimeSwitchTargetReservation {
        let eventID = RunLedgerEventID(rawValue: reservationID.rawValue)
        _ = try append(.init(
            eventID: eventID,
            occurredAt: occurredAt,
            event: .runtimeSwitchTargetReserved(
                request: request,
                requestDigest: requestDigest,
                reservationID: reservationID
            )
        ))
        guard let reservation = try projection().runtimeSwitchReservations[reservationID] else {
            throw RunLedgerError.projectionDrift("Committed runtime-switch reservation is missing")
        }
        return reservation
    }

    /// Commits an exact policy CAS. External effects are identified here but
    /// are never executed by the ledger; the broker dispatches only after this
    /// durable intent has returned successfully.
    @discardableResult
    package func transitionRuntimeSwitchPolicy(
        expected: RuntimeSwitchPolicyState,
        next: RuntimeSwitchPolicyState,
        effectID: RuntimeSwitchEffectID?,
        eventID: RunLedgerEventID,
        occurredAt: Date
    ) throws -> RunLedgerAppendResult {
        try append(.init(
            eventID: eventID,
            occurredAt: occurredAt,
            event: .runtimeSwitchPolicyTransitioned(
                expected: expected,
                next: next,
                effectID: effectID
            )
        ))
    }

    /// Archives an exact completed switch under CAS. The projector constructs
    /// the rollover using the sequence assigned inside the append transaction;
    /// callers never predict or reserve a ledger sequence.
    @discardableResult
    package func archiveRuntimeSwitchCompletion(
        expected: RuntimeSwitchPolicyState,
        archiveEvidenceID: RuntimeSwitchEvidenceID,
        eventID: RunLedgerEventID,
        occurredAt: Date
    ) throws -> RunLedgerAppendResult {
        try append(.init(
            eventID: eventID,
            occurredAt: occurredAt,
            event: .runtimeSwitchCompletionArchived(
                expected: expected,
                archiveEvidenceID: archiveEvidenceID
            )
        ))
    }

    /// Exact retry fence checked before any replacement launch capability is
    /// created. It is observation-only and cannot mint or expose a capability.
    public func validateReservedStartIf(
        reservation: RuntimeSwitchTargetReservation,
        manifestDigest: ExecutionLaunchArgumentsSHA256,
        effectID: RuntimeSwitchEffectID
    ) throws {
        let current = try projection()
        guard current.runtimeSwitchReservations[reservation.reservationID] == reservation,
              current.runtimeSwitchTargetReservations[reservation.targetExecutionID]
                == reservation.reservationID,
              current.runtimeSwitchEffectBindings[effectID] == reservation.requestDigest,
              manifestDigest == reservation.targetManifestSHA256,
              let record = current.runtimeSwitchPolicyState.record,
              record.request.intent.requestID == reservation.requestID,
              record.requestDigest == reservation.requestDigest,
              record.targetReservation == reservation,
              record.replacementEffect?.effectID == effectID,
              record.replacementEffect?.target.manifestSHA256 == manifestDigest,
              record.progress == .replacementDispatchPending else {
            throw RunLedgerError.invalidEvent("Runtime-switch replacement start fence is stale")
        }
    }
}

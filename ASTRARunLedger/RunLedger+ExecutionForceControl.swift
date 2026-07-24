import ASTRACore
import Foundation

extension RunLedger {
    @discardableResult
    public func recordExecutionForceChallenge(
        _ challenge: ExecutionForceChallenge,
        eventID: RunLedgerEventID,
        occurredAt: Date
    ) throws -> RunLedgerAppendResult {
        try append(.init(
            eventID: eventID,
            occurredAt: occurredAt,
            event: .executionForceChallengeRecorded(challenge)
        ))
    }

    @discardableResult
    public func consumeExecutionForceChallenge(
        challengeID: RuntimeForceChallengeID,
        requestDigest: ExecutionForceRequestDigest,
        effectID: RuntimeSwitchEffectID,
        actorID: RuntimeSwitchActorID,
        sessionID: UUID,
        confirmedAt: Date,
        eventID: RunLedgerEventID
    ) throws -> RunLedgerAppendResult {
        try append(.init(
            eventID: eventID,
            occurredAt: confirmedAt,
            event: .executionForceChallengeConsumed(
                challengeID: challengeID,
                requestDigest: requestDigest,
                effectID: effectID,
                actorID: actorID,
                sessionID: sessionID,
                confirmedAt: confirmedAt
            )
        ))
    }
}

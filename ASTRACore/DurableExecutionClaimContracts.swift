import Foundation

public enum DurableExecutionClaimTombstoneReason: String, Codable, Hashable, Sendable {
    case completed
    case cancelled
    case failed
    case superseded
    case administrativelyReleased = "administratively_released"
}

/// Durable evidence that a claim stopped holding its effects. Tombstones are
/// absorbing: reusing the same operation identity can never reactivate it.
public struct DurableExecutionClaimTombstone: Codable, Hashable, Sendable {
    public let reason: DurableExecutionClaimTombstoneReason
    public let recordedAt: Date

    public init(reason: DurableExecutionClaimTombstoneReason, recordedAt: Date) {
        self.reason = reason
        self.recordedAt = recordedAt
    }
}

public enum DurableExecutionClaimState: Codable, Hashable, Sendable {
    case active
    case tombstoned(DurableExecutionClaimTombstone)

    public var holdsEffects: Bool {
        if case .active = self { return true }
        return false
    }
}

/// Durable ownership of all declared effects for one operation. Effects remain
/// on tombstones for audit and reconciliation, but no longer block admission.
public struct DurableExecutionClaimRecord: Codable, Hashable, Sendable {
    public let storeID: RunBrokerStoreID
    public let operationID: RunBrokerOperationID
    public let executionID: RunBrokerExecutionID
    public let authority: RunBrokerAuthority
    public let effects: [ExecutionEffectClaim]
    public let state: DurableExecutionClaimState
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        storeID: RunBrokerStoreID,
        operationID: RunBrokerOperationID,
        executionID: RunBrokerExecutionID,
        authority: RunBrokerAuthority,
        effects: [ExecutionEffectClaim],
        state: DurableExecutionClaimState = .active,
        createdAt: Date,
        updatedAt: Date? = nil
    ) {
        self.storeID = storeID
        self.operationID = operationID
        self.executionID = executionID
        self.authority = authority
        self.effects = effects
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    public var holdsEffects: Bool { state.holdsEffects }
}

public enum DurableExecutionClaimEvent: Equatable, Sendable {
    case transferAuthority(RunBrokerAuthority, at: Date)
    case tombstone(
        authority: RunBrokerAuthority,
        reason: DurableExecutionClaimTombstoneReason,
        at: Date
    )

    fileprivate var authority: RunBrokerAuthority {
        switch self {
        case .transferAuthority(let authority, _), .tombstone(let authority, _, _):
            return authority
        }
    }
}

public enum DurableExecutionClaimDisposition: String, Codable, Equatable, Sendable {
    case applied
    case idempotent
    case staleEpochRejected = "stale_epoch_rejected"
    case authorityConflict = "authority_conflict"
    case tombstoneIsFinal = "tombstone_is_final"
}

public struct DurableExecutionClaimReduction: Equatable, Sendable {
    public let record: DurableExecutionClaimRecord
    public let disposition: DurableExecutionClaimDisposition

    public init(record: DurableExecutionClaimRecord, disposition: DurableExecutionClaimDisposition) {
        self.record = record
        self.disposition = disposition
    }
}

/// Pure reducer for fencing and tombstoning durable effect claims.
public enum DurableExecutionClaimReducer {
    public static func reduce(
        _ record: DurableExecutionClaimRecord,
        event: DurableExecutionClaimEvent
    ) -> DurableExecutionClaimReduction {
        let incomingAuthority = event.authority
        if incomingAuthority.epoch < record.authority.epoch {
            return .init(record: record, disposition: .staleEpochRejected)
        }

        if incomingAuthority.epoch == record.authority.epoch,
           incomingAuthority.id != record.authority.id {
            return .init(record: record, disposition: .authorityConflict)
        }

        if case .tombstoned(let existingTombstone) = record.state {
            if case .tombstone(let authority, let reason, let at) = event,
               authority == record.authority,
               existingTombstone == .init(reason: reason, recordedAt: at) {
                return .init(record: record, disposition: .idempotent)
            }
            return .init(record: record, disposition: .tombstoneIsFinal)
        }

        switch event {
        case .transferAuthority(let authority, let at):
            guard authority != record.authority else {
                return .init(record: record, disposition: .idempotent)
            }
            return .init(
                record: replacing(record, authority: authority, state: record.state, updatedAt: at),
                disposition: .applied
            )

        case .tombstone(let authority, let reason, let at):
            return .init(
                record: replacing(
                    record,
                    authority: authority,
                    state: .tombstoned(.init(reason: reason, recordedAt: at)),
                    updatedAt: at
                ),
                disposition: .applied
            )
        }
    }

    private static func replacing(
        _ record: DurableExecutionClaimRecord,
        authority: RunBrokerAuthority,
        state: DurableExecutionClaimState,
        updatedAt: Date
    ) -> DurableExecutionClaimRecord {
        DurableExecutionClaimRecord(
            storeID: record.storeID,
            operationID: record.operationID,
            executionID: record.executionID,
            authority: authority,
            effects: record.effects,
            state: state,
            createdAt: record.createdAt,
            updatedAt: updatedAt
        )
    }
}

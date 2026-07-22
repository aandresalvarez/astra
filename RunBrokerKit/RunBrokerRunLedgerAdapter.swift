import ASTRACore
import ASTRARunLedger
import Foundation
import RunBrokerClient

/// Concrete scheduler persistence boundary over the canonical RunLedger.
/// Conversion is field-for-field so authority, generation, and causal audit
/// timestamps participate in the same exact CAS on both sides of the boundary.
public final class RunBrokerRunLedgerAdapter: RunBrokerMonitorLedger, @unchecked Sendable {
    private let ledger: RunLedger

    public init(ledger: RunLedger) {
        self.ledger = ledger
    }

    /// The broker daemon's composition path. Claims the process-lifetime
    /// exclusive-writer lock by default so two live broker processes can never
    /// interleave appends over one ledger; observation ordering is serialized
    /// in-process and a second writer would corrupt it undetectably.
    public convenience init(
        identity: RunBrokerChannelIdentity,
        installationID: RunBrokerInstallationID,
        exclusiveWriter: Bool = true
    ) throws {
        try self.init(
            ledger: RunLedger(
                configuration: .init(
                    ledgerDirectoryURL: identity.ledgerDirectoryURL,
                    installationID: installationID,
                    exclusiveWriter: exclusiveWriter
                )
            )
        )
    }

    public var isAvailable: Bool { true }

    public func recoverMonitorDeadlines() throws -> [RunBrokerMonitorDeadline] {
        try ledger.monitorDeadlines().map(Self.brokerDeadline)
    }

    public func upsertMonitorDeadline(
        _ deadline: RunBrokerMonitorDeadline,
        replacing expected: RunBrokerMonitorDeadline?,
        idempotencyKey: UUID
    ) throws -> RunBrokerMonitorMutationDisposition {
        do {
            let result = try ledger.upsertMonitorDeadline(
                Self.ledgerDeadline(deadline),
                replacing: expected.map(Self.ledgerDeadline),
                idempotencyKey: idempotencyKey
            )
            return Self.mutationDisposition(result.disposition)
        } catch RunLedgerError.monitorScheduleConflict(let operationID) {
            throw RunBrokerLedgerError.monitorScheduleConflict(operationID)
        } catch RunLedgerError.claimTransitionRejected(_) {
            // Authority transfer rewrites the active deadline atomically. A
            // caller still holding the old authority is therefore stale at
            // the same exact-CAS boundary and must refresh the projection.
            throw RunBrokerLedgerError.monitorScheduleConflict(deadline.operationID)
        }
    }

    public func removeMonitorDeadline(
        expected: RunBrokerMonitorDeadline,
        occurredAt: Date,
        idempotencyKey: UUID
    ) throws -> RunBrokerMonitorMutationDisposition {
        do {
            let result = try ledger.removeMonitorDeadline(
                expected: Self.ledgerDeadline(expected),
                occurredAt: occurredAt,
                idempotencyKey: idempotencyKey
            )
            return Self.mutationDisposition(result.disposition)
        } catch RunLedgerError.monitorScheduleConflict(let operationID) {
            throw RunBrokerLedgerError.monitorScheduleConflict(operationID)
        } catch RunLedgerError.claimTransitionRejected(_) {
            throw RunBrokerLedgerError.monitorScheduleConflict(expected.operationID)
        }
    }

    public func recordMonitorAttempt(
        expectedDeadline: RunBrokerMonitorDeadline,
        attemptedAt: Date,
        disposition: RunBrokerMonitorAttemptDisposition,
        nextDueAt: Date?,
        idempotencyKey: UUID
    ) throws -> RunBrokerMonitorAttemptCommit {
        let result = try ledger.recordMonitorAttempt(
            expected: Self.ledgerDeadline(expectedDeadline),
            attemptedAt: attemptedAt,
            disposition: Self.ledgerDisposition(disposition),
            nextDueAt: nextDueAt,
            idempotencyKey: idempotencyKey
        )
        switch result {
        case .applied: return .applied
        case .stale: return .stale
        }
    }

    private static func ledgerDeadline(
        _ value: RunBrokerMonitorDeadline
    ) -> RunLedgerMonitorDeadline {
        .init(
            operationID: value.operationID,
            authority: value.authority,
            dueAt: value.dueAt,
            recordedAt: value.recordedAt,
            attempt: value.attempt,
            generation: value.generation
        )
    }

    private static func brokerDeadline(
        _ value: RunLedgerMonitorDeadline
    ) -> RunBrokerMonitorDeadline {
        .init(
            operationID: value.operationID,
            authority: value.authority,
            dueAt: value.dueAt,
            recordedAt: value.recordedAt,
            attempt: value.attempt,
            generation: value.generation
        )
    }

    private static func ledgerDisposition(
        _ value: RunBrokerMonitorAttemptDisposition
    ) -> RunLedgerMonitorAttemptDisposition {
        switch value {
        case .completed: return .completed
        case .retryableFailure: return .retryableFailure
        case .terminalFailure: return .terminalFailure
        }
    }

    private static func mutationDisposition(
        _ value: RunLedgerAppendDisposition
    ) -> RunBrokerMonitorMutationDisposition {
        switch value {
        case .appended: return .appended
        case .exactReplay: return .exactReplay
        }
    }
}

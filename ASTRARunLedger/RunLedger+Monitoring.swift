import ASTRACore
import Foundation

extension RunLedger {
    public func monitorDeadlines() throws -> [RunLedgerMonitorDeadline] {
        let deadlines = try projection().monitorDeadlines.values
        return deadlines.sorted {
            if $0.dueAt != $1.dueAt { return $0.dueAt < $1.dueAt }
            return RunLedgerSchema.uuid($0.operationID.rawValue)
                < RunLedgerSchema.uuid($1.operationID.rawValue)
        }
    }

    @discardableResult
    public func upsertMonitorDeadline(
        _ deadline: RunLedgerMonitorDeadline,
        replacing expected: RunLedgerMonitorDeadline?,
        idempotencyKey: UUID
    ) throws -> RunLedgerAppendResult {
        try append(.init(
            eventID: .init(rawValue: idempotencyKey),
            occurredAt: deadline.recordedAt,
            event: .monitorDeadlineUpserted(deadline: deadline, replacing: expected)
        ))
    }

    @discardableResult
    public func upsertMonitorDeadline(
        operationID: RunBrokerOperationID,
        authority: RunBrokerAuthority,
        dueAt: Date,
        attempt: UInt64,
        scheduledAt: Date,
        replacing expected: RunLedgerMonitorDeadline?,
        idempotencyKey: UUID
    ) throws -> RunLedgerAppendResult {
        try upsertMonitorDeadline(
            .init(
                operationID: operationID,
                authority: authority,
                dueAt: dueAt,
                recordedAt: scheduledAt,
                attempt: attempt,
                generation: idempotencyKey
            ),
            replacing: expected,
            idempotencyKey: idempotencyKey
        )
    }

    @discardableResult
    public func removeMonitorDeadline(
        expected: RunLedgerMonitorDeadline,
        occurredAt: Date,
        idempotencyKey: UUID
    ) throws -> RunLedgerAppendResult {
        try append(.init(
            eventID: .init(rawValue: idempotencyKey),
            occurredAt: occurredAt,
            event: .monitorDeadlineRemoved(expected: expected)
        ))
    }

    /// Records every observation for audit, but changes the active schedule
    /// only when all recovered deadline fields still match. Exact idempotency
    /// replay returns the originally persisted applied/stale disposition.
    @discardableResult
    public func recordMonitorAttempt(
        expected: RunLedgerMonitorDeadline,
        attemptedAt: Date,
        disposition: RunLedgerMonitorAttemptDisposition,
        nextDueAt: Date?,
        idempotencyKey: UUID
    ) throws -> RunLedgerMonitorAttemptApplyDisposition {
        let eventID = RunLedgerEventID(rawValue: idempotencyKey)
        _ = try append(.init(
            eventID: eventID,
            occurredAt: attemptedAt,
            event: .monitorAttemptRecorded(
                expected: expected,
                attemptedAt: attemptedAt,
                disposition: disposition,
                nextDueAt: nextDueAt
            )
        ))
        let attempt = try connection.withLock { database in
            try RunLedgerMonitorAuditStore.load(
                eventID: eventID,
                connection: connection,
                database: database
            )
        }
        guard let attempt else {
            throw RunLedgerError.projectionDrift(
                "Monitor attempt journal event has no durable attempt projection"
            )
        }
        return attempt.applyDisposition
    }
}

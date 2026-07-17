import ASTRACore
import Foundation

enum RunLedgerMonitorProjector {
    static func reduce(
        _ projection: RunLedgerProjection,
        storedEvent: StoredRunLedgerEvent
    ) throws -> RunLedgerProjection {
        switch storedEvent.envelope.event {
        case .monitorDeadlineUpserted(let deadline, let expectedCurrent):
            try validate(deadline)
            guard deadline.generation == storedEvent.envelope.eventID.rawValue else {
                throw RunLedgerError.invalidEvent(
                    "Monitor generation must equal its upsert idempotency UUID"
                )
            }
            guard let operation = projection.operations[deadline.operationID] else {
                throw RunLedgerError.missingOperation(deadline.operationID)
            }
            guard deadline.authority == operation.record.authority else {
                throw RunLedgerError.claimTransitionRejected(
                    deadline.authority.epoch < operation.record.authority.epoch
                        ? .staleEpochRejected
                        : .authorityConflict
                )
            }
            guard operation.record.holdsEffects else {
                throw RunLedgerError.invalidEvent("A terminal operation cannot be monitored")
            }
            guard deadline.recordedAt == storedEvent.envelope.occurredAt else {
                throw RunLedgerError.invalidEvent(
                    "Monitor deadline recordedAt must equal its event time"
                )
            }
            guard deadline.recordedAt >= operation.record.updatedAt else {
                throw RunLedgerError.invalidEvent(
                    "Monitor deadline predates the current operation claim"
                )
            }
            var deadlines = projection.monitorDeadlines
            let current = deadlines[deadline.operationID]
            guard current == expectedCurrent else {
                throw RunLedgerError.monitorScheduleConflict(
                    operationID: deadline.operationID
                )
            }
            if let expectedCurrent {
                try validate(expectedCurrent)
                guard expectedCurrent.operationID == deadline.operationID,
                      deadline.recordedAt >= expectedCurrent.recordedAt else {
                    throw RunLedgerError.invalidEvent(
                        "Monitor replacement is not causally after its expected schedule"
                    )
                }
            }
            deadlines[deadline.operationID] = deadline
            return replacing(projection, deadlines: deadlines)

        case .monitorDeadlineRemoved(let expected):
            try validate(expected)
            guard let operation = projection.operations[expected.operationID] else {
                throw RunLedgerError.missingOperation(expected.operationID)
            }
            guard expected.authority == operation.record.authority else {
                throw RunLedgerError.claimTransitionRejected(
                    expected.authority.epoch < operation.record.authority.epoch
                        ? .staleEpochRejected
                        : .authorityConflict
                )
            }
            guard storedEvent.envelope.occurredAt >= operation.record.updatedAt,
                  storedEvent.envelope.occurredAt >= expected.recordedAt else {
                throw RunLedgerError.invalidEvent(
                    "Monitor removal predates its claim or expected schedule"
                )
            }
            var deadlines = projection.monitorDeadlines
            guard deadlines[expected.operationID] == expected else {
                throw RunLedgerError.monitorScheduleConflict(
                    operationID: expected.operationID
                )
            }
            deadlines.removeValue(forKey: expected.operationID)
            return replacing(projection, deadlines: deadlines)

        case .monitorAttemptRecorded(
            let expected, let attemptedAt, let disposition, _
        ):
            guard let audit = try auditRecord(for: storedEvent, in: projection) else {
                throw RunLedgerError.invalidEvent("Monitor attempt has no audit record")
            }
            let applies = audit.applyDisposition == .applied
            var deadlines = projection.monitorDeadlines
            if applies {
                deadlines[expected.operationID] = audit.nextDeadline
            }
            var operations = projection.operations
            if applies, disposition != .retryableFailure {
                guard let operation = operations[expected.operationID] else {
                    throw RunLedgerError.missingOperation(expected.operationID)
                }
                guard attemptedAt >= operation.record.updatedAt else {
                    throw RunLedgerError.invalidEvent(
                        "Terminal monitor evidence predates the current operation claim"
                    )
                }
                let reason: DurableExecutionClaimTombstoneReason = disposition == .completed
                    ? .completed
                    : .failed
                let reduction = DurableExecutionClaimReducer.reduce(
                    operation.record,
                    event: .tombstone(
                        authority: expected.authority,
                        reason: reason,
                        at: attemptedAt
                    )
                )
                guard reduction.disposition == .applied else {
                    throw RunLedgerError.claimTransitionRejected(reduction.disposition)
                }
                operations[expected.operationID] = .init(
                    record: reduction.record,
                    createdSequence: operation.createdSequence,
                    updatedSequence: storedEvent.sequence
                )
            }
            return .init(
                executions: projection.executions,
                operations: operations,
                monitorDeadlines: deadlines
            )

        default:
            throw RunLedgerError.invalidEvent("Non-monitor event reached monitor projector")
        }
    }

    static func auditRecord(
        for storedEvent: StoredRunLedgerEvent,
        in projection: RunLedgerProjection
    ) throws -> RunLedgerMonitorAttemptProjection? {
        guard case .monitorAttemptRecorded(
            let expected,
            let attemptedAt,
            let disposition,
            let nextDueAt
        ) = storedEvent.envelope.event else { return nil }
        try validate(expected)
        guard let operation = projection.operations[expected.operationID] else {
            throw RunLedgerError.missingOperation(expected.operationID)
        }
        guard attemptedAt.timeIntervalSince1970.isFinite else {
            throw RunLedgerError.invalidEvent("Monitor attempt date must be finite")
        }
        let applies = projection.monitorDeadlines[expected.operationID] == expected
        if applies {
            guard attemptedAt >= operation.record.updatedAt else {
                throw RunLedgerError.invalidEvent(
                    "Applied monitor evidence predates the current operation claim"
                )
            }
            guard attemptedAt >= expected.recordedAt else {
                throw RunLedgerError.invalidEvent(
                    "Applied monitor evidence predates its expected schedule"
                )
            }
        }
        let next = try nextDeadline(
            expected: expected,
            attemptedAt: attemptedAt,
            disposition: disposition,
            nextDueAt: nextDueAt,
            generation: storedEvent.envelope.eventID.rawValue
        )
        if applies, attemptedAt < expected.dueAt {
            throw RunLedgerError.invalidEvent(
                "An applied monitor attempt cannot predate its expected deadline"
            )
        }
        return .init(
            eventID: storedEvent.envelope.eventID,
            expected: expected,
            attemptedAt: attemptedAt,
            disposition: disposition,
            nextDeadline: next,
            applyDisposition: applies ? .applied : .stale,
            recordedSequence: storedEvent.sequence
        )
    }

    private static func nextDeadline(
        expected: RunLedgerMonitorDeadline,
        attemptedAt: Date,
        disposition: RunLedgerMonitorAttemptDisposition,
        nextDueAt: Date?,
        generation: UUID
    ) throws -> RunLedgerMonitorDeadline? {
        switch disposition {
        case .completed, .terminalFailure:
            guard nextDueAt == nil else {
                throw RunLedgerError.invalidEvent("Terminal monitor results cannot schedule a retry")
            }
            return nil
        case .retryableFailure:
            guard let nextDueAt, nextDueAt.timeIntervalSince1970.isFinite else {
                throw RunLedgerError.invalidEvent("Retryable monitor results require a finite deadline")
            }
            guard nextDueAt >= attemptedAt else {
                throw RunLedgerError.invalidEvent("A monitor retry cannot predate its attempt")
            }
            guard expected.attempt < UInt64(Int64.max) else {
                throw RunLedgerError.invalidEvent("Monitor attempt counter cannot advance within SQLite")
            }
            return .init(
                operationID: expected.operationID,
                authority: expected.authority,
                dueAt: nextDueAt,
                recordedAt: attemptedAt,
                attempt: expected.attempt + 1,
                generation: generation
            )
        }
    }

    private static func validate(_ deadline: RunLedgerMonitorDeadline) throws {
        guard deadline.dueAt.timeIntervalSince1970.isFinite else {
            throw RunLedgerError.invalidEvent("Monitor deadline must be finite")
        }
        guard deadline.recordedAt.timeIntervalSince1970.isFinite else {
            throw RunLedgerError.invalidEvent("Monitor recorded date must be finite")
        }
        guard deadline.attempt <= UInt64(Int64.max) else {
            throw RunLedgerError.invalidEvent("Monitor attempt exceeds SQLite Int64 bounds")
        }
        guard deadline.authority.epoch.rawValue >= 1,
              deadline.authority.epoch.rawValue <= UInt64(Int64.max) else {
            throw RunLedgerError.invalidEvent("Monitor authority epoch exceeds SQLite Int64 bounds")
        }
    }

    private static func replacing(
        _ projection: RunLedgerProjection,
        deadlines: [RunBrokerOperationID: RunLedgerMonitorDeadline]
    ) -> RunLedgerProjection {
        .init(
            executions: projection.executions,
            operations: projection.operations,
            monitorDeadlines: deadlines
        )
    }
}

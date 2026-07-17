import ASTRACore
@testable import ASTRARunLedger
import Foundation
import Testing

@Suite("RunLedger durable monitor scheduling")
struct RunLedgerMonitorTests {
    @Test("Deadline survives restart, canonicalizes milliseconds, and replays exactly")
    func restartRecoveryAndExactReplay() throws {
        let fixture = try MonitorLedgerFixture()
        defer { fixture.cleanup() }
        let ledger = try fixture.open()
        let operation = try fixture.createActiveOperation(in: ledger, seed: 100)
        let dueAt = fixture.date(30.987_654)
        let scheduledAt = fixture.date(3.123_456)
        let key = monitorUUID(110)

        let first = try ledger.upsertMonitorDeadline(
            operationID: operation.operationID,
            authority: operation.authority,
            dueAt: dueAt,
            attempt: 0,
            scheduledAt: scheduledAt,
            replacing: nil,
            idempotencyKey: key
        )
        let replay = try ledger.upsertMonitorDeadline(
            operationID: operation.operationID,
            authority: operation.authority,
            dueAt: dueAt,
            attempt: 0,
            scheduledAt: scheduledAt,
            replacing: nil,
            idempotencyKey: key
        )
        let recovered = try #require(ledger.monitorDeadlines().first)
        #expect(first.disposition == .appended)
        #expect(replay.disposition == .exactReplay)
        #expect(recovered.dueAt == canonicalMilliseconds(dueAt))
        #expect(recovered.recordedAt == canonicalMilliseconds(scheduledAt))
        #expect(recovered.generation == key)
        #expect(recovered.authority == operation.authority)

        #expect(monitorLedgerError {
            try ledger.upsertMonitorDeadline(
                operationID: operation.operationID,
                authority: operation.authority,
                dueAt: dueAt.addingTimeInterval(1),
                attempt: 0,
                scheduledAt: scheduledAt,
                replacing: nil,
                idempotencyKey: key
            )
        } == .eventIDReuse(.init(rawValue: key)))
        let storeID = ledger.identity.storeID
        try ledger.close()

        let reopened = try fixture.open(expectedStoreID: storeID)
        defer { try? reopened.close() }
        #expect(try reopened.monitorDeadlines() == [recovered])
        #expect(reopened.verifyHealth().status == .healthy)
    }

    @Test("Retry advances once and an old applied replay cannot overwrite a reschedule")
    func retryAdvancementAndAppliedReplay() throws {
        let fixture = try MonitorLedgerFixture()
        defer { fixture.cleanup() }
        let ledger = try fixture.open()
        defer { try? ledger.close() }
        let operation = try fixture.createActiveOperation(in: ledger, seed: 200)
        let initialKey = monitorUUID(210)
        try ledger.upsertMonitorDeadline(
            operationID: operation.operationID,
            authority: operation.authority,
            dueAt: fixture.date(10),
            attempt: 0,
            scheduledAt: fixture.date(3),
            replacing: nil,
            idempotencyKey: initialKey
        )
        let expected = try #require(ledger.monitorDeadlines().first)
        let attemptKey = monitorUUID(211)

        #expect(try ledger.recordMonitorAttempt(
            expected: expected,
            attemptedAt: fixture.date(11),
            disposition: .retryableFailure,
            nextDueAt: fixture.date(20.555_555),
            idempotencyKey: attemptKey
        ) == .applied)
        let retry = try #require(ledger.monitorDeadlines().first)
        #expect(retry.attempt == 1)
        #expect(retry.generation == attemptKey)
        #expect(retry.dueAt == canonicalMilliseconds(fixture.date(20.555_555)))
        #expect(retry.recordedAt == canonicalMilliseconds(fixture.date(11)))

        let rescheduleKey = monitorUUID(212)
        try ledger.upsertMonitorDeadline(
            operationID: operation.operationID,
            authority: operation.authority,
            dueAt: fixture.date(40),
            attempt: 7,
            scheduledAt: fixture.date(12),
            replacing: retry,
            idempotencyKey: rescheduleKey
        )
        let rescheduled = try #require(ledger.monitorDeadlines().first)
        #expect(try ledger.recordMonitorAttempt(
            expected: expected,
            attemptedAt: fixture.date(11),
            disposition: .retryableFailure,
            nextDueAt: fixture.date(20.555_555),
            idempotencyKey: attemptKey
        ) == .applied)
        #expect(try ledger.monitorDeadlines() == [rescheduled])
    }

    @Test("A current attempt before its due time fails closed without an audit row")
    func appliedAttemptBeforeDueIsRejected() throws {
        let fixture = try MonitorLedgerFixture()
        defer { fixture.cleanup() }
        let ledger = try fixture.open()
        defer { try? ledger.close() }
        let operation = try fixture.createActiveOperation(in: ledger, seed: 800)
        try ledger.upsertMonitorDeadline(
            operationID: operation.operationID,
            authority: operation.authority,
            dueAt: fixture.date(20),
            attempt: 0,
            scheduledAt: fixture.date(3),
            replacing: nil,
            idempotencyKey: monitorUUID(810)
        )
        let expected = try #require(ledger.monitorDeadlines().first)
        let eventCount = try ledger.events().count

        #expect(monitorLedgerError {
            _ = try ledger.recordMonitorAttempt(
                expected: expected,
                attemptedAt: fixture.date(19.999),
                disposition: .completed,
                nextDueAt: nil,
                idempotencyKey: monitorUUID(811)
            )
        } == .invalidEvent("An applied monitor attempt cannot predate its expected deadline"))
        #expect(try ledger.events().count == eventCount)
        #expect(try ledger.monitorDeadlines() == [expected])
        let auditCount = try ledger.connection.withLock { database in
            try ledger.connection.scalarInt64(
                "SELECT COUNT(*) FROM monitor_attempts",
                database: database
            )
        }
        #expect(auditCount == 0)
    }

    @Test("Recorded time participates in the exact recovered-deadline CAS")
    func recordedAtParticipatesInCAS() throws {
        let fixture = try MonitorLedgerFixture()
        defer { fixture.cleanup() }
        let ledger = try fixture.open()
        defer { try? ledger.close() }
        let operation = try fixture.createActiveOperation(in: ledger, seed: 820)
        try ledger.upsertMonitorDeadline(
            operationID: operation.operationID,
            authority: operation.authority,
            dueAt: fixture.date(20),
            attempt: 0,
            scheduledAt: fixture.date(3),
            replacing: nil,
            idempotencyKey: monitorUUID(830)
        )
        let current = try #require(ledger.monitorDeadlines().first)
        let countBeforePredatedAttempt = try ledger.events().count
        #expect(monitorLedgerError {
            _ = try ledger.recordMonitorAttempt(
                expected: current,
                attemptedAt: fixture.date(2.5),
                disposition: .retryableFailure,
                nextDueAt: fixture.date(30),
                idempotencyKey: monitorUUID(829)
            )
        } == .invalidEvent("Applied monitor evidence predates its expected schedule"))
        #expect(try ledger.events().count == countBeforePredatedAttempt)
        let lookalike = RunLedgerMonitorDeadline(
            operationID: current.operationID,
            authority: current.authority,
            dueAt: current.dueAt,
            recordedAt: current.recordedAt.addingTimeInterval(0.001),
            attempt: current.attempt,
            generation: current.generation
        )
        let key = monitorUUID(831)

        #expect(try ledger.recordMonitorAttempt(
            expected: lookalike,
            attemptedAt: fixture.date(21),
            disposition: .completed,
            nextDueAt: nil,
            idempotencyKey: key
        ) == .stale)
        #expect(try ledger.recordMonitorAttempt(
            expected: lookalike,
            attemptedAt: fixture.date(21),
            disposition: .completed,
            nextDueAt: nil,
            idempotencyKey: key
        ) == .stale)
        #expect(try ledger.monitorDeadlines() == [current])
        #expect(try ledger.projection().operations[operation.operationID]?.record.holdsEffects == true)
    }

    @Test("Historical attempts stay out of the bounded hot projection")
    func historicalAttemptsAreAuditOnly() throws {
        let fixture = try MonitorLedgerFixture()
        defer { fixture.cleanup() }
        let ledger = try fixture.open()
        defer { try? ledger.close() }
        let operation = try fixture.createActiveOperation(in: ledger, seed: 700)
        try ledger.upsertMonitorDeadline(
            operationID: operation.operationID,
            authority: operation.authority,
            dueAt: fixture.date(10),
            attempt: 0,
            scheduledAt: fixture.date(3),
            replacing: nil,
            idempotencyKey: monitorUUID(710)
        )
        let firstExpected = try #require(ledger.monitorDeadlines().first)
        let firstAttemptedAt = fixture.date(10)
        let firstNextDueAt = fixture.date(11)
        var expected = firstExpected

        for index in 0..<100 {
            let attemptedAt = fixture.date(TimeInterval(10 + index))
            let nextDueAt = fixture.date(TimeInterval(11 + index))
            #expect(try ledger.recordMonitorAttempt(
                expected: expected,
                attemptedAt: attemptedAt,
                disposition: .retryableFailure,
                nextDueAt: nextDueAt,
                idempotencyKey: monitorUUID(711 + index)
            ) == .applied)
            expected = try #require(ledger.monitorDeadlines().first)
        }

        let projection = try ledger.projection()
        #expect(projection.executions.count == 1)
        #expect(projection.operations.count == 1)
        #expect(projection.monitorDeadlines.count == 1)
        let auditCount = try ledger.connection.withLock { database in
            try ledger.connection.scalarInt64(
                "SELECT COUNT(*) FROM monitor_attempts",
                database: database
            )
        }
        #expect(auditCount == 100)
        let final = try ledger.monitorDeadlines()
        #expect(try ledger.recordMonitorAttempt(
            expected: firstExpected,
            attemptedAt: firstAttemptedAt,
            disposition: .retryableFailure,
            nextDueAt: firstNextDueAt,
            idempotencyKey: monitorUUID(711)
        ) == .applied)
        #expect(try ledger.monitorDeadlines() == final)
    }

    @Test("Stale attempt replay remains stale after remove and later reschedule")
    func staleReplayDoesNotMutateCurrentSchedule() throws {
        let fixture = try MonitorLedgerFixture()
        defer { fixture.cleanup() }
        let ledger = try fixture.open()
        defer { try? ledger.close() }
        let operation = try fixture.createActiveOperation(in: ledger, seed: 300)
        try ledger.upsertMonitorDeadline(
            operationID: operation.operationID,
            authority: operation.authority,
            dueAt: fixture.date(10),
            attempt: 0,
            scheduledAt: fixture.date(3),
            replacing: nil,
            idempotencyKey: monitorUUID(310)
        )
        let old = try #require(ledger.monitorDeadlines().first)
        try ledger.removeMonitorDeadline(
            expected: old,
            occurredAt: fixture.date(4),
            idempotencyKey: monitorUUID(311)
        )
        let staleKey = monitorUUID(312)
        #expect(try ledger.recordMonitorAttempt(
            expected: old,
            attemptedAt: fixture.date(11),
            disposition: .completed,
            nextDueAt: nil,
            idempotencyKey: staleKey
        ) == .stale)
        #expect(try ledger.projection().operations[operation.operationID]?.record.holdsEffects == true)

        try ledger.upsertMonitorDeadline(
            operationID: operation.operationID,
            authority: operation.authority,
            dueAt: fixture.date(50),
            attempt: 8,
            scheduledAt: fixture.date(12),
            replacing: nil,
            idempotencyKey: monitorUUID(313)
        )
        let current = try #require(ledger.monitorDeadlines().first)
        #expect(try ledger.recordMonitorAttempt(
            expected: old,
            attemptedAt: fixture.date(11),
            disposition: .completed,
            nextDueAt: nil,
            idempotencyKey: staleKey
        ) == .stale)
        #expect(try ledger.monitorDeadlines() == [current])
    }

    @Test("Two connections fence stale schedule upserts and removals by exact CAS")
    func scheduleMutationCASAcrossConnections() throws {
        let fixture = try MonitorLedgerFixture()
        defer { fixture.cleanup() }
        let first = try fixture.open()
        defer { try? first.close() }
        let operation = try fixture.createActiveOperation(in: first, seed: 400)
        let countBeforeSchedule = try first.events().count
        #expect(monitorLedgerError {
            try first.upsertMonitorDeadline(
                operationID: operation.operationID,
                authority: operation.authority,
                dueAt: fixture.date(10),
                attempt: 0,
                scheduledAt: fixture.date(1),
                replacing: nil,
                idempotencyKey: monitorUUID(409)
            )
        } == .invalidEvent("Monitor deadline predates the current operation claim"))
        #expect(try first.events().count == countBeforeSchedule)
        try first.upsertMonitorDeadline(
            operationID: operation.operationID,
            authority: operation.authority,
            dueAt: fixture.date(10),
            attempt: 0,
            scheduledAt: fixture.date(3),
            replacing: nil,
            idempotencyKey: monitorUUID(410)
        )
        let initial = try #require(first.monitorDeadlines().first)
        let second = try fixture.open(expectedStoreID: first.identity.storeID)
        defer { try? second.close() }

        let firstWinnerKey = monitorUUID(411)
        #expect(try first.upsertMonitorDeadline(
            operationID: operation.operationID,
            authority: operation.authority,
            dueAt: fixture.date(20),
            attempt: 1,
            scheduledAt: fixture.date(4),
            replacing: initial,
            idempotencyKey: firstWinnerKey
        ).disposition == .appended)
        let firstWinner = try #require(second.monitorDeadlines().first)
        let countAfterFirstWinner = try first.events().count
        #expect(monitorLedgerError {
            try second.upsertMonitorDeadline(
                operationID: operation.operationID,
                authority: operation.authority,
                dueAt: fixture.date(30),
                attempt: 2,
                scheduledAt: fixture.date(5),
                replacing: initial,
                idempotencyKey: monitorUUID(412)
            )
        } == .monitorScheduleConflict(operationID: operation.operationID))
        #expect(try first.events().count == countAfterFirstWinner)
        #expect(try first.outbox().count == countAfterFirstWinner)
        #expect(try second.monitorDeadlines() == [firstWinner])
        #expect(try second.upsertMonitorDeadline(
            operationID: operation.operationID,
            authority: operation.authority,
            dueAt: fixture.date(20),
            attempt: 1,
            scheduledAt: fixture.date(4),
            replacing: initial,
            idempotencyKey: firstWinnerKey
        ).disposition == .exactReplay)

        let secondWinnerKey = monitorUUID(413)
        #expect(try second.upsertMonitorDeadline(
            operationID: operation.operationID,
            authority: operation.authority,
            dueAt: fixture.date(40),
            attempt: 3,
            scheduledAt: fixture.date(6),
            replacing: firstWinner,
            idempotencyKey: secondWinnerKey
        ).disposition == .appended)
        let secondWinner = try #require(first.monitorDeadlines().first)
        let countAfterSecondWinner = try first.events().count
        #expect(monitorLedgerError {
            try first.upsertMonitorDeadline(
                operationID: operation.operationID,
                authority: operation.authority,
                dueAt: fixture.date(50),
                attempt: 4,
                scheduledAt: fixture.date(7),
                replacing: firstWinner,
                idempotencyKey: monitorUUID(414)
            )
        } == .monitorScheduleConflict(operationID: operation.operationID))
        #expect(try first.events().count == countAfterSecondWinner)
        #expect(try first.outbox().count == countAfterSecondWinner)
        #expect(try first.monitorDeadlines() == [secondWinner])

        let newerKey = monitorUUID(415)
        try first.upsertMonitorDeadline(
            operationID: operation.operationID,
            authority: operation.authority,
            dueAt: fixture.date(60),
            attempt: 5,
            scheduledAt: fixture.date(8),
            replacing: secondWinner,
            idempotencyKey: newerKey
        )
        let newer = try #require(first.monitorDeadlines().first)
        let countAfterNewer = try first.events().count
        #expect(try second.upsertMonitorDeadline(
            operationID: operation.operationID,
            authority: operation.authority,
            dueAt: fixture.date(20),
            attempt: 1,
            scheduledAt: fixture.date(4),
            replacing: initial,
            idempotencyKey: firstWinnerKey
        ).disposition == .exactReplay)
        #expect(try second.monitorDeadlines() == [newer])
        #expect(try first.events().count == countAfterNewer)
        #expect(try first.outbox().count == countAfterNewer)
        #expect(monitorLedgerError {
            try second.removeMonitorDeadline(
                expected: secondWinner,
                occurredAt: fixture.date(9),
                idempotencyKey: monitorUUID(416)
            )
        } == .monitorScheduleConflict(operationID: operation.operationID))
        #expect(try first.events().count == countAfterNewer)
        #expect(try first.outbox().count == countAfterNewer)
        #expect(try first.monitorDeadlines() == [newer])
        #expect(monitorLedgerError {
            try second.upsertMonitorDeadline(
                operationID: operation.operationID,
                authority: operation.authority,
                dueAt: fixture.date(70),
                attempt: 6,
                scheduledAt: fixture.date(7),
                replacing: newer,
                idempotencyKey: monitorUUID(417)
            )
        } == .invalidEvent(
            "Monitor replacement is not causally after its expected schedule"
        ))
        #expect(try first.events().count == countAfterNewer)
        #expect(try first.outbox().count == countAfterNewer)

        let removeKey = monitorUUID(418)
        #expect(try first.removeMonitorDeadline(
            expected: newer,
            occurredAt: fixture.date(9),
            idempotencyKey: removeKey
        ).disposition == .appended)
        #expect(try second.removeMonitorDeadline(
            expected: newer,
            occurredAt: fixture.date(9),
            idempotencyKey: removeKey
        ).disposition == .exactReplay)
        #expect(try first.monitorDeadlines().isEmpty)
        let auditCount = try first.connection.withLock { database in
            try first.connection.scalarInt64(
                "SELECT COUNT(*) FROM monitor_attempts",
                database: database
            )
        }
        #expect(auditCount == 0)
        #expect(first.verifyHealth().status == .healthy)
    }

    @Test("Terminal evidence removes schedule and releases the effect claim atomically")
    func terminalAttemptReleasesEffects() throws {
        let fixture = try MonitorLedgerFixture()
        defer { fixture.cleanup() }
        let ledger = try fixture.open()
        defer { try? ledger.close() }
        let firstOperation = try fixture.createActiveOperation(in: ledger, seed: 500)
        try ledger.upsertMonitorDeadline(
            operationID: firstOperation.operationID,
            authority: firstOperation.authority,
            dueAt: fixture.date(10),
            attempt: 0,
            scheduledAt: fixture.date(3),
            replacing: nil,
            idempotencyKey: monitorUUID(510)
        )
        let deadline = try #require(ledger.monitorDeadlines().first)

        #expect(try ledger.recordMonitorAttempt(
            expected: deadline,
            attemptedAt: fixture.date(11),
            disposition: .completed,
            nextDueAt: nil,
            idempotencyKey: monitorUUID(511)
        ) == .applied)
        #expect(try ledger.monitorDeadlines().isEmpty)
        #expect(try ledger.projection().operations[firstOperation.operationID]?.record.holdsEffects == false)

        let secondOperation = try fixture.createActiveOperation(in: ledger, seed: 520)
        #expect(try ledger.projection().operations[secondOperation.operationID]?.record.holdsEffects == true)
        #expect(ledger.verifyHealth().status == .healthy)
    }

    @Test("Authority transfer fences the old schedule and explicit tombstones clear schedules")
    func authorityAndTombstoneFencing() throws {
        let fixture = try MonitorLedgerFixture()
        defer { fixture.cleanup() }
        let ledger = try fixture.open()
        defer { try? ledger.close() }
        let operation = try fixture.createActiveOperation(in: ledger, seed: 600)
        try ledger.upsertMonitorDeadline(
            operationID: operation.operationID,
            authority: operation.authority,
            dueAt: fixture.date(10),
            attempt: 0,
            scheduledAt: fixture.date(3),
            replacing: nil,
            idempotencyKey: monitorUUID(610)
        )
        let stale = try #require(ledger.monitorDeadlines().first)
        let newAuthority = RunBrokerAuthority(
            id: .init(rawValue: monitorUUID(611)),
            epoch: .init(rawValue: 2)
        )
        try ledger.append(.init(
            eventID: .init(rawValue: monitorUUID(612)),
            occurredAt: fixture.date(4),
            event: .executionAuthorityTransferred(
                executionID: operation.executionID,
                expectedAuthority: operation.authority,
                newAuthority: newAuthority
            )
        ))
        let recovered = try #require(ledger.monitorDeadlines().first)
        #expect(recovered.operationID == stale.operationID)
        #expect(recovered.authority == newAuthority)
        #expect(recovered.dueAt == stale.dueAt)
        #expect(recovered.recordedAt == stale.recordedAt)
        #expect(recovered.attempt == stale.attempt)
        #expect(recovered.generation == stale.generation)
        let countAfterTransfer = try ledger.events().count
        #expect(monitorLedgerError {
            _ = try ledger.recordMonitorAttempt(
                expected: recovered,
                attemptedAt: fixture.date(3.5),
                disposition: .retryableFailure,
                nextDueAt: fixture.date(20),
                idempotencyKey: monitorUUID(609)
            )
        } == .invalidEvent("Applied monitor evidence predates the current operation claim"))
        #expect(try ledger.events().count == countAfterTransfer)
        #expect(try ledger.recordMonitorAttempt(
            expected: stale,
            attemptedAt: fixture.date(11),
            disposition: .completed,
            nextDueAt: nil,
            idempotencyKey: monitorUUID(613)
        ) == .stale)
        #expect(try ledger.recordMonitorAttempt(
            expected: recovered,
            attemptedAt: fixture.date(11),
            disposition: .retryableFailure,
            nextDueAt: fixture.date(20),
            idempotencyKey: monitorUUID(614)
        ) == .applied)
        try ledger.append(.init(
            eventID: .init(rawValue: monitorUUID(615)),
            occurredAt: fixture.date(12),
            event: .operationTombstoned(
                operationID: operation.operationID,
                authority: newAuthority,
                reason: .administrativelyReleased
            )
        ))
        #expect(try ledger.monitorDeadlines().isEmpty)
    }
}

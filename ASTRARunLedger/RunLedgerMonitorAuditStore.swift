import ASTRACore
import Foundation

/// Append-only monitoring evidence is intentionally separate from the bounded
/// current-state projection. Hot appends never load historical attempts.
enum RunLedgerMonitorAuditStore {
    static func insert(
        _ value: RunLedgerMonitorAttemptProjection,
        connection: RunLedgerSQLiteConnection,
        database: OpaquePointer
    ) throws {
        let next = value.nextDeadline
        let statement = try connection.statement(
            """
            INSERT INTO monitor_attempts (
                event_id, operation_id, expected_authority_id, expected_authority_epoch,
                expected_due_at, expected_recorded_at, expected_attempt, expected_generation,
                attempted_at, disposition, next_due_at, next_recorded_at,
                next_attempt, next_generation,
                apply_disposition, recorded_sequence
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(RunLedgerSchema.uuid(value.eventID.rawValue)),
                .text(RunLedgerSchema.uuid(value.expected.operationID.rawValue)),
                .text(RunLedgerSchema.uuid(value.expected.authority.id.rawValue)),
                .integer(try epoch(value.expected.authority.epoch)),
                .real(value.expected.dueAt.timeIntervalSince1970),
                .real(value.expected.recordedAt.timeIntervalSince1970),
                .integer(try attempt(value.expected.attempt)),
                .text(RunLedgerSchema.uuid(value.expected.generation)),
                .real(value.attemptedAt.timeIntervalSince1970),
                .text(value.disposition.rawValue),
                next.map { .real($0.dueAt.timeIntervalSince1970) } ?? .null,
                next.map { .real($0.recordedAt.timeIntervalSince1970) } ?? .null,
                try next.map { .integer(try attempt($0.attempt)) } ?? .null,
                next.map { .text(RunLedgerSchema.uuid($0.generation)) } ?? .null,
                .text(value.applyDisposition.rawValue),
                .integer(value.recordedSequence),
            ],
            database: database
        )
        defer { statement.finalize() }
        guard try statement.step() == .done else {
            throw RunLedgerError.projectionDrift("Monitor attempt insert returned a row")
        }
    }

    static func load(
        eventID: RunLedgerEventID,
        connection: RunLedgerSQLiteConnection,
        database: OpaquePointer
    ) throws -> RunLedgerMonitorAttemptProjection? {
        let statement = try connection.statement(
            """
            SELECT event_id, operation_id, expected_authority_id, expected_authority_epoch,
                   expected_due_at, expected_recorded_at, expected_attempt, expected_generation,
                   attempted_at, disposition, next_due_at, next_recorded_at,
                   next_attempt, next_generation,
                   apply_disposition, recorded_sequence
            FROM monitor_attempts WHERE event_id = ?
            """,
            bindings: [.text(RunLedgerSchema.uuid(eventID.rawValue))],
            database: database
        )
        defer { statement.finalize() }
        guard try statement.step() == .row else { return nil }
        let result = try decode(statement)
        guard try statement.step() == .done else {
            throw RunLedgerError.projectionDrift("Monitor attempt event ID is not unique")
        }
        return result
    }

    static func verify(
        expected: [RunLedgerEventID: RunLedgerMonitorAttemptProjection],
        connection: RunLedgerSQLiteConnection,
        database: OpaquePointer
    ) throws {
        let count = try connection.scalarInt64(
            "SELECT COUNT(*) FROM monitor_attempts",
            database: database
        ) ?? 0
        guard count == Int64(expected.count) else {
            throw RunLedgerError.projectionDrift(
                "Monitor attempt audit count differs from journal replay"
            )
        }
        for (eventID, record) in expected {
            guard try load(
                eventID: eventID,
                connection: connection,
                database: database
            ) == record else {
                throw RunLedgerError.projectionDrift(
                    "Monitor attempt audit differs from journal replay"
                )
            }
        }
    }

    private static func decode(
        _ statement: RunLedgerSQLiteStatement
    ) throws -> RunLedgerMonitorAttemptProjection {
        let eventID = RunLedgerEventID(
            rawValue: try uuid(statement.text(at: 0), field: "monitor event_id")
        )
        let operationID = RunBrokerOperationID(
            rawValue: try uuid(statement.text(at: 1), field: "monitor operation_id")
        )
        let expected = RunLedgerMonitorDeadline(
            operationID: operationID,
            authority: try authority(
                id: statement.text(at: 2),
                epoch: statement.int64(at: 3)
            ),
            dueAt: Date(timeIntervalSince1970: statement.double(at: 4)),
            recordedAt: Date(timeIntervalSince1970: statement.double(at: 5)),
            attempt: try attempt(statement.int64(at: 6)),
            generation: try uuid(statement.text(at: 7), field: "expected monitor generation")
        )
        guard let disposition = RunLedgerMonitorAttemptDisposition(
            rawValue: try statement.text(at: 9)
        ), let applyDisposition = RunLedgerMonitorAttemptApplyDisposition(
            rawValue: try statement.text(at: 14)
        ) else {
            throw RunLedgerError.projectionDrift("Monitor attempt contains an invalid disposition")
        }
        return .init(
            eventID: eventID,
            expected: expected,
            attemptedAt: Date(timeIntervalSince1970: statement.double(at: 8)),
            disposition: disposition,
            nextDeadline: try nextDeadline(operationID: operationID, statement: statement),
            applyDisposition: applyDisposition,
            recordedSequence: statement.int64(at: 15)
        )
    }

    private static func nextDeadline(
        operationID: RunBrokerOperationID,
        statement: RunLedgerSQLiteStatement
    ) throws -> RunLedgerMonitorDeadline? {
        let nulls = (10...13).map(statement.isNull(at:))
        if nulls.allSatisfy({ $0 }) { return nil }
        guard nulls.allSatisfy({ !$0 }) else {
            throw RunLedgerError.projectionDrift("Monitor next-deadline fields disagree")
        }
        return .init(
            operationID: operationID,
            authority: try authority(id: statement.text(at: 2), epoch: statement.int64(at: 3)),
            dueAt: Date(timeIntervalSince1970: statement.double(at: 10)),
            recordedAt: Date(timeIntervalSince1970: statement.double(at: 11)),
            attempt: try attempt(statement.int64(at: 12)),
            generation: try uuid(statement.text(at: 13), field: "next monitor generation")
        )
    }

    private static func attempt(_ value: Int64) throws -> UInt64 {
        guard value >= 0 else {
            throw RunLedgerError.projectionDrift("Monitor attempt counter is negative")
        }
        return UInt64(value)
    }

    private static func attempt(_ value: UInt64) throws -> Int64 {
        guard value <= UInt64(Int64.max) else {
            throw RunLedgerError.invalidEvent("Monitor attempt exceeds SQLite Int64 bounds")
        }
        return Int64(value)
    }

    private static func authority(id: String, epoch: Int64) throws -> RunBrokerAuthority {
        guard epoch >= 1 else {
            throw RunLedgerError.projectionDrift("Monitor authority epoch is not positive")
        }
        return .init(
            id: .init(rawValue: try uuid(id, field: "monitor authority_id")),
            epoch: .init(rawValue: UInt64(epoch))
        )
    }

    private static func epoch(_ value: RunBrokerAuthorityEpoch) throws -> Int64 {
        guard value.rawValue >= 1, value.rawValue <= UInt64(Int64.max) else {
            throw RunLedgerError.invalidEvent("Monitor authority epoch exceeds SQLite Int64 bounds")
        }
        return Int64(value.rawValue)
    }

    private static func uuid(_ value: String, field: String) throws -> UUID {
        guard let value = UUID(uuidString: value) else {
            throw RunLedgerError.projectionDrift("Projection field \(field) is not a UUID")
        }
        return value
    }
}

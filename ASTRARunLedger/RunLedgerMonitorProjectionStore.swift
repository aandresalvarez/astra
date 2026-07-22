import ASTRACore
import Foundation

enum RunLedgerMonitorProjectionStore {
    static func load(
        connection: RunLedgerSQLiteConnection,
        database: OpaquePointer
    ) throws -> [RunBrokerOperationID: RunLedgerMonitorDeadline] {
        var deadlines: [RunBrokerOperationID: RunLedgerMonitorDeadline] = [:]
        let deadlineStatement = try connection.statement(
            """
            SELECT operation_id, authority_id, authority_epoch,
                   due_at, recorded_at, attempt, generation
            FROM monitor_schedules ORDER BY operation_id
            """,
            database: database
        )
        defer { deadlineStatement.finalize() }
        while try deadlineStatement.step() == .row {
            let operationID = RunBrokerOperationID(
                rawValue: try uuid(deadlineStatement.text(at: 0), field: "monitor operation_id")
            )
            guard deadlines[operationID] == nil else {
                throw RunLedgerError.projectionDrift("Duplicate monitor schedule key")
            }
            deadlines[operationID] = .init(
                operationID: operationID,
                authority: try authority(
                    id: deadlineStatement.text(at: 1),
                    epoch: deadlineStatement.int64(at: 2)
                ),
                dueAt: Date(timeIntervalSince1970: deadlineStatement.double(at: 3)),
                recordedAt: Date(timeIntervalSince1970: deadlineStatement.double(at: 4)),
                attempt: try attempt(deadlineStatement.int64(at: 5)),
                generation: try uuid(deadlineStatement.text(at: 6), field: "monitor generation")
            )
        }

        return deadlines
    }

    static func persist(
        from previous: RunLedgerProjection,
        to next: RunLedgerProjection,
        connection: RunLedgerSQLiteConnection,
        database: OpaquePointer
    ) throws {
        for operationID in previous.monitorDeadlines.keys where next.monitorDeadlines[operationID] == nil {
            let statement = try connection.statement(
                "DELETE FROM monitor_schedules WHERE operation_id = ?",
                bindings: [.text(RunLedgerSchema.uuid(operationID.rawValue))],
                database: database
            )
            defer { statement.finalize() }
            guard try statement.step() == .done,
                  connection.changes(database: database) == 1 else {
                throw RunLedgerError.projectionDrift("Monitor schedule removal affected no row")
            }
        }

        for operationID in next.monitorDeadlines.keys.sorted(by: uuidOrder) {
            guard let deadline = next.monitorDeadlines[operationID],
                  previous.monitorDeadlines[operationID] != deadline else { continue }
            let values: [RunLedgerSQLiteValue] = [
                .text(RunLedgerSchema.uuid(deadline.authority.id.rawValue)),
                .integer(try epoch(deadline.authority.epoch)),
                .real(deadline.dueAt.timeIntervalSince1970),
                .real(deadline.recordedAt.timeIntervalSince1970),
                .integer(try attempt(deadline.attempt)),
                .text(RunLedgerSchema.uuid(deadline.generation)),
            ]
            if previous.monitorDeadlines[operationID] == nil {
                let statement = try connection.statement(
                    """
                    INSERT INTO monitor_schedules (
                        authority_id, authority_epoch, due_at, recorded_at,
                        attempt, generation, operation_id
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    bindings: values + [.text(RunLedgerSchema.uuid(operationID.rawValue))],
                    database: database
                )
                defer { statement.finalize() }
                guard try statement.step() == .done else {
                    throw RunLedgerError.projectionDrift("Monitor schedule insert returned a row")
                }
            } else {
                let statement = try connection.statement(
                    """
                    UPDATE monitor_schedules
                    SET authority_id = ?, authority_epoch = ?, due_at = ?, recorded_at = ?,
                        attempt = ?, generation = ?
                    WHERE operation_id = ?
                    """,
                    bindings: values + [.text(RunLedgerSchema.uuid(operationID.rawValue))],
                    database: database
                )
                defer { statement.finalize() }
                guard try statement.step() == .done,
                      connection.changes(database: database) == 1 else {
                    throw RunLedgerError.projectionDrift("Monitor schedule update affected no row")
                }
            }
        }
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

    private static func uuidOrder(_ lhs: RunBrokerOperationID, _ rhs: RunBrokerOperationID) -> Bool {
        RunLedgerSchema.uuid(lhs.rawValue) < RunLedgerSchema.uuid(rhs.rawValue)
    }

}

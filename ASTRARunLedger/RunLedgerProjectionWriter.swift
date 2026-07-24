import ASTRACore
import Foundation

/// Transactional projection writes. Read-side decoding remains isolated in
/// `RunLedgerProjectionStore` so projection ownership is explicit and testable.
enum RunLedgerProjectionWriter {
    static func persist(
        from previous: RunLedgerProjection,
        to next: RunLedgerProjection,
        connection: RunLedgerSQLiteConnection,
        database: OpaquePointer
    ) throws {
        guard Set(previous.executions.keys).isSubset(of: next.executions.keys),
              Set(previous.operations.keys).isSubset(of: next.operations.keys) else {
            throw RunLedgerError.projectionDrift("Projector attempted to delete durable state")
        }

        for executionID in next.executions.keys.sorted(by: uuidOrder) {
            guard let value = next.executions[executionID] else { continue }
            if let old = previous.executions[executionID] {
                guard old.manifest == value.manifest,
                      old.createdSequence == value.createdSequence else {
                    throw RunLedgerError.projectionDrift("Projector mutated immutable execution truth")
                }
                guard old != value else { continue }
                let statement = try connection.statement(
                    """
                    UPDATE executions
                    SET authority_id = ?, authority_epoch = ?,
                        desired_execution = ?, observed_execution = ?,
                        desired_cancellation = ?, observed_cancellation = ?,
                        updated_at = ?, updated_sequence = ?
                    WHERE execution_id = ?
                    """,
                    bindings: try executionUpdateBindings(executionID: executionID, value: value),
                    database: database
                )
                defer { statement.finalize() }
                guard try statement.step() == .done,
                      connection.changes(database: database) == 1 else {
                    throw RunLedgerError.projectionDrift("Execution projection update affected no row")
                }
            } else {
                let statement = try connection.statement(
                    """
                    INSERT INTO executions (
                        execution_id, manifest, authority_id, authority_epoch,
                        desired_execution, observed_execution,
                        desired_cancellation, observed_cancellation,
                        updated_at, created_sequence, updated_sequence
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    bindings: try executionInsertBindings(executionID: executionID, value: value),
                    database: database
                )
                defer { statement.finalize() }
                guard try statement.step() == .done else {
                    throw RunLedgerError.projectionDrift("Execution projection insert returned a row")
                }
            }
        }

        for operationID in next.operations.keys.sorted(by: uuidOrder) {
            guard let value = next.operations[operationID] else { continue }
            if let old = previous.operations[operationID] {
                guard old.record.storeID == value.record.storeID,
                      old.record.operationID == value.record.operationID,
                      old.record.executionID == value.record.executionID,
                      old.record.effects == value.record.effects,
                      old.record.createdAt == value.record.createdAt,
                      old.createdSequence == value.createdSequence else {
                    throw RunLedgerError.projectionDrift("Projector mutated immutable operation truth")
                }
                guard old != value else { continue }
                let state = claimStateBindings(value.record.state)
                let statement = try connection.statement(
                    """
                    UPDATE operation_claims
                    SET authority_id = ?, authority_epoch = ?,
                        claim_state = ?, tombstone_reason = ?, tombstone_recorded_at = ?,
                        updated_at = ?, updated_sequence = ?
                    WHERE operation_id = ?
                    """,
                    bindings: [
                        .text(RunLedgerSchema.uuid(value.record.authority.id.rawValue)),
                        .integer(try epoch(value.record.authority.epoch)),
                        state.name,
                        state.reason,
                        state.recordedAt,
                        .real(value.record.updatedAt.timeIntervalSince1970),
                        .integer(value.updatedSequence),
                        .text(RunLedgerSchema.uuid(operationID.rawValue)),
                    ],
                    database: database
                )
                defer { statement.finalize() }
                guard try statement.step() == .done,
                      connection.changes(database: database) == 1 else {
                    throw RunLedgerError.projectionDrift("Operation projection update affected no row")
                }
            } else {
                try insertOperation(
                    operationID: operationID,
                    value: value,
                    connection: connection,
                    database: database
                )
            }
        }

        try RunLedgerMonitorProjectionStore.persist(
            from: previous,
            to: next,
            connection: connection,
            database: database
        )
    }

    private static func insertOperation(
        operationID: RunBrokerOperationID,
        value: RunLedgerOperationProjection,
        connection: RunLedgerSQLiteConnection,
        database: OpaquePointer
    ) throws {
        let state = claimStateBindings(value.record.state)
        let effectsData = try RunLedgerCodec.encode(value.record.effects)
        let statement = try connection.statement(
            """
            INSERT INTO operation_claims (
                operation_id, store_id, execution_id, authority_id, authority_epoch,
                effects, claim_state, tombstone_reason, tombstone_recorded_at,
                created_at, updated_at, created_sequence, updated_sequence
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(RunLedgerSchema.uuid(operationID.rawValue)),
                .text(RunLedgerSchema.uuid(value.record.storeID.rawValue)),
                .text(RunLedgerSchema.uuid(value.record.executionID.rawValue)),
                .text(RunLedgerSchema.uuid(value.record.authority.id.rawValue)),
                .integer(try epoch(value.record.authority.epoch)),
                .blob(effectsData),
                state.name,
                state.reason,
                state.recordedAt,
                .real(value.record.createdAt.timeIntervalSince1970),
                .real(value.record.updatedAt.timeIntervalSince1970),
                .integer(value.createdSequence),
                .integer(value.updatedSequence),
            ],
            database: database
        )
        defer { statement.finalize() }
        guard try statement.step() == .done else {
            throw RunLedgerError.projectionDrift("Operation projection insert returned a row")
        }

        for (index, effect) in value.record.effects.enumerated() {
            let effectStatement = try connection.statement(
                """
                INSERT INTO effect_claims (operation_id, effect_index, scope, access)
                VALUES (?, ?, ?, ?)
                """,
                bindings: [
                    .text(RunLedgerSchema.uuid(operationID.rawValue)),
                    .integer(Int64(index)),
                    .blob(try RunLedgerCodec.encode(effect.scope)),
                    .text(effect.access.rawValue),
                ],
                database: database
            )
            defer { effectStatement.finalize() }
            guard try effectStatement.step() == .done else {
                throw RunLedgerError.projectionDrift("Effect projection insert returned a row")
            }
        }
    }

    private static func executionInsertBindings(
        executionID: RunBrokerExecutionID,
        value: RunLedgerExecutionProjection
    ) throws -> [RunLedgerSQLiteValue] {
        [
            .text(RunLedgerSchema.uuid(executionID.rawValue)),
            .blob(try RunLedgerCodec.encode(value.manifest)),
            .text(RunLedgerSchema.uuid(value.authority.id.rawValue)),
            .integer(try epoch(value.authority.epoch)),
            .text(value.control.desiredExecution.rawValue),
            .text(value.control.observedExecution.rawValue),
            .text(value.control.desiredCancellation.rawValue),
            .text(value.control.observedCancellation.rawValue),
            .real(value.updatedAt.timeIntervalSince1970),
            .integer(value.createdSequence),
            .integer(value.updatedSequence),
        ]
    }

    private static func executionUpdateBindings(
        executionID: RunBrokerExecutionID,
        value: RunLedgerExecutionProjection
    ) throws -> [RunLedgerSQLiteValue] {
        [
            .text(RunLedgerSchema.uuid(value.authority.id.rawValue)),
            .integer(try epoch(value.authority.epoch)),
            .text(value.control.desiredExecution.rawValue),
            .text(value.control.observedExecution.rawValue),
            .text(value.control.desiredCancellation.rawValue),
            .text(value.control.observedCancellation.rawValue),
            .real(value.updatedAt.timeIntervalSince1970),
            .integer(value.updatedSequence),
            .text(RunLedgerSchema.uuid(executionID.rawValue)),
        ]
    }

    private static func epoch(_ value: RunBrokerAuthorityEpoch) throws -> Int64 {
        guard value.rawValue >= 1, value.rawValue <= UInt64(Int64.max) else {
            throw RunLedgerError.invalidEvent("Authority epoch is outside SQLite's positive Int64 range")
        }
        return Int64(value.rawValue)
    }

    private static func claimStateBindings(
        _ state: DurableExecutionClaimState
    ) -> (name: RunLedgerSQLiteValue, reason: RunLedgerSQLiteValue, recordedAt: RunLedgerSQLiteValue) {
        switch state {
        case .active:
            return (.text("active"), .null, .null)
        case .tombstoned(let tombstone):
            return (
                .text("tombstoned"),
                .text(tombstone.reason.rawValue),
                .real(tombstone.recordedAt.timeIntervalSince1970)
            )
        }
    }

    private static func uuidOrder<ID: RawRepresentable>(_ lhs: ID, _ rhs: ID) -> Bool
        where ID.RawValue == UUID {
        RunLedgerSchema.uuid(lhs.rawValue) < RunLedgerSchema.uuid(rhs.rawValue)
    }
}

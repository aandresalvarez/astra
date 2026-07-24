import Foundation

extension RunLedger {
    public func verifyHealth() -> RunLedgerHealthReport {
        do {
            let lastSequence = try connection.withLock { database in
                try assertIntegrity(database: database)
            }
            return .init(
                status: .healthy,
                identity: identity,
                lastEventSequence: lastSequence
            )
        } catch {
            let report = Self.healthReport(for: RunLedgerSchema.classify(error))
            return .init(
                status: report.status,
                identity: identity,
                lastEventSequence: report.lastEventSequence,
                detail: report.detail
            )
        }
    }

    func assertIntegrity(database: OpaquePointer) throws -> Int64 {
        guard try connection.scalarText("PRAGMA quick_check", database: database) == "ok" else {
            throw RunLedgerError.corrupt("SQLite quick_check failed")
        }
        let foreignKeyCheck = try connection.statement("PRAGMA foreign_key_check", database: database)
        defer { foreignKeyCheck.finalize() }
        guard try foreignKeyCheck.step() == .done else {
            throw RunLedgerError.corrupt("SQLite foreign_key_check found a violation")
        }
        try verifySchemaObjects(database: database)

        let current = try RunLedgerProjectionStore.load(
            connection: connection,
            database: database
        )
        let replayed = try replayState(database: database)
        guard current == replayed.projection else {
            throw RunLedgerError.projectionDrift("Current-state projection differs from journal replay")
        }
        try RunLedgerMonitorAuditStore.verify(
            expected: replayed.monitorAudits,
            connection: connection,
            database: database
        )
        let eventCount = try connection.scalarInt64("SELECT COUNT(*) FROM events", database: database) ?? 0
        let outboxCount = try connection.scalarInt64("SELECT COUNT(*) FROM outbox", database: database) ?? 0
        guard eventCount == outboxCount else {
            throw RunLedgerError.projectionDrift("Every event must have exactly one outbox message")
        }
        let mismatchCount = try connection.scalarInt64(
            """
            SELECT COUNT(*) FROM events e
            LEFT JOIN outbox o ON o.sequence = e.sequence
            WHERE o.sequence IS NULL OR o.message_id != e.event_id OR o.event_kind != e.event_kind
               OR o.payload != e.payload OR o.occurred_at != e.occurred_at
            """,
            database: database
        ) ?? 0
        guard mismatchCount == 0 else {
            throw RunLedgerError.projectionDrift("Outbox rows differ from their journal events")
        }
        let typedOutbox = try connection.statement(
            """
            SELECT event_kind, projection_schema_version, projection_payload, projection_sha256,
                   execution_id, supervisor_sequence, stream_channel,
                   stream_ends_logical_line, stream_fragment_byte_count,
                   stream_fragment_truncated, has_terminal
            FROM outbox ORDER BY sequence
            """,
            database: database
        )
        defer { typedOutbox.finalize() }
        while try typedOutbox.step() == .row {
            guard typedOutbox.int64(at: 1)
                    == Int64(RunLedgerPersistedOutboxProjection.currentSchemaVersion) else {
                throw RunLedgerError.projectionDrift("Unsupported stored outbox projection schema")
            }
            let projection = try RunLedgerOutboxProjectionCodec.decode(
                payload: try typedOutbox.blob(at: 2),
                sha256: try typedOutbox.blob(at: 3)
            )
            try Self.validateOutboxMetadata(
                projection: projection,
                eventKind: try typedOutbox.text(at: 0),
                executionID: try typedOutbox.optionalText(at: 4),
                supervisorSequence: typedOutbox.isNull(at: 5) ? nil : typedOutbox.int64(at: 5),
                streamChannel: try typedOutbox.optionalText(at: 6),
                streamEndsLogicalLine: typedOutbox.isNull(at: 7) ? nil : typedOutbox.int64(at: 7),
                streamFragmentByteCount: typedOutbox.isNull(at: 8) ? nil : typedOutbox.int64(at: 8),
                streamFragmentTruncated: typedOutbox.isNull(at: 9) ? nil : typedOutbox.int64(at: 9),
                hasTerminal: typedOutbox.int64(at: 10)
            )
        }
        let acknowledgement = try outboxAcknowledgement(database: database)
        if acknowledgement > 0 {
            guard try connection.scalarInt64(
                "SELECT 1 FROM outbox WHERE sequence = ?",
                bindings: [.integer(acknowledgement)],
                database: database
            ) == 1 else {
                throw RunLedgerError.projectionDrift("Outbox acknowledgement references no message")
            }
        }
        return try connection.scalarInt64("SELECT MAX(sequence) FROM events", database: database) ?? 0
    }

    private func verifySchemaObjects(database: OpaquePointer) throws {
        let expectedTables: Set<String> = [
            "ledger_metadata", "events", "executions", "operation_claims",
            "effect_claims", "monitor_schedules", "monitor_attempts",
            "outbox", "outbox_state", "consumer_checkpoints",
        ]
        let expectedTriggers: Set<String> = [
            "ledger_metadata_no_update", "ledger_metadata_no_delete",
            "events_no_update", "events_no_delete",
            "executions_no_delete", "executions_immutable",
            "operation_claims_no_delete", "operation_claims_immutable",
            "effect_claims_no_update", "effect_claims_no_delete",
            "monitor_attempts_no_update", "monitor_attempts_no_delete",
            "outbox_no_update", "outbox_no_delete",
            "outbox_state_no_delete", "outbox_state_monotonic",
            "consumer_checkpoints_no_delete", "consumer_checkpoint_initial",
            "consumer_checkpoint_monotonic",
        ]
        let statement = try connection.statement(
            """
            SELECT type, name FROM sqlite_master
            WHERE type IN ('table', 'trigger') AND name NOT LIKE 'sqlite_%'
            """,
            database: database
        )
        defer { statement.finalize() }
        var tables: Set<String> = []
        var triggers: Set<String> = []
        while try statement.step() == .row {
            let type = try statement.text(at: 0)
            let name = try statement.text(at: 1)
            if type == "table" { tables.insert(name) }
            if type == "trigger" { triggers.insert(name) }
        }
        guard tables == expectedTables, triggers == expectedTriggers else {
            throw RunLedgerError.incompatibleSchema(
                expected: RunLedgerSchema.version,
                found: identity.schemaVersion
            )
        }
        try verifyOutboxIndexes(database: database)
    }

    private func verifyOutboxIndexes(database: OpaquePointer) throws {
        let expected: [String: [RunLedgerExpectedIndexColumn]] = [
            "outbox_execution_supervisor": [
                .init(name: "execution_id", descending: false),
                .init(name: "supervisor_sequence", descending: false),
            ],
            "outbox_execution_stream": [
                .init(name: "execution_id", descending: false),
                .init(name: "stream_channel", descending: false),
                .init(name: "sequence", descending: true),
            ],
            "outbox_execution_terminal": [
                .init(name: "execution_id", descending: false),
                .init(name: "has_terminal", descending: false),
                .init(name: "sequence", descending: true),
            ],
        ]
        let statement = try connection.statement(
            "PRAGMA index_list('outbox')",
            database: database
        )
        defer { statement.finalize() }
        var found: Set<String> = []
        while try statement.step() == .row {
            let name = try statement.text(at: 1)
            let origin = try statement.text(at: 3)
            guard origin == "c" else { continue }
            guard let columns = expected[name],
                  statement.int64(at: 2) == 0,
                  statement.int64(at: 4) == 0 else {
                throw RunLedgerError.incompatibleSchema(
                    expected: RunLedgerSchema.version,
                    found: identity.schemaVersion
                )
            }
            try verifyOutboxIndex(name, expected: columns, database: database)
            found.insert(name)
        }
        guard found == Set(expected.keys) else {
            throw RunLedgerError.incompatibleSchema(
                expected: RunLedgerSchema.version,
                found: identity.schemaVersion
            )
        }
    }

    private func verifyOutboxIndex(
        _ name: String,
        expected: [RunLedgerExpectedIndexColumn],
        database: OpaquePointer
    ) throws {
        // `name` has already been proven to be one of the hard-coded expected
        // identifiers above, so interpolating it into this PRAGMA is safe.
        let statement = try connection.statement(
            "PRAGMA index_xinfo(\(name))",
            database: database
        )
        defer { statement.finalize() }
        var actual: [RunLedgerExpectedIndexColumn] = []
        while try statement.step() == .row {
            guard statement.int64(at: 5) == 1 else { continue }
            actual.append(.init(
                name: try statement.text(at: 2),
                descending: statement.int64(at: 3) == 1,
                collation: try statement.text(at: 4)
            ))
        }
        guard actual == expected else {
            throw RunLedgerError.incompatibleSchema(
                expected: RunLedgerSchema.version,
                found: identity.schemaVersion
            )
        }
    }

    static func healthReport(for error: RunLedgerError) -> RunLedgerHealthReport {
        let status: RunLedgerHealthStatus
        switch error {
        case .missingLedger:
            status = .missing
        case .incompatibleSchema, .applicationIdentityMismatch:
            status = .incompatibleSchema
        case .storeIdentityMismatch, .installationIdentityMismatch:
            status = .identityMismatch
        case .unsafeStorage:
            status = .unsafeStorage
        case .corrupt:
            status = .corrupt
        case .projectionDrift:
            status = .projectionDrift
        default:
            status = .unavailable
        }
        return .init(status: status, detail: String(describing: error))
    }
}

private struct RunLedgerExpectedIndexColumn: Equatable {
    let name: String
    let descending: Bool
    let collation: String

    init(name: String, descending: Bool, collation: String = "BINARY") {
        self.name = name
        self.descending = descending
        self.collation = collation
    }
}

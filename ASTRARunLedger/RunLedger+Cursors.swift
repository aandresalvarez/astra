import Foundation

extension RunLedger {
    public func outboxAcknowledgedThrough() throws -> Int64 {
        try connection.withLock { database in
            try outboxAcknowledgement(database: database)
        }
    }

    public func outbox(
        after sequence: Int64 = 0,
        limit: Int = 1_000
    ) throws -> [RunLedgerOutboxMessage] {
        guard sequence >= 0 else {
            throw RunLedgerError.invalidEvent("Outbox cursor cannot be negative")
        }
        let safeLimit = max(1, min(limit, 10_000))
        return try connection.withLock { database in
            let acknowledged = try outboxAcknowledgement(database: database)
            let statement = try connection.statement(
                """
                SELECT sequence, message_id, event_kind, payload, occurred_at,
                       projection_schema_version, projection_payload, projection_sha256,
                       execution_id, supervisor_sequence, stream_channel,
                       stream_ends_logical_line, stream_fragment_byte_count,
                       stream_fragment_truncated, has_terminal
                FROM outbox WHERE sequence > ? ORDER BY sequence LIMIT ?
                """,
                bindings: [.integer(sequence), .integer(Int64(safeLimit))],
                database: database
            )
            defer { statement.finalize() }
            var messages: [RunLedgerOutboxMessage] = []
            while try statement.step() == .row {
                let messageID = RunLedgerEventID(
                    rawValue: try uuid(try statement.text(at: 1), field: "outbox.message_id")
                )
                let messageSequence = statement.int64(at: 0)
                guard statement.int64(at: 5)
                        == Int64(RunLedgerPersistedOutboxProjection.currentSchemaVersion) else {
                    throw RunLedgerError.projectionDrift("Unsupported stored outbox projection schema")
                }
                let projection = try RunLedgerOutboxProjectionCodec.decode(
                    payload: try statement.blob(at: 6),
                    sha256: try statement.blob(at: 7)
                )
                try Self.validateOutboxMetadata(
                    projection: projection,
                    eventKind: try statement.text(at: 2),
                    executionID: try statement.optionalText(at: 8),
                    supervisorSequence: statement.isNull(at: 9) ? nil : statement.int64(at: 9),
                    streamChannel: try statement.optionalText(at: 10),
                    streamEndsLogicalLine: statement.isNull(at: 11) ? nil : statement.int64(at: 11),
                    streamFragmentByteCount: statement.isNull(at: 12) ? nil : statement.int64(at: 12),
                    streamFragmentTruncated: statement.isNull(at: 13) ? nil : statement.int64(at: 13),
                    hasTerminal: statement.int64(at: 14)
                )
                messages.append(.init(
                    sequence: messageSequence,
                    messageID: messageID,
                    eventKind: try statement.text(at: 2),
                    payload: try statement.blob(at: 3),
                    occurredAt: Date(timeIntervalSince1970: statement.double(at: 4)),
                    isAcknowledged: messageSequence <= acknowledged,
                    projection: projection
                ))
            }
            return messages
        }
    }

    /// Reads the immutable durable head without walking the backlog. The
    /// recursive connection lock keeps the MAX lookup and exact row decode in
    /// one serialized view while reusing the strict outbox decoder above.
    public func outboxHead() throws -> RunLedgerOutboxMessage? {
        try connection.withLock { database in
            guard let maximum = try connection.scalarInt64(
                "SELECT MAX(sequence) FROM outbox",
                database: database
            ) else { return nil }
            guard maximum > 0 else {
                throw RunLedgerError.projectionDrift("Outbox head sequence is invalid")
            }
            guard let head = try outbox(after: maximum - 1, limit: 1).first,
                  head.sequence == maximum else {
                throw RunLedgerError.projectionDrift("Outbox head row is missing")
            }
            return head
        }
    }

    static func validateOutboxMetadata(
        projection: RunLedgerOutboxProjectionV1,
        eventKind: String,
        executionID: String?,
        supervisorSequence: Int64?,
        streamChannel: String?,
        streamEndsLogicalLine: Int64?,
        streamFragmentByteCount: Int64?,
        streamFragmentTruncated: Int64?,
        hasTerminal: Int64
    ) throws {
        let expectedExecutionID = projection.executionID.map {
            RunLedgerSchema.uuid($0.rawValue)
        }
        let expectedSupervisorSequence = projection.supervisorSequence.flatMap(Int64.init(exactly:))
        let stream = projection.stream
        guard projection.matches(eventKind: eventKind),
              executionID == expectedExecutionID,
              supervisorSequence == expectedSupervisorSequence,
              streamChannel == stream?.channel.rawValue,
              streamEndsLogicalLine == stream.map({ $0.endsLogicalLine ? 1 : 0 }),
              streamFragmentByteCount == stream.map({ Int64($0.trailingFragmentByteCount) }),
              streamFragmentTruncated == stream.map({ $0.fragmentTruncated ? 1 : 0 }),
              hasTerminal == (projection.hasTerminalEvidence ? 1 : 0) else {
            throw RunLedgerError.projectionDrift("Stored outbox projection metadata mismatch")
        }
    }

    /// Acknowledges exactly the next message. Single-step advancement is
    /// intentionally conservative: consumers must durably process each message
    /// before the ledger will expose progress past it.
    @discardableResult
    public func acknowledgeOutbox(
        sequence requested: Int64,
        messageID requestedMessageID: RunLedgerEventID
    ) throws -> RunLedgerCursorDisposition {
        try connection.withLock { database in
            try connection.withImmediateTransaction(database: database) {
                let current = try outboxAcknowledgement(database: database)
                if requested == current, current > 0 {
                    let currentMessageID = try outboxMessageID(
                        sequence: current,
                        database: database
                    )
                    guard currentMessageID == requestedMessageID else {
                        throw RunLedgerError.outboxMessageIdentityMismatch(
                            sequence: requested,
                            expected: currentMessageID,
                            requested: requestedMessageID
                        )
                    }
                    return .idempotent
                }
                guard requested > current else {
                    throw RunLedgerError.outboxAcknowledgementWouldRegress(
                        current: current,
                        requested: requested
                    )
                }
                let next = try nextOutboxMessage(after: current, database: database)
                guard requested == next?.sequence else {
                    throw RunLedgerError.outboxAcknowledgementWouldSkip(
                        current: current,
                        requested: requested,
                        next: next?.sequence
                    )
                }
                guard let next, next.messageID == requestedMessageID else {
                    throw RunLedgerError.outboxMessageIdentityMismatch(
                        sequence: requested,
                        expected: next?.messageID ?? requestedMessageID,
                        requested: requestedMessageID
                    )
                }
                let statement = try connection.statement(
                    """
                    UPDATE outbox_state SET last_acknowledged_sequence = ? WHERE singleton_id = 1
                    """,
                    bindings: [.integer(requested)],
                    database: database
                )
                defer { statement.finalize() }
                guard try statement.step() == .done,
                      connection.changes(database: database) == 1 else {
                    throw RunLedgerError.projectionDrift("Outbox acknowledgement row is missing")
                }
                return .applied
            }
        }
    }

    public func checkpoint(for consumerID: RunLedgerConsumerID) throws -> Int64 {
        try connection.withLock { database in
            try connection.scalarInt64(
                "SELECT event_sequence FROM consumer_checkpoints WHERE consumer_id = ?",
                bindings: [.text(consumerID.rawValue)],
                database: database
            ) ?? 0
        }
    }

    /// Advances exactly one durable journal event. Batch skipping is forbidden
    /// so a consumer cannot checkpoint work it has not individually observed.
    @discardableResult
    public func advanceCheckpoint(
        for consumerID: RunLedgerConsumerID,
        through requested: Int64
    ) throws -> RunLedgerCursorDisposition {
        try connection.withLock { database in
            try connection.withImmediateTransaction(database: database) {
                let current = try connection.scalarInt64(
                    "SELECT event_sequence FROM consumer_checkpoints WHERE consumer_id = ?",
                    bindings: [.text(consumerID.rawValue)],
                    database: database
                ) ?? 0
                if requested == current { return .idempotent }
                guard requested > current else {
                    throw RunLedgerError.checkpointWouldRegress(
                        current: current,
                        requested: requested
                    )
                }
                let next = try connection.scalarInt64(
                    "SELECT MIN(sequence) FROM events WHERE sequence > ?",
                    bindings: [.integer(current)],
                    database: database
                )
                guard requested == next else {
                    throw RunLedgerError.checkpointWouldSkip(
                        current: current,
                        requested: requested,
                        next: next
                    )
                }
                let existing = current > 0
                let sql = existing
                    ? "UPDATE consumer_checkpoints SET event_sequence = ? WHERE consumer_id = ?"
                    : "INSERT INTO consumer_checkpoints (event_sequence, consumer_id) VALUES (?, ?)"
                let statement = try connection.statement(
                    sql,
                    bindings: [.integer(requested), .text(consumerID.rawValue)],
                    database: database
                )
                defer { statement.finalize() }
                guard try statement.step() == .done,
                      connection.changes(database: database) == 1 else {
                    throw RunLedgerError.projectionDrift("Consumer checkpoint write affected no row")
                }
                return .applied
            }
        }
    }

    func outboxAcknowledgement(database: OpaquePointer) throws -> Int64 {
        guard let value = try connection.scalarInt64(
            "SELECT last_acknowledged_sequence FROM outbox_state WHERE singleton_id = 1",
            database: database
        ) else {
            throw RunLedgerError.projectionDrift("Outbox acknowledgement state is missing")
        }
        return value
    }

    private func nextOutboxMessage(
        after sequence: Int64,
        database: OpaquePointer
    ) throws -> (sequence: Int64, messageID: RunLedgerEventID)? {
        let statement = try connection.statement(
            """
            SELECT sequence, message_id FROM outbox
            WHERE sequence > ? ORDER BY sequence LIMIT 1
            """,
            bindings: [.integer(sequence)],
            database: database
        )
        defer { statement.finalize() }
        guard try statement.step() == .row else { return nil }
        let result = (
            sequence: statement.int64(at: 0),
            messageID: RunLedgerEventID(
                rawValue: try uuid(try statement.text(at: 1), field: "outbox.message_id")
            )
        )
        guard try statement.step() == .done else {
            throw RunLedgerError.projectionDrift("Outbox sequence is not unique")
        }
        return result
    }

    private func outboxMessageID(
        sequence: Int64,
        database: OpaquePointer
    ) throws -> RunLedgerEventID {
        guard let value = try connection.scalarText(
            "SELECT message_id FROM outbox WHERE sequence = ?",
            bindings: [.integer(sequence)],
            database: database
        ) else {
            throw RunLedgerError.projectionDrift("Acknowledged outbox message is missing")
        }
        return .init(rawValue: try uuid(value, field: "outbox.message_id"))
    }
}

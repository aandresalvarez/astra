import ASTRACore
import Foundation

public final class RunLedger: @unchecked Sendable {
    public let identity: RunLedgerIdentity

    let configuration: RunLedgerConfiguration
    let connection: RunLedgerSQLiteConnection

    public convenience init(configuration: RunLedgerConfiguration) throws {
        try self.init(
            configuration: configuration,
            createIfMissing: true,
            initializationCrashPoint: nil,
            migrationCrashPoint: nil
        )
    }

    @_spi(RunLedgerTesting)
    public convenience init(
        configuration: RunLedgerConfiguration,
        crashingInitializationAt crashPoint: RunLedgerInitializationCrashPoint
    ) throws {
        try self.init(
            configuration: configuration,
            createIfMissing: true,
            initializationCrashPoint: crashPoint,
            migrationCrashPoint: nil
        )
    }

    @_spi(RunLedgerTesting)
    public convenience init(
        configuration: RunLedgerConfiguration,
        crashingMigrationAt crashPoint: RunLedgerMigrationCrashPoint
    ) throws {
        try self.init(
            configuration: configuration,
            createIfMissing: true,
            initializationCrashPoint: nil,
            migrationCrashPoint: crashPoint
        )
    }

    private init(
        configuration: RunLedgerConfiguration,
        createIfMissing: Bool,
        initializationCrashPoint: RunLedgerInitializationCrashPoint?,
        migrationCrashPoint: RunLedgerMigrationCrashPoint?
    ) throws {
        let opened = try RunLedgerSchema.open(
            configuration: configuration,
            createIfMissing: createIfMissing,
            initializationCrashPoint: initializationCrashPoint,
            migrationCrashPoint: migrationCrashPoint
        )
        self.configuration = configuration
        connection = opened.0
        identity = opened.1
        do {
            try connection.withLock { database in
                _ = try assertIntegrity(database: database)
            }
        } catch {
            try? connection.close()
            throw RunLedgerSchema.classify(error)
        }
    }

    public static func inspect(_ configuration: RunLedgerConfiguration) -> RunLedgerHealthReport {
        do {
            let ledger = try RunLedger(
                configuration: configuration,
                createIfMissing: false,
                initializationCrashPoint: nil,
                migrationCrashPoint: nil
            )
            let report = ledger.verifyHealth()
            try? ledger.close()
            return report
        } catch {
            return healthReport(for: RunLedgerSchema.classify(error))
        }
    }

    public func close() throws {
        try connection.close()
    }

    /// Exact idempotency preflight used before external launch preparation.
    /// It lets callers reject a reused event ID before creating capabilities
    /// or spawning a process; `append` remains the authoritative CAS.
    public func event(eventID: RunLedgerEventID) throws -> StoredRunLedgerEvent? {
        try connection.withLock { database in
            guard let existing = try existingEvent(eventID: eventID, database: database) else {
                return nil
            }
            let envelope = try RunLedgerCodec.envelope(eventID: eventID, from: existing.payload)
            guard envelope.event.kind == existing.eventKind,
                  envelope.event.aggregateKind == existing.aggregateKind,
                  envelope.event.aggregateID == existing.aggregateID else {
                throw RunLedgerError.corrupt("Event index columns do not match canonical payload")
            }
            return .init(sequence: existing.sequence, envelope: envelope)
        }
    }

    /// Runs the exact event-id and pure projection checks used by `append`
    /// without changing SQLite or the outbox. Effect owners use this before
    /// preparing immutable capabilities so a rejected domain event cannot leave
    /// orphaned external state. `append` remains the authoritative transaction.
    func preflightAppend(_ envelope: RunLedgerEventEnvelope) throws -> RunLedgerAppendResult {
        let (canonicalEnvelope, payload) = try RunLedgerCodec.canonicalize(envelope)
        return try connection.withLock { database in
            if let existing = try existingEvent(
                eventID: canonicalEnvelope.eventID,
                database: database
            ) {
                guard existing.payload == payload,
                      existing.eventKind == canonicalEnvelope.event.kind,
                      existing.aggregateKind == canonicalEnvelope.event.aggregateKind,
                      existing.aggregateID == canonicalEnvelope.event.aggregateID else {
                    throw RunLedgerError.eventIDReuse(canonicalEnvelope.eventID)
                }
                return .init(sequence: existing.sequence, disposition: .exactReplay)
            }

            let previous = try RunLedgerProjectionStore.load(
                connection: connection,
                database: database
            )
            let last = try connection.scalarInt64(
                "SELECT COALESCE(MAX(sequence), 0) FROM events",
                database: database
            ) ?? 0
            guard last < Int64.max else {
                throw RunLedgerError.corrupt("Event sequence is exhausted")
            }
            let sequence = last + 1
            _ = try RunLedgerProjector.reduce(
                previous,
                storedEvent: .init(sequence: sequence, envelope: canonicalEnvelope),
                storeID: identity.storeID
            )
            return .init(sequence: sequence, disposition: .appended)
        }
    }

    @discardableResult
    public func append(_ envelope: RunLedgerEventEnvelope) throws -> RunLedgerAppendResult {
        let (canonicalEnvelope, payload) = try RunLedgerCodec.canonicalize(envelope)
        let result: RunLedgerAppendResult = try connection.withLock { database in
            try connection.withImmediateTransaction(database: database) {
                if let existing = try existingEvent(
                    eventID: canonicalEnvelope.eventID,
                    database: database
                ) {
                    guard existing.payload == payload,
                          existing.eventKind == canonicalEnvelope.event.kind,
                          existing.aggregateKind == canonicalEnvelope.event.aggregateKind,
                          existing.aggregateID == canonicalEnvelope.event.aggregateID else {
                        throw RunLedgerError.eventIDReuse(canonicalEnvelope.eventID)
                    }
                    try verifyOutboxMaterialization(
                        sequence: existing.sequence,
                        envelope: canonicalEnvelope,
                        payload: payload,
                        database: database
                    )
                    try RunLedgerStorageSecurity.secureArtifacts(at: configuration.databaseURL)
                    return RunLedgerAppendResult(
                        sequence: existing.sequence,
                        disposition: .exactReplay
                    )
                }

                let previous = try RunLedgerProjectionStore.load(
                    connection: connection,
                    database: database
                )
                let insert = try connection.statement(
                    """
                    INSERT INTO events (
                        event_id, event_kind, aggregate_kind, aggregate_id, payload, occurred_at
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    bindings: [
                        .text(RunLedgerSchema.uuid(canonicalEnvelope.eventID.rawValue)),
                        .text(canonicalEnvelope.event.kind),
                        .text(canonicalEnvelope.event.aggregateKind),
                        .text(canonicalEnvelope.event.aggregateID),
                        .blob(payload),
                        .real(canonicalEnvelope.occurredAt.timeIntervalSince1970),
                    ],
                    database: database
                )
                defer { insert.finalize() }
                guard try insert.step() == .done else {
                    throw RunLedgerError.corrupt("Event insert returned a row")
                }
                let sequence = connection.lastInsertRowID(database: database)
                let storedEvent = StoredRunLedgerEvent(
                    sequence: sequence,
                    envelope: canonicalEnvelope
                )
                let monitorAudit = try RunLedgerMonitorProjector.auditRecord(
                    for: storedEvent,
                    in: previous
                )
                let next = try RunLedgerProjector.reduce(
                    previous,
                    storedEvent: storedEvent,
                    storeID: identity.storeID
                )
                let outboxProjection = try RunLedgerOutboxProjectionMaterializer.materialize(
                    storedEvent: storedEvent,
                    projection: next,
                    connection: connection,
                    database: database
                )
                try RunLedgerProjectionWriter.persist(
                    from: previous,
                    to: next,
                    connection: connection,
                    database: database
                )
                if let monitorAudit {
                    try RunLedgerMonitorAuditStore.insert(
                        monitorAudit,
                        connection: connection,
                        database: database
                    )
                }
                try insertOutbox(
                    sequence: sequence,
                    envelope: canonicalEnvelope,
                    payload: payload,
                    projection: outboxProjection,
                    database: database
                )
                // WAL and SHM can be created lazily by the first write. Tighten
                // their modes before commit so a permission failure rolls the
                // logical event back instead of returning ambiguous success.
                try RunLedgerStorageSecurity.secureArtifacts(at: configuration.databaseURL)
                return RunLedgerAppendResult(sequence: sequence, disposition: .appended)
            }
        }
        return result
    }

    public func events(after sequence: Int64 = 0, limit: Int = 1_000) throws -> [StoredRunLedgerEvent] {
        guard sequence >= 0 else { throw RunLedgerError.invalidEvent("Event cursor cannot be negative") }
        return try connection.withLock { database in
            try loadEvents(after: sequence, limit: limit, database: database)
        }
    }

    public func projection() throws -> RunLedgerProjection {
        try connection.withLock { database in
            try RunLedgerProjectionStore.load(connection: connection, database: database)
        }
    }

    public func replayedProjection() throws -> RunLedgerProjection {
        try connection.withLock { database in
            try replayProjection(database: database)
        }
    }

    /// Deterministic historical projection used to materialize one exact
    /// outbox message. Later journal events cannot change its semantic body.
    public func replayedProjection(through sequence: Int64) throws -> RunLedgerProjection {
        guard sequence >= 0 else {
            throw RunLedgerError.invalidEvent("Historical projection cursor cannot be negative")
        }
        return try connection.withLock { database in
            try replayState(database: database, through: sequence).projection
        }
    }

    private struct ExistingEvent {
        let sequence: Int64
        let eventKind: String
        let aggregateKind: String
        let aggregateID: String
        let payload: Data
    }

    private func existingEvent(
        eventID: RunLedgerEventID,
        database: OpaquePointer
    ) throws -> ExistingEvent? {
        let statement = try connection.statement(
            """
            SELECT sequence, event_kind, aggregate_kind, aggregate_id, payload
            FROM events WHERE event_id = ?
            """,
            bindings: [.text(RunLedgerSchema.uuid(eventID.rawValue))],
            database: database
        )
        defer { statement.finalize() }
        guard try statement.step() == .row else { return nil }
        let result = ExistingEvent(
            sequence: statement.int64(at: 0),
            eventKind: try statement.text(at: 1),
            aggregateKind: try statement.text(at: 2),
            aggregateID: try statement.text(at: 3),
            payload: try statement.blob(at: 4)
        )
        guard try statement.step() == .done else {
            throw RunLedgerError.corrupt("Event ID uniqueness constraint is violated")
        }
        return result
    }

    private func insertOutbox(
        sequence: Int64,
        envelope: RunLedgerEventEnvelope,
        payload: Data,
        projection: RunLedgerOutboxProjectionMaterialization,
        database: OpaquePointer
    ) throws {
        let statement = try connection.statement(
            """
            INSERT INTO outbox (
                sequence, message_id, event_kind, payload, occurred_at,
                projection_schema_version, projection_payload, projection_sha256,
                execution_id, supervisor_sequence, stream_channel,
                stream_ends_logical_line, stream_fragment_byte_count,
                stream_fragment_truncated, has_terminal
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .integer(sequence),
                .text(RunLedgerSchema.uuid(envelope.eventID.rawValue)),
                .text(envelope.event.kind),
                .blob(payload),
                .real(envelope.occurredAt.timeIntervalSince1970),
                .integer(Int64(RunLedgerPersistedOutboxProjection.currentSchemaVersion)),
                .blob(projection.payload),
                .blob(projection.sha256),
                projection.projection.executionID.map {
                    .text(RunLedgerSchema.uuid($0.rawValue))
                } ?? .null,
                projection.projection.supervisorSequence.flatMap(Int64.init(exactly:)).map {
                    .integer($0)
                } ?? .null,
                projection.projection.stream.map { .text($0.channel.rawValue) } ?? .null,
                projection.projection.stream.map { .integer($0.endsLogicalLine ? 1 : 0) } ?? .null,
                projection.projection.stream.map {
                    .integer(Int64($0.trailingFragmentByteCount))
                } ?? .null,
                projection.projection.stream.map { .integer($0.fragmentTruncated ? 1 : 0) } ?? .null,
                .integer(projection.projection.hasTerminalEvidence ? 1 : 0),
            ],
            database: database
        )
        defer { statement.finalize() }
        guard try statement.step() == .done else {
            throw RunLedgerError.corrupt("Outbox insert returned a row")
        }
    }

    private func verifyOutboxMaterialization(
        sequence: Int64,
        envelope: RunLedgerEventEnvelope,
        payload: Data,
        database: OpaquePointer
    ) throws {
        let statement = try connection.statement(
            """
            SELECT message_id, event_kind, payload, occurred_at,
                   projection_schema_version, projection_payload, projection_sha256,
                   execution_id, supervisor_sequence, stream_channel,
                   stream_ends_logical_line, stream_fragment_byte_count,
                   stream_fragment_truncated, has_terminal
            FROM outbox WHERE sequence = ?
            """,
            bindings: [.integer(sequence)],
            database: database
        )
        defer { statement.finalize() }
        guard try statement.step() == .row,
              try statement.text(at: 0) == RunLedgerSchema.uuid(envelope.eventID.rawValue),
              try statement.text(at: 1) == envelope.event.kind,
              try statement.blob(at: 2) == payload,
              statement.double(at: 3) == envelope.occurredAt.timeIntervalSince1970,
              statement.int64(at: 4)
                == Int64(RunLedgerPersistedOutboxProjection.currentSchemaVersion),
              let projection = try? RunLedgerOutboxProjectionCodec.decode(
                  payload: statement.blob(at: 5),
                  sha256: statement.blob(at: 6)
              ) else {
            throw RunLedgerError.projectionDrift("Exact event replay has no exact outbox materialization")
        }
        try Self.validateOutboxMetadata(
            projection: projection,
            eventKind: try statement.text(at: 1),
            executionID: try statement.optionalText(at: 7),
            supervisorSequence: statement.isNull(at: 8) ? nil : statement.int64(at: 8),
            streamChannel: try statement.optionalText(at: 9),
            streamEndsLogicalLine: statement.isNull(at: 10) ? nil : statement.int64(at: 10),
            streamFragmentByteCount: statement.isNull(at: 11) ? nil : statement.int64(at: 11),
            streamFragmentTruncated: statement.isNull(at: 12) ? nil : statement.int64(at: 12),
            hasTerminal: statement.int64(at: 13)
        )
        guard try statement.step() == .done else {
            throw RunLedgerError.projectionDrift("Exact event replay has duplicate outbox materialization")
        }
    }

    func loadEvents(
        after sequence: Int64,
        limit: Int,
        database: OpaquePointer
    ) throws -> [StoredRunLedgerEvent] {
        let safeLimit = max(1, min(limit, 10_000))
        let statement = try connection.statement(
            """
            SELECT sequence, event_id, event_kind, aggregate_kind, aggregate_id, payload, occurred_at
            FROM events WHERE sequence > ? ORDER BY sequence LIMIT ?
            """,
            bindings: [.integer(sequence), .integer(Int64(safeLimit))],
            database: database
        )
        defer { statement.finalize() }
        var events: [StoredRunLedgerEvent] = []
        while try statement.step() == .row {
            let eventID = RunLedgerEventID(
                rawValue: try uuid(try statement.text(at: 1), field: "events.event_id")
            )
            let payload = try statement.blob(at: 5)
            let envelope = try RunLedgerCodec.envelope(eventID: eventID, from: payload)
            guard try statement.text(at: 2) == envelope.event.kind,
                  try statement.text(at: 3) == envelope.event.aggregateKind,
                  try statement.text(at: 4) == envelope.event.aggregateID,
                  statement.double(at: 6) == envelope.occurredAt.timeIntervalSince1970 else {
                throw RunLedgerError.corrupt("Event index columns do not match canonical payload")
            }
            events.append(.init(sequence: statement.int64(at: 0), envelope: envelope))
        }
        return events
    }

    func replayProjection(database: OpaquePointer) throws -> RunLedgerProjection {
        try replayState(database: database, through: nil).projection
    }

    func replayState(
        database: OpaquePointer,
        through maximumSequence: Int64? = nil
    ) throws -> (
        projection: RunLedgerProjection,
        monitorAudits: [RunLedgerEventID: RunLedgerMonitorAttemptProjection]
    ) {
        var projection = RunLedgerProjection()
        var monitorAudits: [RunLedgerEventID: RunLedgerMonitorAttemptProjection] = [:]
        var cursor: Int64 = 0
        while true {
            let page = try loadEvents(after: cursor, limit: 1_000, database: database)
            guard !page.isEmpty else { break }
            for event in page {
                if let maximumSequence, event.sequence > maximumSequence {
                    return (projection, monitorAudits)
                }
                guard event.sequence > cursor else {
                    throw RunLedgerError.corrupt("Event sequence did not increase monotonically")
                }
                if let audit = try RunLedgerMonitorProjector.auditRecord(
                    for: event,
                    in: projection
                ) {
                    guard monitorAudits.updateValue(audit, forKey: audit.eventID) == nil else {
                        throw RunLedgerError.projectionDrift(
                            "Replay found a duplicate monitor attempt event ID"
                        )
                    }
                }
                let reduced = try RunLedgerProjector.reduce(
                    projection,
                    storedEvent: event,
                    storeID: identity.storeID
                )
                switch event.envelope.event {
                case .runtimeSwitchTargetReserved, .runtimeSwitchAdmitted,
                     .runtimeSwitchPolicyTransitioned,
                     .runtimeSwitchCompletionArchived,
                     .executionForceChallengeRecorded, .executionForceChallengeConsumed:
                    projection = reduced
                default:
                    projection = reduced.preservingRuntimeSwitch(from: projection)
                }
                cursor = event.sequence
            }
        }
        return (projection, monitorAudits)
    }

    func uuid(_ value: String, field: String) throws -> UUID {
        guard let value = UUID(uuidString: value) else {
            throw RunLedgerError.corrupt("\(field) is not a UUID")
        }
        return value
    }

}

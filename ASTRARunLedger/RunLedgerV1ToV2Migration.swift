import ASTRACore
import CryptoKit
import Darwin
import Foundation
import SQLite3

/// Process-level crash seam used only by the standalone ledger harness.
/// Each point is a durable transaction boundary: reopening must expose either
/// the untouched v1 database or the fully committed v2 database.
@_spi(RunLedgerTesting)
public enum RunLedgerMigrationCrashPoint: String, CaseIterable, Sendable {
    case beforeTransaction = "migration-before-transaction"
    case afterLegacyOutboxRename = "migration-after-legacy-outbox-rename"
    case afterV2OutboxCreation = "migration-after-v2-outbox-creation"
    case afterFirstBackfilledRow = "migration-after-first-backfilled-row"
    case afterBackfill = "migration-after-backfill"
    case afterLegacyOutboxRemoval = "migration-after-legacy-outbox-removal"
    case afterMetadataPublication = "migration-after-metadata-publication"
    case afterCommit = "migration-after-commit"
}

private enum RunLedgerMigrationCrash {
    static func trigger(
        _ point: RunLedgerMigrationCrashPoint,
        requested: RunLedgerMigrationCrashPoint?
    ) -> Never? {
        guard requested == point else { return nil }
        Darwin._exit(87)
    }
}

/// Transactional schema-v1 to schema-v2 upgrade.
///
/// V1 owns the canonical event journal and a raw delivery outbox. V2 retains
/// those immutable bytes and backfills an exact typed application projection
/// for every outbox row. The reducer, event payload and typed projection used
/// here are all explicitly schema v1; future semantic changes require a new
/// migration rather than reinterpretation of this input.
enum RunLedgerV1ToV2Migration {
    /// Golden manifest of every non-SQLite-owned v1 table, trigger and explicit
    /// index, including its exact SQL. It was computed from the last shipped
    /// raw-outbox schema and is deliberately independent from v2 schema text.
    static let legacySchemaManifestSHA256 =
        "740c753cfc8603a8f5f8b1df1cbe2369a842b9d0dd4aa936e115863a06f80796"

    /// Event kinds understood by the shipped v1 reducer. New kinds that the
    /// current binary can decode are still rejected in a v1 store so migration
    /// never retroactively assigns them semantics.
    static let legacyEventKinds: Set<String> = [
        "execution.admitted",
        "operation.claimed",
        "execution.authority_transferred",
        "operation.tombstoned",
        "execution.control_transitioned",
        "execution.supervisor_observation_recorded",
        "monitor.deadline_upserted",
        "monitor.deadline_removed",
        "monitor.attempt_recorded",
    ]

    private struct SchemaObject: Equatable {
        let type: String
        let name: String
        let tableName: String
        let sql: String?
    }

    private struct LegacyEvent {
        let sequence: Int64
        let envelope: RunLedgerEventEnvelope
        let payload: Data
    }

    private struct ReplayResult {
        let projection: RunLedgerProjection
        let monitorAudits: [RunLedgerEventID: RunLedgerMonitorAttemptProjection]
        let eventCount: Int64
    }

    static func migrate(
        connection: RunLedgerSQLiteConnection,
        database: OpaquePointer,
        identity: RunLedgerIdentity,
        crashPoint: RunLedgerMigrationCrashPoint?
    ) throws {
        guard identity.schemaVersion == RunLedgerSchema.legacyVersion,
              RunLedgerPersistedEventPayload.currentSchemaVersion == 1,
              RunLedgerPersistedOutboxProjection.currentSchemaVersion == 1 else {
            throw RunLedgerError.incompatibleSchema(
                expected: RunLedgerSchema.version,
                found: identity.schemaVersion
            )
        }

        // Validate every legacy owner before the first DDL statement. A store
        // that merely forges the v1 fingerprint is never adopted or repaired.
        let validated = try validateLegacyStore(
            connection: connection,
            database: database,
            identity: identity
        )
        _ = RunLedgerMigrationCrash.trigger(.beforeTransaction, requested: crashPoint)

        try connection.withImmediateTransaction(database: database) {
            try connection.execute(
                """
                DROP TRIGGER outbox_no_update;
                DROP TRIGGER outbox_no_delete;
                DROP TRIGGER outbox_state_monotonic;
                ALTER TABLE outbox RENAME TO outbox_v1_migration_source;
                """,
                database: database
            )
            _ = RunLedgerMigrationCrash.trigger(
                .afterLegacyOutboxRename,
                requested: crashPoint
            )

            try connection.execute(RunLedgerSchemaSQL.outboxV2, database: database)
            try connection.execute(outboxProtectionTriggersV2, database: database)
            _ = RunLedgerMigrationCrash.trigger(
                .afterV2OutboxCreation,
                requested: crashPoint
            )

            let migrated = try backfillTypedOutbox(
                connection: connection,
                database: database,
                storeID: identity.storeID,
                crashPoint: crashPoint
            )
            guard migrated.eventCount == validated.eventCount,
                  migrated.projection == validated.projection,
                  migrated.monitorAudits == validated.monitorAudits else {
                throw RunLedgerError.projectionDrift(
                    "V1 replay changed while rebuilding the typed outbox"
                )
            }
            try validateCurrentProjection(
                migrated,
                connection: connection,
                database: database
            )
            try validateTypedOutbox(
                expectedCount: migrated.eventCount,
                connection: connection,
                database: database
            )
            _ = RunLedgerMigrationCrash.trigger(.afterBackfill, requested: crashPoint)

            try connection.execute(
                "DROP TABLE outbox_v1_migration_source",
                database: database
            )
            _ = RunLedgerMigrationCrash.trigger(
                .afterLegacyOutboxRemoval,
                requested: crashPoint
            )

            // Metadata is normally immutable. Migration temporarily removes
            // exactly the update guard, publishes both version owners, and
            // restores the identical guard before commit.
            try connection.execute(
                "DROP TRIGGER ledger_metadata_no_update",
                database: database
            )
            try { () throws -> Void in
                let update = try connection.statement(
                    """
                    UPDATE ledger_metadata
                    SET schema_version = ?, schema_fingerprint = ?
                    WHERE singleton_id = 1 AND schema_version = ? AND schema_fingerprint = ?
                      AND store_id = ? AND installation_id = ? AND created_at = ?
                    """,
                    bindings: [
                        .integer(Int64(RunLedgerSchema.version)),
                        .text(RunLedgerSchema.fingerprint),
                        .integer(Int64(RunLedgerSchema.legacyVersion)),
                        .text(RunLedgerSchema.legacyFingerprint),
                        .text(RunLedgerSchema.uuid(identity.storeID.rawValue)),
                        .text(RunLedgerSchema.uuid(identity.installationID.rawValue)),
                        .real(identity.createdAt.timeIntervalSince1970),
                    ],
                    database: database
                )
                defer { update.finalize() }
                guard try update.step() == .done,
                      connection.changes(database: database) == 1 else {
                    throw RunLedgerError.corrupt("V1 metadata changed during migration")
                }
            }()
            try connection.execute(metadataUpdateProtectionTrigger, database: database)
            try connection.execute(
                "PRAGMA user_version = \(RunLedgerSchema.version)",
                database: database
            )
            _ = RunLedgerMigrationCrash.trigger(
                .afterMetadataPublication,
                requested: crashPoint
            )

            try requireNoRows(
                "PRAGMA foreign_key_check",
                detail: "V2 foreign_key_check found a violation",
                connection: connection,
                database: database
            )
            guard try connection.scalarText("PRAGMA quick_check", database: database) == "ok" else {
                throw RunLedgerError.corrupt("V2 quick_check failed before migration commit")
            }
        }

        _ = RunLedgerMigrationCrash.trigger(.afterCommit, requested: crashPoint)
    }

    private static func validateLegacyStore(
        connection: RunLedgerSQLiteConnection,
        database: OpaquePointer,
        identity: RunLedgerIdentity
    ) throws -> ReplayResult {
        guard try connection.scalarText("PRAGMA quick_check", database: database) == "ok" else {
            throw RunLedgerError.corrupt("V1 quick_check failed")
        }
        try requireNoRows(
            "PRAGMA foreign_key_check",
            detail: "V1 foreign_key_check found a violation",
            connection: connection,
            database: database
        )
        guard try schemaManifestSHA256(connection: connection, database: database)
                == legacySchemaManifestSHA256 else {
            throw RunLedgerError.incompatibleSchema(
                expected: RunLedgerSchema.version,
                found: RunLedgerSchema.legacyVersion
            )
        }

        let eventCount = try connection.scalarInt64(
            "SELECT COUNT(*) FROM events",
            database: database
        ) ?? 0
        let outboxCount = try connection.scalarInt64(
            "SELECT COUNT(*) FROM outbox",
            database: database
        ) ?? 0
        guard eventCount == outboxCount else {
            throw RunLedgerError.projectionDrift(
                "V1 event and outbox counts differ"
            )
        }
        let eventMismatchCount = try connection.scalarInt64(
            """
            SELECT COUNT(*) FROM events e
            LEFT JOIN outbox o ON o.sequence = e.sequence
            WHERE o.sequence IS NULL OR o.message_id != e.event_id OR o.event_kind != e.event_kind
               OR o.payload != e.payload OR o.occurred_at != e.occurred_at
            """,
            database: database
        ) ?? 0
        let outboxMismatchCount = try connection.scalarInt64(
            """
            SELECT COUNT(*) FROM outbox o
            LEFT JOIN events e ON e.sequence = o.sequence
            WHERE e.sequence IS NULL
            """,
            database: database
        ) ?? 0
        guard eventMismatchCount == 0, outboxMismatchCount == 0 else {
            throw RunLedgerError.projectionDrift(
                "V1 outbox differs from the canonical event journal"
            )
        }
        try validateAcknowledgement(
            sourceTable: "outbox",
            connection: connection,
            database: database
        )

        let replay = try replayLegacyEvents(
            sourceTable: "outbox",
            materialize: false,
            connection: connection,
            database: database,
            storeID: identity.storeID,
            crashPoint: nil
        )
        guard replay.eventCount == eventCount else {
            throw RunLedgerError.projectionDrift("V1 replay did not consume every event")
        }
        try validateCurrentProjection(replay, connection: connection, database: database)
        return replay
    }

    private static func backfillTypedOutbox(
        connection: RunLedgerSQLiteConnection,
        database: OpaquePointer,
        storeID: RunBrokerStoreID,
        crashPoint: RunLedgerMigrationCrashPoint?
    ) throws -> ReplayResult {
        let replay = try replayLegacyEvents(
            sourceTable: "outbox_v1_migration_source",
            materialize: true,
            connection: connection,
            database: database,
            storeID: storeID,
            crashPoint: crashPoint
        )
        try validateAcknowledgement(
            sourceTable: "outbox",
            connection: connection,
            database: database
        )
        return replay
    }

    private static func replayLegacyEvents(
        sourceTable: String,
        materialize: Bool,
        connection: RunLedgerSQLiteConnection,
        database: OpaquePointer,
        storeID: RunBrokerStoreID,
        crashPoint: RunLedgerMigrationCrashPoint?
    ) throws -> ReplayResult {
        // Only the two hard-coded table identifiers above can reach this SQL.
        guard sourceTable == "outbox" || sourceTable == "outbox_v1_migration_source" else {
            throw RunLedgerError.corrupt("Invalid migration outbox source")
        }
        var projection = RunLedgerProjection()
        var monitorAudits: [RunLedgerEventID: RunLedgerMonitorAttemptProjection] = [:]
        var cursor: Int64 = 0
        var count: Int64 = 0
        while let legacy = try nextLegacyEvent(
            after: cursor,
            sourceTable: sourceTable,
            connection: connection,
            database: database
        ) {
            guard legacy.sequence > cursor else {
                throw RunLedgerError.corrupt("V1 event sequence did not increase")
            }
            if let audit = try RunLedgerMonitorProjector.auditRecord(
                for: .init(sequence: legacy.sequence, envelope: legacy.envelope),
                in: projection
            ) {
                guard monitorAudits.updateValue(audit, forKey: audit.eventID) == nil else {
                    throw RunLedgerError.projectionDrift(
                        "V1 replay found a duplicate monitor attempt event ID"
                    )
                }
            }
            let stored = StoredRunLedgerEvent(
                sequence: legacy.sequence,
                envelope: legacy.envelope
            )
            let reduced = try RunLedgerProjector.reduce(
                projection,
                storedEvent: stored,
                storeID: storeID
            )
            switch legacy.envelope.event {
            case .runtimeSwitchTargetReserved, .runtimeSwitchPolicyTransitioned,
                 .runtimeSwitchCompletionArchived, .executionForceChallengeRecorded,
                 .executionForceChallengeConsumed:
                projection = reduced
            default:
                projection = reduced.preservingRuntimeSwitch(from: projection)
            }

            if materialize {
                let typed = try RunLedgerOutboxProjectionMaterializer.materialize(
                    storedEvent: stored,
                    projection: projection,
                    connection: connection,
                    database: database
                )
                try insertTypedOutbox(
                    legacy,
                    materialization: typed,
                    connection: connection,
                    database: database
                )
            }
            cursor = legacy.sequence
            count += 1
            if count == 1 {
                _ = RunLedgerMigrationCrash.trigger(
                    .afterFirstBackfilledRow,
                    requested: crashPoint
                )
            }
        }
        return .init(
            projection: projection,
            monitorAudits: monitorAudits,
            eventCount: count
        )
    }

    private static func nextLegacyEvent(
        after sequence: Int64,
        sourceTable: String,
        connection: RunLedgerSQLiteConnection,
        database: OpaquePointer
    ) throws -> LegacyEvent? {
        let statement = try connection.statement(
            """
            SELECT e.sequence, e.event_id, e.event_kind, e.aggregate_kind,
                   e.aggregate_id, e.payload, e.occurred_at,
                   o.sequence, o.message_id, o.event_kind, o.payload, o.occurred_at
            FROM events e
            LEFT JOIN \(sourceTable) o ON o.sequence = e.sequence
            WHERE e.sequence > ? ORDER BY e.sequence LIMIT 1
            """,
            bindings: [.integer(sequence)],
            database: database
        )
        defer { statement.finalize() }
        guard try statement.step() == .row else { return nil }
        let eventIDText = try statement.text(at: 1)
        let eventKind = try statement.text(at: 2)
        guard legacyEventKinds.contains(eventKind) else {
            throw RunLedgerError.incompatibleSchema(
                expected: RunLedgerSchema.version,
                found: RunLedgerSchema.legacyVersion
            )
        }
        guard let eventUUID = UUID(uuidString: eventIDText) else {
            throw RunLedgerError.corrupt("V1 event ID is not a UUID")
        }
        let eventID = RunLedgerEventID(rawValue: eventUUID)
        let payload = try statement.blob(at: 5)
        let envelope = try RunLedgerCodec.envelope(eventID: eventID, from: payload)
        guard statement.int64(at: 0) > 0,
              eventKind == envelope.event.kind,
              try statement.text(at: 3) == envelope.event.aggregateKind,
              try statement.text(at: 4) == envelope.event.aggregateID,
              statement.double(at: 6) == envelope.occurredAt.timeIntervalSince1970,
              !statement.isNull(at: 7),
              statement.int64(at: 7) == statement.int64(at: 0),
              try statement.text(at: 8) == eventIDText,
              try statement.text(at: 9) == envelope.event.kind,
              try statement.blob(at: 10) == payload,
              statement.double(at: 11) == envelope.occurredAt.timeIntervalSince1970 else {
            throw RunLedgerError.projectionDrift(
                "V1 event and outbox row are not exact mirrors"
            )
        }
        return .init(sequence: statement.int64(at: 0), envelope: envelope, payload: payload)
    }

    private static func insertTypedOutbox(
        _ legacy: LegacyEvent,
        materialization: RunLedgerOutboxProjectionMaterialization,
        connection: RunLedgerSQLiteConnection,
        database: OpaquePointer
    ) throws {
        let projection = materialization.projection
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
                .integer(legacy.sequence),
                .text(RunLedgerSchema.uuid(legacy.envelope.eventID.rawValue)),
                .text(legacy.envelope.event.kind),
                .blob(legacy.payload),
                .real(legacy.envelope.occurredAt.timeIntervalSince1970),
                .integer(Int64(RunLedgerPersistedOutboxProjection.currentSchemaVersion)),
                .blob(materialization.payload),
                .blob(materialization.sha256),
                projection.executionID.map {
                    .text(RunLedgerSchema.uuid($0.rawValue))
                } ?? .null,
                projection.supervisorSequence.flatMap(Int64.init(exactly:)).map {
                    .integer($0)
                } ?? .null,
                projection.stream.map { .text($0.channel.rawValue) } ?? .null,
                projection.stream.map { .integer($0.endsLogicalLine ? 1 : 0) } ?? .null,
                projection.stream.map {
                    .integer(Int64($0.trailingFragmentByteCount))
                } ?? .null,
                projection.stream.map { .integer($0.fragmentTruncated ? 1 : 0) } ?? .null,
                .integer(projection.hasTerminalEvidence ? 1 : 0),
            ],
            database: database
        )
        defer { statement.finalize() }
        guard try statement.step() == .done else {
            throw RunLedgerError.corrupt("V2 outbox backfill insert returned a row")
        }
    }

    private static func validateCurrentProjection(
        _ replay: ReplayResult,
        connection: RunLedgerSQLiteConnection,
        database: OpaquePointer
    ) throws {
        let current = try RunLedgerProjectionStore.load(
            connection: connection,
            database: database
        )
        guard current == replay.projection else {
            throw RunLedgerError.projectionDrift(
                "Current-state projection differs from v1 journal replay"
            )
        }
        try RunLedgerMonitorAuditStore.verify(
            expected: replay.monitorAudits,
            connection: connection,
            database: database
        )
    }

    private static func validateTypedOutbox(
        expectedCount: Int64,
        connection: RunLedgerSQLiteConnection,
        database: OpaquePointer
    ) throws {
        guard try connection.scalarInt64("SELECT COUNT(*) FROM outbox", database: database)
                == expectedCount else {
            throw RunLedgerError.projectionDrift("V2 outbox backfill count differs from v1")
        }
        let statement = try connection.statement(
            """
            SELECT event_kind, projection_schema_version, projection_payload, projection_sha256,
                   execution_id, supervisor_sequence, stream_channel,
                   stream_ends_logical_line, stream_fragment_byte_count,
                   stream_fragment_truncated, has_terminal
            FROM outbox ORDER BY sequence
            """,
            database: database
        )
        defer { statement.finalize() }
        while try statement.step() == .row {
            guard statement.int64(at: 1)
                    == Int64(RunLedgerPersistedOutboxProjection.currentSchemaVersion) else {
                throw RunLedgerError.projectionDrift("Backfill wrote an unsupported projection schema")
            }
            let projection = try RunLedgerOutboxProjectionCodec.decode(
                payload: try statement.blob(at: 2),
                sha256: try statement.blob(at: 3)
            )
            try RunLedger.validateOutboxMetadata(
                projection: projection,
                eventKind: try statement.text(at: 0),
                executionID: try statement.optionalText(at: 4),
                supervisorSequence: statement.isNull(at: 5) ? nil : statement.int64(at: 5),
                streamChannel: try statement.optionalText(at: 6),
                streamEndsLogicalLine: statement.isNull(at: 7) ? nil : statement.int64(at: 7),
                streamFragmentByteCount: statement.isNull(at: 8) ? nil : statement.int64(at: 8),
                streamFragmentTruncated: statement.isNull(at: 9) ? nil : statement.int64(at: 9),
                hasTerminal: statement.int64(at: 10)
            )
        }
    }

    private static func validateAcknowledgement(
        sourceTable: String,
        connection: RunLedgerSQLiteConnection,
        database: OpaquePointer
    ) throws {
        guard sourceTable == "outbox" || sourceTable == "outbox_v1_migration_source" else {
            throw RunLedgerError.corrupt("Invalid acknowledgement source")
        }
        let rowCount = try connection.scalarInt64(
            "SELECT COUNT(*) FROM outbox_state WHERE singleton_id = 1",
            database: database
        ) ?? 0
        guard rowCount == 1,
              let acknowledged = try connection.scalarInt64(
                  "SELECT last_acknowledged_sequence FROM outbox_state WHERE singleton_id = 1",
                  database: database
              ),
              acknowledged >= 0 else {
            throw RunLedgerError.projectionDrift("V1 acknowledgement cursor is missing or invalid")
        }
        if acknowledged > 0 {
            guard try connection.scalarInt64(
                "SELECT 1 FROM \(sourceTable) WHERE sequence = ?",
                bindings: [.integer(acknowledged)],
                database: database
            ) == 1 else {
                throw RunLedgerError.projectionDrift(
                    "V1 acknowledgement cursor references no outbox message"
                )
            }
        }
    }

    private static func schemaObjects(
        connection: RunLedgerSQLiteConnection,
        database: OpaquePointer
    ) throws -> [SchemaObject] {
        let statement = try connection.statement(
            """
            SELECT type, name, tbl_name, sql FROM sqlite_schema
            WHERE name NOT LIKE 'sqlite_%'
            ORDER BY type, name
            """,
            database: database
        )
        defer { statement.finalize() }
        var result: [SchemaObject] = []
        while try statement.step() == .row {
            result.append(.init(
                type: try statement.text(at: 0),
                name: try statement.text(at: 1),
                tableName: try statement.text(at: 2),
                sql: try statement.optionalText(at: 3)
            ))
        }
        return result
    }

    static func schemaManifestSHA256(
        connection: RunLedgerSQLiteConnection,
        database: OpaquePointer
    ) throws -> String {
        let objects = try schemaObjects(connection: connection, database: database)
        var bytes = Data()
        for object in objects {
            for value in [object.type, object.name, object.tableName, object.sql ?? "<NULL>"] {
                bytes.append(contentsOf: value.utf8)
                bytes.append(0)
            }
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func requireNoRows(
        _ sql: String,
        detail: String,
        connection: RunLedgerSQLiteConnection,
        database: OpaquePointer
    ) throws {
        let statement = try connection.statement(sql, database: database)
        defer { statement.finalize() }
        guard try statement.step() == .done else {
            throw RunLedgerError.corrupt(detail)
        }
    }

    private static let outboxProtectionTriggersV2 = """
    CREATE TRIGGER outbox_no_update BEFORE UPDATE ON outbox
    BEGIN SELECT RAISE(ABORT, 'outbox messages are immutable'); END;
    CREATE TRIGGER outbox_no_delete BEFORE DELETE ON outbox
    BEGIN SELECT RAISE(ABORT, 'outbox messages are durable'); END;
    CREATE TRIGGER outbox_state_monotonic BEFORE UPDATE ON outbox_state
    WHEN NEW.last_acknowledged_sequence != OLD.last_acknowledged_sequence
      AND NEW.last_acknowledged_sequence != COALESCE(
          (SELECT MIN(sequence) FROM outbox WHERE sequence > OLD.last_acknowledged_sequence),
          -1
      )
    BEGIN SELECT RAISE(ABORT, 'outbox acknowledgement cannot skip or regress'); END;
    """

    private static let metadataUpdateProtectionTrigger = """
    CREATE TRIGGER ledger_metadata_no_update BEFORE UPDATE ON ledger_metadata
    BEGIN SELECT RAISE(ABORT, 'ledger metadata is immutable'); END;
    """
}

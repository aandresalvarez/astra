enum RunLedgerSchemaSQL {
    static let v1 = """
    CREATE TABLE ledger_metadata (
        singleton_id INTEGER PRIMARY KEY CHECK (singleton_id = 1),
        schema_version INTEGER NOT NULL CHECK (schema_version > 0),
        schema_fingerprint TEXT NOT NULL,
        store_id TEXT NOT NULL UNIQUE CHECK (length(store_id) = 36),
        installation_id TEXT NOT NULL CHECK (length(installation_id) = 36),
        created_at REAL NOT NULL
    ) STRICT;

    CREATE TABLE events (
        sequence INTEGER PRIMARY KEY AUTOINCREMENT CHECK (sequence > 0),
        event_id TEXT NOT NULL UNIQUE CHECK (length(event_id) = 36),
        event_kind TEXT NOT NULL,
        aggregate_kind TEXT NOT NULL CHECK (aggregate_kind IN ('execution', 'operation')),
        aggregate_id TEXT NOT NULL CHECK (length(aggregate_id) = 36),
        payload BLOB NOT NULL CHECK (length(payload) > 0),
        occurred_at REAL NOT NULL
    ) STRICT;

    CREATE TABLE executions (
        execution_id TEXT PRIMARY KEY CHECK (length(execution_id) = 36),
        manifest BLOB NOT NULL CHECK (length(manifest) > 0),
        authority_id TEXT NOT NULL CHECK (length(authority_id) = 36),
        authority_epoch INTEGER NOT NULL CHECK (authority_epoch >= 1),
        desired_execution TEXT NOT NULL CHECK (desired_execution IN ('running', 'cancelled')),
        observed_execution TEXT NOT NULL CHECK (
            observed_execution IN ('registered', 'starting', 'running', 'completed', 'failed', 'cancelled', 'in_doubt')
        ),
        desired_cancellation TEXT NOT NULL CHECK (desired_cancellation IN ('none', 'graceful', 'immediate')),
        observed_cancellation TEXT NOT NULL CHECK (
            observed_cancellation IN (
                'not_requested', 'request_pending', 'accepted', 'terminating', 'cancelled',
                'completed_before_cancel', 'rejected', 'unsupported', 'in_doubt'
            )
        ),
        updated_at REAL NOT NULL,
        created_sequence INTEGER NOT NULL REFERENCES events(sequence),
        updated_sequence INTEGER NOT NULL REFERENCES events(sequence),
        CHECK (updated_sequence >= created_sequence)
    ) STRICT;

    CREATE TABLE operation_claims (
        operation_id TEXT PRIMARY KEY CHECK (length(operation_id) = 36),
        store_id TEXT NOT NULL CHECK (length(store_id) = 36),
        execution_id TEXT NOT NULL REFERENCES executions(execution_id),
        authority_id TEXT NOT NULL CHECK (length(authority_id) = 36),
        authority_epoch INTEGER NOT NULL CHECK (authority_epoch >= 1),
        effects BLOB NOT NULL CHECK (length(effects) > 0),
        claim_state TEXT NOT NULL CHECK (claim_state IN ('active', 'tombstoned')),
        tombstone_reason TEXT,
        tombstone_recorded_at REAL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        created_sequence INTEGER NOT NULL REFERENCES events(sequence),
        updated_sequence INTEGER NOT NULL REFERENCES events(sequence),
        CHECK (updated_sequence >= created_sequence),
        CHECK (updated_at >= created_at),
        CHECK (
            (claim_state = 'active' AND tombstone_reason IS NULL AND tombstone_recorded_at IS NULL)
            OR
            (claim_state = 'tombstoned' AND tombstone_reason IS NOT NULL AND tombstone_recorded_at IS NOT NULL)
        )
    ) STRICT;

    CREATE TABLE effect_claims (
        operation_id TEXT NOT NULL REFERENCES operation_claims(operation_id),
        effect_index INTEGER NOT NULL CHECK (effect_index >= 0),
        scope BLOB NOT NULL CHECK (length(scope) > 0),
        access TEXT NOT NULL CHECK (access IN ('shared', 'exclusive')),
        PRIMARY KEY (operation_id, effect_index)
    ) STRICT;

    CREATE TABLE monitor_schedules (
        operation_id TEXT PRIMARY KEY REFERENCES operation_claims(operation_id),
        authority_id TEXT NOT NULL CHECK (length(authority_id) = 36),
        authority_epoch INTEGER NOT NULL CHECK (authority_epoch >= 1),
        due_at REAL NOT NULL,
        recorded_at REAL NOT NULL,
        attempt INTEGER NOT NULL CHECK (attempt >= 0),
        generation TEXT NOT NULL CHECK (length(generation) = 36)
    ) STRICT;

    CREATE TABLE monitor_attempts (
        event_id TEXT PRIMARY KEY CHECK (length(event_id) = 36),
        operation_id TEXT NOT NULL REFERENCES operation_claims(operation_id),
        expected_authority_id TEXT NOT NULL CHECK (length(expected_authority_id) = 36),
        expected_authority_epoch INTEGER NOT NULL CHECK (expected_authority_epoch >= 1),
        expected_due_at REAL NOT NULL,
        expected_recorded_at REAL NOT NULL,
        expected_attempt INTEGER NOT NULL CHECK (expected_attempt >= 0),
        expected_generation TEXT NOT NULL CHECK (length(expected_generation) = 36),
        attempted_at REAL NOT NULL,
        disposition TEXT NOT NULL CHECK (
            disposition IN ('completed', 'retryable_failure', 'terminal_failure')
        ),
        next_due_at REAL,
        next_recorded_at REAL,
        next_attempt INTEGER CHECK (next_attempt >= 0),
        next_generation TEXT CHECK (next_generation IS NULL OR length(next_generation) = 36),
        apply_disposition TEXT NOT NULL CHECK (apply_disposition IN ('applied', 'stale')),
        recorded_sequence INTEGER NOT NULL UNIQUE REFERENCES events(sequence),
        CHECK (
            (next_due_at IS NULL AND next_recorded_at IS NULL
                AND next_attempt IS NULL AND next_generation IS NULL)
            OR
            (next_due_at IS NOT NULL AND next_recorded_at IS NOT NULL
                AND next_attempt IS NOT NULL AND next_generation IS NOT NULL)
        )
    ) STRICT;

    CREATE TABLE outbox (
        sequence INTEGER PRIMARY KEY REFERENCES events(sequence),
        message_id TEXT NOT NULL UNIQUE CHECK (length(message_id) = 36),
        event_kind TEXT NOT NULL,
        payload BLOB NOT NULL CHECK (length(payload) > 0),
        occurred_at REAL NOT NULL
    ) STRICT;

    CREATE TABLE outbox_state (
        singleton_id INTEGER PRIMARY KEY CHECK (singleton_id = 1),
        last_acknowledged_sequence INTEGER NOT NULL CHECK (last_acknowledged_sequence >= 0)
    ) STRICT;

    CREATE TABLE consumer_checkpoints (
        consumer_id TEXT PRIMARY KEY CHECK (length(consumer_id) BETWEEN 1 AND 200),
        event_sequence INTEGER NOT NULL REFERENCES events(sequence)
    ) STRICT;

    CREATE TRIGGER ledger_metadata_no_update BEFORE UPDATE ON ledger_metadata
    BEGIN SELECT RAISE(ABORT, 'ledger metadata is immutable'); END;
    CREATE TRIGGER ledger_metadata_no_delete BEFORE DELETE ON ledger_metadata
    BEGIN SELECT RAISE(ABORT, 'ledger metadata is immutable'); END;

    CREATE TRIGGER events_no_update BEFORE UPDATE ON events
    BEGIN SELECT RAISE(ABORT, 'event journal is append-only'); END;
    CREATE TRIGGER events_no_delete BEFORE DELETE ON events
    BEGIN SELECT RAISE(ABORT, 'event journal is append-only'); END;

    CREATE TRIGGER executions_no_delete BEFORE DELETE ON executions
    BEGIN SELECT RAISE(ABORT, 'execution projection cannot be deleted'); END;
    CREATE TRIGGER executions_immutable BEFORE UPDATE OF execution_id, manifest, created_sequence ON executions
    BEGIN SELECT RAISE(ABORT, 'execution identity and manifest are immutable'); END;

    CREATE TRIGGER operation_claims_no_delete BEFORE DELETE ON operation_claims
    BEGIN SELECT RAISE(ABORT, 'operation claims cannot be deleted'); END;
    CREATE TRIGGER operation_claims_immutable
    BEFORE UPDATE OF operation_id, store_id, execution_id, effects, created_at, created_sequence ON operation_claims
    BEGIN SELECT RAISE(ABORT, 'operation identity and effects are immutable'); END;

    CREATE TRIGGER effect_claims_no_update BEFORE UPDATE ON effect_claims
    BEGIN SELECT RAISE(ABORT, 'effect claims are immutable'); END;
    CREATE TRIGGER effect_claims_no_delete BEFORE DELETE ON effect_claims
    BEGIN SELECT RAISE(ABORT, 'effect claims are immutable'); END;

    CREATE TRIGGER monitor_attempts_no_update BEFORE UPDATE ON monitor_attempts
    BEGIN SELECT RAISE(ABORT, 'monitor attempts are immutable'); END;
    CREATE TRIGGER monitor_attempts_no_delete BEFORE DELETE ON monitor_attempts
    BEGIN SELECT RAISE(ABORT, 'monitor attempts are append-only'); END;

    CREATE TRIGGER outbox_no_update BEFORE UPDATE ON outbox
    BEGIN SELECT RAISE(ABORT, 'outbox messages are immutable'); END;
    CREATE TRIGGER outbox_no_delete BEFORE DELETE ON outbox
    BEGIN SELECT RAISE(ABORT, 'outbox messages are durable'); END;

    CREATE TRIGGER outbox_state_no_delete BEFORE DELETE ON outbox_state
    BEGIN SELECT RAISE(ABORT, 'outbox acknowledgement cursor cannot be deleted'); END;
    CREATE TRIGGER outbox_state_monotonic BEFORE UPDATE ON outbox_state
    WHEN NEW.last_acknowledged_sequence != OLD.last_acknowledged_sequence
      AND NEW.last_acknowledged_sequence != COALESCE(
          (SELECT MIN(sequence) FROM outbox WHERE sequence > OLD.last_acknowledged_sequence),
          -1
      )
    BEGIN SELECT RAISE(ABORT, 'outbox acknowledgement cannot skip or regress'); END;

    CREATE TRIGGER consumer_checkpoints_no_delete BEFORE DELETE ON consumer_checkpoints
    BEGIN SELECT RAISE(ABORT, 'consumer checkpoint cannot be deleted'); END;
    CREATE TRIGGER consumer_checkpoint_initial BEFORE INSERT ON consumer_checkpoints
    WHEN NEW.event_sequence != COALESCE((SELECT MIN(sequence) FROM events), -1)
    BEGIN SELECT RAISE(ABORT, 'consumer checkpoint cannot skip initial event'); END;
    CREATE TRIGGER consumer_checkpoint_monotonic BEFORE UPDATE ON consumer_checkpoints
    WHEN NEW.event_sequence != OLD.event_sequence
      AND NEW.event_sequence != COALESCE(
          (SELECT MIN(sequence) FROM events WHERE sequence > OLD.event_sequence),
          -1
      )
    BEGIN SELECT RAISE(ABORT, 'consumer checkpoint cannot skip or regress'); END;
    """
}

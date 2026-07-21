import ASTRACore
import Foundation

public final class RunLedger: @unchecked Sendable {
    public let identity: RunLedgerIdentity

    let configuration: RunLedgerConfiguration
    let connection: RunLedgerSQLiteConnection
    /// Held for the ledger's whole lifetime when `configuration.exclusiveWriter`
    /// is set; the kernel drops it on process death. See
    /// `RunLedgerConfiguration.exclusiveWriter` for why the broker requires it.
    private var exclusiveWriterLockDescriptor: Int32?
    private let exclusiveWriterLockGuard = NSLock()

    public convenience init(configuration: RunLedgerConfiguration) throws {
        try self.init(
            configuration: configuration,
            createIfMissing: true,
            initializationCrashPoint: nil
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
            initializationCrashPoint: crashPoint
        )
    }

    private init(
        configuration: RunLedgerConfiguration,
        createIfMissing: Bool,
        initializationCrashPoint: RunLedgerInitializationCrashPoint?
    ) throws {
        let opened = try RunLedgerSchema.open(
            configuration: configuration,
            createIfMissing: createIfMissing,
            initializationCrashPoint: initializationCrashPoint
        )
        self.configuration = configuration
        connection = opened.0
        identity = opened.1
        if configuration.exclusiveWriter {
            do {
                exclusiveWriterLockDescriptor =
                    try RunLedgerStorageSecurity.acquireExclusiveWriterLock(
                        directory: configuration.ledgerDirectoryURL
                    )
            } catch {
                try? connection.close()
                throw RunLedgerSchema.classify(error)
            }
        }
        do {
            try connection.withLock { database in
                _ = try assertIntegrity(database: database)
            }
        } catch {
            releaseExclusiveWriterLockIfHeld()
            try? connection.close()
            throw RunLedgerSchema.classify(error)
        }
    }

    public static func inspect(_ configuration: RunLedgerConfiguration) -> RunLedgerHealthReport {
        do {
            let ledger = try RunLedger(
                configuration: configuration,
                createIfMissing: false,
                initializationCrashPoint: nil
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
        releaseExclusiveWriterLockIfHeld()
    }

    deinit {
        releaseExclusiveWriterLockIfHeld()
    }

    private func releaseExclusiveWriterLockIfHeld() {
        exclusiveWriterLockGuard.lock()
        defer { exclusiveWriterLockGuard.unlock() }
        if let descriptor = exclusiveWriterLockDescriptor {
            RunLedgerStorageSecurity.releaseExclusiveWriterLock(descriptor)
            exclusiveWriterLockDescriptor = nil
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
        database: OpaquePointer
    ) throws {
        let statement = try connection.statement(
            """
            INSERT INTO outbox (sequence, message_id, event_kind, payload, occurred_at)
            VALUES (?, ?, ?, ?, ?)
            """,
            bindings: [
                .integer(sequence),
                .text(RunLedgerSchema.uuid(envelope.eventID.rawValue)),
                .text(envelope.event.kind),
                .blob(payload),
                .real(envelope.occurredAt.timeIntervalSince1970),
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
            SELECT message_id, event_kind, payload, occurred_at FROM outbox WHERE sequence = ?
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
              try statement.step() == .done else {
            throw RunLedgerError.projectionDrift("Exact event replay has no exact outbox materialization")
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
        try replayState(database: database).projection
    }

    func replayState(
        database: OpaquePointer
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
                projection = try RunLedgerProjector.reduce(
                    projection,
                    storedEvent: event,
                    storeID: identity.storeID
                )
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

import Foundation

package struct RunLedgerOutboxDeliverySnapshot: Sendable {
    package let acknowledgedThrough: Int64
    package let acknowledgedMessageID: RunLedgerEventID?
    package let durableHead: RunLedgerOutboxMessage?
    package let next: RunLedgerOutboxMessage?
}

extension RunLedger {
    /// Captures every value used by a projection handshake from one SQLite WAL
    /// read snapshot. A concurrent ACK or append on another connection may
    /// commit without waiting, while all values returned here remain from the
    /// same pre-commit view.
    package func outboxDeliverySnapshot(
        afterAcknowledgementRead: (@Sendable () -> Void)? = nil
    ) throws -> RunLedgerOutboxDeliverySnapshot {
        try connection.withLock { database in
            try connection.execute("BEGIN DEFERRED", database: database)
            do {
                // The first SELECT establishes the WAL read snapshot.
                let acknowledged = try outboxAcknowledgement(database: database)
                afterAcknowledgementRead?()

                let acknowledgedMessageID: RunLedgerEventID?
                if acknowledged > 0 {
                    guard let value = try connection.scalarText(
                        "SELECT message_id FROM outbox WHERE sequence = ?",
                        bindings: [.integer(acknowledged)],
                        database: database
                    ) else {
                        throw RunLedgerError.projectionDrift(
                            "Acknowledged outbox message is missing"
                        )
                    }
                    acknowledgedMessageID = .init(
                        rawValue: try uuid(value, field: "outbox.message_id")
                    )
                } else {
                    acknowledgedMessageID = nil
                }

                let snapshot = try RunLedgerOutboxDeliverySnapshot(
                    acknowledgedThrough: acknowledged,
                    acknowledgedMessageID: acknowledgedMessageID,
                    durableHead: outboxHead(),
                    next: outbox(after: acknowledged, limit: 1).first
                )
                try connection.execute("COMMIT", database: database)
                return snapshot
            } catch {
                try? connection.execute("ROLLBACK", database: database)
                throw error
            }
        }
    }
}

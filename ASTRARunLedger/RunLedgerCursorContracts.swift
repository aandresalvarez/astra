import Foundation

public struct RunLedgerOutboxMessage: Equatable, Sendable {
    public let sequence: Int64
    public let messageID: RunLedgerEventID
    public let eventKind: String
    public let payload: Data
    public let occurredAt: Date
    public let isAcknowledged: Bool
    package let projection: RunLedgerOutboxProjectionV1

    package init(
        sequence: Int64,
        messageID: RunLedgerEventID,
        eventKind: String,
        payload: Data,
        occurredAt: Date,
        isAcknowledged: Bool,
        projection: RunLedgerOutboxProjectionV1
    ) {
        self.sequence = sequence
        self.messageID = messageID
        self.eventKind = eventKind
        self.payload = payload
        self.occurredAt = occurredAt
        self.isAcknowledged = isAcknowledged
        self.projection = projection
    }
}

public enum RunLedgerCursorDisposition: String, Codable, Equatable, Sendable {
    case applied
    case idempotent
}

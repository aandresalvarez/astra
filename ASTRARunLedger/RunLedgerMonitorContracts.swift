import ASTRACore
import Foundation

/// Durable scheduler truth. `generation` is the idempotency UUID of the event
/// that installed this exact deadline, making compare-and-apply ABA-safe.
public struct RunLedgerMonitorDeadline: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let operationID: RunBrokerOperationID
    public let authority: RunBrokerAuthority
    public let dueAt: Date
    public let recordedAt: Date
    public let attempt: UInt64
    public let generation: UUID

    public init(
        operationID: RunBrokerOperationID,
        authority: RunBrokerAuthority,
        dueAt: Date,
        recordedAt: Date,
        attempt: UInt64,
        generation: UUID
    ) {
        self.operationID = operationID
        self.authority = authority
        self.dueAt = Self.canonicalMilliseconds(dueAt)
        self.recordedAt = Self.canonicalMilliseconds(recordedAt)
        self.attempt = attempt
        self.generation = generation
    }

    public var id: RunBrokerOperationID { operationID }

    private enum CodingKeys: String, CodingKey {
        case operationID
        case authority
        case dueAt
        case recordedAt
        case attempt
        case generation
    }

    public init(from decoder: Decoder) throws {
        try RunLedgerStrictCoding.requireExactKeys(
            decoder,
            expected: [
                CodingKeys.operationID.rawValue,
                CodingKeys.authority.rawValue,
                CodingKeys.dueAt.rawValue,
                CodingKeys.recordedAt.rawValue,
                CodingKeys.attempt.rawValue,
                CodingKeys.generation.rawValue,
            ],
            typeName: "RunLedgerMonitorDeadline"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            operationID: try container.decode(RunBrokerOperationID.self, forKey: .operationID),
            authority: try container.decode(RunBrokerAuthority.self, forKey: .authority),
            dueAt: try container.decode(Date.self, forKey: .dueAt),
            recordedAt: try container.decode(Date.self, forKey: .recordedAt),
            attempt: try container.decode(UInt64.self, forKey: .attempt),
            generation: try container.decode(UUID.self, forKey: .generation)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(operationID, forKey: .operationID)
        try container.encode(authority, forKey: .authority)
        try container.encode(dueAt, forKey: .dueAt)
        try container.encode(recordedAt, forKey: .recordedAt)
        try container.encode(attempt, forKey: .attempt)
        try container.encode(generation, forKey: .generation)
    }

    private static func canonicalMilliseconds(_ date: Date) -> Date {
        guard date.timeIntervalSince1970.isFinite else { return date }
        let milliseconds = Int64((date.timeIntervalSince1970 * 1_000).rounded(.towardZero))
        return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
    }
}

public enum RunLedgerMonitorAttemptDisposition: String, Codable, Equatable, Sendable {
    case completed
    case retryableFailure = "retryable_failure"
    case terminalFailure = "terminal_failure"
}

public enum RunLedgerMonitorAttemptApplyDisposition: String, Codable, Equatable, Sendable {
    case applied
    case stale
}

public struct RunLedgerMonitorAttemptProjection: Equatable, Sendable {
    public let eventID: RunLedgerEventID
    public let expected: RunLedgerMonitorDeadline
    public let attemptedAt: Date
    public let disposition: RunLedgerMonitorAttemptDisposition
    public let nextDeadline: RunLedgerMonitorDeadline?
    public let applyDisposition: RunLedgerMonitorAttemptApplyDisposition
    public let recordedSequence: Int64

    public init(
        eventID: RunLedgerEventID,
        expected: RunLedgerMonitorDeadline,
        attemptedAt: Date,
        disposition: RunLedgerMonitorAttemptDisposition,
        nextDeadline: RunLedgerMonitorDeadline?,
        applyDisposition: RunLedgerMonitorAttemptApplyDisposition,
        recordedSequence: Int64
    ) {
        self.eventID = eventID
        self.expected = expected
        self.attemptedAt = attemptedAt
        self.disposition = disposition
        self.nextDeadline = nextDeadline
        self.applyDisposition = applyDisposition
        self.recordedSequence = recordedSequence
    }
}

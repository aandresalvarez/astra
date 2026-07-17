import ASTRARunLedger
import Foundation

public enum RunBrokerProjectionApplyDisposition: Equatable, Sendable {
    /// The SwiftData (or future app-domain) transaction and its dedupe key are
    /// both durable. Only this result permits outbox acknowledgement.
    case durable
    case exactReplayDurable
    case notDurable
}

public protocol RunBrokerProjectionApplying: Sendable {
    func durablyApply(_ message: RunLedgerOutboxMessage) throws -> RunBrokerProjectionApplyDisposition
}

public final class RunBrokerProjectionDeliveryService: @unchecked Sendable {
    private let ledger: RunLedger
    private let projection: any RunBrokerProjectionApplying
    private let lock = NSLock()

    public init(ledger: RunLedger, projection: any RunBrokerProjectionApplying) {
        self.ledger = ledger
        self.projection = projection
    }

    /// Advances one message at a time. A crash after the app transaction but
    /// before acknowledgement replays the same message ID; the app projector's
    /// durable dedupe makes that exact replay safe.
    @discardableResult
    public func deliver(limit: Int = 1_000) throws -> Int {
        try lock.withLock {
            guard limit > 0 else { return 0 }
            var delivered = 0
            while delivered < limit {
                let acknowledged = try ledger.outboxAcknowledgedThrough()
                guard let message = try ledger.outbox(after: acknowledged, limit: 1).first else {
                    break
                }
                switch try projection.durablyApply(message) {
                case .durable, .exactReplayDurable:
                    _ = try ledger.acknowledgeOutbox(
                        sequence: message.sequence,
                        messageID: message.messageID
                    )
                    delivered += 1
                case .notDurable:
                    throw RunBrokerServiceError.projectionDidNotBecomeDurable
                }
            }
            return delivered
        }
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}

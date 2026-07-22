import Foundation
import RunBrokerClient

/// Service-owned application boundary. RunBrokerKit authenticates and bounds
/// the wire request; the broker service owns durable idempotency and effects.
public protocol RunBrokerApplicationCommandHandling: Sendable {
    /// Capability truth belongs to the handler that owns the effect boundary.
    /// Endpoint composition alone must never advertise destructive control.
    var supportsGracefulCancellation: Bool { get }
    var supportsImmediateTermination: Bool { get }

    func handle(
        _ command: RunBrokerApplicationCommand,
        idempotencyKey: UUID,
        now: Date
    ) throws -> RunBrokerApplicationResponse
}

public extension RunBrokerApplicationCommandHandling {
    var supportsGracefulCancellation: Bool { false }
    var supportsImmediateTermination: Bool { false }
}

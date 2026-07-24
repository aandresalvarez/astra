import Foundation
import RunBrokerClient
import ASTRACore

public protocol RunBrokerSchedulerClock: Sendable {
    var now: Date { get }
}

public struct SystemRunBrokerSchedulerClock: RunBrokerSchedulerClock {
    public init() {}
    public var now: Date { Date() }
}

public protocol RunBrokerSchedulerRandomSource: Sendable {
    /// Returns a deterministic-testable sample in the closed range 0...1.
    func nextUnitInterval() -> Double
}

public struct SystemRunBrokerSchedulerRandomSource: RunBrokerSchedulerRandomSource {
    public init() {}
    public func nextUnitInterval() -> Double { Double.random(in: 0...1) }
}

public protocol RunBrokerScheduledDeadline: AnyObject, Sendable {
    func cancel()
}

public protocol RunBrokerOneShotTimer: Sendable {
    func schedule(
        at deadline: Date,
        _ action: @escaping @Sendable () -> Void
    ) -> any RunBrokerScheduledDeadline
}

private final class DispatchRunBrokerDeadline: RunBrokerScheduledDeadline, @unchecked Sendable {
    private let lock = NSLock()
    private var source: DispatchSourceTimer?

    init(source: DispatchSourceTimer) {
        self.source = source
    }

    func cancel() {
        lock.lock()
        let source = self.source
        self.source = nil
        lock.unlock()
        source?.setEventHandler {}
        source?.cancel()
    }

    deinit { cancel() }
}

public struct DispatchRunBrokerOneShotTimer: RunBrokerOneShotTimer {
    private let queue: DispatchQueue
    private let now: @Sendable () -> Date

    public init(
        queue: DispatchQueue = DispatchQueue(label: "com.coral.astra.run-broker.scheduler"),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.queue = queue
        self.now = now
    }

    public func schedule(
        at deadline: Date,
        _ action: @escaping @Sendable () -> Void
    ) -> any RunBrokerScheduledDeadline {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + max(0, deadline.timeIntervalSince(now())))
        source.setEventHandler(handler: action)
        let token = DispatchRunBrokerDeadline(source: source)
        source.resume()
        return token
    }
}

public enum RunBrokerMonitorAttemptDisposition: String, Codable, Equatable, Sendable {
    case completed
    case retryableFailure = "retryable_failure"
    case terminalFailure = "terminal_failure"
}

public struct RunBrokerMonitorAttemptResult: Equatable, Sendable {
    public let disposition: RunBrokerMonitorAttemptDisposition

    public init(disposition: RunBrokerMonitorAttemptDisposition) {
        self.disposition = disposition
    }
}

public protocol RunBrokerExternalOperationMonitoring: Sendable {
    var isAvailable: Bool { get }
    func monitor(operationID: RunBrokerOperationID) throws -> RunBrokerMonitorAttemptResult
}

public extension RunBrokerExternalOperationMonitoring {
    var isAvailable: Bool { true }
}

/// PR4 supplies the durable implementation. Every mutation includes an
/// idempotency key; an unavailable ledger must fail before monitoring or timer
/// effects occur.
public protocol RunBrokerMonitorLedger: Sendable {
    var isAvailable: Bool { get }

    func recoverMonitorDeadlines() throws -> [RunBrokerMonitorDeadline]

    func upsertMonitorDeadline(
        _ deadline: RunBrokerMonitorDeadline,
        replacing expected: RunBrokerMonitorDeadline?,
        idempotencyKey: UUID
    ) throws -> RunBrokerMonitorMutationDisposition

    func removeMonitorDeadline(
        expected: RunBrokerMonitorDeadline,
        occurredAt: Date,
        idempotencyKey: UUID
    ) throws -> RunBrokerMonitorMutationDisposition

    func recordMonitorAttempt(
        expectedDeadline: RunBrokerMonitorDeadline,
        attemptedAt: Date,
        disposition: RunBrokerMonitorAttemptDisposition,
        nextDueAt: Date?,
        idempotencyKey: UUID
    ) throws -> RunBrokerMonitorAttemptCommit
}

public enum RunBrokerMonitorAttemptCommit: Equatable, Sendable {
    case applied
    case stale
}

public enum RunBrokerMonitorMutationDisposition: Equatable, Sendable {
    case appended
    case exactReplay
}

public enum RunBrokerLedgerError: Error, Equatable, Sendable {
    case unavailable
    case monitorScheduleConflict(RunBrokerOperationID)
}

public struct UnavailableRunBrokerMonitorLedger: RunBrokerMonitorLedger {
    public init() {}
    public var isAvailable: Bool { false }

    public func recoverMonitorDeadlines() throws -> [RunBrokerMonitorDeadline] {
        throw RunBrokerLedgerError.unavailable
    }

    public func upsertMonitorDeadline(
        _ deadline: RunBrokerMonitorDeadline,
        replacing expected: RunBrokerMonitorDeadline?,
        idempotencyKey: UUID
    ) throws -> RunBrokerMonitorMutationDisposition {
        throw RunBrokerLedgerError.unavailable
    }

    public func removeMonitorDeadline(
        expected: RunBrokerMonitorDeadline,
        occurredAt: Date,
        idempotencyKey: UUID
    ) throws -> RunBrokerMonitorMutationDisposition {
        throw RunBrokerLedgerError.unavailable
    }

    public func recordMonitorAttempt(
        expectedDeadline: RunBrokerMonitorDeadline,
        attemptedAt: Date,
        disposition: RunBrokerMonitorAttemptDisposition,
        nextDueAt: Date?,
        idempotencyKey: UUID
    ) throws -> RunBrokerMonitorAttemptCommit {
        throw RunBrokerLedgerError.unavailable
    }
}

public struct RunBrokerBackoffPolicy: Equatable, Sendable {
    public let initialDelay: TimeInterval
    public let maximumDelay: TimeInterval
    public let jitterFraction: Double

    public init(
        initialDelay: TimeInterval = 5,
        maximumDelay: TimeInterval = 15 * 60,
        jitterFraction: Double = 0.20
    ) {
        precondition(initialDelay > 0)
        precondition(maximumDelay >= initialDelay)
        precondition((0...1).contains(jitterFraction))
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
        self.jitterFraction = jitterFraction
    }

    public func retryDelay(attempt: UInt64, randomUnitInterval: Double) -> TimeInterval {
        let exponent = min(attempt, 20)
        let exponential = min(initialDelay * pow(2, Double(exponent)), maximumDelay)
        let sample = min(max(randomUnitInterval, 0), 1)
        let jitterMultiplier = 1 + ((sample * 2 - 1) * jitterFraction)
        return min(max(initialDelay, exponential * jitterMultiplier), maximumDelay)
    }
}

public enum RunBrokerSchedulerError: Error, Equatable, Sendable {
    case ledgerUnavailable
    case monitorUnavailable
    case duplicateRecoveredDeadline(RunBrokerOperationID)
    case monitorScheduleConflict(RunBrokerOperationID)
}

public struct UnavailableRunBrokerExternalOperationMonitor: RunBrokerExternalOperationMonitoring {
    public init() {}
    public var isAvailable: Bool { false }
    public func monitor(operationID: RunBrokerOperationID) throws -> RunBrokerMonitorAttemptResult {
        throw RunBrokerLedgerError.unavailable
    }
}

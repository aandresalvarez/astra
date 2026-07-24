import Foundation
import RunBrokerKit

struct RunBrokerRuntimeSwitchWorkerHealth: Equatable, Sendable {
    enum State: String, Equatable, Sendable {
        case stopped, idle, scheduled, reconciling, degraded
    }

    let state: State
    let consecutiveFailures: UInt64
    let lastErrorType: String?
    let lastFailureAt: Date?
}

/// Broker-process owner for durable runtime-switch progress. The ledger is the
/// source of truth; this worker only performs startup recovery and one-shot,
/// bounded-backoff retries while a persisted transition is awaiting evidence.
final class RunBrokerRuntimeSwitchReconciliationWorker: @unchecked Sendable {
    private let reconcile: @Sendable (Date) throws -> RunBrokerRuntimeSwitchReconciliationDisposition
    private let installSignal: @Sendable (@escaping @Sendable () -> Void) -> Void
    private let removeSignal: @Sendable () -> Void
    private let timer: any RunBrokerOneShotTimer
    private let clock: any RunBrokerSchedulerClock
    private let random: any RunBrokerSchedulerRandomSource
    private let backoff: RunBrokerBackoffPolicy
    private let logger: any RunBrokerServiceLogging
    private let lock = NSLock()

    private var started = false
    private var generation: UInt64 = 0
    private var retryAttempt: UInt64 = 0
    private var scheduleState: ScheduleState = .idle
    private var consecutiveFailures: UInt64 = 0
    private var lastErrorType: String?
    private var lastFailureAt: Date?

    private enum ScheduleState {
        case idle
        case arming(UInt64)
        case armed(UInt64, any RunBrokerScheduledDeadline)
        case firing(UInt64)
    }

    init(
        service: RunBrokerRuntimeSwitchService,
        timer: any RunBrokerOneShotTimer = DispatchRunBrokerOneShotTimer(
            queue: DispatchQueue(label: "com.coral.astra.run-broker.runtime-switch")
        ),
        clock: any RunBrokerSchedulerClock = SystemRunBrokerSchedulerClock(),
        random: any RunBrokerSchedulerRandomSource = SystemRunBrokerSchedulerRandomSource(),
        backoff: RunBrokerBackoffPolicy = .init(),
        logger: any RunBrokerServiceLogging = NoOpRunBrokerServiceLogger()
    ) {
        self.reconcile = { try service.reconcilePending(now: $0) }
        self.installSignal = { service.installReconciliationSignal($0) }
        self.removeSignal = { service.removeReconciliationSignal() }
        self.timer = timer
        self.clock = clock
        self.random = random
        self.backoff = backoff
        self.logger = logger
    }

    init(
        reconcile: @escaping @Sendable (Date) throws
            -> RunBrokerRuntimeSwitchReconciliationDisposition,
        installSignal: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void,
        removeSignal: @escaping @Sendable () -> Void,
        timer: any RunBrokerOneShotTimer,
        clock: any RunBrokerSchedulerClock,
        random: any RunBrokerSchedulerRandomSource,
        backoff: RunBrokerBackoffPolicy,
        logger: any RunBrokerServiceLogging = NoOpRunBrokerServiceLogger()
    ) {
        self.reconcile = reconcile
        self.installSignal = installSignal
        self.removeSignal = removeSignal
        self.timer = timer
        self.clock = clock
        self.random = random
        self.backoff = backoff
        self.logger = logger
    }

    /// Installs the broker-local mutation signal and always performs one
    /// startup pass. Repeated starts are exact no-ops.
    func start() {
        let shouldStart = lock.withLock {
            guard !started else { return false }
            started = true
            return true
        }
        guard shouldStart else { return }
        installSignal { [weak self] in self?.signal() }
        signal()
    }

    func stop() {
        removeSignal()
        let token = lock.withLock { () -> (any RunBrokerScheduledDeadline)? in
            guard started else { return nil }
            started = false
            generation &+= 1
            retryAttempt = 0
            defer { scheduleState = .idle }
            if case .armed(_, let token) = scheduleState { return token }
            return nil
        }
        token?.cancel()
    }

    deinit { stop() }

    func healthSnapshot() -> RunBrokerRuntimeSwitchWorkerHealth {
        lock.withLock {
            let state: RunBrokerRuntimeSwitchWorkerHealth.State
            if !started {
                state = .stopped
            } else if consecutiveFailures > 0 {
                state = .degraded
            } else {
                switch scheduleState {
                case .idle: state = .idle
                case .arming, .armed: state = .scheduled
                case .firing: state = .reconciling
                }
            }
            return .init(
                state: state,
                consecutiveFailures: consecutiveFailures,
                lastErrorType: lastErrorType,
                lastFailureAt: lastFailureAt
            )
        }
    }

    /// Coalesces a newly admitted/confirmed mutation with any later retry and
    /// moves the next pass to `now` without performing work on the caller.
    func signal() {
        replaceSchedule(at: clock.now, resetAttempt: true)
    }

    private func replaceSchedule(at deadline: Date, resetAttempt: Bool) {
        let preparation = lock.withLock { () -> (
            generation: UInt64,
            previous: (any RunBrokerScheduledDeadline)?
        )? in
            guard started else { return nil }
            if resetAttempt { retryAttempt = 0 }
            let previous: (any RunBrokerScheduledDeadline)?
            if case .armed(_, let token) = scheduleState {
                previous = token
            } else {
                previous = nil
            }
            generation &+= 1
            scheduleState = .arming(generation)
            return (generation, previous)
        }
        guard let preparation else { return }
        preparation.previous?.cancel()

        let token = timer.schedule(at: deadline) { [weak self] in
            self?.fire(generation: preparation.generation)
        }
        let keep = lock.withLock { () -> Bool in
            guard started, generation == preparation.generation,
                  case .arming(preparation.generation) = scheduleState else {
                return false
            }
            scheduleState = .armed(preparation.generation, token)
            return true
        }
        if !keep { token.cancel() }
    }

    private func fire(generation expectedGeneration: UInt64) {
        let shouldRun = lock.withLock { () -> Bool in
            guard started, generation == expectedGeneration else { return false }
            switch scheduleState {
            case .arming(expectedGeneration), .armed(expectedGeneration, _):
                scheduleState = .firing(expectedGeneration)
                return true
            case .idle, .arming, .armed, .firing:
                return false
            }
        }
        guard shouldRun else { return }

        do {
            let disposition = try reconcile(clock.now)
            logger.record(
                event: "run_broker.runtime_switch_reconciled",
                fields: ["disposition": disposition.logValue]
            )
            lock.withLock { consecutiveFailures = 0 }
            if disposition == .pending {
                scheduleRetry(after: expectedGeneration)
            } else {
                resetAttempt(ifGeneration: expectedGeneration)
            }
        } catch {
            let errorType = String(describing: type(of: error))
            lock.withLock {
                if consecutiveFailures < 1_000_000 { consecutiveFailures += 1 }
                lastErrorType = String(errorType.prefix(256))
                lastFailureAt = clock.now
            }
            logger.record(
                event: "run_broker.runtime_switch_reconcile_failed",
                fields: ["error_type": errorType]
            )
            scheduleRetry(after: expectedGeneration)
        }
    }

    private func scheduleRetry(after expectedGeneration: UInt64) {
        let deadline = lock.withLock { () -> Date? in
            guard started, generation == expectedGeneration,
                  case .firing(expectedGeneration) = scheduleState else { return nil }
            let delay = backoff.retryDelay(
                attempt: retryAttempt,
                randomUnitInterval: random.nextUnitInterval()
            )
            retryAttempt &+= 1
            return clock.now.addingTimeInterval(delay)
        }
        guard let deadline else { return }
        replaceSchedule(at: deadline, resetAttempt: false)
    }

    private func resetAttempt(ifGeneration expectedGeneration: UInt64) {
        lock.withLock {
            guard generation == expectedGeneration,
                  case .firing(expectedGeneration) = scheduleState else { return }
            retryAttempt = 0
            scheduleState = .idle
        }
    }
}

private extension RunBrokerRuntimeSwitchReconciliationDisposition {
    var logValue: String {
        switch self {
        case .idle: "idle"
        case .pending: "pending"
        case .awaitingConfirmation: "awaiting_confirmation"
        case .completed: "completed"
        case .inDoubt: "in_doubt"
        }
    }
}

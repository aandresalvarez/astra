import Foundation
import RunBrokerClient
import CryptoKit
import ASTRACore

/// Event/deadline-driven projection over the durable ledger. The in-memory
/// dictionary only determines which one-shot timer to arm; it is reconstructed
/// from the ledger after restart and is never an idempotency or ownership store.
public final class RunBrokerMonitorScheduler: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let ledger: any RunBrokerMonitorLedger
    private let monitor: any RunBrokerExternalOperationMonitoring
    private let timer: any RunBrokerOneShotTimer
    private let clock: any RunBrokerSchedulerClock
    private let random: any RunBrokerSchedulerRandomSource
    private let backoff: RunBrokerBackoffPolicy
    private let diagnostics: any RunBrokerDiagnosing
    private var deadlines: [RunBrokerOperationID: RunBrokerMonitorDeadline] = [:]
    private var armedDeadline: (any RunBrokerScheduledDeadline)?
    private var degraded = false
    private var wakeInProgress = false

    public init(
        ledger: any RunBrokerMonitorLedger,
        monitor: any RunBrokerExternalOperationMonitoring,
        timer: any RunBrokerOneShotTimer = DispatchRunBrokerOneShotTimer(),
        clock: any RunBrokerSchedulerClock = SystemRunBrokerSchedulerClock(),
        random: any RunBrokerSchedulerRandomSource = SystemRunBrokerSchedulerRandomSource(),
        backoff: RunBrokerBackoffPolicy = .init(),
        diagnostics: any RunBrokerDiagnosing = StandardErrorRunBrokerDiagnostics()
    ) {
        self.ledger = ledger
        self.monitor = monitor
        self.timer = timer
        self.clock = clock
        self.random = random
        self.backoff = backoff
        self.diagnostics = diagnostics
    }

    deinit { armedDeadline?.cancel() }

    public var ledgerAvailable: Bool { ledger.isAvailable }
    public var monitorAvailable: Bool { monitor.isAvailable }

    public var isOperational: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ledger.isAvailable && !degraded
    }

    public func recover() throws {
        try requireLedger()
        do {
            let validated = try validatedProjectionFromLedger()
            lock.lock()
            deadlines = validated
            degraded = false
            rearmLocked()
            lock.unlock()
        } catch {
            markDegraded()
            diagnostics.record(.schedulerRecoveryFailed, error: error)
            throw error
        }
    }

    public func upsert(
        _ deadline: RunBrokerMonitorDeadline,
        replacing expected: RunBrokerMonitorDeadline?,
        idempotencyKey: UUID
    ) throws {
        try requireLedger()
        let durableDeadline = RunBrokerMonitorDeadline(
            operationID: deadline.operationID,
            authority: deadline.authority,
            dueAt: deadline.dueAt,
            recordedAt: deadline.recordedAt,
            attempt: deadline.attempt,
            generation: idempotencyKey
        )
        do {
            _ = try ledger.upsertMonitorDeadline(
                durableDeadline,
                replacing: expected,
                idempotencyKey: idempotencyKey
            )
        } catch RunBrokerLedgerError.monitorScheduleConflict(let operationID) {
            try reconcileScheduleConflict(operationID)
        }
        // The durable event may be an exact replay while a later connection
        // has already advanced the schedule. Always fetch current truth rather
        // than applying the replayed command to this process's cache.
        try refreshFromDurableTruth()
    }

    public func remove(
        expected: RunBrokerMonitorDeadline,
        occurredAt: Date,
        idempotencyKey: UUID
    ) throws {
        try requireLedger()
        do {
            _ = try ledger.removeMonitorDeadline(
                expected: expected,
                occurredAt: occurredAt,
                idempotencyKey: idempotencyKey
            )
        } catch RunBrokerLedgerError.monitorScheduleConflict(let operationID) {
            try reconcileScheduleConflict(operationID)
        }
        try refreshFromDurableTruth()
    }

    public func status() throws -> [RunBrokerMonitorDeadline] {
        try requireLedger()
        try refreshFromDurableTruth(rearm: true)
        lock.lock()
        defer { lock.unlock() }
        return deadlines.values.sorted {
            if $0.dueAt != $1.dueAt { return $0.dueAt < $1.dueAt }
            return $0.operationID.rawValue.uuidString < $1.operationID.rawValue.uuidString
        }
    }

    public func wake() throws {
        try requireLedger()
        try requireMonitor()
        // Terminal application transitions remove deadlines in the same
        // RunLedger transaction without routing through this scheduler. Treat
        // the cache only as a timer projection and refresh before any monitor
        // side effect so an externally tombstoned operation is never polled.
        try refreshFromDurableTruth(rearm: false)
        lock.lock()
        guard !wakeInProgress else {
            lock.unlock()
            return
        }
        wakeInProgress = true
        armedDeadline?.cancel()
        armedDeadline = nil
        let now = clock.now
        let due = deadlines.values
            .filter { $0.dueAt <= now }
            .sorted(by: Self.deadlinePrecedes)
        lock.unlock()
        defer {
            lock.lock()
            wakeInProgress = false
            rearmLocked()
            lock.unlock()
        }

        for deadline in due {
            lock.lock()
            let isStillCurrent = deadlines[deadline.operationID] == deadline
            lock.unlock()
            guard isStillCurrent else { continue }

            let disposition: RunBrokerMonitorAttemptDisposition
            do {
                disposition = try monitor.monitor(operationID: deadline.operationID).disposition
            } catch {
                diagnostics.record(.schedulerOperationFailed, error: error)
                disposition = .retryableFailure
            }
            let next: RunBrokerMonitorDeadline?
            let attemptKey = Self.monitorAttemptIdempotencyKey(deadline)
            switch disposition {
            case .completed, .terminalFailure:
                next = nil
            case .retryableFailure:
                let nextAttempt = deadline.attempt == UInt64.max ? UInt64.max : deadline.attempt + 1
                next = RunBrokerMonitorDeadline(
                    operationID: deadline.operationID,
                    authority: deadline.authority,
                    dueAt: now.addingTimeInterval(
                        backoff.retryDelay(
                            attempt: nextAttempt,
                            randomUnitInterval: random.nextUnitInterval()
                        )
                    ),
                    recordedAt: now,
                    attempt: nextAttempt,
                    generation: attemptKey
                )
            }
            let commit: RunBrokerMonitorAttemptCommit
            do {
                commit = try ledger.recordMonitorAttempt(
                    expectedDeadline: deadline,
                    attemptedAt: now,
                    disposition: disposition,
                    nextDueAt: next?.dueAt,
                    idempotencyKey: attemptKey
                )
            } catch {
                diagnostics.record(.schedulerOperationFailed, error: error)
                markDegraded()
                return
            }
            lock.lock()
            if commit == .applied, deadlines[deadline.operationID] == deadline {
                deadlines[deadline.operationID] = next
            }
            lock.unlock()
            if commit == .stale {
                do {
                    try refreshProjectionFromLedger(rearm: false)
                } catch {
                    diagnostics.record(.schedulerRecoveryFailed, error: error)
                    markDegraded()
                    return
                }
            }
        }

    }

    private func requireLedger() throws {
        guard ledger.isAvailable else { throw RunBrokerSchedulerError.ledgerUnavailable }
    }

    private func requireMonitor() throws {
        guard monitor.isAvailable else { throw RunBrokerSchedulerError.monitorUnavailable }
    }

    private func rearmLocked() {
        armedDeadline?.cancel()
        armedDeadline = nil
        guard monitor.isAvailable,
              !degraded,
              let earliest = deadlines.values.min(by: Self.deadlinePrecedes) else { return }
        armedDeadline = timer.schedule(at: earliest.dueAt) { [weak self] in
            do {
                try self?.wake()
            } catch {
                self?.diagnostics.record(.schedulerOperationFailed, error: error)
            }
        }
    }

    private func refreshProjectionFromLedger(rearm: Bool) throws {
        let validated = try validatedProjectionFromLedger()
        lock.lock()
        deadlines = validated
        if rearm { rearmLocked() }
        lock.unlock()
    }

    private func refreshFromDurableTruth(rearm: Bool = true) throws {
        do {
            try refreshProjectionFromLedger(rearm: rearm)
        } catch {
            diagnostics.record(.schedulerRecoveryFailed, error: error)
            markDegraded()
            throw error
        }
    }

    private func reconcileScheduleConflict(_ operationID: RunBrokerOperationID) throws -> Never {
        try refreshFromDurableTruth()
        throw RunBrokerSchedulerError.monitorScheduleConflict(operationID)
    }

    private func validatedProjectionFromLedger() throws
        -> [RunBrokerOperationID: RunBrokerMonitorDeadline] {
        let recovered = try ledger.recoverMonitorDeadlines()
        var validated: [RunBrokerOperationID: RunBrokerMonitorDeadline] = [:]
        for deadline in recovered {
            guard validated[deadline.operationID] == nil else {
                throw RunBrokerSchedulerError.duplicateRecoveredDeadline(deadline.operationID)
            }
            validated[deadline.operationID] = deadline
        }
        return validated
    }

    private func markDegraded() {
        lock.lock()
        degraded = true
        armedDeadline?.cancel()
        armedDeadline = nil
        lock.unlock()
    }

    private static func deadlinePrecedes(
        _ lhs: RunBrokerMonitorDeadline,
        _ rhs: RunBrokerMonitorDeadline
    ) -> Bool {
        if lhs.dueAt != rhs.dueAt { return lhs.dueAt < rhs.dueAt }
        return lhs.operationID.rawValue.uuidString < rhs.operationID.rawValue.uuidString
    }

    private static func monitorAttemptIdempotencyKey(
        _ deadline: RunBrokerMonitorDeadline
    ) -> UUID {
        let milliseconds = Int64(
            (deadline.dueAt.timeIntervalSince1970 * 1_000).rounded(.towardZero)
        )
        let material = Data(
            "astra.monitor-attempt.v1|\(deadline.operationID.rawValue.uuidString)|\(deadline.authority.id.rawValue.uuidString)|\(deadline.authority.epoch.rawValue)|\(deadline.generation.uuidString)|\(deadline.attempt)|\(milliseconds)"
                .utf8
        )
        let bytes = Array(SHA256.hash(data: material).prefix(16))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

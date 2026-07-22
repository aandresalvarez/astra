import ASTRACore
import ASTRARunLedger
import Foundation
import RunBrokerKit

/// Broker-owned liveness loop for active executions. Durable ledger state is
/// the work queue; the timer is only a retry trigger and never owns progress.
final class RunBrokerExecutionReconciliationWorker: @unchecked Sendable {
    private let activeExecutions: @Sendable () throws -> [RunBrokerExecutionID]
    private let reconcile: @Sendable (RunBrokerExecutionID) throws -> Void
    private let timer: any RunBrokerOneShotTimer
    private let clock: any RunBrokerSchedulerClock
    private let interval: TimeInterval
    private let logger: any RunBrokerServiceLogging
    private let lock = NSLock()
    private var started = false
    private var generation: UInt64 = 0
    private var scheduled: (any RunBrokerScheduledDeadline)?

    init(
        ledger: RunLedger,
        orchestrator: RunBrokerOrchestrator,
        timer: any RunBrokerOneShotTimer = DispatchRunBrokerOneShotTimer(
            queue: DispatchQueue(label: "com.coral.astra.run-broker.executions")
        ),
        clock: any RunBrokerSchedulerClock = SystemRunBrokerSchedulerClock(),
        interval: TimeInterval = 1,
        logger: any RunBrokerServiceLogging = NoOpRunBrokerServiceLogger()
    ) {
        self.activeExecutions = {
            try ledger.projection().executions.values
                .filter { !$0.control.observedExecution.isAuthoritativelyTerminal }
                .map { $0.manifest.executionID }
                .sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
        }
        self.reconcile = { _ = try orchestrator.reconcile(executionID: $0) }
        self.timer = timer
        self.clock = clock
        self.interval = interval
        self.logger = logger
    }

    init(
        activeExecutions: @escaping @Sendable () throws -> [RunBrokerExecutionID],
        reconcile: @escaping @Sendable (RunBrokerExecutionID) throws -> Void,
        timer: any RunBrokerOneShotTimer,
        clock: any RunBrokerSchedulerClock,
        interval: TimeInterval,
        logger: any RunBrokerServiceLogging = NoOpRunBrokerServiceLogger()
    ) {
        self.activeExecutions = activeExecutions
        self.reconcile = reconcile
        self.timer = timer
        self.clock = clock
        self.interval = interval
        self.logger = logger
    }

    func start() {
        let currentGeneration = lock.withLock { () -> UInt64? in
            guard !started else { return nil }
            started = true
            generation &+= 1
            return generation
        }
        guard let currentGeneration else { return }
        runPass(generation: currentGeneration)
    }

    func stop() {
        let token = lock.withLock { () -> (any RunBrokerScheduledDeadline)? in
            guard started else { return nil }
            started = false
            generation &+= 1
            defer { scheduled = nil }
            return scheduled
        }
        token?.cancel()
    }

    deinit { stop() }

    private func runPass(generation expectedGeneration: UInt64) {
        guard lock.withLock({ started && generation == expectedGeneration }) else { return }
        let executionIDs: [RunBrokerExecutionID]
        do {
            executionIDs = try activeExecutions()
            for executionID in executionIDs {
                do {
                    try reconcile(executionID)
                } catch {
                    logger.record(
                        event: "run_broker.execution_reconciliation_failed",
                        fields: [
                            "execution_id": executionID.rawValue.uuidString.lowercased(),
                            "error_type": String(describing: type(of: error)),
                        ]
                    )
                }
            }
        } catch {
            logger.record(
                event: "run_broker.execution_reconciliation_scan_failed",
                fields: ["error_type": String(describing: type(of: error))]
            )
            schedule(generation: expectedGeneration)
            return
        }

        // Re-read durable state after ingestion. Stop polling only when no
        // execution remains active; a quiet supervisor replay is not terminal.
        do {
            if try !activeExecutions().isEmpty {
                schedule(generation: expectedGeneration)
            }
        } catch {
            schedule(generation: expectedGeneration)
        }
    }

    private func schedule(generation expectedGeneration: UInt64) {
        let token = timer.schedule(at: clock.now.addingTimeInterval(interval)) { [weak self] in
            self?.timerFired(generation: expectedGeneration)
        }
        let shouldKeep = lock.withLock { () -> Bool in
            guard started, generation == expectedGeneration else { return false }
            scheduled = token
            return true
        }
        if !shouldKeep { token.cancel() }
    }

    private func timerFired(generation expectedGeneration: UInt64) {
        let shouldRun = lock.withLock { () -> Bool in
            guard started, generation == expectedGeneration else { return false }
            scheduled = nil
            return true
        }
        if shouldRun { runPass(generation: expectedGeneration) }
    }
}

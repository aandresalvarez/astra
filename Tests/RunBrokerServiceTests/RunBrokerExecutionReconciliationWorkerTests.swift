import ASTRACore
import Foundation
import RunBrokerKit
import Testing
@testable import RunBrokerService

@Suite("RunBroker active execution reconciliation")
struct RunBrokerExecutionReconciliationWorkerTests {
    @Test("quiet active execution remains scheduled until terminal evidence arrives")
    func quietGapDoesNotEndBrokerOwnedReconciliation() throws {
        let executionID = RunBrokerExecutionID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000901")!
        )
        let state = ExecutionWorkerState(executionID: executionID)
        let timer = ExecutionWorkerTimer()
        let worker = RunBrokerExecutionReconciliationWorker(
            activeExecutions: { state.activeExecutions },
            reconcile: { state.recordReconciliation($0) },
            timer: timer,
            clock: ExecutionWorkerClock(now: Date(timeIntervalSince1970: 100)),
            interval: 1
        )

        worker.start()
        #expect(state.reconciliations == [executionID])
        #expect(timer.pendingCount == 1)

        let scheduledPass = try #require(timer.fireNext())
        scheduledPass()
        #expect(state.reconciliations == [executionID, executionID])
        #expect(timer.pendingCount == 1)

        state.terminal = true
        let terminalPass = try #require(timer.fireNext())
        terminalPass()
        #expect(state.reconciliations == [executionID, executionID])
        #expect(timer.pendingCount == 0)
    }
}

private final class ExecutionWorkerState: @unchecked Sendable {
    private let lock = NSLock()
    private let executionID: RunBrokerExecutionID
    private var isTerminal = false
    private var recorded: [RunBrokerExecutionID] = []

    init(executionID: RunBrokerExecutionID) { self.executionID = executionID }

    var terminal: Bool {
        get { lock.withLock { isTerminal } }
        set { lock.withLock { isTerminal = newValue } }
    }

    var activeExecutions: [RunBrokerExecutionID] {
        lock.withLock { isTerminal ? [] : [executionID] }
    }

    var reconciliations: [RunBrokerExecutionID] { lock.withLock { recorded } }

    func recordReconciliation(_ executionID: RunBrokerExecutionID) {
        lock.withLock { recorded.append(executionID) }
    }
}

private final class ExecutionWorkerToken: RunBrokerScheduledDeadline, @unchecked Sendable {
    var cancelled = false
    func cancel() { cancelled = true }
}

private final class ExecutionWorkerTimer: RunBrokerOneShotTimer, @unchecked Sendable {
    private let lock = NSLock()
    private var actions: [@Sendable () -> Void] = []
    var pendingCount: Int { lock.withLock { actions.count } }

    func schedule(
        at deadline: Date,
        _ action: @escaping @Sendable () -> Void
    ) -> any RunBrokerScheduledDeadline {
        lock.withLock { actions.append(action) }
        return ExecutionWorkerToken()
    }

    func fireNext() -> (@Sendable () -> Void)? {
        lock.withLock { actions.isEmpty ? nil : actions.removeFirst() }
    }
}

private struct ExecutionWorkerClock: RunBrokerSchedulerClock {
    let now: Date
}

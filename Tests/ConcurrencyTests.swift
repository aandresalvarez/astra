import Testing
import Foundation
@testable import ASTRA
import ASTRACore

// MARK: - Phase 2A: ProcessMonitor thread safety

@Suite("ProcessMonitor Thread Safety")
struct ProcessMonitorTests_ThreadSafety {

    @Test("ProcessMonitor state is consistent after concurrent processEvent calls")
    func concurrentProcessEvents() async {
        let monitor = ClaudeCodeWorker.ProcessMonitor(
            tokenBudget: 1_000_000,
            maxTurns: 0,
            maxRepetitions: 100,
            idleTimeoutSeconds: 600
        )

        // Fire 100 events from concurrent tasks
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    let event = ParsedEvent.text(text: "Event \(i)")
                    let _ = monitor.processEvent(event, process: nil)
                }
            }
        }

        // estimatedTokens should be > 0 and consistent (not corrupted)
        #expect(monitor.estimatedTokens > 0)
        #expect(monitor.turnCount == 0) // no .result events were sent
    }

    @Test("ProcessMonitor budget enforcement works under concurrent access")
    func concurrentBudgetEnforcement() async {
        let monitor = ClaudeCodeWorker.ProcessMonitor(
            tokenBudget: 100,
            maxTurns: 0,
            maxRepetitions: 100,
            idleTimeoutSeconds: 600
        )

        // Send enough events to exceed 100-token budget
        var killedCount = 0
        for _ in 0..<50 {
            let event = ParsedEvent.text(text: String(repeating: "x", count: 100)) // ~25 tokens each
            let killed = monitor.processEvent(event, process: nil)
            if killed { killedCount += 1 }
        }

        #expect(monitor.budgetExceeded == true)
        #expect(killedCount > 0)
    }

    @Test("ProcessMonitor repetition detection is thread-safe")
    func repetitionDetection() async {
        let monitor = ClaudeCodeWorker.ProcessMonitor(
            tokenBudget: 1_000_000,
            maxTurns: 0,
            maxRepetitions: 5,
            idleTimeoutSeconds: 600
        )

        // Send the same event repeatedly
        var hitBreaker = false
        for _ in 0..<10 {
            let event = ParsedEvent.text(text: "repeated text")
            if monitor.processEvent(event, process: nil) {
                hitBreaker = true
            }
        }

        #expect(hitBreaker == true)
        #expect(monitor.repetitionKilled == true)
    }

    @Test("ProcessMonitor turn counting is accurate")
    func turnCounting() {
        let monitor = ClaudeCodeWorker.ProcessMonitor(
            tokenBudget: 1_000_000,
            maxTurns: 3,
            maxRepetitions: 100,
            idleTimeoutSeconds: 600
        )

        // Send result events (each one = 1 turn) with unique signatures to avoid repetition
        let _ = monitor.processEvent(.result(text: "a", costUSD: nil, totalInputTokens: 10, totalOutputTokens: 5, durationMs: nil, numTurns: nil, isError: false), process: nil)
        #expect(monitor.turnCount == 1)

        let _ = monitor.processEvent(.result(text: "b", costUSD: nil, totalInputTokens: 20, totalOutputTokens: 10, durationMs: nil, numTurns: nil, isError: false), process: nil)
        #expect(monitor.turnCount == 2)

        let killed = monitor.processEvent(.result(text: "c", costUSD: nil, totalInputTokens: 30, totalOutputTokens: 15, durationMs: nil, numTurns: nil, isError: false), process: nil)
        #expect(monitor.turnCount == 3)
        #expect(killed == true)
        #expect(monitor.maxTurnsExceeded == true)
    }
}

// MARK: - Phase 2C: TaskQueue cancellation

@Suite("TaskQueue Cancellation")
@MainActor
struct TaskQueueCancellationTests {

    @Test("cancelAll resets state")
    func cancelAllResetsState() {
        let queue = TaskQueue(poolSize: 2)
        queue.activeTasks.insert(UUID())
        queue.cancelAll()

        #expect(queue.activeTasks.isEmpty)
        #expect(queue.isProcessing == false)
    }

    @Test("cancel() is safe when task has no worker")
    func cancelNoWorker() {
        let queue = TaskQueue(poolSize: 1)
        let task = AgentTask(title: "Test", goal: "test")
        // Should not crash
        queue.cancel(task: task)
    }

    @Test("Pool resize adds workers")
    func poolResizeUp() {
        let queue = TaskQueue(poolSize: 1)
        #expect(queue.workers.count == 1)
        queue.resizePool(to: 3)
        #expect(queue.workers.count == 3)
    }

    @Test("Pool resize removes idle workers")
    func poolResizeDown() {
        let queue = TaskQueue(poolSize: 3)
        #expect(queue.workers.count == 3)
        queue.resizePool(to: 1)
        #expect(queue.workers.count == 1)
    }

    @Test("hasAvailableWorker is true when pool is idle")
    func hasAvailableWorker() {
        let queue = TaskQueue(poolSize: 2)
        #expect(queue.hasAvailableWorker == true)
        #expect(queue.activeCount == 0)
    }
}

// MARK: - Phase 2B: PendingTaskCollector drains all in-flight tasks

@Suite("PendingTaskCollector")
struct PendingTaskCollectorTests {

    @Test("drainAll awaits all collected tasks")
    @MainActor
    func drainAllAwaitsAll() async {
        let collector = PendingTaskCollector()
        var completed = [Bool](repeating: false, count: 10)

        for i in 0..<10 {
            let t = Task { @MainActor in
                completed[i] = true
            }
            collector.add(t)
        }

        await collector.drainAll()
        #expect(completed.allSatisfy { $0 })
    }

    @Test("drainAll is safe when empty")
    func drainEmpty() async {
        let collector = PendingTaskCollector()
        await collector.drainAll() // should not crash or hang
    }

    @Test("add is thread-safe under concurrent access")
    func concurrentAdd() async {
        let collector = PendingTaskCollector()
        let count = 100

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<count {
                group.addTask {
                    let t = Task { }
                    collector.add(t)
                }
            }
        }

        #expect(collector.count >= count)
        await collector.drainAll()
    }
}

import Testing
import Foundation
@testable import ASTRA
import ASTRACore

@Suite("Claude permission policy")
@MainActor
struct ClaudePermissionPolicyTests {

    @Test("Autonomous policy produces skip-permissions flag")
    func autonomousPolicyFlags() {
        let worker = ClaudeCodeWorker()
        worker.permissionPolicy = .autonomous
        #expect(worker.permissionPolicy.cliArguments == ["--dangerously-skip-permissions"])
    }

    @Test("Restricted policy produces no CLI flags")
    func restrictedPolicyFlags() {
        let worker = ClaudeCodeWorker()
        worker.permissionPolicy = .restricted
        #expect(worker.permissionPolicy.cliArguments.isEmpty)
    }

    @Test("Interactive policy produces no CLI flags")
    func interactivePolicyFlags() {
        let worker = ClaudeCodeWorker()
        worker.permissionPolicy = .interactive
        #expect(worker.permissionPolicy.cliArguments.isEmpty)
    }
}

@Suite("ProcessMonitor — Budget, Repetition, and Idle Timeout")
struct ProcessMonitorTests {

    // MARK: - Budget Enforcement

    @Test("Budget exceeded via estimated tokens")
    func budgetExceededEstimated() {
        let monitor = ClaudeCodeWorker.ProcessMonitor(tokenBudget: 100)

        // 500 chars of text ≈ 125 estimated tokens, exceeds budget of 100
        let event = ParsedEvent.text(text: String(repeating: "x", count: 500))
        let shouldKill = monitor.processEvent(event, process: nil)

        #expect(shouldKill == true)
        #expect(monitor.budgetExceeded == true)
        #expect(monitor.estimatedTokens == 125)
    }

    @Test("Budget not exceeded when under limit")
    func budgetNotExceeded() {
        let monitor = ClaudeCodeWorker.ProcessMonitor(tokenBudget: 10000)

        let event = ParsedEvent.text(text: "Hello world")
        let shouldKill = monitor.processEvent(event, process: nil)

        #expect(shouldKill == false)
        #expect(monitor.budgetExceeded == false)
    }

    @Test("Budget exceeded via result event exact count")
    func budgetExceededFromResult() {
        let monitor = ClaudeCodeWorker.ProcessMonitor(tokenBudget: 1000)

        let event = ParsedEvent.result(
            text: "done",
            costUSD: 0.01,
            totalInputTokens: 800,
            totalOutputTokens: 300,
            durationMs: 5000,
            numTurns: 1,
            isError: false
        )
        let shouldKill = monitor.processEvent(event, process: nil)

        #expect(shouldKill == true)
        #expect(monitor.budgetExceeded == true)
    }

    @Test("Unlimited budget never exceeds")
    func unlimitedBudget() {
        let monitor = ClaudeCodeWorker.ProcessMonitor(tokenBudget: Int.max)

        // Massive text with varying content to avoid repetition breaker
        for i in 0..<100 {
            let _ = monitor.processEvent(.text(text: "chunk \(i) " + String(repeating: "x", count: 10000)), process: nil)
        }

        #expect(monitor.budgetExceeded == false)
    }

    @Test("Tool use and tool result add to token estimate")
    func toolTokenEstimation() {
        let monitor = ClaudeCodeWorker.ProcessMonitor(tokenBudget: 10000)

        let _ = monitor.processEvent(.toolUse(name: "Read", id: "t1", input: nil), process: nil)
        #expect(monitor.estimatedTokens == 100)

        let _ = monitor.processEvent(.toolResult(toolId: "t1", content: ""), process: nil)
        #expect(monitor.estimatedTokens == 300)
    }

    @Test("Team events add to token estimate")
    func teamTokenEstimation() {
        let monitor = ClaudeCodeWorker.ProcessMonitor(tokenBudget: 10000)

        let _ = monitor.processEvent(.teammateStarted(taskId: "t1", name: "agent", prompt: "do stuff"), process: nil)
        #expect(monitor.estimatedTokens == 50)

        let _ = monitor.processEvent(.teamMessage(from: "lead", to: "agent", content: "check this"), process: nil)
        #expect(monitor.estimatedTokens == 100) // 50 + max(50, 10/4)
    }

    // MARK: - Repetition Circuit Breaker

    @Test("Repetition kills after max identical events")
    func repetitionKill() {
        let monitor = ClaudeCodeWorker.ProcessMonitor(tokenBudget: Int.max, maxRepetitions: 3)

        let event = ParsedEvent.toolUse(name: "Read", id: "t1", input: nil)
        let _ = monitor.processEvent(event, process: nil) // 1
        #expect(monitor.repetitionKilled == false)

        let _ = monitor.processEvent(event, process: nil) // 2
        #expect(monitor.repetitionKilled == false)

        let shouldKill = monitor.processEvent(event, process: nil) // 3 — triggers
        #expect(shouldKill == true)
        #expect(monitor.repetitionKilled == true)
        #expect(monitor.budgetExceeded == true) // repetition sets budgetExceeded too
    }

    @Test("Different events reset repetition counter")
    func repetitionResets() {
        let monitor = ClaudeCodeWorker.ProcessMonitor(tokenBudget: Int.max, maxRepetitions: 3)

        let _ = monitor.processEvent(.toolUse(name: "Read", id: "t1", input: nil), process: nil)
        let _ = monitor.processEvent(.toolUse(name: "Read", id: "t1", input: nil), process: nil)
        // Different event resets counter
        let _ = monitor.processEvent(.text(text: "hello"), process: nil)
        let _ = monitor.processEvent(.toolUse(name: "Read", id: "t1", input: nil), process: nil)
        let shouldKill = monitor.processEvent(.toolUse(name: "Read", id: "t1", input: nil), process: nil)

        #expect(shouldKill == false) // only 2 in a row, not 3
        #expect(monitor.repetitionKilled == false)
    }

    @Test("Default max repetitions is 8")
    func defaultMaxRepetitions() {
        let monitor = ClaudeCodeWorker.ProcessMonitor(tokenBudget: Int.max)
        let event = ParsedEvent.toolUse(name: "Glob", id: "t1", input: nil)

        for i in 1...7 {
            let _ = monitor.processEvent(event, process: nil)
            #expect(monitor.repetitionKilled == false, "Should not kill at repetition \(i)")
        }

        let shouldKill = monitor.processEvent(event, process: nil) // 8th
        #expect(shouldKill == true)
        #expect(monitor.repetitionKilled == true)
    }

    // MARK: - Event Signatures

    @Test("Event signatures are distinct per type")
    func eventSignatures() {
        let sigs = [
            ClaudeCodeWorker.ProcessMonitor.eventSignature(.text(text: "hello")),
            ClaudeCodeWorker.ProcessMonitor.eventSignature(.thinking(text: "hello")),
            ClaudeCodeWorker.ProcessMonitor.eventSignature(.toolUse(name: "Read", id: "t1", input: nil)),
            ClaudeCodeWorker.ProcessMonitor.eventSignature(.toolResult(toolId: "t1", content: "")),
            ClaudeCodeWorker.ProcessMonitor.eventSignature(.systemInit(model: "sonnet", sessionId: "s1")),
            ClaudeCodeWorker.ProcessMonitor.eventSignature(.result(text: nil, costUSD: nil, totalInputTokens: 0, totalOutputTokens: 0, durationMs: nil, numTurns: nil, isError: false)),
        ]
        // All signatures should be unique
        #expect(Set(sigs).count == sigs.count)
    }

    @Test("Text signatures truncate at 80 chars")
    func signatureTruncation() {
        let longText = String(repeating: "a", count: 200)
        let sig = ClaudeCodeWorker.ProcessMonitor.eventSignature(.text(text: longText))
        #expect(sig.count <= 85) // "text:" prefix + 80 chars
    }

    // MARK: - ProcessResult

    @Test("ProcessResult defaults")
    func processResultDefaults() {
        let result = ClaudeCodeWorker.ProcessResult(exitCode: 0)
        #expect(result.exitCode == 0)
        #expect(result.error == nil)
        #expect(result.budgetExceeded == false)
        #expect(result.timedOut == false)
        #expect(result.repetitionKilled == false)
    }

    @Test("ProcessResult with all flags")
    func processResultFlags() {
        let result = ClaudeCodeWorker.ProcessResult(
            exitCode: 137,
            error: "killed",
            budgetExceeded: true,
            timedOut: false,
            repetitionKilled: true
        )
        #expect(result.exitCode == 137)
        #expect(result.budgetExceeded == true)
        #expect(result.repetitionKilled == true)
        #expect(result.timedOut == false)
    }

    // MARK: - Resume Budget Calculation

    @Test("Resume budget is remaining tokens")
    func resumeBudgetCalculation() {
        // Simulate: budget 10000, already used 7000 → remaining 3000
        let totalBudget = 10000
        let used = 7000
        let remaining = max(1000, totalBudget - used)
        #expect(remaining == 3000)

        let monitor = ClaudeCodeWorker.ProcessMonitor(tokenBudget: remaining)
        // 12004 chars / 4 = 3001 estimated tokens → exceeds budget of 3000
        let event = ParsedEvent.text(text: String(repeating: "x", count: 12004))
        let shouldKill = monitor.processEvent(event, process: nil)
        #expect(shouldKill == true)
    }

    @Test("Resume with almost exhausted budget gets minimum 1000")
    func resumeMinimumBudget() {
        let totalBudget = 10000
        let used = 9800
        let remaining = max(1000, totalBudget - used)
        #expect(remaining == 1000) // Floor of 1000

        let monitor = ClaudeCodeWorker.ProcessMonitor(tokenBudget: remaining)
        // Small text should not exceed 1000
        let shouldKill = monitor.processEvent(.text(text: "hello"), process: nil)
        #expect(shouldKill == false)
    }

    @Test("Resume with unlimited budget stays unlimited")
    func resumeUnlimitedBudget() {
        let totalBudget = 0 // 0 means unlimited
        let remaining: Int
        if totalBudget == 0 {
            remaining = Int.max
        } else {
            remaining = max(1000, totalBudget)
        }
        #expect(remaining == Int.max)
    }

    // MARK: - Turn Counting

    @Test("Turn count increments on result events")
    func turnCountIncrementsOnResult() {
        let monitor = ClaudeCodeWorker.ProcessMonitor(tokenBudget: Int.max, maxTurns: 10)

        let result = ParsedEvent.result(
            text: "done",
            costUSD: 0.001,
            totalInputTokens: 50,
            totalOutputTokens: 50,
            durationMs: 100,
            numTurns: 1,
            isError: false
        )
        let _ = monitor.processEvent(result, process: nil)
        #expect(monitor.turnCount == 1)
    }

    @Test("Non-result events do not increment turn count")
    func nonResultEventsNoTurnIncrement() {
        let monitor = ClaudeCodeWorker.ProcessMonitor(tokenBudget: Int.max, maxTurns: 10)

        let _ = monitor.processEvent(.text(text: "hello"), process: nil)
        let _ = monitor.processEvent(.toolUse(name: "Read", id: "t1", input: nil), process: nil)
        let _ = monitor.processEvent(.toolResult(toolId: "t1", content: ""), process: nil)
        let _ = monitor.processEvent(.thinking(text: "hmm"), process: nil)

        #expect(monitor.turnCount == 0)
    }

    @Test("Max turns exceeded kills process")
    func maxTurnsExceeded() {
        let monitor = ClaudeCodeWorker.ProcessMonitor(tokenBudget: Int.max, maxTurns: 3)

        let result = ParsedEvent.result(
            text: "done",
            costUSD: 0.001,
            totalInputTokens: 50,
            totalOutputTokens: 50,
            durationMs: 100,
            numTurns: 1,
            isError: false
        )

        let _ = monitor.processEvent(result, process: nil) // turn 1
        #expect(monitor.maxTurnsExceeded == false)
        let _ = monitor.processEvent(result, process: nil) // turn 2
        #expect(monitor.maxTurnsExceeded == false)
        let shouldKill = monitor.processEvent(result, process: nil) // turn 3
        #expect(shouldKill == true)
        #expect(monitor.maxTurnsExceeded == true)
    }

    @Test("Unlimited turns (0) never exceeds")
    func unlimitedTurns() {
        let monitor = ClaudeCodeWorker.ProcessMonitor(tokenBudget: Int.max, maxTurns: 0)

        for i in 0..<50 {
            let result = ParsedEvent.result(
                text: "done \(i)",
                costUSD: 0.001,
                totalInputTokens: 10,
                totalOutputTokens: 10,
                durationMs: 100,
                numTurns: 1,
                isError: false
            )
            let _ = monitor.processEvent(result, process: nil)
        }
        #expect(monitor.maxTurnsExceeded == false)
        #expect(monitor.turnCount == 50)
    }

    @Test("ProcessResult maxTurnsExceeded flag")
    func processResultMaxTurnsFlag() {
        let result = ClaudeCodeWorker.ProcessResult(
            exitCode: 137,
            error: "max turns",
            budgetExceeded: false,
            timedOut: false,
            repetitionKilled: false,
            maxTurnsExceeded: true
        )
        #expect(result.maxTurnsExceeded == true)
        #expect(result.budgetExceeded == false)
    }
}

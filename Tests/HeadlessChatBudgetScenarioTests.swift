import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA
import ASTRACore

extension HeadlessChatScenarioTests {
    @Test("Headless chat enforces budget guardrails")
    func headlessChatEnforcesBudget() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let largeOutput = String(repeating: "x", count: 600)
        let launchMarker = harness.rootURL.appendingPathComponent("hard-stop-launched")
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            printf 'launched\\n' > '\(launchMarker.path)'
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"\(largeOutput)"}}'
            sleep 1
            exit 0
            """)
        )

        let task = harness.makeTask(
            runtime: .copilotCLI,
            goal: "Produce too much output",
            model: "gpt-5",
            tokenBudget: 20
        )
        let worker = harness.makeWorker(runtime: .copilotCLI, executablePath: copilotPath)
        worker.budgetEnforcementModeOverride = .hardStop

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .budgetExceeded)
        #expect(run.status == .budgetExceeded)
        #expect(run.stopReason == "max_budget_reached")
        #expect(!FileManager.default.fileExists(atPath: launchMarker.path))
        #expect(task.events.contains { $0.type == "budget.exceeded" })
    }

    @Test("Copilot hard stop rejects prompt estimate before starting")
    func copilotHardStopRejectsPromptEstimateBeforeLaunch() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let launchMarker = harness.rootURL.appendingPathComponent("copilot-low-budget-launched")
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            printf 'launched\\n' > '\(launchMarker.path)'
            printf '%s\\n' '{"type":"usage","usage":{"input_tokens":1,"output_tokens":1},"duration_ms":10,"turns":1}'
            exit 0
            """)
        )

        let task = harness.makeTask(
            runtime: .copilotCLI,
            goal: String(repeating: "x", count: 400),
            model: "gpt-5",
            tokenBudget: 20
        )
        let worker = harness.makeWorker(runtime: .copilotCLI, executablePath: copilotPath)
        worker.budgetEnforcementModeOverride = .hardStop

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .budgetExceeded)
        #expect(run.status == .budgetExceeded)
        #expect(run.stopReason == "max_budget_reached")
        #expect(!worker.isRunning)
        #expect(!FileManager.default.fileExists(atPath: launchMarker.path))
        #expect(task.events.contains { $0.type == "budget.exceeded" && $0.payload.contains("Provider was not started") })
    }

    @Test("Copilot hard stop enforces reported usage")
    func copilotHardStopEnforcesReportedUsage() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let launchMarker = harness.rootURL.appendingPathComponent("copilot-usage-launched")
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            printf 'launched\\n' > '\(launchMarker.path)'
            printf '%s\\n' '{"type":"usage","usage":{"input_tokens":12000,"output_tokens":15},"duration_ms":10,"turns":1}'
            exit 0
            """)
        )

        let task = harness.makeTask(
            runtime: .copilotCLI,
            goal: "Use reported usage",
            model: "gpt-5",
            tokenBudget: 10_000
        )
        let worker = harness.makeWorker(runtime: .copilotCLI, executablePath: copilotPath)
        worker.budgetEnforcementModeOverride = .hardStop

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .budgetExceeded)
        #expect(run.status == .budgetExceeded)
        #expect(run.stopReason == "max_budget_reached")
        #expect(FileManager.default.fileExists(atPath: launchMarker.path))
        #expect(task.events.contains { $0.type == "budget.exceeded" })
    }

    @Test("Headless chat warning budget records warning and keeps running")
    func headlessChatWarningBudgetKeepsRunning() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let launchMarker = harness.rootURL.appendingPathComponent("warning-launched")
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            printf 'launched\\n' > '\(launchMarker.path)'
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Warning mode still runs"}}'
            printf '%s\\n' '{"type":"usage","usage":{"input_tokens":30,"output_tokens":15},"duration_ms":10,"turns":1}'
            exit 0
            """)
        )

        let task = harness.makeTask(
            runtime: .copilotCLI,
            goal: "Produce output above budget",
            model: "gpt-5",
            tokenBudget: 20
        )
        let worker = harness.makeWorker(runtime: .copilotCLI, executablePath: copilotPath)
        worker.budgetEnforcementModeOverride = .warning

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .completed)
        #expect(run.status == .completed)
        #expect(run.tokensUsed == 45)
        #expect(task.tokensUsed == 45)
        #expect(FileManager.default.fileExists(atPath: launchMarker.path))
        #expect(task.events.contains { $0.type == "budget.warning" })
        #expect(!task.events.contains { $0.type == "budget.exceeded" })
    }

    @Test("Antigravity estimated usage participates in final budget warnings")
    func antigravityEstimatedUsageRecordsFinalBudgetWarning() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let antigravityPath = try harness.writeExecutable(
            named: "agy",
            script: """
            #!/bin/sh
            if [ "$1" = "--version" ]; then
              printf '%s\\n' '1.0.3'
              exit 0
            fi
            /usr/bin/python3 - <<'PY'
            print("A" * 5000)
            PY
            exit 0
            """
        )

        let task = harness.makeTask(
            runtime: .antigravityCLI,
            goal: "Produce a long Antigravity response",
            model: "Gemini 3.5 Flash",
            tokenBudget: 1_000
        )
        let worker = harness.makeWorker(runtime: .antigravityCLI, executablePath: antigravityPath)
        worker.budgetEnforcementModeOverride = .warning

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .completed)
        #expect(run.status == .completed)
        #expect(run.tokensUsed > task.tokenBudget)
        #expect(task.events.contains { $0.type == "task.stats" && $0.payload.contains("estimated tokens") })
        #expect(task.events.contains { $0.type == "budget.warning" })
        #expect(!task.events.contains { $0.type == "budget.exceeded" })
    }

    @Test("Antigravity hard stop rejects budgets below estimated prompt before starting")
    func antigravityHardStopRejectsLowBudgetBeforeLaunch() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let launchMarker = harness.rootURL.appendingPathComponent("agy-low-budget-launched")
        let antigravityPath = try harness.writeExecutable(
            named: "agy",
            script: """
            #!/bin/sh
            if [ "$1" = "--version" ]; then
              printf '%s\\n' '1.0.3'
              exit 0
            fi
            printf 'launched\\n' > '\(launchMarker.path)'
            printf '%s\\n' 'Should not appear'
            exit 0
            """
        )

        let task = harness.makeTask(
            runtime: .antigravityCLI,
            goal: String(repeating: "x", count: 400),
            model: "Gemini 3.5 Flash",
            tokenBudget: 20
        )
        let worker = harness.makeWorker(runtime: .antigravityCLI, executablePath: antigravityPath)
        worker.budgetEnforcementModeOverride = .hardStop

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .budgetExceeded)
        #expect(run.status == .budgetExceeded)
        #expect(run.stopReason == "max_budget_reached")
        #expect(!FileManager.default.fileExists(atPath: launchMarker.path))
        #expect(task.events.contains { $0.type == "budget.exceeded" && $0.payload.contains("Provider was not started") })
    }

    @Test("Claude hard stop enforces reported usage mid-run")
    func claudeHardStopEnforcesReportedUsageMidRun() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let launchMarker = harness.rootURL.appendingPathComponent("claude-usage-launched")
        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(body: """
            printf 'launched\\n' > '\(launchMarker.path)'
            printf '%s\\n' '{"type":"system","subtype":"init","session_id":"session-budget","model":"claude-sonnet-4-6"}'
            printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"num_turns":1,"result":"Budget exceeded response","usage":{"input_tokens":180000,"output_tokens":30000}}'
            exit 0
            """)
        )

        let task = harness.makeTask(
            runtime: .claudeCode,
            goal: "Use reported usage to exceed budget",
            model: "claude-sonnet-4-6",
            tokenBudget: 150_000
        )
        let worker = harness.makeWorker(runtime: .claudeCode, executablePath: claudePath)
        worker.budgetEnforcementModeOverride = .hardStop

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .budgetExceeded)
        #expect(run.status == .budgetExceeded)
        #expect(run.stopReason == "max_budget_reached")
        #expect(FileManager.default.fileExists(atPath: launchMarker.path))
        #expect(task.events.contains { $0.type == "budget.exceeded" })
    }

    @Test("Claude warning budget records warning and keeps running")
    func claudeWarningBudgetKeepsRunning() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let launchMarker = harness.rootURL.appendingPathComponent("claude-warning-launched")
        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(body: """
            printf 'launched\\n' > '\(launchMarker.path)'
            printf '%s\\n' '{"type":"system","subtype":"init","session_id":"session-warn","model":"claude-sonnet-4-6"}'
            printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"num_turns":1,"result":"Warning mode response","usage":{"input_tokens":180000,"output_tokens":30000}}'
            exit 0
            """)
        )

        let task = harness.makeTask(
            runtime: .claudeCode,
            goal: "Produce output above budget in warning mode",
            model: "claude-sonnet-4-6",
            tokenBudget: 150_000
        )
        let worker = harness.makeWorker(runtime: .claudeCode, executablePath: claudePath)
        worker.budgetEnforcementModeOverride = .warning

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .completed)
        #expect(run.status == .completed)
        #expect(run.output == "Warning mode response")
        #expect(FileManager.default.fileExists(atPath: launchMarker.path))
        #expect(task.events.contains { $0.type == "budget.warning" })
        #expect(!task.events.contains { $0.type == "budget.exceeded" })
    }

    @Test("Copilot repetition stop is reported separately from token budget")
    func copilotRepetitionStopIsNotBudgetExceeded() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            for i in 1 2 3 4 5 6 7 8 9; do
              printf '%s\\n' '{"type":"tool.execution_complete","data":{"toolCallId":"toolu_repeat","success":true,"result":{"content":"same output"}}}'
            done
            sleep 1
            exit 0
            """)
        )

        let task = harness.makeTask(
            runtime: .copilotCLI,
            goal: "Trigger repeated provider events",
            model: "gpt-5",
            tokenBudget: 50_000
        )
        let worker = harness.makeWorker(runtime: .copilotCLI, executablePath: copilotPath)
        worker.budgetEnforcementModeOverride = .warning

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .failed)
        #expect(run.status == .failed)
        #expect(run.stopReason == "repetition_detected")
        #expect(task.events.contains { $0.type == "error" && $0.payload.contains("Repetition loop detected") })
        #expect(!task.events.contains { $0.type == "budget.exceeded" })
    }

    @Test("Claude hard stop rejects budgets below launch overhead before starting")
    func claudeHardStopRejectsLowBudgetBeforeLaunch() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let launchMarker = harness.rootURL.appendingPathComponent("claude-low-budget-launched")
        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(body: """
            printf 'launched\\n' > '\(launchMarker.path)'
            printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"num_turns":1,"result":"should not launch","usage":{"input_tokens":3,"output_tokens":5}}'
            exit 0
            """)
        )

        let task = harness.makeTask(
            runtime: .claudeCode,
            goal: "This low-budget Claude task should not launch",
            model: "claude-sonnet-4-6",
            tokenBudget: 10_000
        )
        let worker = harness.makeWorker(runtime: .claudeCode, executablePath: claudePath)
        worker.budgetEnforcementModeOverride = .hardStop

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .budgetExceeded)
        #expect(run.status == .budgetExceeded)
        #expect(run.stopReason == "max_budget_reached")
        #expect(!worker.isRunning)
        #expect(!FileManager.default.fileExists(atPath: launchMarker.path))
        #expect(task.events.contains { $0.type == "budget.exceeded" && $0.payload.contains("Provider was not started") })
    }
}

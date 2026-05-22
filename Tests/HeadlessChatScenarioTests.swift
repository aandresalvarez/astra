import Foundation
import SwiftData
import Testing
@testable import ASTRA
import ASTRACore

@Suite("Headless Chat Scenarios")
@MainActor
struct HeadlessChatScenarioTests {
    @Test("Fake Copilot chat completes through the worker without UI")
    func fakeCopilotChatCompletes() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Headless Copilot response"}}'
            printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":4},"duration_ms":10,"turns":1}'
            exit 0
            """)
        )

        let task = harness.makeTask(runtime: .copilotCLI, goal: "Answer from Copilot", model: "gpt-5")
        let worker = harness.makeWorker(runtime: .copilotCLI, executablePath: copilotPath)

        let events = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .completed)
        #expect(run.status == .completed)
        #expect(run.output == "Headless Copilot response")
        #expect(run.inputTokens == 2)
        #expect(run.outputTokens == 4)
        #expect(events.contains { if case .text("Headless Copilot response") = $0 { true } else { false } })
    }

    @Test("Fake Claude chat completes through the worker without UI")
    func fakeClaudeChatCompletes() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(body: """
            printf '%s\\n' '{"type":"system","subtype":"init","session_id":"session-1","model":"claude-sonnet-4-6"}'
            printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"Headless Claude response"}]}}'
            printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"num_turns":1,"result":"Headless Claude response","usage":{"input_tokens":3,"output_tokens":5}}'
            exit 0
            """)
        )

        let task = harness.makeTask(runtime: .claudeCode, goal: "Answer from Claude", model: "claude-sonnet-4-6")
        let worker = harness.makeWorker(runtime: .claudeCode, executablePath: claudePath)

        let events = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .completed)
        #expect(task.sessionId == "session-1")
        #expect(run.status == .completed)
        #expect(run.output == "Headless Claude response")
        #expect(run.inputTokens == 3)
        #expect(run.outputTokens == 5)
        #expect(events.contains { if case .systemInit(_, "session-1") = $0 { true } else { false } })
    }

    @Test("Standalone artifact task without created files stays pending review")
    func standaloneArtifactTaskWithoutCreatedFilesStaysPendingReview() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Save this as index.html: <html><script></script></html>"}}'
            printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":4},"duration_ms":10,"turns":1}'
            exit 0
            """)
        )

        let task = harness.makeTask(
            runtime: .copilotCLI,
            goal: "write a web page with html and javascript for a tic tac toe game",
            model: "gpt-5"
        )
        let worker = harness.makeWorker(runtime: .copilotCLI, executablePath: copilotPath)

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .pendingUser)
        #expect(run.status == .failed)
        #expect(run.stopReason == "no_usable_result")
        #expect(task.completedAt == nil)
        #expect(task.events.contains { $0.type == "error" && $0.payload.contains("did not create a usable file") })
        #expect(!task.events.contains { $0.type == "task.completed" })
    }

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

    @Test("Permission warning can recover when later provider output arrives")
    func permissionWarningCanRecover() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            printf '%s\\n' '{"type":"event","data":{"type":"permission_request","toolName":"Bash","message":"approval needed for Bash"}}'
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Recovered after the warning"}}'
            printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":3},"duration_ms":11,"turns":1}'
            exit 0
            """)
        )

        let task = harness.makeTask(runtime: .copilotCLI, goal: "Recover after warning", model: "gpt-5")
        let worker = harness.makeWorker(runtime: .copilotCLI, executablePath: copilotPath)

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .completed)
        #expect(run.output == "Recovered after the warning")
        #expect(task.events.contains { $0.type == "permission.denied" && $0.payload.contains("Bash") })
        #expect(task.events.contains { $0.type == "agent.response" && $0.payload == "Recovered after the warning" })
    }

    @Test("Permission mode is passed to the provider command")
    func permissionModeIsPassedToProviderCommand() async throws {
        let reviewHarness = try HeadlessChatHarness()
        defer { reviewHarness.cleanup() }
        let reviewArgsURL = reviewHarness.rootURL.appendingPathComponent("review-args.txt")
        let reviewCopilotPath = try reviewHarness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(
                body: """
                printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"review mode"}}'
                exit 0
                """,
                argsFile: reviewArgsURL
            )
        )
        let reviewTask = reviewHarness.makeTask(runtime: .copilotCLI, goal: "Run in review mode", model: "gpt-5")
        let reviewWorker = reviewHarness.makeWorker(
            runtime: .copilotCLI,
            executablePath: reviewCopilotPath,
            permissionPolicy: .restricted
        )

        _ = await reviewHarness.execute(task: reviewTask, worker: reviewWorker)

        let reviewArgs = try String(contentsOf: reviewArgsURL, encoding: .utf8)
        #expect(reviewArgs.contains("--allow-tool"))
        #expect(!reviewArgs.contains("--allow-all-tools"))

        let autoHarness = try HeadlessChatHarness()
        defer { autoHarness.cleanup() }
        let autoArgsURL = autoHarness.rootURL.appendingPathComponent("auto-args.txt")
        let autoCopilotPath = try autoHarness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(
                body: """
                printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"auto mode"}}'
                exit 0
                """,
                argsFile: autoArgsURL
            )
        )
        let autoTask = autoHarness.makeTask(runtime: .copilotCLI, goal: "Run in auto mode", model: "gpt-5")
        let autoWorker = autoHarness.makeWorker(
            runtime: .copilotCLI,
            executablePath: autoCopilotPath,
            permissionPolicy: .autonomous
        )

        _ = await autoHarness.execute(task: autoTask, worker: autoWorker)

        let autoArgs = try String(contentsOf: autoArgsURL, encoding: .utf8)
        #expect(autoArgs.contains("--allow-all-tools"))

        let skipHarness = try HeadlessChatHarness()
        defer { skipHarness.cleanup() }
        let skipArgsURL = skipHarness.rootURL.appendingPathComponent("skip-args.txt")
        let skipClaudePath = try skipHarness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(
                body: """
                printf '%s\\n' '{"type":"system","subtype":"init","session_id":"skip-session","model":"claude-sonnet-4-6"}'
                printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"skip mode"}}]}'
                printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"num_turns":1,"result":"skip mode","usage":{"input_tokens":3,"output_tokens":5}}'
                exit 0
                """,
                argsFile: skipArgsURL
            )
        )
        let skipTask = skipHarness.makeTask(
            runtime: .claudeCode,
            goal: "Run with skipPermissions",
            model: "claude-sonnet-4-6"
        )
        let skipWorker = skipHarness.makeWorker(
            runtime: .claudeCode,
            executablePath: skipClaudePath,
            permissionPolicy: .restricted
        )
        skipWorker.skipPermissions = true

        _ = await skipHarness.execute(task: skipTask, worker: skipWorker)

        let skipArgs = try String(contentsOf: skipArgsURL, encoding: .utf8)
        #expect(skipArgs.contains("--dangerously-skip-permissions"))
    }

    @Test("Copilot autonomous provider denial fails without approval loop")
    func copilotAutonomousProviderDenialFailsWithoutApprovalLoop() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            printf '%s\\n' '{"type":"tool.execution_start","data":{"toolCallId":"toolu_denied","toolName":"bash","input":{"command":"cat ~/.zsh_history"}}}'
            printf '%s\\n' '{"type":"tool.execution_complete","data":{"toolCallId":"toolu_denied","success":false,"error":{"message":"Permission denied and could not request permission from user","code":"denied"}}}'
            sleep 1
            exit 0
            """)
        )

        let task = harness.makeTask(
            runtime: .copilotCLI,
            goal: "Read shell history",
            model: "gpt-5",
            tokenBudget: 200_000
        )
        let worker = harness.makeWorker(
            runtime: .copilotCLI,
            executablePath: copilotPath,
            permissionPolicy: .autonomous
        )

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .failed)
        #expect(run.status == .failed)
        #expect(run.stopReason == "provider_permission_denied_broad_permissions")
        #expect(!task.events.contains { $0.type == "permission.approval.requested" })
        #expect(task.events.contains {
            $0.type == "error"
                && $0.payload.contains("--allow-all-tools")
                && $0.payload.contains("cat ~/.zsh_history")
        })
    }

    @Test("Copilot hidden permission prompt pauses for user approval and can continue")
    func copilotHiddenPermissionPromptPausesForUserApprovalAndCanContinue() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsURL = harness.rootURL.appendingPathComponent("permission-approval-args.txt")
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(
                body: """
                if printf '%s\\n' "$@" | grep -Fxq -- 'write'; then
                  printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Wrote the approved story"}}'
                  printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":3},"duration_ms":11,"turns":1}'
                  exit 0
                fi
                printf '%s\\n' '● I will write the story to the task folder.'
                printf '%s\\n' '✗ Create .astra/tasks/BAD5D673/warriors_story.md'
                printf '%s\\n' 'Permission denied and could not request permission from user' >&2
                exit 15
                """,
                argsFile: argsURL
            )
        )

        let task = harness.makeTask(
            runtime: .copilotCLI,
            goal: "write a story about golden state warriors",
            model: "gpt-5",
            tokenBudget: 200_000
        )
        let worker = harness.makeWorker(
            runtime: .copilotCLI,
            executablePath: copilotPath,
            permissionPolicy: .restricted
        )

        _ = await harness.execute(task: task, worker: worker)

        let firstRun = try #require(task.runs.first)
        #expect(task.status == .pendingUser)
        #expect(firstRun.status == .failed)
        #expect(firstRun.stopReason == "permission_approval_required")
        #expect(task.events.contains { $0.type == "permission.approval.requested" })

        _ = await harness.continueTask(
            task: task,
            message: "The user approved the blocked permission.",
            worker: worker,
            executionPolicy: .approvedRuntimePermission(runtime: .copilotCLI, allowedTools: ["Write"])
        )

        let args = try String(contentsOf: argsURL, encoding: .utf8)
        let runs = task.runs.sorted { $0.startedAt < $1.startedAt }
        #expect(runs.count == 2)
        #expect(!args.contains("--allow-all-tools"))
        #expect(args.contains("write"))
        #expect(task.status == .completed)
        #expect(runs[1].output == "Wrote the approved story")
    }

    @Test("UI approval resumes a Copilot runtime permission pause")
    func uiApprovalResumesCopilotRuntimePermissionPause() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsURL = harness.rootURL.appendingPathComponent("ui-permission-approval-args.txt")
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(
                body: """
                if printf '%s\\n' "$@" | grep -Fxq -- 'write'; then
                  printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Approved through UI path"}}'
                  printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":3},"duration_ms":11,"turns":1}'
                  exit 0
                fi
                printf '%s\\n' '{"type":"event","data":{"type":"permission_request","toolName":"Write","message":"Permission denied and could not request permission from user"}}'
                printf '%s\\n' 'Permission denied and could not request permission from user' >&2
                exit 15
                """,
                argsFile: argsURL
            )
        )

        let task = harness.makeTask(
            runtime: .copilotCLI,
            goal: "write a story about golden state warriors",
            model: "gpt-5",
            tokenBudget: 200_000
        )
        let queue = TaskQueue(poolSize: 1)
        queue.applySettings(
            claudePath: nil,
            copilotPath: copilotPath,
            copilotHome: harness.rootURL.appendingPathComponent("copilot-home", isDirectory: true).path,
            defaultRuntimeID: .copilotCLI,
            timeoutSeconds: 10,
            validationModel: "gpt-5"
        )
        let coordinator = TaskLifecycleCoordinator(modelContext: harness.context, taskQueue: queue)

        await queue.executeTask(task, modelContext: harness.context)
        #expect(task.status == .pendingUser)
        #expect(task.runs.first?.stopReason == "permission_approval_required")
        #expect(task.events.contains { $0.type == "permission.approval.requested" })

        coordinator.approveTask(task)
        let completed = await harness.waitUntil(task: task, timeoutSeconds: 20) { $0.status == .completed }

        let args = try String(contentsOf: argsURL, encoding: .utf8)
        let runs = task.runs.sorted { $0.startedAt < $1.startedAt }
        #expect(completed)
        #expect(runs.count == 2)
        #expect(!args.contains("--allow-all-tools"))
        #expect(args.contains("write"))
        #expect(runs.last?.output == "Approved through UI path")
        #expect(task.events.contains { $0.type == "task.approved" && $0.payload.contains("Runtime permission approved") })
    }

    @Test("UI approval repairs Copilot wrapper shell grants")
    func uiApprovalRepairsCopilotWrapperShellGrants() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsURL = harness.rootURL.appendingPathComponent("ui-copilot-wrapper-approval-args.txt")
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(
                body: """
                if printf '%s\\n' "$@" | grep -Fxq -- 'shell(gh:search prs *)' \\
                  && printf '%s\\n' "$@" | grep -Fxq -- 'shell(gh:auth status *)' \\
                  && printf '%s\\n' "$@" | grep -Fxq -- 'shell(mkdir:-p *)' \\
                  && ! printf '%s\\n' "$@" | grep -Fxq -- 'shell(#:*)' \\
                  && ! printf '%s\\n' "$@" | grep -Fxq -- 'shell(echo:*)'; then
                  printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Reviewed open PRs after repaired approval"}}'
                  printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":3},"duration_ms":11,"turns":1}'
                  exit 0
                fi
                printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":3},"duration_ms":11,"turns":1}'
                exit 1
                """,
                argsFile: argsURL
            )
        )

        let task = harness.makeTask(
            runtime: .copilotCLI,
            goal: "review my open prs",
            model: "gpt-5",
            tokenBudget: 200_000
        )
        task.status = .pendingUser
        let blockedRun = TaskRun(task: task)
        blockedRun.status = .failed
        blockedRun.stopReason = "permission_approval_required"
        harness.context.insert(blockedRun)

        let command = """
        set -euo pipefail
        # Check gh auth before running the search
        if ! gh auth status >/dev/null 2>&1; then
          echo '{"error":"gh not authenticated"}'
          exit 0
        fi
        echo "Fetching open PRs"
        gh search prs "author:@me is:open" --limit 100 --json number,title,url
        """
        harness.context.insert(TaskEvent(
            task: task,
            type: "permission.approval.requested",
            payload: PermissionBroker.approvalPayloadString(
                providerID: .copilotCLI,
                request: .shell(command: command, toolName: "bash"),
                reason: "The shell command requires user approval by the effective ASTRA policy.",
                grants: [
                    .shellCommand(executable: "#", pattern: "*"),
                    .shellCommand(executable: "echo", pattern: "*")
                ]
            ),
            run: blockedRun
        ))
        try harness.context.save()

        let queue = TaskQueue(poolSize: 1)
        queue.applySettings(
            claudePath: nil,
            copilotPath: copilotPath,
            copilotHome: harness.rootURL.appendingPathComponent("copilot-home", isDirectory: true).path,
            defaultRuntimeID: .copilotCLI,
            timeoutSeconds: 10,
            validationModel: "gpt-5"
        )
        let coordinator = TaskLifecycleCoordinator(modelContext: harness.context, taskQueue: queue)
        defer { queue.cancelAll() }

        coordinator.approveTask(task)
        let completed = await harness.waitUntil(task: task, timeoutSeconds: 60) { $0.status == .completed }

        let args = try String(contentsOf: argsURL, encoding: .utf8)
        let runs = task.runs.sorted { $0.startedAt < $1.startedAt }
        #expect(completed)
        #expect(runs.count == 2)
        #expect(args.contains("shell(gh:search prs *)"))
        #expect(args.contains("shell(gh:auth status *)"))
        #expect(args.contains("shell(mkdir:-p *)"))
        #expect(!args.contains("shell(#:*)"))
        #expect(!args.contains("shell(echo:*)"))
        #expect(!args.contains("shell(gh:*)"))
        #expect(args.contains("Start shell calls with the approved executable"))
        #expect(runs.last?.output == "Reviewed open PRs after repaired approval")
    }

    @Test("UI approve similar records task-scoped command grant")
    func uiApproveSimilarRecordsTaskScopedCommandGrant() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsURL = harness.rootURL.appendingPathComponent("ui-copilot-similar-approval-args.txt")
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(
                body: """
                if printf '%s\\n' "$@" | grep -Fxq -- 'shell(gh:search prs *)' \\
                  && printf '%s\\n' "$@" | grep -Fxq -- 'shell(gh:auth status *)' \\
                  && printf '%s\\n' "$@" | grep -Fxq -- 'shell(mkdir:-p *)' \\
                  && ! printf '%s\\n' "$@" | grep -Fxq -- 'shell(gh:*)'; then
                  printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Reviewed open PRs after task-scoped approval"}}'
                  printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":3},"duration_ms":11,"turns":1}'
                  exit 0
                fi
                printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":3},"duration_ms":11,"turns":1}'
                exit 1
                """,
                argsFile: argsURL
            )
        )

        let task = harness.makeTask(
            runtime: .copilotCLI,
            goal: "review my open prs",
            model: "gpt-5",
            tokenBudget: 200_000
        )
        task.status = .pendingUser
        let blockedRun = TaskRun(task: task)
        blockedRun.status = .failed
        blockedRun.stopReason = "permission_approval_required"
        harness.context.insert(blockedRun)

        let command = """
        set -euo pipefail
        if ! gh auth status >/dev/null 2>&1; then
          echo '{"error":"gh not authenticated"}'
          exit 0
        fi
        gh search prs "author:@me is:open" --limit 100 --json number,title,url
        """
        harness.context.insert(TaskEvent(
            task: task,
            type: "permission.approval.requested",
            payload: PermissionBroker.approvalPayloadString(
                providerID: .copilotCLI,
                request: .shell(command: command, toolName: "bash"),
                reason: "The shell command requires user approval by the effective ASTRA policy.",
                grants: [.shellCommand(executable: "gh", pattern: "*")]
            ),
            run: blockedRun
        ))
        try harness.context.save()

        let queue = TaskQueue(poolSize: 1)
        queue.applySettings(
            claudePath: nil,
            copilotPath: copilotPath,
            copilotHome: harness.rootURL.appendingPathComponent("copilot-home", isDirectory: true).path,
            defaultRuntimeID: .copilotCLI,
            timeoutSeconds: 10,
            validationModel: "gpt-5"
        )
        let coordinator = TaskLifecycleCoordinator(modelContext: harness.context, taskQueue: queue)
        defer { queue.cancelAll() }

        coordinator.approveSimilarRuntimePermissionForTask(task)
        let completed = await harness.waitUntil(task: task, timeoutSeconds: 60) { $0.status == .completed }

        let args = try String(contentsOf: argsURL, encoding: .utf8)
        let runs = task.runs.sorted { $0.startedAt < $1.startedAt }
        #expect(completed)
        #expect(runs.count == 2)
        #expect(args.contains("shell(gh:search prs *)"))
        #expect(args.contains("shell(gh:auth status *)"))
        #expect(args.contains("shell(mkdir:-p *)"))
        #expect(!args.contains("shell(gh:*)"))
        #expect(args.contains("task-scoped runtime permission"))
        #expect(task.events.contains { $0.type == TaskRuntimePermissionGrants.eventType })
        #expect(TaskRuntimePermissionGrants.approvedGrants(for: task) == [
            .shellCommand(executable: "gh", pattern: "search prs *")
        ])
        #expect(runs.last?.output == "Reviewed open PRs after task-scoped approval")
    }

    @Test("UI approval resumes a Claude ASTRA ask-first shell pause")
    func uiApprovalResumesClaudeAstraAskFirstShellPause() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsURL = harness.rootURL.appendingPathComponent("ui-claude-policy-approval-args.txt")
        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(
                body: """
                if printf '%s\\n' "$@" | grep -Fxq -- 'Bash(curl *redcap.stanford.edu*)'; then
                  printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-policy-approved","model":"claude-sonnet-4-6"}'
                  printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"Approved curl completed"}]}}'
                  printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"num_turns":1,"result":"Approved curl completed","usage":{"input_tokens":3,"output_tokens":5}}'
                  exit 0
                fi
                printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-policy-needs-approval","model":"claude-sonnet-4-6"}'
                printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"tool_use","name":"Bash","id":"toolu_curl","input":{"command":"curl https://redcap.stanford.edu/api/"}}]}}'
                /bin/sleep 20
                exit 0
                """,
                argsFile: argsURL
            )
        )

        let task = harness.makeTask(
            runtime: .claudeCode,
            goal: "Read REDCap project info",
            model: "claude-sonnet-4-6",
            tokenBudget: 200_000
        )
        let queue = TaskQueue(poolSize: 1)
        queue.applySettings(
            claudePath: claudePath,
            copilotPath: nil,
            defaultRuntimeID: .claudeCode,
            timeoutSeconds: 10,
            validationModel: "claude-haiku-4-5-20251001"
        )
        let coordinator = TaskLifecycleCoordinator(modelContext: harness.context, taskQueue: queue)

        await queue.executeTask(task, modelContext: harness.context)
        #expect(task.status == .pendingUser)
        #expect(task.runs.first?.stopReason == "permission_approval_required")
        let approvalEvent = try #require(task.events.first {
            $0.type == "permission.approval.requested" && $0.payload.contains("Runtime grant: Bash(curl *redcap.stanford.edu*)")
        })
        let approvalPayload = try #require(PermissionApprovalEventPayload.decoded(from: approvalEvent.payload))
        #expect(approvalPayload.providerID == .claudeCode)
        #expect(approvalPayload.grants.contains(.shellCommand(executable: "curl", pattern: "*redcap.stanford.edu*")))
        #expect(approvalPayload.displayMessage.contains("Runtime grant: Bash(curl *redcap.stanford.edu*)"))

        coordinator.approveTask(task)
        let completed = await harness.waitUntil(task: task, timeoutSeconds: 20) { $0.status == .completed }

        let args = try String(contentsOf: argsURL, encoding: .utf8)
        let runs = task.runs.sorted { $0.startedAt < $1.startedAt }
        #expect(completed)
        #expect(runs.count == 2)
        #expect(args.contains("Bash(curl *redcap.stanford.edu*)"))
        #expect(!args.contains("--dangerously-skip-permissions"))
        #expect(runs.last?.output == "Approved curl completed")
    }

    @Test("UI approval ignores stale broad shell runtime grants")
    func uiApprovalIgnoresStaleBroadShellRuntimeGrants() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsURL = harness.rootURL.appendingPathComponent("ui-stale-broad-grant-args.txt")
        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(
                body: """
                printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-sanitized-approval","model":"claude-sonnet-4-6"}'
                printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"Sanitized approval completed"}]}}'
                printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"num_turns":1,"result":"Sanitized approval completed","usage":{"input_tokens":3,"output_tokens":5}}'
                exit 0
                """,
                argsFile: argsURL
            )
        )

        let task = harness.makeTask(
            runtime: .claudeCode,
            goal: "Continue after an old permission request",
            model: "claude-sonnet-4-6",
            tokenBudget: 200_000
        )
        task.status = .pendingUser
        let blockedRun = TaskRun(task: task)
        blockedRun.status = .failed
        blockedRun.stopReason = "permission_approval_required"
        harness.context.insert(blockedRun)
        harness.context.insert(TaskEvent(
            task: task,
            type: "permission.approval.requested",
            payload: """
            Permission requested for tool: Bash.
            Runtime grant: Bash(*)
            """,
            run: blockedRun
        ))
        try harness.context.save()

        let queue = TaskQueue(poolSize: 1)
        queue.applySettings(
            claudePath: claudePath,
            copilotPath: nil,
            defaultRuntimeID: .claudeCode,
            timeoutSeconds: 10,
            validationModel: "claude-haiku-4-5-20251001"
        )
        let coordinator = TaskLifecycleCoordinator(modelContext: harness.context, taskQueue: queue)
        defer { queue.cancelAll() }

        coordinator.approveTask(task)
        let completed = await harness.waitUntil(task: task, timeoutSeconds: 60) { $0.status == .completed }

        let args = try String(contentsOf: argsURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        #expect(completed)
        #expect(!args.contains("Bash(*)"))
        #expect(!args.contains("Bash"))
        #expect(!args.contains("--dangerously-skip-permissions"))
    }

    @Test("UI approval replays structured permission grants")
    func uiApprovalReplaysStructuredPermissionGrants() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsURL = harness.rootURL.appendingPathComponent("ui-structured-grant-args.txt")
        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(
                body: """
                if printf '%s\\n' "$@" | grep -Fxq -- 'Bash(curl *redcap.stanford.edu*)'; then
                  printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-structured-approval","model":"claude-sonnet-4-6"}'
                  printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"Structured approval completed"}]}}'
                  printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"num_turns":1,"result":"Structured approval completed","usage":{"input_tokens":3,"output_tokens":5}}'
                  exit 0
                fi
                printf '%s\\n' '{"type":"result","subtype":"error","is_error":true,"duration_ms":12,"num_turns":1,"result":"Missing structured grant","usage":{"input_tokens":3,"output_tokens":5}}'
                exit 1
                """,
                argsFile: argsURL
            )
        )

        let task = harness.makeTask(
            runtime: .claudeCode,
            goal: "Continue after a structured permission request",
            model: "claude-sonnet-4-6",
            tokenBudget: 200_000
        )
        task.status = .pendingUser
        let blockedRun = TaskRun(task: task)
        blockedRun.status = .failed
        blockedRun.stopReason = "permission_approval_required"
        harness.context.insert(blockedRun)
        let request = PermissionRequest.shell(command: "curl https://redcap.stanford.edu/api/", toolName: "Bash")
        let grants = [PermissionGrant.shellCommand(executable: "curl", pattern: "*")]
        harness.context.insert(TaskEvent(
            task: task,
            type: "permission.approval.requested",
            payload: PermissionBroker.approvalPayloadString(
                providerID: .claudeCode,
                request: request,
                reason: "The shell command requires user approval by the effective ASTRA policy.",
                grants: grants
            ),
            run: blockedRun
        ))
        try harness.context.save()

        let queue = TaskQueue(poolSize: 1)
        queue.applySettings(
            claudePath: claudePath,
            copilotPath: nil,
            defaultRuntimeID: .claudeCode,
            timeoutSeconds: 10,
            validationModel: "claude-haiku-4-5-20251001"
        )
        let coordinator = TaskLifecycleCoordinator(modelContext: harness.context, taskQueue: queue)
        defer { queue.cancelAll() }

        coordinator.approveTask(task)
        let completed = await harness.waitUntil(task: task, timeoutSeconds: 60) { $0.status == .completed }

        let args = try String(contentsOf: argsURL, encoding: .utf8)
        #expect(completed)
        #expect(args.contains("Bash(curl *redcap.stanford.edu*)"))
        #expect(!args.contains("--dangerously-skip-permissions"))
    }

    @Test("Claude hidden permission prompt pauses for user approval and can continue")
    func claudeHiddenPermissionPromptPausesForUserApprovalAndCanContinue() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsURL = harness.rootURL.appendingPathComponent("claude-permission-approval-args.txt")
        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(
                body: """
                if printf '%s\\n' "$@" | grep -Fxq -- 'Write'; then
                  printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-approved-session","model":"claude-sonnet-4-6"}'
                  printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"Claude continued after approval"}]}}'
                  printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"num_turns":1,"result":"Claude continued after approval","usage":{"input_tokens":3,"output_tokens":5}}'
                  exit 0
                fi
                printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"Permission denied for tool: Write. approval required"}]}}'
                printf '%s\\n' '{"type":"result","subtype":"error","is_error":true,"duration_ms":12,"num_turns":1,"result":"Permission denied for tool: Write","usage":{"input_tokens":3,"output_tokens":5}}'
                printf '%s\\n' 'Permission denied for tool: Write. approval required' >&2
                exit 1
                """,
                argsFile: argsURL
            )
        )

        let task = harness.makeTask(
            runtime: .claudeCode,
            goal: "use the write tool after approval",
            model: "claude-sonnet-4-6",
            tokenBudget: 200_000
        )
        let worker = harness.makeWorker(
            runtime: .claudeCode,
            executablePath: claudePath,
            permissionPolicy: .restricted
        )

        _ = await harness.execute(task: task, worker: worker)

        let firstRun = try #require(task.runs.first)
        #expect(task.status == .pendingUser)
        #expect(firstRun.status == .failed)
        #expect(firstRun.stopReason == "permission_approval_required")
        #expect(task.events.contains { $0.type == "permission.approval.requested" })

        _ = await harness.continueTask(
            task: task,
            message: "The user approved the blocked permission.",
            worker: worker,
            executionPolicy: .approvedRuntimePermission(runtime: .claudeCode, allowedTools: ["Write"])
        )

        let args = try String(contentsOf: argsURL, encoding: .utf8)
        let runs = task.runs.sorted { $0.startedAt < $1.startedAt }
        #expect(runs.count == 2)
        #expect(!args.contains("--dangerously-skip-permissions"))
        #expect(args.contains("Write"))
        #expect(task.status == .completed)
        #expect(runs[1].output == "Claude continued after approval")
    }

    @Test("Headless chat can continue a task")
    func headlessChatCanContinueTask() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let countFile = harness.rootURL.appendingPathComponent("call-count.txt")
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            count="$(cat \(Self.shQuote(countFile.path)) 2>/dev/null || echo 0)"
            count=$((count + 1))
            printf '%s' "$count" > \(Self.shQuote(countFile.path))
            if [ "$count" = "1" ]; then
              printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Initial answer"}}'
            else
              printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Follow-up answer"}}'
            fi
            printf '%s\\n' '{"type":"usage","usage":{"input_tokens":1,"output_tokens":1},"duration_ms":5,"turns":1}'
            exit 0
            """)
        )

        let task = harness.makeTask(runtime: .copilotCLI, goal: "Start a thread", model: "gpt-5")
        let worker = harness.makeWorker(runtime: .copilotCLI, executablePath: copilotPath)

        _ = await harness.execute(task: task, worker: worker)
        _ = await harness.continueTask(task: task, message: "Follow up", worker: worker)

        #expect(task.runs.count == 2)
        #expect(task.runs.contains { $0.output == "Initial answer" })
        #expect(task.runs.contains { $0.output == "Follow-up answer" })
        #expect(task.events.contains { $0.type == "user.message" && $0.payload == "Follow up" })
        #expect(task.status == .completed)
    }

    @Test("Approved plan execution records runtime step progress")
    func approvedPlanExecutionRecordsStepProgress() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let plan = TaskPlanPayload(
            title: "Headless plan",
            goal: "Execute one planned step",
            steps: [
                TaskPlanPayloadStep(id: "step-1", title: "Inspect", likelyTools: ["Read"])
            ]
        )
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"ASTRA_EVENT {\\"v\\":1,\\"type\\":\\"plan.step.started\\",\\"stepID\\":\\"step-1\\"}\\n"}}'
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Plan executed"}}'
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"ASTRA_EVENT {\\"v\\":1,\\"type\\":\\"plan.step.completed\\",\\"stepID\\":\\"step-1\\",\\"summary\\":\\"Done\\"}\\n"}}'
            printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":3},"duration_ms":11,"turns":1}'
            exit 0
            """)
        )

        let task = harness.makeTask(runtime: .copilotCLI, goal: plan.goal, model: "gpt-5")
        TaskPlanService.recordCreated(plan, task: task, modelContext: harness.context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: harness.context)
        let worker = harness.makeWorker(runtime: .copilotCLI, executablePath: copilotPath)

        _ = await harness.executeApprovedPlan(task: task, plan: plan, worker: worker)

        let state = TaskPlanService.reconstruct(for: task)
        #expect(task.status == .completed)
        #expect(task.runs.first?.output == "Plan executed")
        #expect(state.lifecycleStatus == .completed)
        #expect(state.plan?.steps.first?.status == .done)
        #expect(task.events.contains { $0.type == "plan.execution.started" })
        #expect(task.events.contains { $0.type == "plan.execution.completed" })
        #expect(task.events.contains { $0.type == "plan.step.started" })
        #expect(task.events.contains { $0.type == "plan.step.completed" })
    }

    @Test("Approved plan execution records failure lifecycle on failure")
    func approvedPlanExecutionRecordsFailureLifecycleOnFailure() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let plan = TaskPlanPayload(
            title: "Failing plan",
            goal: "Fail during execution",
            steps: [
                TaskPlanPayloadStep(id: "step-1", title: "Run")
            ]
        )
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            printf '%s\\n' '{"type":"error","message":"provider failed"}'
            exit 1
            """)
        )

        let task = harness.makeTask(runtime: .copilotCLI, goal: plan.goal, model: "gpt-5")
        TaskPlanService.recordCreated(plan, task: task, modelContext: harness.context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: harness.context)
        let worker = harness.makeWorker(runtime: .copilotCLI, executablePath: copilotPath)

        _ = await harness.executeApprovedPlan(task: task, plan: plan, worker: worker)

        let state = TaskPlanService.reconstruct(for: task)
        #expect(task.status == .failed)
        #expect(state.lifecycleStatus == .failed)
        #expect(task.events.contains { $0.type == "plan.execution.failed" })
        #expect(!task.events.contains { $0.type == "plan.execution.completed" })
    }

    @Test("Approved plan execution uses explicit approval for Copilot Review mode")
    func approvedPlanExecutionUsesExplicitApprovalForCopilotReviewMode() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsURL = harness.rootURL.appendingPathComponent("review-plan-args.txt")
        let plan = TaskPlanPayload(
            title: "Review plan",
            goal: "Execute in review mode",
            steps: [
                TaskPlanPayloadStep(id: "step-1", title: "Write artifact", likelyTools: ["Write"]),
                TaskPlanPayloadStep(id: "step-2", title: "Verify artifact", likelyTools: ["Read"])
            ]
        )
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(
                body: """
                printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"review plan executed"}}'
                printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":3},"duration_ms":11,"turns":1}'
                exit 0
                """,
                argsFile: argsURL
            )
        )

        let task = harness.makeTask(runtime: .copilotCLI, goal: plan.goal, model: "gpt-5")
        TaskPlanService.recordCreated(plan, task: task, modelContext: harness.context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: harness.context)
        let worker = harness.makeWorker(
            runtime: .copilotCLI,
            executablePath: copilotPath,
            permissionPolicy: .restricted
        )

        _ = await harness.executeApprovedPlan(task: task, plan: plan, worker: worker, mode: .nextStep)

        let args = try String(contentsOf: argsURL, encoding: .utf8)
        let state = TaskPlanService.reconstruct(for: task)
        #expect(!args.contains("--allow-all-tools"))
        #expect(args.contains("--allow-tool"))
        #expect(args.contains("write"))
        #expect(args.contains("ASTRA review mode approved only the next plan step"))
        #expect(args.contains("Execute exactly this approved step and stop: step-1"))
        #expect(args.contains("Do not execute later plan steps"))
        #expect(task.status == .pendingUser)
        #expect(task.runs.first?.output == "review plan executed")
        #expect(state.lifecycleStatus == .executing)
        #expect(state.plan?.steps.first(where: { $0.id == "step-1" })?.status == .done)
        #expect(state.plan?.steps.first(where: { $0.id == "step-2" })?.status == .pending)
        #expect(task.events.contains { $0.type == "system.info" && $0.payload.contains("Review the next step") })
        #expect(!task.events.contains { $0.type == "plan.execution.completed" })
    }

    @Test("Review mode executes the next unfinished plan step on each approval")
    func reviewModeExecutesNextUnfinishedPlanStepOnEachApproval() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsURL = harness.rootURL.appendingPathComponent("review-next-step-args.txt")
        let countFile = harness.rootURL.appendingPathComponent("review-next-step-count.txt")
        let plan = TaskPlanPayload(
            title: "Two step review plan",
            goal: "Execute one approved step at a time",
            steps: [
                TaskPlanPayloadStep(id: "step-1", title: "Write artifact", likelyTools: ["Write"]),
                TaskPlanPayloadStep(id: "step-2", title: "Verify artifact", likelyTools: ["Read"])
            ]
        )
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(
                body: """
                count="$(cat \(Self.shQuote(countFile.path)) 2>/dev/null || echo 0)"
                count=$((count + 1))
                printf '%s' "$count" > \(Self.shQuote(countFile.path))
                printf '%s\\n' "{\\"sessionUpdate\\":\\"agent_message_chunk\\",\\"content\\":{\\"type\\":\\"text\\",\\"text\\":\\"review step $count executed\\"}}"
                printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":3},"duration_ms":11,"turns":1}'
                exit 0
                """,
                argsFile: argsURL
            )
        )

        let task = harness.makeTask(runtime: .copilotCLI, goal: plan.goal, model: "gpt-5")
        TaskPlanService.recordCreated(plan, task: task, modelContext: harness.context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: harness.context)
        let worker = harness.makeWorker(
            runtime: .copilotCLI,
            executablePath: copilotPath,
            permissionPolicy: .restricted
        )

        _ = await harness.executeApprovedPlan(task: task, plan: plan, worker: worker, mode: .nextStep)
        #expect(task.status == .pendingUser)

        let stateAfterFirstStep = TaskPlanService.reconstruct(for: task)
        let currentPlan = try #require(stateAfterFirstStep.plan)
        _ = await harness.executeApprovedPlan(task: task, plan: currentPlan, worker: worker, mode: .nextStep)

        let finalState = TaskPlanService.reconstruct(for: task)
        let secondPromptArgs = try String(contentsOf: argsURL, encoding: .utf8)
        #expect(secondPromptArgs.contains("Execute exactly this approved step and stop: step-2"))
        #expect(task.status == .completed)
        #expect(task.runs.count == 2)
        #expect(finalState.lifecycleStatus == .completed)
        #expect(finalState.plan?.steps.allSatisfy { $0.status == .done } == true)
        #expect(task.events.contains { $0.type == "plan.execution.completed" })
    }

    @Test("Review mode preserves blocked plan steps for user approval")
    func reviewModePreservesBlockedPlanStepForUserApproval() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let planID = UUID(uuidString: "73EF73A8-433C-485E-8E76-91881D1D3798")!
        let plan = TaskPlanPayload(
            planID: planID,
            title: "Blocked review plan",
            goal: "Stop when blocked",
            steps: [
                TaskPlanPayloadStep(id: "step-1", title: "Write artifact", likelyTools: ["Write"]),
                TaskPlanPayloadStep(id: "step-2", title: "Verify artifact", likelyTools: ["Read"])
            ]
        )
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"ASTRA_EVENT {\\"v\\":1,\\"type\\":\\"plan.step.blocked\\",\\"planID\\":\\"\(planID.uuidString)\\",\\"stepID\\":\\"step-1\\",\\"status\\":\\"blocked\\",\\"reason\\":\\"Needs credentials\\"}\\n"}}'
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Need credentials before continuing."}}'
            printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":3},"duration_ms":11,"turns":1}'
            exit 0
            """)
        )

        let task = harness.makeTask(runtime: .copilotCLI, goal: plan.goal, model: "gpt-5")
        TaskPlanService.recordCreated(plan, task: task, modelContext: harness.context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: harness.context)
        let worker = harness.makeWorker(runtime: .copilotCLI, executablePath: copilotPath)

        _ = await harness.executeApprovedPlan(task: task, plan: plan, worker: worker, mode: .nextStep)

        let state = TaskPlanService.reconstruct(for: task)
        #expect(task.status == .pendingUser)
        #expect(state.lifecycleStatus == .executing)
        #expect(state.plan?.steps.first(where: { $0.id == "step-1" })?.status == .blocked)
        #expect(state.plan?.steps.first(where: { $0.id == "step-2" })?.status == .pending)
        #expect(!task.events.contains { $0.type == "plan.step.completed" && $0.payload.contains("step-1") })
        #expect(!task.events.contains { $0.type == "plan.execution.completed" })
        #expect(task.events.contains { $0.type == "system.info" && $0.payload.contains("Plan step blocked") })
        #expect(!task.events.contains { $0.type == "system.info" && $0.payload.contains("Plan step complete") })
    }

    @Test("Plan mode runtime policy violation stops provider")
    func planModeRuntimePolicyViolationStopsProvider() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let plan = TaskPlanPayload(
            title: "Guarded review plan",
            goal: "Execute a write-only approved step",
            steps: [
                TaskPlanPayloadStep(id: "step-1", title: "Write artifact", likelyTools: ["Write"])
            ]
        )
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            printf '%s\\n' '{"type":"tool_call","tool":"shell","id":"call-1","command":"rm -rf build"}'
            /bin/sleep 20
            exit 0
            """)
        )

        let task = harness.makeTask(runtime: .copilotCLI, goal: plan.goal, model: "gpt-5")
        TaskPlanService.recordCreated(plan, task: task, modelContext: harness.context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: harness.context)
        let worker = harness.makeWorker(
            runtime: .copilotCLI,
            executablePath: copilotPath,
            permissionPolicy: .restricted
        )

        _ = await harness.executeApprovedPlan(task: task, plan: plan, worker: worker, mode: .nextStep)

        let run = try #require(task.runs.first)
        let state = TaskPlanService.reconstruct(for: task)
        #expect(task.status == .pendingUser)
        #expect(run.status == .failed)
        #expect(run.stopReason == "policy_violation")
        #expect(task.events.contains { $0.type == "error" && $0.payload.contains("violated the run policy") })
        #expect(!task.events.contains { $0.type == "plan.step.completed" })
        #expect(state.plan?.steps.first?.status != .done)
    }

    @Test("Approved plan execution keeps Auto mode autonomous for Copilot")
    func approvedPlanExecutionKeepsAutoModeAutonomousForCopilot() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsURL = harness.rootURL.appendingPathComponent("auto-plan-args.txt")
        let plan = TaskPlanPayload(
            title: "Auto plan",
            goal: "Execute in auto mode",
            steps: [
                TaskPlanPayloadStep(id: "step-1", title: "Write artifact", likelyTools: ["Write"]),
                TaskPlanPayloadStep(id: "step-2", title: "Verify artifact", likelyTools: ["Read"])
            ]
        )
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(
                body: """
                printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"auto plan executed"}}'
                printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":3},"duration_ms":11,"turns":1}'
                exit 0
                """,
                argsFile: argsURL
            )
        )

        let task = harness.makeTask(runtime: .copilotCLI, goal: plan.goal, model: "gpt-5")
        TaskPlanService.recordCreated(plan, task: task, modelContext: harness.context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: harness.context)
        let worker = harness.makeWorker(
            runtime: .copilotCLI,
            executablePath: copilotPath,
            permissionPolicy: .autonomous
        )

        _ = await harness.executeApprovedPlan(task: task, plan: plan, worker: worker)

        let args = try String(contentsOf: argsURL, encoding: .utf8)
        #expect(args.contains("--allow-all-tools"))
        #expect(!args.contains("--allow-tool"))
        #expect(args.contains("ASTRA auto mode approved the full plan"))
        #expect(args.contains("Execute the remaining approved plan steps"))
        #expect(task.status == .completed)
        #expect(task.runs.first?.output == "auto plan executed")
    }

    @Test("Approved plan execution records step progress with Claude")
    func approvedPlanExecutionRecordsStepProgressWithClaude() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let plan = TaskPlanPayload(
            title: "Claude plan",
            goal: "Execute one planned step with Claude",
            steps: [
                TaskPlanPayloadStep(id: "step-1", title: "Inspect", likelyTools: ["Read"])
            ]
        )
        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(body: """
            printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-plan-session","model":"claude-sonnet-4-6"}'
            printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"ASTRA_EVENT {\\"v\\":1,\\"type\\":\\"plan.step.started\\",\\"stepID\\":\\"step-1\\"}\\n"}]}}'
            printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"Claude plan executed"}]}}'
            printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"ASTRA_EVENT {\\"v\\":1,\\"type\\":\\"plan.step.completed\\",\\"stepID\\":\\"step-1\\",\\"summary\\":\\"Done\\"}\\n"}]}}'
            printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"num_turns":1,"result":"Claude plan executed","usage":{"input_tokens":3,"output_tokens":5}}'
            exit 0
            """)
        )

        let task = harness.makeTask(runtime: .claudeCode, goal: plan.goal, model: "claude-sonnet-4-6")
        TaskPlanService.recordCreated(plan, task: task, modelContext: harness.context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: harness.context)
        let worker = harness.makeWorker(runtime: .claudeCode, executablePath: claudePath)

        _ = await harness.executeApprovedPlan(task: task, plan: plan, worker: worker)

        let state = TaskPlanService.reconstruct(for: task)
        #expect(task.status == .completed)
        #expect(task.sessionId == "claude-plan-session")
        #expect(task.runs.first?.output == "Claude plan executed")
        #expect(state.lifecycleStatus == .completed)
        #expect(state.plan?.steps.first?.status == .done)
        #expect(task.events.contains { $0.type == "plan.step.started" })
        #expect(task.events.contains { $0.type == "plan.step.completed" })
    }

    @Test("Claude review mode grants approved step tools")
    func claudeReviewModeGrantsApprovedStepTools() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsURL = harness.rootURL.appendingPathComponent("claude-review-args.txt")
        let plan = TaskPlanPayload(
            title: "Claude write plan",
            goal: "Create an artifact with Claude",
            steps: [
                TaskPlanPayloadStep(id: "step-1", title: "Write artifact", likelyTools: ["Write"])
            ]
        )
        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(
                body: """
                printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-review-session","model":"claude-sonnet-4-6"}'
                printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"ASTRA_EVENT {\\"v\\":1,\\"type\\":\\"plan.step.completed\\",\\"stepID\\":\\"step-1\\",\\"summary\\":\\"Done\\"}\\n"}]}}'
                printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"num_turns":1,"result":"Claude wrote artifact","usage":{"input_tokens":3,"output_tokens":5}}'
                exit 0
                """,
                argsFile: argsURL
            )
        )

        let task = harness.makeTask(runtime: .claudeCode, goal: plan.goal, model: "claude-sonnet-4-6")
        let restrictedSkill = Skill(
            name: "Read-only",
            allowedTools: ["Read", "Grep"],
            disallowedTools: ["Write", "Edit", "Bash"],
            behaviorInstructions: ""
        )
        harness.context.insert(restrictedSkill)
        task.skills = [restrictedSkill]
        TaskPlanService.recordCreated(plan, task: task, modelContext: harness.context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: harness.context)
        let worker = harness.makeWorker(
            runtime: .claudeCode,
            executablePath: claudePath,
            permissionPolicy: .restricted
        )

        _ = await harness.executeApprovedPlan(task: task, plan: plan, worker: worker, mode: .nextStep)

        let args = try String(contentsOf: argsURL, encoding: .utf8)
        #expect(args.contains("--allowedTools"))
        #expect(args.contains("Write"))

        let settingsURL = harness.workspaceURL
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.local.json")
        let data = try Data(contentsOf: settingsURL)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let permissions = try #require(json["permissions"] as? [String: Any])
        let allow = try #require(permissions["allow"] as? [String])
        #expect(allow.contains("Write(*)"))
    }

    @Test("Claude plan mode runtime policy violation stops provider")
    func claudePlanModeRuntimePolicyViolationStopsProvider() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let plan = TaskPlanPayload(
            title: "Guarded Claude review plan",
            goal: "Execute a write-only approved step with Claude",
            steps: [
                TaskPlanPayloadStep(id: "step-1", title: "Write artifact", likelyTools: ["Write"])
            ]
        )
        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(body: """
            printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-guard-session","model":"claude-sonnet-4-6"}'
            printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"tool_use","name":"Bash","id":"toolu_bad","input":{"command":"rm -rf build"}}]}}'
            /bin/sleep 20
            exit 0
            """)
        )

        let task = harness.makeTask(runtime: .claudeCode, goal: plan.goal, model: "claude-sonnet-4-6")
        TaskPlanService.recordCreated(plan, task: task, modelContext: harness.context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: harness.context)
        let worker = harness.makeWorker(
            runtime: .claudeCode,
            executablePath: claudePath,
            permissionPolicy: .restricted
        )

        _ = await harness.executeApprovedPlan(task: task, plan: plan, worker: worker, mode: .nextStep)

        let run = try #require(task.runs.first)
        let state = TaskPlanService.reconstruct(for: task)
        #expect(task.status == .pendingUser)
        #expect(run.status == .failed)
        #expect(run.stopReason == "policy_violation")
        #expect(task.events.contains { $0.type == "error" && $0.payload.contains("violated the run policy") })
        #expect(!task.events.contains { $0.type == "plan.step.completed" })
        #expect(state.plan?.steps.first?.status != .done)
    }

    @Test("Blocked write permission enriches the next approved retry")
    func blockedWritePermissionEnrichesNextApprovedRetry() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsURL = harness.rootURL.appendingPathComponent("claude-retry-args.txt")
        let blockedFlagURL = harness.rootURL.appendingPathComponent("blocked-once")
        let plan = TaskPlanPayload(
            title: "Retry write plan",
            goal: "Create an HTML file after permission repair",
            steps: [
                TaskPlanPayloadStep(id: "step-1", title: "Create homepage", likelyTools: ["Read"])
            ]
        )
        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(
                body: """
                if [ ! -f \(Self.shQuote(blockedFlagURL.path)) ]; then
                  touch \(Self.shQuote(blockedFlagURL.path))
                  printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-retry-session-1","model":"claude-sonnet-4-6"}'
                  printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"ASTRA_EVENT {\\"v\\":1,\\"type\\":\\"plan.step.blocked\\",\\"stepID\\":\\"step-1\\",\\"status\\":\\"blocked\\",\\"reason\\":\\"Write permission needed to create .astra/tasks/97EF1FD6/index.html.\\"}\\n"}]}}'
                  printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"num_turns":1,"result":"blocked","usage":{"input_tokens":3,"output_tokens":5}}'
                  exit 0
                fi
                task_dir="$(find \(Self.shQuote(harness.workspaceURL.appendingPathComponent(".astra/tasks", isDirectory: true).path)) -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n 1)"
                if [ -n "$task_dir" ]; then
                  printf '%s\\n' '<!doctype html><html><body>Home</body></html>' > "$task_dir/index.html"
                fi
                printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-retry-session-2","model":"claude-sonnet-4-6"}'
                printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"ASTRA_EVENT {\\"v\\":1,\\"type\\":\\"plan.step.completed\\",\\"stepID\\":\\"step-1\\",\\"summary\\":\\"Created index.html\\"}\\n"}]}}'
                printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"num_turns":1,"result":"wrote artifact","usage":{"input_tokens":3,"output_tokens":5}}'
                exit 0
                """,
                argsFile: argsURL
            )
        )

        let task = harness.makeTask(runtime: .claudeCode, goal: plan.goal, model: "claude-sonnet-4-6")
        let restrictedSkill = Skill(
            name: "Read-only",
            allowedTools: ["Read", "Grep"],
            disallowedTools: ["Write", "Edit", "Bash"],
            behaviorInstructions: ""
        )
        harness.context.insert(restrictedSkill)
        task.skills = [restrictedSkill]
        TaskPlanService.recordCreated(plan, task: task, modelContext: harness.context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: harness.context)
        let worker = harness.makeWorker(
            runtime: .claudeCode,
            executablePath: claudePath,
            permissionPolicy: .restricted
        )

        _ = await harness.executeApprovedPlan(task: task, plan: plan, worker: worker, mode: .nextStep)
        var state = TaskPlanService.reconstruct(for: task)
        #expect(task.status == .pendingUser)
        #expect(state.plan?.steps.first?.status == .blocked)
        #expect(state.plan?.steps.first?.likelyTools.contains("Write") == true)

        _ = await harness.executeApprovedPlan(task: task, plan: plan, worker: worker, mode: .nextStep)

        let args = try String(contentsOf: argsURL, encoding: .utf8)
        #expect(args.contains("--allowedTools"))
        #expect(args.contains("Write"))
        state = TaskPlanService.reconstruct(for: task)
        #expect(task.status == .completed)
        #expect(state.plan?.steps.first?.status == .done)
        #expect(state.lifecycleStatus == .completed)
    }

    @Test("Plan mode can be approved and executed after an existing chat turn")
    func planModeCanExecuteAfterExistingChatTurn() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let countFile = harness.rootURL.appendingPathComponent("plan-call-count.txt")
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            count="$(cat \(Self.shQuote(countFile.path)) 2>/dev/null || echo 0)"
            count=$((count + 1))
            printf '%s' "$count" > \(Self.shQuote(countFile.path))
            if [ "$count" = "1" ]; then
              printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Initial chat answer"}}'
            else
              printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"ASTRA_EVENT {\\"v\\":1,\\"type\\":\\"plan.step.completed\\",\\"stepID\\":\\"step-1\\",\\"summary\\":\\"Done\\"}\\n"}}'
              printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Approved plan executed"}}'
            fi
            printf '%s\\n' '{"type":"usage","usage":{"input_tokens":1,"output_tokens":1},"duration_ms":5,"turns":1}'
            exit 0
            """)
        )

        let plan = TaskPlanPayload(
            title: "Mid-thread plan",
            goal: "Execute a plan after chat context exists",
            steps: [
                TaskPlanPayloadStep(id: "step-1", title: "Apply plan", likelyTools: ["Write"])
            ]
        )
        let task = harness.makeTask(runtime: .copilotCLI, goal: "Start normally", model: "gpt-5")
        let worker = harness.makeWorker(runtime: .copilotCLI, executablePath: copilotPath)

        _ = await harness.execute(task: task, worker: worker)
        TaskPlanService.recordCreated(plan, task: task, modelContext: harness.context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: harness.context)
        _ = await harness.executeApprovedPlan(task: task, plan: plan, worker: worker)

        let runs = task.runs.sorted { $0.startedAt < $1.startedAt }
        let state = TaskPlanService.reconstruct(for: task)
        #expect(runs.count == 2)
        #expect(runs[0].output == "Initial chat answer")
        #expect(runs[1].output == "Approved plan executed")
        #expect(task.status == .completed)
        #expect(state.lifecycleStatus == .completed)
        #expect(state.plan?.steps.first?.status == .done)
    }

    @Test("Approved plan path permission prompts stop instead of looping")
    func approvedPlanPathPermissionPromptStopsInsteadOfLooping() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let plan = TaskPlanPayload(
            title: "Prompt plan",
            goal: "Trigger a hidden permission prompt",
            steps: [
                TaskPlanPayloadStep(id: "step-1", title: "Write outside workspace", likelyTools: ["Write"])
            ]
        )
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            /usr/bin/python3 -u - <<'PY'
            import time
            print('The following paths are outside the allowed directories:', flush=True)
            print('  - /Users/example/Documents/Astra\\\\', flush=True)
            print('Allow access to these paths? (y/n):', flush=True)
            time.sleep(20)
            PY
            exit $?
            """)
        )

        let task = harness.makeTask(runtime: .copilotCLI, goal: plan.goal, model: "gpt-5")
        TaskPlanService.recordCreated(plan, task: task, modelContext: harness.context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: harness.context)
        let worker = harness.makeWorker(
            runtime: .copilotCLI,
            executablePath: copilotPath,
            permissionPolicy: .restricted
        )

        _ = await harness.executeApprovedPlan(task: task, plan: plan, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .failed)
        #expect(run.status == .failed)
        #expect(run.stopReason == "provider_permission_unresumable")
        #expect(task.events.contains { $0.type == "permission.denied" && $0.payload.contains("WorkspaceAccess") })
        #expect(task.events.contains { $0.type == "error" && $0.payload.contains("does not map to a scoped runtime permission") })
        #expect(!task.events.contains { $0.type == "permission.approval.requested" })
        #expect(!task.events.contains { $0.type == "error" && $0.payload.contains("idle timeout") })
    }

    @Test("Changing runtime from Claude to Copilot starts a clean provider run")
    func changingRuntimeFromClaudeToCopilotStartsCleanProviderRun() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(body: """
            printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-session-1","model":"claude-sonnet-4-6"}'
            printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"Claude first answer"}]}}'
            printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":12,"num_turns":1,"result":"Claude first answer","usage":{"input_tokens":3,"output_tokens":5}}'
            exit 0
            """)
        )
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            printf '%s\\n' '{"type":"session.mcp_servers_loaded","session":{"id":"copilot-session-1","model":"gpt-5"}}'
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Copilot follow-up answer"}}'
            printf '%s\\n' '{"type":"usage","usage":{"input_tokens":4,"output_tokens":6},"duration_ms":9,"turns":1}'
            exit 0
            """)
        )

        let task = harness.makeTask(runtime: .claudeCode, goal: "Start with Claude", model: "claude-sonnet-4-6")
        let worker = harness.makeWorker(claudePath: claudePath, copilotPath: copilotPath)

        _ = await harness.execute(task: task, worker: worker)
        #expect(task.sessionId == "claude-session-1")

        task.runtimeID = AgentRuntimeID.copilotCLI.rawValue
        task.model = "gpt-5"
        _ = await harness.continueTask(task: task, message: "Continue with Copilot", worker: worker)

        let runs = task.runs.sorted { $0.startedAt < $1.startedAt }
        #expect(runs.count == 2)
        #expect(runs[0].runtimeID == AgentRuntimeID.claudeCode.rawValue)
        #expect(runs[0].providerSessionId == "claude-session-1")
        #expect(runs[1].runtimeID == AgentRuntimeID.copilotCLI.rawValue)
        #expect(runs[1].providerSessionId == "copilot-session-1")
        #expect(runs[1].providerSessionId != "claude-session-1")
        #expect(runs[1].output == "Copilot follow-up answer")
        #expect(task.sessionId == "copilot-session-1")
        #expect(task.status == .completed)
    }

    @Test("Changing runtime from Copilot to Claude starts a clean provider run")
    func changingRuntimeFromCopilotToClaudeStartsCleanProviderRun() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            printf '%s\\n' '{"type":"session.mcp_servers_loaded","session":{"id":"copilot-session-1","model":"gpt-5"}}'
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Copilot first answer"}}'
            printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":4},"duration_ms":10,"turns":1}'
            exit 0
            """)
        )
        let claudePath = try harness.writeExecutable(
            named: "claude",
            script: Self.claudeScript(body: """
            printf '%s\\n' '{"type":"system","subtype":"init","session_id":"claude-session-2","model":"claude-sonnet-4-6"}'
            printf '%s\\n' '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":[{"type":"text","text":"Claude follow-up answer"}]}}'
            printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":13,"num_turns":1,"result":"Claude follow-up answer","usage":{"input_tokens":5,"output_tokens":7}}'
            exit 0
            """)
        )

        let task = harness.makeTask(runtime: .copilotCLI, goal: "Start with Copilot", model: "gpt-5")
        let worker = harness.makeWorker(claudePath: claudePath, copilotPath: copilotPath)

        _ = await harness.execute(task: task, worker: worker)
        #expect(task.sessionId == "copilot-session-1")

        task.runtimeID = AgentRuntimeID.claudeCode.rawValue
        task.model = "claude-sonnet-4-6"
        task.tokenBudget = 200_000
        _ = await harness.continueTask(task: task, message: "Continue with Claude", worker: worker)

        let runs = task.runs.sorted { $0.startedAt < $1.startedAt }
        #expect(runs.count == 2)
        #expect(runs[0].runtimeID == AgentRuntimeID.copilotCLI.rawValue)
        #expect(runs[0].providerSessionId == "copilot-session-1")
        #expect(runs[1].runtimeID == AgentRuntimeID.claudeCode.rawValue)
        #expect(runs[1].providerSessionId == "claude-session-2")
        #expect(runs[1].providerSessionId != "copilot-session-1")
        #expect(runs[1].output == "Claude follow-up answer")
        #expect(task.sessionId == "claude-session-2")
        #expect(task.status == .completed)
    }

    private static func copilotScript(body: String, argsFile: URL? = nil) -> String {
        let recordArgs = argsFile.map { "printf '%s\\n' \"$@\" > \(shQuote($0.path))" } ?? ""
        return """
        #!/bin/sh
        if [ "$1" = "help" ]; then
          cat <<'HELP'
        --output-format=FORMAT --stream=MODE --no-ask-user --secret-env-vars=VAR
        --allow-all-tools required for non-interactive mode
        HELP
          exit 0
        fi
        if [ "$1" = "--version" ] || [ "$1" = "version" ]; then
          echo "copilot fake 1.0"
          exit 0
        fi
        \(recordArgs)
        \(body)
        """
    }

    private static func claudeScript(body: String, argsFile: URL? = nil) -> String {
        let recordArgs = argsFile.map { "printf '%s\\n' \"$@\" > \(shQuote($0.path))" } ?? ""
        return """
        #!/bin/sh
        \(recordArgs)
        \(body)
        """
    }

    private static func shQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

@MainActor
private final class HeadlessChatHarness {
    let rootURL: URL
    let workspaceURL: URL
    let container: ModelContainer
    let context: ModelContext

    init() throws {
        rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-headless-chat-\(UUID().uuidString)", isDirectory: true)
        workspaceURL = rootURL.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)

        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [config]
        )
        context = container.mainContext
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func writeExecutable(named name: String, script: String) throws -> String {
        let url = rootURL.appendingPathComponent(name)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    func makeTask(
        runtime: AgentRuntimeID,
        goal: String,
        model: String,
        tokenBudget: Int? = nil
    ) -> AgentTask {
        let workspace = Workspace(name: "Headless", primaryPath: workspaceURL.path)
        context.insert(workspace)
        let resolvedBudget = tokenBudget ?? (runtime == .claudeCode ? 200_000 : 1_000)

        let task = AgentTask(
            title: "Headless \(runtime.rawValue)",
            goal: goal,
            workspace: workspace,
            tokenBudget: resolvedBudget,
            model: model
        )
        task.runtimeID = runtime.rawValue
        task.status = .queued
        context.insert(task)
        try? context.save()
        return task
    }

    func makeWorker(
        runtime: AgentRuntimeID,
        executablePath: String,
        permissionPolicy: PermissionPolicy = .restricted
    ) -> AgentRuntimeWorker {
        let worker = AgentRuntimeWorker()
        worker.timeoutSeconds = 10
        worker.permissionPolicy = permissionPolicy
        switch runtime {
        case .claudeCode:
            worker.claudePath = executablePath
        case .copilotCLI:
            worker.copilotPath = executablePath
            worker.copilotHome = rootURL.appendingPathComponent("copilot-home", isDirectory: true).path
        }
        return worker
    }

    func makeWorker(
        claudePath: String,
        copilotPath: String,
        permissionPolicy: PermissionPolicy = .restricted
    ) -> AgentRuntimeWorker {
        let worker = AgentRuntimeWorker()
        worker.timeoutSeconds = 10
        worker.permissionPolicy = permissionPolicy
        worker.claudePath = claudePath
        worker.copilotPath = copilotPath
        worker.copilotHome = rootURL.appendingPathComponent("copilot-home", isDirectory: true).path
        return worker
    }

    func execute(task: AgentTask, worker: AgentRuntimeWorker) async -> [ParsedEvent] {
        var events: [ParsedEvent] = []
        await worker.execute(task: task, modelContext: context) { event in
            events.append(event)
        }
        try? context.save()
        return events
    }

    func continueTask(
        task: AgentTask,
        message: String,
        worker: AgentRuntimeWorker,
        executionPolicy: AgentRuntimeExecutionPolicy = .default
    ) async -> [ParsedEvent] {
        var events: [ParsedEvent] = []
        await worker.continueSession(
            task: task,
            message: message,
            modelContext: context,
            executionPolicy: executionPolicy
        ) { event in
            events.append(event)
        }
        try? context.save()
        return events
    }

    func executeApprovedPlan(
        task: AgentTask,
        plan: TaskPlanPayload,
        worker: AgentRuntimeWorker,
        mode: TaskPlanExecutionMode = .fullPlan
    ) async -> [ParsedEvent] {
        var events: [ParsedEvent] = []
        await worker.executeApprovedPlan(task: task, plan: plan, mode: mode, modelContext: context) { event in
            events.append(event)
        }
        try? context.save()
        return events
    }

    func waitUntil(
        task: AgentTask,
        timeoutSeconds: TimeInterval = 3,
        predicate: @escaping (AgentTask) -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if predicate(task) {
                return true
            }
            try? await Swift.Task.sleep(nanoseconds: 50_000_000)
        }
        return predicate(task)
    }
}

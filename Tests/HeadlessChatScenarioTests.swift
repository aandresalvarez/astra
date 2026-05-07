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

    @Test("Headless chat enforces budget guardrails")
    func headlessChatEnforcesBudget() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let largeOutput = String(repeating: "x", count: 600)
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
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

        _ = await harness.execute(task: task, worker: worker)

        let run = try #require(task.runs.first)
        #expect(task.status == .budgetExceeded)
        #expect(run.status == .budgetExceeded)
        #expect(run.stopReason == "max_budget_reached")
        #expect(task.events.contains { $0.type == "budget.exceeded" })
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
        #expect(args.contains("--allow-all-tools"))
        #expect(!args.contains("--allow-tool"))
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

    @Test("Approved plan permission prompts fail fast instead of timing out")
    func approvedPlanPermissionPromptFailsFastInsteadOfTimingOut() async throws {
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
        let errorEvent = try #require(task.events.first { $0.type == "error" })
        #expect(task.status == .failed)
        #expect(run.status == .failed)
        #expect(run.stopReason == "failed")
        #expect(task.events.contains { $0.type == "permission.denied" && $0.payload.contains("WorkspaceAccess") })
        #expect(errorEvent.payload.contains("approval prompt ASTRA could not answer"))
        #expect(!errorEvent.payload.contains("idle timeout"))
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
        tokenBudget: Int = 1_000
    ) -> AgentTask {
        let workspace = Workspace(name: "Headless", primaryPath: workspaceURL.path)
        context.insert(workspace)

        let task = AgentTask(
            title: "Headless \(runtime.rawValue)",
            goal: goal,
            workspace: workspace,
            tokenBudget: tokenBudget,
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

    func continueTask(task: AgentTask, message: String, worker: AgentRuntimeWorker) async -> [ParsedEvent] {
        var events: [ParsedEvent] = []
        await worker.continueSession(task: task, message: message, modelContext: context) { event in
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
}

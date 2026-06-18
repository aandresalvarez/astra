import Foundation
import SwiftData
import Testing
@testable import ASTRA
import ASTRACore

extension HeadlessChatScenarioTests {
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

    @Test("Approved plan completion is blocked when validation contract fails")
    func approvedPlanCompletionBlockedWhenValidationContractFails() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let plan = TaskPlanPayload(
            title: "Contract gated plan",
            goal: "Do work with proof",
            steps: [
                TaskPlanPayloadStep(id: "step-1", title: "Implement", likelyTools: ["Write"])
            ],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "proof-command",
                    description: "Proof command passes",
                    method: .command,
                    command: "false"
                )
            ])
        )
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"ASTRA_EVENT {\\"v\\":1,\\"type\\":\\"plan.step.completed\\",\\"stepID\\":\\"step-1\\",\\"summary\\":\\"Done\\"}\\n"}}'
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Plan work completed"}}'
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
        let run = try #require(task.runs.first)
        #expect(task.status == .pendingUser)
        #expect(run.status == .failed)
        #expect(run.stopReason == "validation_contract_failed")
        #expect(state.lifecycleStatus == .executing)
        #expect(!task.events.contains { $0.type == TaskPlanEventTypes.executionCompleted })
        #expect(task.events.contains { $0.type == TaskValidationEventTypes.assertionFailed })
        #expect(task.events.contains { $0.type == TaskValidationEventTypes.contractFailed })
        #expect(task.events.contains { $0.type == "system.info" && $0.payload.contains("Validation contract failed") })
    }

    @Test("Approved plan completion proceeds when validation contract passes")
    func approvedPlanCompletionProceedsWhenValidationContractPasses() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let plan = TaskPlanPayload(
            title: "Contract gated plan",
            goal: "Do work with proof",
            steps: [
                TaskPlanPayloadStep(id: "step-1", title: "Implement", likelyTools: ["Write"])
            ],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "proof-command",
                    description: "Proof command passes",
                    method: .command,
                    command: "true"
                )
            ])
        )
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"ASTRA_EVENT {\\"v\\":1,\\"type\\":\\"plan.step.completed\\",\\"stepID\\":\\"step-1\\",\\"summary\\":\\"Done\\"}\\n"}}'
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Plan work completed"}}'
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
        #expect(state.lifecycleStatus == .completed)
        #expect(task.events.contains { $0.type == TaskValidationEventTypes.assertionPassed })
        #expect(task.events.contains { $0.type == TaskValidationEventTypes.contractPassed })
        #expect(task.events.contains { $0.type == TaskPlanEventTypes.executionCompleted })
    }

    @Test("Approved artifact plan validates generated files without shell composition")
    func approvedArtifactPlanValidatesGeneratedFilesWithoutShellComposition() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let plan = TaskPlanPayload(
            title: "Med13 homepage",
            goal: "Create a static homepage for Med13",
            steps: [
                TaskPlanPayloadStep(
                    id: "step-1",
                    title: "Generate static homepage files",
                    likelyTools: ["Write"],
                    outputs: [
                        TaskPlanStepOutput(kind: .file, scope: .taskOutput, path: "index.html"),
                        TaskPlanStepOutput(kind: .file, scope: .taskOutput, path: "styles.css")
                    ]
                )
            ],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "index-exists",
                    description: "Index page exists",
                    method: .artifact,
                    path: "index.html"
                ),
                TaskValidationAssertion(
                    id: "styles-exists",
                    description: "Stylesheet exists",
                    method: .artifact,
                    path: "styles.css"
                ),
                TaskValidationAssertion(
                    id: "index-med13",
                    description: "Index page contains Med13",
                    method: .textContains,
                    path: "index.html",
                    evidenceQuery: "Med13"
                )
            ])
        )
        let task = harness.makeTask(runtime: .copilotCLI, goal: plan.goal, model: "gpt-5")
        let taskFolder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        let indexPath = (taskFolder as NSString).appendingPathComponent("index.html")
        let stylesPath = (taskFolder as NSString).appendingPathComponent("styles.css")
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            cat > \(Self.shQuote(indexPath)) <<'HTML'
            <!doctype html>
            <html><body><h1>Med13 Foundation</h1></body></html>
            HTML
            printf 'body { font-family: system-ui; }\\n' > \(Self.shQuote(stylesPath))
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"ASTRA_EVENT {\\"v\\":1,\\"type\\":\\"plan.step.completed\\",\\"stepID\\":\\"step-1\\",\\"summary\\":\\"Created Med13 homepage artifacts\\"}\\n"}}'
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Created Med13 homepage artifacts."}}'
            printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":3},"duration_ms":11,"turns":1}'
            exit 0
            """)
        )
        TaskPlanService.recordCreated(plan, task: task, modelContext: harness.context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: harness.context)
        let worker = harness.makeWorker(runtime: .copilotCLI, executablePath: copilotPath)

        _ = await harness.executeApprovedPlan(task: task, plan: plan, worker: worker)

        let state = TaskPlanService.reconstruct(for: task)
        #expect(task.status == .completed)
        #expect(state.lifecycleStatus == .completed)
        #expect(task.events.contains { $0.type == TaskValidationEventTypes.contractPassed })
        #expect(task.events.contains { $0.type == TaskValidationEventTypes.assertionPassed && $0.payload.contains("index-med13") })
        #expect(!task.events.contains { $0.payload.contains("command_not_allowed") })
        #expect(!task.events.contains { $0.type == TaskValidationEventTypes.contractFailed })
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
        #expect(args.contains("create"))
        #expect(args.contains("ASTRA review mode approved only the next plan step"))
        #expect(args.contains("Execute exactly the approved step whose ID is step-1"))
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
        #expect(secondPromptArgs.contains("Execute exactly the approved step whose ID is step-2"))
        #expect(task.status == .completed)
        #expect(task.runs.count == 2)
        #expect(finalState.lifecycleStatus == .completed)
        #expect(finalState.plan?.steps.allSatisfy { $0.status == .done } == true)
        #expect(task.events.contains { $0.type == "plan.execution.completed" })
    }

    @Test("Review mode validates contract only after the final approved step")
    func reviewModeValidatesContractOnlyAfterFinalApprovedStep() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let countFile = harness.rootURL.appendingPathComponent("review-contract-count.txt")
        let proofURL = harness.rootURL.appendingPathComponent("final-proof.txt")
        let plan = TaskPlanPayload(
            title: "Two step proof plan",
            goal: "Build proof across multiple approvals",
            steps: [
                TaskPlanPayloadStep(id: "step-1", title: "Prepare proof", likelyTools: ["Write"]),
                TaskPlanPayloadStep(id: "step-2", title: "Finish proof", likelyTools: ["Write"])
            ],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "final-proof",
                    description: "Final proof exists",
                    method: .command,
                    command: "test -f \(Self.shQuote(proofURL.path))"
                )
            ])
        )
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            count="$(cat \(Self.shQuote(countFile.path)) 2>/dev/null || echo 0)"
            count=$((count + 1))
            printf '%s' "$count" > \(Self.shQuote(countFile.path))
            if [ "$count" = "1" ]; then
              printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"ASTRA_EVENT {\\"v\\":1,\\"type\\":\\"plan.step.completed\\",\\"stepID\\":\\"step-1\\",\\"summary\\":\\"Prepared\\"}\\n"}}'
            else
              touch \(Self.shQuote(proofURL.path))
              printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"ASTRA_EVENT {\\"v\\":1,\\"type\\":\\"plan.step.completed\\",\\"stepID\\":\\"step-2\\",\\"summary\\":\\"Finished\\"}\\n"}}'
            fi
            printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":3},"duration_ms":11,"turns":1}'
            exit 0
            """)
        )

        let task = harness.makeTask(runtime: .copilotCLI, goal: plan.goal, model: "gpt-5")
        TaskPlanService.recordCreated(plan, task: task, modelContext: harness.context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: harness.context)
        let worker = harness.makeWorker(runtime: .copilotCLI, executablePath: copilotPath)

        _ = await harness.executeApprovedPlan(task: task, plan: plan, worker: worker, mode: .nextStep)

        let stateAfterFirstStep = TaskPlanService.reconstruct(for: task)
        let currentPlan = try #require(stateAfterFirstStep.plan)
        #expect(task.status == .pendingUser)
        #expect(stateAfterFirstStep.lifecycleStatus == .executing)
        #expect(stateAfterFirstStep.plan?.steps.first(where: { $0.id == "step-1" })?.status == .done)
        #expect(stateAfterFirstStep.plan?.steps.first(where: { $0.id == "step-2" })?.status == .pending)
        #expect(!task.events.contains { $0.type == TaskValidationEventTypes.assertionStarted })
        #expect(!task.events.contains { $0.type == TaskValidationEventTypes.contractFailed })
        #expect(!task.events.contains { $0.type == TaskPlanEventTypes.executionCompleted })

        _ = await harness.executeApprovedPlan(task: task, plan: currentPlan, worker: worker, mode: .nextStep)

        let finalState = TaskPlanService.reconstruct(for: task)
        #expect(task.status == .completed)
        #expect(finalState.lifecycleStatus == .completed)
        #expect(finalState.plan?.steps.allSatisfy { $0.status == .done } == true)
        #expect(task.events.contains { $0.type == TaskValidationEventTypes.assertionPassed })
        #expect(task.events.contains { $0.type == TaskValidationEventTypes.contractPassed })
        #expect(task.events.contains { $0.type == TaskPlanEventTypes.executionCompleted })
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

    @Test("Approved plan execution records step progress with Antigravity")
    func approvedPlanExecutionRecordsStepProgressWithAntigravity() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let plan = TaskPlanPayload(
            title: "Antigravity plan",
            goal: "Execute one planned step with Antigravity",
            steps: [
                TaskPlanPayloadStep(id: "step-1", title: "Inspect", likelyTools: ["Read"])
            ]
        )
        let antigravityPath = try harness.writeExecutable(
            named: "agy",
            script: """
            #!/bin/sh
            if [ "$1" = "--version" ]; then
              printf '%s\\n' '1.0.3'
              exit 0
            fi
            printf '%s\\n' 'ASTRA_EVENT {"v":1,"type":"plan.step.started","stepID":"step-1"}'
            printf '%s\\n' 'Antigravity plan executed'
            printf '%s\\n' 'ASTRA_EVENT {"v":1,"type":"plan.step.completed","stepID":"step-1","summary":"Done"}'
            exit 0
            """
        )

        let task = harness.makeTask(
            runtime: .antigravityCLI,
            goal: plan.goal,
            model: "Gemini 3.5 Flash"
        )
        TaskPlanService.recordCreated(plan, task: task, modelContext: harness.context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: harness.context)
        let worker = harness.makeWorker(runtime: .antigravityCLI, executablePath: antigravityPath)

        _ = await harness.executeApprovedPlan(task: task, plan: plan, worker: worker)

        let state = TaskPlanService.reconstruct(for: task)
        #expect(task.status == .completed)
        #expect(task.runs.first?.output.trimmingCharacters(in: .whitespacesAndNewlines) == "Antigravity plan executed")
        #expect(state.lifecycleStatus == .completed)
        #expect(state.plan?.steps.first?.status == .done)
        #expect(task.events.contains { $0.type == "plan.execution.started" })
        #expect(task.events.contains { $0.type == "plan.execution.completed" })
        #expect(task.events.contains { $0.type == "plan.step.started" })
        #expect(task.events.contains { $0.type == "plan.step.completed" })
    }

    @Test("Approved Antigravity plan records failure lifecycle on provider crash")
    func approvedAntigravityPlanRecordsFailureOnCrash() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let plan = TaskPlanPayload(
            title: "Failing Antigravity plan",
            goal: "Fail during Antigravity execution",
            steps: [
                TaskPlanPayloadStep(id: "step-1", title: "Run")
            ]
        )
        let antigravityPath = try harness.writeExecutable(
            named: "agy",
            script: """
            #!/bin/sh
            if [ "$1" = "--version" ]; then
              printf '%s\\n' '1.0.3'
              exit 0
            fi
            printf '%s\\n' 'something went wrong'
            exit 1
            """
        )

        let task = harness.makeTask(
            runtime: .antigravityCLI,
            goal: plan.goal,
            model: "Gemini 3.5 Flash"
        )
        TaskPlanService.recordCreated(plan, task: task, modelContext: harness.context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: harness.context)
        let worker = harness.makeWorker(runtime: .antigravityCLI, executablePath: antigravityPath)

        _ = await harness.executeApprovedPlan(task: task, plan: plan, worker: worker)

        let state = TaskPlanService.reconstruct(for: task)
        #expect(task.status == .failed)
        #expect(state.lifecycleStatus == .failed)
        #expect(task.events.contains { $0.type == "plan.execution.failed" })
        #expect(!task.events.contains { $0.type == "plan.execution.completed" })
    }

    @Test("Antigravity plan mode autonomous execution passes skip-permissions flag")
    func antigravityPlanModeAutonomousPassesFlag() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let argsURL = harness.rootURL.appendingPathComponent("agy-plan-auto-args.txt")
        let plan = TaskPlanPayload(
            title: "Auto Antigravity plan",
            goal: "Run Antigravity plan in auto mode",
            steps: [
                TaskPlanPayloadStep(id: "step-1", title: "Build")
            ]
        )
        let antigravityPath = try harness.writeExecutable(
            named: "agy",
            script: """
            #!/bin/sh
            if [ "$1" = "--version" ]; then
              printf '%s\\n' '1.0.3'
              exit 0
            fi
            printf '%s\\n' "$@" > \(Self.shQuoteSandboxPath(argsURL.path))
            printf '%s\\n' 'ASTRA_EVENT {"v":1,"type":"plan.step.started","stepID":"step-1"}'
            printf '%s\\n' 'Autonomous plan done'
            printf '%s\\n' 'ASTRA_EVENT {"v":1,"type":"plan.step.completed","stepID":"step-1","summary":"Built"}'
            exit 0
            """
        )

        let task = harness.makeTask(
            runtime: .antigravityCLI,
            goal: plan.goal,
            model: "Gemini 3.5 Flash"
        )
        TaskPlanService.recordCreated(plan, task: task, modelContext: harness.context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: harness.context)
        let worker = harness.makeWorker(
            runtime: .antigravityCLI,
            executablePath: antigravityPath,
            permissionPolicy: .autonomous
        )

        _ = await harness.executeApprovedPlan(task: task, plan: plan, worker: worker)

        let args = try String(contentsOf: argsURL, encoding: .utf8)
        #expect(args.contains("--dangerously-skip-permissions"))
        #expect(!args.contains("--sandbox"))
        #expect(task.status == .completed)

        let state = TaskPlanService.reconstruct(for: task)
        #expect(state.lifecycleStatus == .completed)
        #expect(state.plan?.steps.first?.status == .done)
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
}

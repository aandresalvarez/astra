import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA
import ASTRACore

extension HeadlessChatScenarioTests {
    @Test("Review-mode step with missing required output blocks instead of completing")
    func reviewModeStepWithMissingRequiredOutputBlocks() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let plan = TaskPlanPayload(
            title: "Checkpointed plan",
            goal: "Produce the report",
            steps: [
                TaskPlanPayloadStep(
                    id: "step-1",
                    title: "Write report",
                    likelyTools: ["Write"],
                    outputs: [TaskPlanStepOutput(kind: .file, scope: .taskOutput, path: "report.md", required: true)]
                ),
                TaskPlanPayloadStep(id: "step-2", title: "Summarize", likelyTools: ["Read"])
            ]
        )
        // The provider CLAIMS the step completed (emits the marker) but never
        // creates report.md — the checkpoint must catch the lie.
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"ASTRA_EVENT {\\"v\\":1,\\"type\\":\\"plan.step.completed\\",\\"planID\\":\\"\(plan.planID)\\",\\"stepID\\":\\"step-1\\",\\"status\\":\\"done\\",\\"summary\\":\\"Wrote the report\\"}"}}'
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Report written."}}'
            printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":3},"duration_ms":9,"turns":1}'
            exit 0
            """)
        )

        let task = harness.makeTask(runtime: .copilotCLI, goal: plan.goal, model: "gpt-5")
        TaskPlanService.recordCreated(plan, task: task, modelContext: harness.context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: harness.context)
        let worker = harness.makeWorker(runtime: .copilotCLI, executablePath: copilotPath)

        _ = await harness.executeApprovedPlan(task: task, plan: plan, worker: worker, mode: .nextStep)

        let state = TaskPlanService.reconstruct(for: task)
        #expect(state.plan?.steps.first(where: { $0.id == "step-1" })?.status == .blocked)
        #expect(state.plan?.steps.first(where: { $0.id == "step-2" })?.status == .pending)
        #expect(task.status == .pendingUser)
        #expect(task.events.contains {
            $0.type == "plan.step.blocked" && $0.payload.contains("report.md")
        })
        #expect(!task.events.contains { $0.type == "plan.execution.completed" })

        // Once the output actually exists, re-approving the step verifies it.
        let taskFolder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        try "report body".write(toFile: taskFolder + "/report.md", atomically: true, encoding: .utf8)

        _ = await harness.executeApprovedPlan(task: task, plan: plan, worker: worker, mode: .nextStep)

        let retried = TaskPlanService.reconstruct(for: task)
        #expect(retried.plan?.steps.first(where: { $0.id == "step-1" })?.status == .done)
        #expect(task.events.contains { $0.type == "plan.step.completed" })
    }

    @Test("Provider-reported blocker is not auto-completed by incidental output evidence")
    func providerBlockerNotLiftedByIncidentalEvidence() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let plan = TaskPlanPayload(
            title: "Blocked plan",
            goal: "Produce the report",
            steps: [
                TaskPlanPayloadStep(
                    id: "step-1",
                    title: "Write report",
                    likelyTools: ["Write"],
                    outputs: [TaskPlanStepOutput(kind: .file, scope: .taskOutput, path: "report.md", required: true)]
                )
            ]
        )
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"ASTRA_EVENT {\\"v\\":1,\\"type\\":\\"plan.step.blocked\\",\\"planID\\":\\"\(plan.planID)\\",\\"stepID\\":\\"step-1\\",\\"status\\":\\"blocked\\",\\"reason\\":\\"Need approval to push the report upstream.\\"}"}}'
            printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":3},"duration_ms":9,"turns":1}'
            exit 0
            """)
        )

        let task = harness.makeTask(runtime: .copilotCLI, goal: plan.goal, model: "gpt-5")
        TaskPlanService.recordCreated(plan, task: task, modelContext: harness.context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: harness.context)
        // The required output already exists (stale artifact from earlier
        // work); it must NOT outrank the provider's explicit blocker.
        let taskFolder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        try "stale".write(toFile: taskFolder + "/report.md", atomically: true, encoding: .utf8)

        let worker = harness.makeWorker(runtime: .copilotCLI, executablePath: copilotPath)
        _ = await harness.executeApprovedPlan(task: task, plan: plan, worker: worker, mode: .nextStep)

        let state = TaskPlanService.reconstruct(for: task)
        #expect(state.plan?.steps.first?.status == .blocked)
        #expect(task.status == .pendingUser)
        #expect(!task.events.contains { $0.type == "plan.step.completed" })
        #expect(task.events.contains {
            $0.type == "system.info" && $0.payload.contains("Need approval to push")
        })
    }

    @Test("Checkpoint-blocked step retried without a marker completes on evidence")
    func checkpointBlockedStepLiftsOnEvidenceWithoutMarker() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let plan = TaskPlanPayload(
            title: "Evidence plan",
            goal: "Produce the report",
            steps: [
                TaskPlanPayloadStep(
                    id: "step-1",
                    title: "Write report",
                    likelyTools: ["Write"],
                    outputs: [TaskPlanStepOutput(kind: .file, scope: .taskOutput, path: "report.md", required: true)]
                )
            ]
        )
        // Emits plain text only — no plan.step markers in either run.
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Worked on the report."}}'
            printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":3},"duration_ms":9,"turns":1}'
            exit 0
            """)
        )

        let task = harness.makeTask(runtime: .copilotCLI, goal: plan.goal, model: "gpt-5")
        TaskPlanService.recordCreated(plan, task: task, modelContext: harness.context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: harness.context)
        let worker = harness.makeWorker(runtime: .copilotCLI, executablePath: copilotPath)

        _ = await harness.executeApprovedPlan(task: task, plan: plan, worker: worker, mode: .nextStep)
        #expect(TaskPlanService.reconstruct(for: task).plan?.steps.first?.status == .blocked)

        let taskFolder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        try "report body".write(toFile: taskFolder + "/report.md", atomically: true, encoding: .utf8)

        _ = await harness.executeApprovedPlan(task: task, plan: plan, worker: worker, mode: .nextStep)

        let state = TaskPlanService.reconstruct(for: task)
        #expect(state.plan?.steps.first?.status == .done)
        #expect(task.events.contains {
            $0.type == "plan.step.completed" && $0.payload.contains("report.md")
        })
    }

    @Test("Provider-skipped step with declared outputs is not blocked by the checkpoint")
    func providerSkippedStepIsNotBlocked() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let plan = TaskPlanPayload(
            title: "Skip plan",
            goal: "Produce the report if needed",
            steps: [
                TaskPlanPayloadStep(
                    id: "step-1",
                    title: "Write report",
                    likelyTools: ["Write"],
                    outputs: [TaskPlanStepOutput(kind: .file, scope: .taskOutput, path: "report.md", required: true)]
                )
            ]
        )
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"ASTRA_EVENT {\\"v\\":1,\\"type\\":\\"plan.step.skipped\\",\\"planID\\":\\"\(plan.planID)\\",\\"stepID\\":\\"step-1\\",\\"status\\":\\"skipped\\",\\"reason\\":\\"Report already exists upstream.\\"}"}}'
            printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":3},"duration_ms":9,"turns":1}'
            exit 0
            """)
        )

        let task = harness.makeTask(runtime: .copilotCLI, goal: plan.goal, model: "gpt-5")
        TaskPlanService.recordCreated(plan, task: task, modelContext: harness.context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: harness.context)
        let worker = harness.makeWorker(runtime: .copilotCLI, executablePath: copilotPath)

        _ = await harness.executeApprovedPlan(task: task, plan: plan, worker: worker, mode: .nextStep)

        let state = TaskPlanService.reconstruct(for: task)
        #expect(state.plan?.steps.first?.status == .skipped)
        #expect(!task.events.contains { $0.type == "plan.step.blocked" })
        #expect(state.lifecycleStatus == .completed)
    }

    @Test("Full-plan run with missing required outputs pauses instead of completing")
    func fullPlanRunWithMissingOutputsPauses() async throws {
        let harness = try HeadlessChatHarness()
        defer { harness.cleanup() }

        let plan = TaskPlanPayload(
            title: "Full plan",
            goal: "Produce the report",
            steps: [
                TaskPlanPayloadStep(
                    id: "step-1",
                    title: "Write report",
                    likelyTools: ["Write"],
                    outputs: [TaskPlanStepOutput(kind: .file, scope: .taskOutput, path: "report.md", required: true)]
                )
            ]
        )
        let copilotPath = try harness.writeExecutable(
            named: "copilot",
            script: Self.copilotScript(body: """
            printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"All steps done."}}'
            printf '%s\\n' '{"type":"usage","usage":{"input_tokens":2,"output_tokens":3},"duration_ms":9,"turns":1}'
            exit 0
            """)
        )

        let task = harness.makeTask(runtime: .copilotCLI, goal: plan.goal, model: "gpt-5")
        TaskPlanService.recordCreated(plan, task: task, modelContext: harness.context)
        TaskPlanService.recordApproved(plan, task: task, modelContext: harness.context)
        let worker = harness.makeWorker(runtime: .copilotCLI, executablePath: copilotPath)

        _ = await harness.executeApprovedPlan(task: task, plan: plan, worker: worker, mode: .fullPlan)

        let state = TaskPlanService.reconstruct(for: task)
        #expect(task.status == .pendingUser)
        #expect(state.plan?.steps.first?.status == .blocked)
        #expect(task.events.contains {
            $0.type == "plan.step.blocked" && $0.payload.contains("report.md")
        })
        #expect(!task.events.contains { $0.type == "plan.execution.completed" })
    }
}

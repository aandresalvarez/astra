import Foundation
import Testing
@testable import ASTRA
import ASTRACore

@Suite("Plan step checkpoints")
@MainActor
struct PlanStepCheckpointTests {
    private func makeStep(outputs: [TaskPlanStepOutput]) -> TaskPlanPayloadStep {
        TaskPlanPayloadStep(id: "step-1", title: "Produce artifact", outputs: outputs)
    }

    private func makePlan(step: TaskPlanPayloadStep) -> TaskPlanPayload {
        TaskPlanPayload(title: "Plan", goal: "Goal", steps: [step])
    }

    @Test("required task output present verifies; missing fails")
    func requiredTaskOutputGate() throws {
        let folder = NSTemporaryDirectory() + "checkpoint-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: folder) }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)

        let step = makeStep(outputs: [
            TaskPlanStepOutput(kind: .file, scope: .taskOutput, path: "report.md", required: true)
        ])
        let plan = makePlan(step: step)

        let missing = PlanStepCheckpointVerifier.verify(
            step: step, plan: plan, taskFolder: folder, workspacePath: ""
        )
        #expect(!missing.isVerified)
        #expect(missing.missingRequiredPaths == ["report.md"])

        try "content".write(toFile: folder + "/report.md", atomically: true, encoding: .utf8)
        let present = PlanStepCheckpointVerifier.verify(
            step: step, plan: plan, taskFolder: folder, workspacePath: ""
        )
        #expect(present.isVerified)
        #expect(present.verifiedPaths == ["report.md"])
        #expect(present.completionEvidence.contains("report.md"))
    }

    @Test("optional, unverifiable, and traversal outputs never block the step")
    func nonGatingOutputs() throws {
        let folder = NSTemporaryDirectory() + "checkpoint-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: folder) }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)

        let step = makeStep(outputs: [
            TaskPlanStepOutput(kind: .file, scope: .taskOutput, path: "optional.md", required: false),
            TaskPlanStepOutput(kind: .file, scope: .chat, path: "answer", required: true),
            TaskPlanStepOutput(kind: .file, scope: .taskOutput, path: "../escape.md", required: true),
            TaskPlanStepOutput(kind: .file, scope: .taskOutput, path: "/etc/hosts", required: true)
        ])
        let plan = makePlan(step: step)

        let outcome = PlanStepCheckpointVerifier.verify(
            step: step, plan: plan, taskFolder: folder, workspacePath: ""
        )
        #expect(outcome.isVerified)
        #expect(outcome.verifiedPaths.isEmpty)
        #expect(outcome.unverifiableScopeCount >= 2)
    }

    @Test("non-disk kinds and unresolvable shapes never gate")
    func nonDiskKindsAndShapesNeverGate() throws {
        let folder = NSTemporaryDirectory() + "checkpoint-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: folder) }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)

        let step = makeStep(outputs: [
            TaskPlanStepOutput(kind: .url, scope: .taskOutput, path: "https://example.com/page", required: true),
            TaskPlanStepOutput(kind: .text, scope: .taskOutput, path: "summary", required: true),
            TaskPlanStepOutput(kind: .file, scope: .taskOutput, path: "~/report.md", required: true),
            TaskPlanStepOutput(kind: .file, scope: .taskOutput, path: "scheme://thing", required: true)
        ])
        let outcome = PlanStepCheckpointVerifier.verify(
            step: step, plan: makePlan(step: step), taskFolder: folder, workspacePath: ""
        )
        #expect(outcome.isVerified)
        #expect(outcome.unverifiableScopeCount == 4)
    }

    @Test("required directory output needs content, not just preflight mkdir")
    func directoryOutputNeedsContent() throws {
        let folder = NSTemporaryDirectory() + "checkpoint-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: folder) }
        try FileManager.default.createDirectory(atPath: folder + "/dist", withIntermediateDirectories: true)

        let step = makeStep(outputs: [
            TaskPlanStepOutput(kind: .directory, scope: .taskOutput, path: "dist", required: true)
        ])
        let plan = makePlan(step: step)

        let empty = PlanStepCheckpointVerifier.verify(
            step: step, plan: plan, taskFolder: folder, workspacePath: ""
        )
        #expect(!empty.isVerified)

        try "asset".write(toFile: folder + "/dist/app.js", atomically: true, encoding: .utf8)
        let filled = PlanStepCheckpointVerifier.verify(
            step: step, plan: plan, taskFolder: folder, workspacePath: ""
        )
        #expect(filled.isVerified)
    }

    @Test("step-scoped contract artifacts accept either the task folder or the working tree")
    func contractArtifactsAcceptEitherRoot() throws {
        let taskFolder = NSTemporaryDirectory() + "checkpoint-task-\(UUID().uuidString)"
        let workTree = NSTemporaryDirectory() + "checkpoint-work-\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(atPath: taskFolder)
            try? FileManager.default.removeItem(atPath: workTree)
        }
        try FileManager.default.createDirectory(atPath: taskFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: workTree, withIntermediateDirectories: true)
        try "page".write(toFile: workTree + "/index.html", atomically: true, encoding: .utf8)

        let step = makeStep(outputs: [])
        var plan = makePlan(step: step)
        plan.validationContract = TaskValidationContract(assertions: [
            TaskValidationAssertion(
                id: "a1",
                scope: .step,
                stepID: step.id,
                description: "Homepage exists",
                method: .artifact,
                path: "index.html"
            )
        ])

        let outcome = PlanStepCheckpointVerifier.verify(
            step: step, plan: plan, taskFolder: taskFolder, workspacePath: workTree
        )
        #expect(outcome.isVerified)
        #expect(outcome.verifiedPaths == ["index.html"])
    }

    @Test("steps with no declared outputs verify vacuously")
    func noOutputsVerifyVacuously() {
        let step = makeStep(outputs: [])
        let outcome = PlanStepCheckpointVerifier.verify(
            step: step, plan: makePlan(step: step), taskFolder: "/tmp", workspacePath: ""
        )
        #expect(outcome.isVerified)
        #expect(outcome.completionEvidence.contains("No verifiable outputs"))
    }

    @Test("checkpoint policy tiers ask-mode execution by pre-action channel")
    func checkpointPolicyTiers() {
        #expect(PlanCheckpointPolicy.tier(for: .claudeCode) == .liveApprovals)
        #expect(PlanCheckpointPolicy.tier(for: .codexCLI) == .runBoundary)
        #expect(PlanCheckpointPolicy.tier(for: .cursorCLI) == .runBoundary)
        #expect(PlanCheckpointPolicy.tier(for: .copilotCLI) == .runBoundary)

        #expect(PlanCheckpointPolicy.executionMode(runtime: .claudeCode, skipPermissions: false) == .fullPlan)
        #expect(PlanCheckpointPolicy.executionMode(runtime: .codexCLI, skipPermissions: false) == .nextStep)
        #expect(PlanCheckpointPolicy.executionMode(runtime: .codexCLI, skipPermissions: true) == .fullPlan)

        #expect(PlanCheckpointPolicy.modeLabel(mode: .nextStep, skipPermissions: false)
            .contains("one approved step"))
        #expect(PlanCheckpointPolicy.modeLabel(mode: .fullPlan, skipPermissions: false)
            .contains("asks before risky actions"))
    }
}

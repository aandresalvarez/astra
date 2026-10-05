import Foundation
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

/// Antigravity is the one adapter that builds its launch plan after waiting on the shared-state
/// gate. The native-continuation decision and the recorded launch signature were made before that
/// wait, so a resumed launch must keep the model they approved instead of a model edited while queued.
@Suite("Antigravity resume model")
@MainActor
struct AntigravityResumeModelTests {
    private func launchContext(
        for task: AgentTask,
        manifestModel: String?,
        resumeSessionID: String?
    ) -> AgentRuntimeProcessLaunchContext {
        let manifest = manifestModel.map { model in
            RunPermissionManifest(
                taskID: task.id,
                runID: UUID(),
                phase: "resume",
                providerID: .antigravityCLI,
                providerVersion: nil,
                model: model,
                policyLevel: .review,
                policyScope: .builtInDefault,
                providerRender: .failClosedLaunchRender(for: .antigravityCLI),
                workspacePath: task.workspace?.primaryPath ?? "",
                additionalPaths: [],
                environmentKeyNames: [],
                credentialLabels: [],
                approvalsGranted: [],
                approvalGrants: []
            )
        }
        return AgentRuntimeProcessLaunchContext(
            prompt: "continue", task: task, workspacePath: task.workspace?.primaryPath ?? "",
            executablePath: "/bin/agy-not-present", providerHomeDirectory: "/tmp/astra-antigravity-resume-home",
            permissionPolicy: .restricted, executionPolicy: .default, permissionManifest: manifest,
            timeoutSeconds: 30, phase: .resume, nativeContinuationSessionID: resumeSessionID)
    }

    private func task() -> AgentTask {
        let workspace = Workspace(name: "Resume Model", primaryPath: "/tmp/astra-antigravity-resume")
        return AgentTask(title: "Antigravity", goal: "Continue", workspace: workspace, model: "Gemini 3.5 Flash", runtime: .antigravityCLI)
    }

    @Test("A resumed launch keeps the model its launch signature approved when the task model changes while queued")
    func resumedLaunchKeepsSignatureModel() {
        let task = task()
        let context = launchContext(for: task, manifestModel: "Gemini 3.5 Flash", resumeSessionID: "agy-session-1")
        task.model = "Gemini 3.5 Pro" // edited while queued on the shared-state gate
        let plan = AgentRuntimeAdapterRegistry.adapter(for: .antigravityCLI).makeProcessLaunchPlan(context: context)
        #expect(plan.commandPlannedFields["model"] == "Gemini 3.5 Flash")
        #expect(plan.arguments.contains("agy-session-1"))
    }

    @Test("Without a manifest, a resumed launch keeps the model captured before the gate wait")
    func resumedLaunchWithoutManifestKeepsSnapshotModel() {
        let task = task()
        let context = launchContext(for: task, manifestModel: nil, resumeSessionID: "agy-session-1")
        task.model = "Gemini 3.5 Pro"
        let plan = AgentRuntimeAdapterRegistry.adapter(for: .antigravityCLI).makeProcessLaunchPlan(context: context)
        #expect(plan.commandPlannedFields["model"] == "Gemini 3.5 Flash")
    }

    @Test("A fresh launch still honors a model edited while queued")
    func freshLaunchHonorsQueuedModelEdit() {
        let task = task()
        let context = launchContext(for: task, manifestModel: "Gemini 3.5 Flash", resumeSessionID: nil)
        task.model = "Gemini 3.5 Pro"
        let plan = AgentRuntimeAdapterRegistry.adapter(for: .antigravityCLI).makeProcessLaunchPlan(context: context)
        #expect(plan.commandPlannedFields["model"] == "Gemini 3.5 Pro")
    }
}

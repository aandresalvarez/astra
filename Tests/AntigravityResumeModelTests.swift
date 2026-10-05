import Foundation
import SwiftData
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

    /// Runs only join `task.runs` once inserted, so the fixtures live in an in-memory store the caller retains.
    private func store(with task: AgentTask) throws -> ModelContainer {
        let container = try ModelContainer(
            for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        container.mainContext.insert(task)
        return container
    }

    private func signedRun(for task: AgentTask, model: String) throws -> TaskRun {
        let run = TaskRun(task: task)
        task.modelContext?.insert(run)
        let payload = try JSONDecoder().decode(ProviderLaunchSignaturePayload.self, from: JSONEncoder().encode(signaturePayload(model: model)))
        run.providerLaunchSignatureJSON = String(data: try JSONEncoder().encode(payload), encoding: .utf8)
        return run
    }

    private func signaturePayload(model: String) -> ProviderLaunchSignaturePayload {
        ProviderLaunchSignaturePayload(
            version: 1, runtimeID: AgentRuntimeID.antigravityCLI.rawValue, model: model, policyLevel: "standard",
            policyScope: "task", providerAdapterVersion: 1, permissionMode: "restricted", allowedTools: [],
            askFirstTools: [], deniedTools: [], allowedShellPatterns: [], askFirstShellPatterns: [],
            deniedShellPatterns: [], allowedURLPatterns: [], deniedURLPatterns: [], runtimeSupportTools: [],
            scopedSkillIDs: [], scopedSkillNames: [], scopedConnectorDescriptors: [], scopedLocalToolCommands: [],
            environmentKeyNames: [], credentialLabels: [], mcpServerIDs: [], browserAdapters: [],
            promptSchemaVersion: "context_capsule_v2",
            executionEnvironmentFingerprint: WorkspaceExecutionEnvironment.host.signatureFingerprint,
            readOnlyResourceContractDigest: nil
        )
    }

    @Test("A fresh launch that honors a queued model edit records the model it launched in its signature")
    func freshLaunchRecordsTheLaunchedModel() throws {
        let task = task()
        let container = try store(with: task)
        defer { withExtendedLifetime(container) {} }
        let run = try signedRun(for: task, model: "Gemini 3.5 Flash")
        var context = launchContext(for: task, manifestModel: "Gemini 3.5 Flash", resumeSessionID: nil)
        context = AgentRuntimeProcessLaunchContext(
            prompt: context.prompt, task: task, workspacePath: context.workspacePath, executablePath: context.executablePath,
            providerHomeDirectory: context.providerHomeDirectory, permissionPolicy: .restricted, executionPolicy: .default,
            permissionManifest: context.permissionManifest, timeoutSeconds: 30, runID: run.id)
        task.model = "Gemini 3.5 Pro"
        _ = AgentRuntimeAdapterRegistry.adapter(for: .antigravityCLI).makeProcessLaunchPlan(context: context)
        #expect(ProviderLaunchSignatureService.storedSignature(for: task, run: run)?.model == "Gemini 3.5 Pro")
    }

    @Test("A resumed launch leaves the approved signature alone")
    func resumedLaunchKeepsTheSignature() throws {
        let task = task()
        let container = try store(with: task)
        defer { withExtendedLifetime(container) {} }
        let run = try signedRun(for: task, model: "Gemini 3.5 Flash")
        var context = launchContext(for: task, manifestModel: "Gemini 3.5 Flash", resumeSessionID: "agy-session-1")
        context = AgentRuntimeProcessLaunchContext(
            prompt: context.prompt, task: task, workspacePath: context.workspacePath, executablePath: context.executablePath,
            providerHomeDirectory: context.providerHomeDirectory, permissionPolicy: .restricted, executionPolicy: .default,
            permissionManifest: context.permissionManifest, timeoutSeconds: 30, phase: .resume,
            nativeContinuationSessionID: "agy-session-1", runID: run.id)
        task.model = "Gemini 3.5 Pro"
        _ = AgentRuntimeAdapterRegistry.adapter(for: .antigravityCLI).makeProcessLaunchPlan(context: context)
        #expect(ProviderLaunchSignatureService.storedSignature(for: task, run: run)?.model == "Gemini 3.5 Flash")
    }
}

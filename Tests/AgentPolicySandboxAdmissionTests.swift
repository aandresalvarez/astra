import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

private func makeAgentPolicySandboxAdmissionContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

@Suite("Agent policy sandbox admission")
@MainActor
struct AgentPolicySandboxAdmissionTests {
    @Test("Preflight sandbox evidence honors the queue admission snapshot")
    func preflightManifestUsesAdmissionSnapshot() throws {
        let suiteName = "astra-agent-policy-sandbox-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(ExecutionSandboxEnforcement.bestEffort.rawValue, forKey: AppStorageKeys.sandboxEnforcement)

        let container = try makeAgentPolicySandboxAdmissionContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Override Tier", primaryPath: "/tmp/override-tier-workspace")
        let task = AgentTask(title: "Claude", goal: "Do work", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        let disabledManifest = AgentPolicyManifestService.recordPreflightManifest(
            task: task,
            run: run,
            runtime: .claudeCode,
            model: "claude-sonnet-4-6",
            workspacePath: workspace.primaryPath,
            phase: "test",
            permissionPolicy: .restricted,
            executionPolicy: AgentRuntimeExecutionPolicy(
                permissionPolicyOverride: .autonomous,
                allowedToolsOverride: nil,
                permissionGrantsOverride: nil,
                sandboxEnforcementSnapshot: .off
            ),
            defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
            sandboxSettingsDefaults: defaults,
            modelContext: context
        )
        #expect(!disabledManifest.providerRender.enforcementTiers.contains(.osSandboxed))
        #expect(disabledManifest.sandboxEvidence?.storedEnforcement == ExecutionSandboxEnforcement.off.rawValue)
        #expect(disabledManifest.sandboxEvidence?.effectiveEnforcement == ExecutionSandboxEnforcement.off.rawValue)

        defaults.set(ExecutionSandboxEnforcement.off.rawValue, forKey: AppStorageKeys.sandboxEnforcement)
        let enabledManifest = AgentPolicyManifestService.recordPreflightManifest(
            task: task,
            run: run,
            runtime: .claudeCode,
            model: "claude-sonnet-4-6",
            workspacePath: workspace.primaryPath,
            phase: "test",
            permissionPolicy: .restricted,
            executionPolicy: AgentRuntimeExecutionPolicy(sandboxEnforcementSnapshot: .bestEffort),
            defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
            sandboxSettingsDefaults: defaults,
            modelContext: context
        )
        #expect(enabledManifest.providerRender.enforcementTiers.contains(.osSandboxed))
        #expect(enabledManifest.sandboxEvidence?.storedEnforcement == ExecutionSandboxEnforcement.bestEffort.rawValue)
        #expect(enabledManifest.sandboxEvidence?.effectiveEnforcement == ExecutionSandboxEnforcement.bestEffort.rawValue)
    }

    @Test("Preflight evidence includes the admitted shared-workspace boundary")
    func preflightManifestIncludesSharedWorkspaceBoundary() throws {
        let suiteName = "astra-agent-policy-shared-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(ExecutionSandboxEnforcement.bestEffort.rawValue, forKey: AppStorageKeys.sandboxEnforcement)
        defaults.set(false, forKey: AppStorageKeys.sandboxLayerNativeProviders)

        let container = try makeAgentPolicySandboxAdmissionContainer()
        let context = container.mainContext
        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceRoot) }
        let workspace = Workspace(name: "Shared Codex", primaryPath: workspaceRoot.path)
        let task = AgentTask(title: "Shared Codex", goal: "Read only.", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        let launchResourcePlan = TaskLaunchResourceResolver.resolve(
            task: task,
            runID: run.id,
            runtime: .codexCLI,
            phase: .run,
            prompt: task.goal,
            contextText: "",
            workspacePath: workspace.primaryPath,
            workspaceAccess: .shared,
            gitCredentialContextProvider: { _, _, _, _ in .empty }
        )

        let manifest = AgentPolicyManifestService.recordPreflightManifest(
            task: task,
            run: run,
            runtime: .codexCLI,
            model: "gpt-5",
            workspacePath: workspace.primaryPath,
            phase: .run,
            permissionPolicy: .restricted,
            executionPolicy: AgentRuntimeExecutionPolicy(
                workspaceAccessOverride: .shared,
                sandboxEnforcementSnapshot: .bestEffort
            ),
            defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
            launchResourcePlan: launchResourcePlan,
            sandboxSettingsDefaults: defaults,
            modelContext: context
        )

        #expect(manifest.providerRender.enforcementTiers.contains(.osSandboxed))
        #expect(manifest.sandboxEvidence?.storedEnforcement == ExecutionSandboxEnforcement.bestEffort.rawValue)
        #expect(manifest.sandboxEvidence?.effectiveEnforcement == ExecutionSandboxEnforcement.strict.rawValue)
    }
}

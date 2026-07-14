import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

@Suite("Git publish policy")
struct GitPublishPolicyTests {
    @Test("Git publication approval is exact one-shot ASTRA authority")
    func gitPublicationApprovalIsExactOneShotAstraAuthority() throws {
        let authorization = GitPublishAuthorization(
            repository: "aandresalvarez/astra",
            baseBranch: "main",
            headBranch: "alvaro/typed-publish",
            expectedHeadSHA: String(repeating: "a", count: 40),
            requestDigest: String(repeating: "b", count: 64),
            isDraft: true
        )
        let request = PermissionRequest.gitPublish(authorization: authorization)
        let grant = PermissionGrant.gitPublish(authorization: authorization)

        #expect(PermissionBroker.approvalGrants(for: request) == [grant])
        #expect(PermissionBroker.providerGrantStrings(for: [grant], runtime: .claudeCode).isEmpty)
        #expect(PermissionBroker.providerRuntimeGrantStrings(for: [grant], runtime: .claudeCode).isEmpty)
        #expect(PermissionBroker.taskScopedApprovalGrants(for: [grant]).isEmpty)

        let payload = PermissionBroker.approvalPayload(
            providerID: .claudeCode,
            request: request,
            reason: "Publishing a branch and pull request changes GitHub",
            grants: [grant]
        )
        let encoded = try #require(payload.encodedString())
        let decoded = try #require(PermissionApprovalEventPayload.decoded(from: encoded))

        #expect(decoded.request == request)
        #expect(decoded.grants == [grant])
        #expect(decoded.displayMessage.contains("Executes this exact reviewed draft publication once through ASTRA"))
        #expect(decoded.displayMessage.contains("does not grant provider shell access, restart the provider, or create a reusable task permission"))
        #expect(decoded.displayMessage.contains(authorization.requestDigest))
    }

    @Test("Git publication approval rejects abbreviated commit identities")
    func gitPublicationApprovalRejectsAbbreviatedCommitIdentity() {
        let authorization = GitPublishAuthorization(
            repository: "aandresalvarez/astra",
            baseBranch: "main",
            headBranch: "alvaro/typed-publish",
            expectedHeadSHA: "abcdef0",
            requestDigest: String(repeating: "b", count: 64),
            isDraft: true
        )

        #expect(PermissionBroker.approvalGrants(
            for: .gitPublish(authorization: authorization)
        ).isEmpty)
    }

    @Test("GitHub host control denies native shell in Ask but preserves it in Auto")
    @MainActor
    func githubHostControlRespectsEffectivePolicyIndependentlyFromSandbox() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let package = try #require(PluginCatalog.builtInPackages.first { $0.id == "github-workflow" })
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-github-mode-routing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let workspace = Workspace(name: "GitHub Mode Routing", primaryPath: root.path)
        workspace.enabledCapabilityIDs = [package.id]
        let packageSkill = try #require(package.skills.first)
        let githubSkill = Skill(
            name: packageSkill.name,
            skillDescription: packageSkill.description,
            allowedTools: packageSkill.allowedTools,
            disallowedTools: packageSkill.disallowedTools,
            behaviorInstructions: packageSkill.behaviorInstructions
        )
        githubSkill.originPackageID = package.id
        githubSkill.workspace = workspace
        let task = AgentTask(
            title: "Publish draft PR",
            goal: "Create a branch, commit the requested changes, push it, and open a draft pull request",
            workspace: workspace,
            model: "claude-sonnet-4-6",
            runtime: .claudeCode
        )
        task.skills = [githubSkill]
        let askRun = TaskRun(task: task)
        let autoRun = TaskRun(task: task)
        context.insert(workspace)
        context.insert(githubSkill)
        context.insert(task)
        context.insert(askRun)
        context.insert(autoRun)

        let askManifest = AgentPolicyManifestService.recordPreflightManifest(
            task: task,
            run: askRun,
            runtime: .claudeCode,
            model: task.model,
            workspacePath: workspace.primaryPath,
            phase: "test",
            permissionPolicy: .restricted,
            executionPolicy: .default,
            defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
            capabilityPackages: [package],
            modelContext: context
        )
        let autoManifest = AgentPolicyManifestService.recordPreflightManifest(
            task: task,
            run: autoRun,
            runtime: .claudeCode,
            model: task.model,
            workspacePath: workspace.primaryPath,
            phase: "test",
            permissionPolicy: .autonomous,
            executionPolicy: .default,
            defaultPolicyLevelRaw: AgentPolicyLevel.autonomous.rawValue,
            capabilityPackages: [package],
            modelContext: context
        )

        let adapter = AgentRuntimeAdapterRegistry.adapter(for: .claudeCode)
        let askPlan = adapter.makeProcessLaunchPlan(context: AgentRuntimeProcessLaunchContext(
            prompt: task.goal,
            task: task,
            workspacePath: workspace.primaryPath,
            executablePath: "/bin/claude",
            providerHomeDirectory: "",
            permissionPolicy: .restricted,
            executionPolicy: .default.applyingProviderRender(askManifest.providerRender),
            permissionManifest: askManifest,
            timeoutSeconds: 30,
            runID: askRun.id
        ))
        let autoPlan = adapter.makeProcessLaunchPlan(context: AgentRuntimeProcessLaunchContext(
            prompt: task.goal,
            task: task,
            workspacePath: workspace.primaryPath,
            executablePath: "/bin/claude",
            providerHomeDirectory: "",
            permissionPolicy: .autonomous,
            executionPolicy: .default.applyingProviderRender(autoManifest.providerRender),
            permissionManifest: autoManifest,
            timeoutSeconds: 30,
            runID: autoRun.id
        ))

        #expect(askManifest.providerRender.deniedTools.contains("Bash"))
        #expect(!askManifest.providerRender.allowedTools.contains("Bash"))
        #expect(askPlan.commandPlannedFields["native_denied_tool_names"]?.split(separator: ",").contains("Bash") == true)
        #expect(askPlan.commandPlannedFields["visible_tool_names"]?.split(separator: ",").contains("Bash") == false)
        #expect(autoManifest.providerRender.allowedTools.contains("Bash"))
        #expect(!autoManifest.providerRender.deniedTools.contains("Bash"))
        #expect(autoPlan.commandPlannedFields["native_denied_tool_names"]?.split(separator: ",").contains("Bash") == false)
        #expect(autoPlan.commandPlannedFields["uses_visible_tools_filter"] == "false")
        #expect(autoPlan.arguments.contains("Bash"))
        #expect(autoPlan.arguments.contains("--dangerously-skip-permissions"))
        #expect(autoManifest.mcpServers.contains {
            $0.id == HostControlPlaneMCPProjection.serverID && $0.allowedTools == ["github"]
        })

        for enforcement in [ExecutionSandboxEnforcement.off, .bestEffort, .strict] {
            let resolution = ExecutionSandboxSettings.resolve(
                permissionPolicy: .autonomous,
                storedEnforcement: enforcement,
                storedAllowNetwork: true,
                storedLayerNativeProviders: false,
                storedReadScope: .open
            )
            #expect(resolution.effectiveSettings.enforcement == enforcement)
            #expect(!HostControlPlaneMCPProjection.requiresNativeShellDenial(
                environment: .host,
                permissionPolicy: .autonomous,
                requiredTools: ["github"]
            ))
        }
    }

    @MainActor
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [config]
        )
    }
}

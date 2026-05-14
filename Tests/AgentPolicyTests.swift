import Foundation
import SwiftData
import Testing
@testable import ASTRA
import ASTRACore

private func makeAgentPolicyContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

private func policyRenderContext(
    runtime: AgentRuntimeID,
    features: ProviderPolicyFeatures,
    requestedAllowedTools: [String] = ["Read", "Grep"],
    environmentKeyNames: [String] = [],
    credentialLabels: [String] = []
) -> PolicyRenderContext {
    PolicyRenderContext(
        runtimeID: runtime,
        model: runtime.defaultModel,
        workspacePath: "/tmp/astra-policy-tests",
        additionalPaths: [],
        requestedAllowedTools: requestedAllowedTools,
        localToolCommands: [],
        environmentKeyNames: environmentKeyNames,
        credentialLabels: credentialLabels,
        providerFeatures: features
    )
}

@Suite("Agent Policy")
struct AgentPolicyTests {
    @Test("Review is the useful conservative default")
    func reviewPreset() {
        let policy = AgentPolicy.preset(.review)

        #expect(policy.allowedTools.contains("Read"))
        #expect(policy.allowedTools.contains("Grep"))
        #expect(policy.askFirstTools.contains("Write"))
        #expect(policy.askFirstTools.contains("Bash"))
        #expect(policy.deniedShellPatterns.contains("rm:*"))
        #expect(policy.deniedShellPatterns.contains("sudo:*"))
    }

    @Test("Deny rules win over requested allowed tools")
    func denyWinsOverAllow() {
        let policy = AgentPolicy(
            level: .build,
            allowedTools: ["Read", "Bash"],
            deniedTools: ["Bash"]
        )

        let renderedTools = policy.providerAllowedTools(requestedTools: ["Bash", "Write"])

        #expect(renderedTools.contains("Read"))
        #expect(renderedTools.contains("Write"))
        #expect(!renderedTools.contains("Bash"))
    }

    @Test("Claude review render avoids broad provider permissions")
    func claudeReviewRender() {
        let adapter = ClaudePolicyAdapter()
        let render = adapter.render(
            policy: .preset(.review),
            context: policyRenderContext(runtime: .claudeCode, features: adapter.supportedFeatures)
        )

        #expect(render.providerID == .claudeCode)
        #expect(render.policyLevel == .review)
        #expect(render.permissionMode == PermissionPolicy.restricted.rawValue)
        #expect(render.allowedTools.contains("Read"))
        #expect(render.askFirstTools.contains("Bash"))
        #expect(!render.usesBroadProviderPermissions)
        #expect(render.diagnostics.contains { $0.id == "claude.shell-deny-provider-native-gap" })
    }

    @Test("Copilot autonomous render uses allow-all only when capability supports it")
    func copilotAutonomousRenderUsesAllowAllWhenSupported() {
        let capabilities = CopilotCLICapabilities(helpText: """
        --allow-all-tools
        --output-format
        --stream
        --no-ask-user
        --secret-env-vars
        """)
        let adapter = CopilotPolicyAdapter(capabilities: capabilities)
        let render = adapter.render(
            policy: .preset(.autonomous),
            context: policyRenderContext(runtime: .copilotCLI, features: adapter.supportedFeatures)
        )

        #expect(render.providerID == .copilotCLI)
        #expect(render.policyLevel == .autonomous)
        #expect(render.cliArgumentsSummary.contains("--allow-all-tools"))
        #expect(render.usesBroadProviderPermissions)
        #expect(render.diagnostics.contains { $0.id == "copilot_cli.autonomous-broad-permissions" })
    }

    @Test("Copilot review render records provider-native permission entries")
    func copilotReviewRenderRecordsProviderPermissions() {
        let capabilities = CopilotCLICapabilities(helpText: """
        --allow-tool
        --output-format
        --stream
        --no-ask-user
        """)
        let adapter = CopilotPolicyAdapter(capabilities: capabilities)
        let render = adapter.render(
            policy: .preset(.review),
            context: policyRenderContext(runtime: .copilotCLI, features: adapter.supportedFeatures)
        )

        #expect(render.allowedTools == ["read"])
        #expect(render.generatedConfigPreview.contains("--allow-tool"))
        #expect(render.enforcementTiers.contains(.astraBrokered))
    }

    @Test("Launch execution policy uses rendered provider tools")
    func launchExecutionPolicyUsesRenderedProviderTools() {
        let adapter = ClaudePolicyAdapter()
        let render = adapter.render(
            policy: .preset(.review),
            context: policyRenderContext(
                runtime: .claudeCode,
                features: adapter.supportedFeatures,
                requestedAllowedTools: ["Bash", "Write"]
            )
        )

        let launchPolicy = AgentRuntimeExecutionPolicy.default.applyingProviderRender(render)

        #expect(launchPolicy.allowedTools(default: ["Bash", "Write"]) == ["Glob", "Grep", "Read"])
        #expect(launchPolicy.permissionPolicy(default: .autonomous) == .restricted)
    }

    @Test("Unsupported credential redaction is a blocked diagnostic")
    func unsupportedCredentialRedactionBlocksRender() {
        let adapter = CopilotPolicyAdapter(capabilities: .conservative)
        let render = adapter.render(
            policy: .preset(.review),
            context: policyRenderContext(
                runtime: .copilotCLI,
                features: adapter.supportedFeatures,
                credentialLabels: ["API_TOKEN"]
            )
        )

        #expect(render.diagnostics.contains {
            $0.severity == .blocked && $0.id == "copilot_cli.secret-redaction-unsupported"
        })
    }
}

@Suite("Task Policy Store")
@MainActor
struct TaskPolicyStoreTests {
    @Test("Resolution order prefers task override over workspace and global defaults")
    func resolutionOrder() throws {
        let container = try makeAgentPolicyContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Policy Workspace", primaryPath: "/tmp/policy-workspace")
        let task = AgentTask(title: "Policy", goal: "Check policy", workspace: workspace)
        context.insert(workspace)
        context.insert(task)
        AgentPolicyDefaults.setWorkspaceLevel(.build, for: workspace)
        defer { AgentPolicyDefaults.setWorkspaceLevel(nil, for: workspace) }

        let workspaceResolution = TaskPolicyStore.resolve(
            for: task,
            globalDefaultLevel: .review,
            fallbackPermissionPolicy: .restricted,
            executionPolicy: .default
        )
        #expect(workspaceResolution.level == .build)
        #expect(workspaceResolution.scope == .workspaceDefault)

        TaskPolicyStore.recordSelection(level: .locked, task: task, modelContext: context, source: "test")
        try context.save()

        let taskResolution = TaskPolicyStore.resolve(
            for: task,
            globalDefaultLevel: .review,
            fallbackPermissionPolicy: .restricted,
            executionPolicy: .default
        )
        #expect(taskResolution.level == .locked)
        #expect(taskResolution.scope == .taskOverride)
    }

    @Test("One-run permission approval preserves policy level and scopes approved tools")
    func oneRunApprovalScopesApprovedTools() throws {
        let container = try makeAgentPolicyContainer()
        let context = container.mainContext
        let task = AgentTask(title: "Policy", goal: "Check policy")
        let run = TaskRun(task: task)
        context.insert(task)
        context.insert(run)
        TaskPolicyStore.recordSelection(level: .locked, task: task, modelContext: context, source: "test")
        try context.save()

        let manifest = AgentPolicyManifestService.recordPreflightManifest(
            task: task,
            run: run,
            runtime: .claudeCode,
            model: "claude-sonnet-4-6",
            workspacePath: "/tmp/policy-workspace",
            phase: "test",
            permissionPolicy: .restricted,
            executionPolicy: .approvedRuntimePermission(runtime: .claudeCode, allowedTools: ["Write"]),
            defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
            modelContext: context
        )

        #expect(manifest.policyLevel == .locked)
        #expect(manifest.policyScope == .oneRunEscalation)
        #expect(manifest.providerRender.permissionMode == PermissionPolicy.restricted.rawValue)
        #expect(manifest.providerRender.allowedTools.contains("Write"))
        #expect(!manifest.providerRender.usesBroadProviderPermissions)
    }

    @Test("Custom workspace policy is resolved into the preflight manifest")
    func customWorkspacePolicyResolvesIntoPreflightManifest() throws {
        let container = try makeAgentPolicyContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Custom Policy Workspace", primaryPath: "/tmp/custom-policy-workspace")
        let task = AgentTask(title: "Policy", goal: "Check custom policy", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        let customPolicy = AgentPolicy(
            level: .custom,
            allowedTools: ["Read", "Bash"],
            askFirstTools: ["Write"],
            allowedShellPatterns: ["git:*"],
            deniedShellPatterns: ["rm:*"]
        )
        AgentPolicyDefaults.setWorkspaceLevel(.custom, for: workspace)
        AgentPolicyDefaults.setCustomPolicy(customPolicy, for: workspace)
        defer {
            AgentPolicyDefaults.setWorkspaceLevel(nil, for: workspace)
            AgentPolicyDefaults.resetCustomPolicy(for: workspace)
        }

        let manifest = AgentPolicyManifestService.recordPreflightManifest(
            task: task,
            run: run,
            runtime: .claudeCode,
            model: "claude-sonnet-4-6",
            workspacePath: workspace.primaryPath,
            phase: "test",
            permissionPolicy: .restricted,
            executionPolicy: .default,
            defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
            modelContext: context
        )

        #expect(manifest.policyLevel == .custom)
        #expect(manifest.policyScope == .workspaceDefault)
        #expect(manifest.providerRender.allowedTools.contains("Bash"))
        #expect(manifest.providerRender.deniedShellPatterns.contains("rm:*"))
        #expect(manifest.providerRender.allowedShellPatterns.contains("git:*"))
    }
}

@Suite("Run Permission Manifest")
@MainActor
struct RunPermissionManifestTests {
    @Test("Preflight manifest persists policy render without environment values")
    func preflightManifestPersistsWithoutEnvValues() throws {
        let container = try makeAgentPolicyContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Manifest", primaryPath: "/tmp/manifest-workspace")
        let task = AgentTask(title: "Manifest", goal: "Persist manifest", workspace: workspace)
        let skill = Skill(
            name: "Env Skill",
            allowedTools: ["Read"],
            environmentVariables: ["PLAIN_ENV": "value-that-must-not-be-logged"]
        )
        task.skills = [skill]
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(skill)
        context.insert(task)
        context.insert(run)

        let manifest = AgentPolicyManifestService.recordPreflightManifest(
            task: task,
            run: run,
            runtime: .claudeCode,
            model: "claude-sonnet-4-6",
            workspacePath: workspace.primaryPath,
            phase: "test",
            permissionPolicy: .restricted,
            executionPolicy: .default,
            defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
            modelContext: context
        )
        try context.save()

        let events = try context.fetch(FetchDescriptor<TaskEvent>())
        let manifestEvent = events.first { $0.type == AgentPolicyManifestService.preflightEventType }

        #expect(manifest.policyLevel == .review)
        #expect(manifest.environmentKeyNames == ["PLAIN_ENV"])
        #expect(manifestEvent != nil)
        #expect(manifestEvent?.payload.contains("PLAIN_ENV") == true)
        #expect(manifestEvent?.payload.contains("value-that-must-not-be-logged") == false)
    }
}

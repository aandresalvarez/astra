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
    localToolCommands: [String] = [],
    environmentKeyNames: [String] = [],
    credentialLabels: [String] = []
) -> PolicyRenderContext {
    PolicyRenderContext(
        runtimeID: runtime,
        model: runtime.defaultModel,
        workspacePath: "/tmp/astra-policy-tests",
        additionalPaths: [],
        requestedAllowedTools: requestedAllowedTools,
        localToolCommands: localToolCommands,
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

    @Test("Denied tools are matched case-insensitively")
    func deniedToolsAreMatchedCaseInsensitively() {
        let reviewPolicy = AgentPolicy(
            level: .review,
            allowedTools: ["Read", "Bash"],
            deniedTools: ["bash"]
        )
        #expect(reviewPolicy.providerAllowedTools(requestedTools: ["Bash"]) == ["Read"])

        let customPolicy = AgentPolicy(
            level: .custom,
            allowedTools: ["Read", "Bash(curl:*)"],
            deniedTools: ["bash(curl:*)"]
        )
        #expect(customPolicy.providerAllowedTools(requestedTools: []) == ["Read"])
    }

    @Test("One-run approvals clear matching ask-first and denied tools")
    func oneRunApprovalsClearMatchingAskFirstAndDeniedTools() {
        let policy = AgentPolicy(
            level: .review,
            allowedTools: ["Read"],
            askFirstTools: ["bash"],
            deniedTools: ["write"]
        )

        let approved = policy.applyingOneRunAllowedTools(["Bash", "Write"])

        #expect(approved.allowedTools.contains("Bash"))
        #expect(approved.allowedTools.contains("Write"))
        #expect(!approved.askFirstTools.contains("bash"))
        #expect(!approved.deniedTools.contains("write"))
    }

    @Test("Custom policy does not inherit skill requested tools")
    func customPolicyDoesNotInheritSkillRequestedTools() {
        let policy = AgentPolicy(
            level: .custom,
            allowedTools: ["Read"],
            askFirstTools: ["Bash"],
            deniedTools: []
        )

        let renderedTools = policy.providerAllowedTools(requestedTools: ["Bash", "Write", "WebFetch"])

        #expect(renderedTools == ["Read"])

        let adapter = ClaudePolicyAdapter()
        let render = adapter.render(
            policy: policy,
            context: policyRenderContext(
                runtime: .claudeCode,
                features: adapter.supportedFeatures,
                requestedAllowedTools: ["Bash", "Write", "WebFetch"],
                localToolCommands: ["gh pr view"]
            )
        )

        #expect(render.allowedTools == ["Read"])
        #expect(!render.allowedTools.contains("Bash"))
        #expect(!render.allowedTools.contains("Write"))
        #expect(!render.allowedTools.contains("WebFetch"))
        #expect(!render.allowedTools.contains("Bash(gh:*)"))
        #expect(render.askFirstTools.contains("Bash"))
    }

    @Test("Custom policy grants local CLI tools only with explicit Bash")
    func customPolicyGrantsLocalCLIToolsOnlyWithExplicitBash() {
        let policy = AgentPolicy(
            level: .custom,
            allowedTools: ["Read", "Bash"],
            askFirstTools: ["Write"],
            deniedTools: []
        )

        let claude = ClaudePolicyAdapter()
        let claudeRender = claude.render(
            policy: policy,
            context: policyRenderContext(
                runtime: .claudeCode,
                features: claude.supportedFeatures,
                requestedAllowedTools: ["WebFetch"],
                localToolCommands: ["gh pr view"]
            )
        )

        #expect(claudeRender.allowedTools.contains("Bash"))
        #expect(claudeRender.allowedTools.contains("Bash(gh:*)"))
        #expect(!claudeRender.allowedTools.contains("WebFetch"))

        let copilot = CopilotPolicyAdapter(capabilities: CopilotCLICapabilities(helpText: """
        --allow-tool
        --output-format
        """))
        let copilotRender = copilot.render(
            policy: policy,
            context: policyRenderContext(
                runtime: .copilotCLI,
                features: copilot.supportedFeatures,
                requestedAllowedTools: ["WebFetch"],
                localToolCommands: ["gh pr view"]
            )
        )

        #expect(copilotRender.allowedTools.contains("shell(gh:*)"))
        #expect(!copilotRender.allowedTools.contains("fetch"))
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

    @Test("Review render does not allow local CLI tools without approval")
    func reviewRenderDoesNotAllowLocalCLIToolsWithoutApproval() {
        let claude = ClaudePolicyAdapter()
        let claudeRender = claude.render(
            policy: .preset(.review),
            context: policyRenderContext(
                runtime: .claudeCode,
                features: claude.supportedFeatures,
                localToolCommands: ["gh"]
            )
        )
        #expect(!claudeRender.allowedTools.contains("Bash(gh:*)"))

        let copilot = CopilotPolicyAdapter(capabilities: CopilotCLICapabilities(helpText: """
        --allow-tool
        --output-format
        """))
        let copilotRender = copilot.render(
            policy: .preset(.review),
            context: policyRenderContext(
                runtime: .copilotCLI,
                features: copilot.supportedFeatures,
                localToolCommands: ["gh"]
            )
        )
        #expect(!copilotRender.allowedTools.contains("shell(gh:*)"))
        #expect(!copilotRender.generatedConfigPreview.contains("shell(gh:*)"))
    }

    @Test("Build render grants enabled local CLI tools")
    func buildRenderGrantsEnabledLocalCLITools() {
        let claude = ClaudePolicyAdapter()
        let claudeRender = claude.render(
            policy: .preset(.build),
            context: policyRenderContext(
                runtime: .claudeCode,
                features: claude.supportedFeatures,
                localToolCommands: ["astra-browser page"]
            )
        )
        #expect(claudeRender.allowedTools.contains("Bash(astra-browser:*)"))

        let copilot = CopilotPolicyAdapter(capabilities: CopilotCLICapabilities(helpText: """
        --allow-tool
        --output-format
        """))
        let copilotRender = copilot.render(
            policy: .preset(.build),
            context: policyRenderContext(
                runtime: .copilotCLI,
                features: copilot.supportedFeatures,
                localToolCommands: ["gh"]
            )
        )
        #expect(copilotRender.allowedTools.contains("shell(gh:*)"))
        #expect(copilotRender.generatedConfigPreview.contains("shell(gh:*)"))
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

    @Test("Preflight manifest includes active browser bridge as local tool grant")
    func preflightManifestIncludesActiveBrowserBridgeLocalToolGrant() throws {
        let container = try makeAgentPolicyContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Browser Policy", primaryPath: "/tmp/browser-policy-workspace")
        let task = AgentTask(title: "Browser", goal: "Use the browser", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        TaskPolicyStore.recordSelection(level: .build, task: task, modelContext: context, source: "test")
        try context.save()

        ShelfBrowserBridgeRegistry.shared.update(
            endpoint: "http://127.0.0.1:49152",
            currentURL: "https://example.com",
            currentTitle: "Example",
            taskID: task.id,
            isPresented: true,
            isEnabled: true
        )
        defer { ShelfBrowserBridgeRegistry.shared.reset() }

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

        #expect(manifest.policyLevel == .build)
        #expect(manifest.providerRender.allowedTools.contains("Bash(astra-browser:*)"))
    }
}

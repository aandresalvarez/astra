import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA
import ASTRACore

private func makeAgentPolicyGitHubRoutingContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

@Suite("Agent policy GitHub routing")
struct AgentPolicyGitHubRoutingTests {
    @MainActor
    @Test("Preflight manifest routes GitHub metadata through host control without Git credential projection")
    func preflightManifestRoutesGitHubMetadataThroughHostControlWithoutGitCredentialProjection() throws {
        let container = try makeAgentPolicyGitHubRoutingContainer()
        let context = container.mainContext
        let package = try #require(PluginCatalog.builtInPackages.first {
            $0.id == HostControlPlaneMCPProjection.githubPackageID
        })
        let workspace = Workspace(name: "GitHub Metadata Policy", primaryPath: "/tmp/astra-github-metadata-policy")
        workspace.enabledCapabilityIDs = [package.id]
        let task = AgentTask(
            title: "Review PR metadata",
            goal: "Use GitHub to inspect pull request metadata and checks",
            workspace: workspace,
            runtime: .claudeCode
        )
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        let manifest = AgentPolicyManifestService.recordPreflightManifest(
            task: task,
            run: run,
            runtime: .claudeCode,
            model: "claude-sonnet-4-6",
            workspacePath: workspace.primaryPath,
            phase: "resume",
            permissionPolicy: .restricted,
            executionPolicy: .default,
            defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
            capabilityPackages: [package],
            contextText: "Use GitHub to list open pull requests and check statuses.",
            modelContext: context
        )

        #expect(manifest.mcpServers.contains { server in
            server.packageID == "astra-builtin"
                && server.id == HostControlPlaneMCPProjection.serverID
                && server.allowedTools == ["github"]
        })
        #expect(manifest.providerRender.runtimeSupportTools.contains { descriptor in
            descriptor.name == HostControlPlaneMCPProjection.providerToolPermission(for: "github")
        })
        #expect(!manifest.credentialLabels.contains("git:credential-context:read-only"))
        #expect(!manifest.providerRender.diagnostics.contains { $0.id == "git.credential-projection" })
    }

    @MainActor
    @Test("Native Git transport still declares Git credential projection with GitHub capability enabled")
    func nativeGitTransportStillDeclaresGitCredentialProjectionWithGitHubCapabilityEnabled() throws {
        let container = try makeAgentPolicyGitHubRoutingContainer()
        let context = container.mainContext
        let package = try #require(PluginCatalog.builtInPackages.first {
            $0.id == HostControlPlaneMCPProjection.githubPackageID
        })
        let workspace = Workspace(name: "Native Git Policy", primaryPath: "/tmp/astra-native-git-policy")
        workspace.enabledCapabilityIDs = [package.id]
        let task = AgentTask(
            title: "Sync branch",
            goal: "Pull latest code before editing",
            workspace: workspace,
            runtime: .claudeCode
        )
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        for command in ["git pull origin main", "git fetch origin main", "git push origin HEAD", "git clone git@github.com:susom/astra.git"] {
            let manifest = AgentPolicyManifestService.recordPreflightManifest(
                task: task,
                run: run,
                runtime: .claudeCode,
                model: "claude-sonnet-4-6",
                workspacePath: workspace.primaryPath,
                phase: "resume",
                permissionPolicy: .restricted,
                executionPolicy: .default,
                defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
                capabilityPackages: [package],
                contextText: command,
                modelContext: context
            )

            #expect(manifest.credentialLabels.contains("git:credential-context:read-only"), "Expected Git credential projection for \(command)")
            #expect(manifest.providerRender.diagnostics.contains { $0.id == "git.credential-projection" }, "Expected Git diagnostic for \(command)")
        }
    }

    @MainActor
    @Test("Native gh auth still declares credential projection with GitHub capability enabled")
    func nativeGhAuthStillDeclaresCredentialProjectionWithGitHubCapabilityEnabled() throws {
        let container = try makeAgentPolicyGitHubRoutingContainer()
        let context = container.mainContext
        let package = try #require(PluginCatalog.builtInPackages.first {
            $0.id == HostControlPlaneMCPProjection.githubPackageID
        })
        let workspace = Workspace(name: "Native gh Auth Policy", primaryPath: "/tmp/astra-native-gh-auth-policy")
        workspace.enabledCapabilityIDs = [package.id]
        let task = AgentTask(
            title: "Check auth",
            goal: "Check GitHub CLI authentication state",
            workspace: workspace,
            runtime: .claudeCode
        )
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        let manifest = AgentPolicyManifestService.recordPreflightManifest(
            task: task,
            run: run,
            runtime: .claudeCode,
            model: "claude-sonnet-4-6",
            workspacePath: workspace.primaryPath,
            phase: "resume",
            permissionPolicy: .restricted,
            executionPolicy: .default,
            defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
            capabilityPackages: [package],
            contextText: "gh auth status",
            modelContext: context
        )

        #expect(manifest.credentialLabels.contains("git:credential-context:read-only"))
        #expect(manifest.providerRender.diagnostics.contains { $0.id == "git.credential-projection" })
    }

    @MainActor
    @Test("Cursor preflight names host-control incompatibility for GitHub metadata")
    func cursorPreflightNamesHostControlIncompatibilityForGitHubMetadata() throws {
        let container = try makeAgentPolicyGitHubRoutingContainer()
        let context = container.mainContext
        let package = try #require(PluginCatalog.builtInPackages.first {
            $0.id == HostControlPlaneMCPProjection.githubPackageID
        })
        let workspace = Workspace(name: "Cursor GitHub Metadata", primaryPath: "/tmp/astra-cursor-github-metadata")
        workspace.enabledCapabilityIDs = [package.id]
        let task = AgentTask(
            title: "ASTRA task 9FA6AF3D PR metadata",
            goal: "Use GitHub to find the pull request and issue metadata for ASTRA task 9FA6AF3D-F4D3-4035-BFC2-826487DA32ED",
            workspace: workspace,
            runtime: .cursorCLI
        )
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        let manifest = AgentPolicyManifestService.recordPreflightManifest(
            task: task,
            run: run,
            runtime: .cursorCLI,
            model: "composer-2.5-fast",
            workspacePath: workspace.primaryPath,
            phase: "resume",
            permissionPolicy: .restricted,
            executionPolicy: .default,
            defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
            capabilityPackages: [package],
            contextText: "Use GitHub to inspect PR metadata, issue links, and checks for this ASTRA task.",
            modelContext: context
        )

        let diagnostic = try #require(manifest.providerRender.diagnostics.first {
            $0.id == "cursor_cli.host-control-plane-unsupported"
        })
        #expect(diagnostic.severity == .blocked)
        #expect(diagnostic.message.contains("GitHub metadata/API"))
        #expect(diagnostic.remediation?.contains("Codex CLI") == true)
        #expect(diagnostic.remediation?.contains("Copilot CLI") == true)
        #expect(!diagnostic.message.lowercased().contains("secret"))
        #expect(!manifest.credentialLabels.contains("git:credential-context:read-only"))
    }
}

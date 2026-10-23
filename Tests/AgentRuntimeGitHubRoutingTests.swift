import Foundation
import Testing
import ASTRAModels
import ASTRACore
@testable import ASTRA

@Suite("Agent runtime GitHub routing")
struct AgentRuntimeGitHubRoutingTests {
    @Test("No repository preflight prevents broad GitHub access claims")
    func noRepositoryPreflightGuidanceIsExplicitlyUnverified() {
        let prompt = GitHubCapabilityLaunchContext.appendingProviderGuidance(
            to: "Base prompt",
            repositoryStatus: .unverified(
                path: "/opt/homebrew/bin/gh",
                detail: "Authenticated as aandresalvarez; no repository target was resolved from this workspace."
            )
        )

        #expect(prompt.contains("authoritative host evidence"))
        #expect(prompt.contains("Repository and organization access are unverified"))
        #expect(prompt.contains("do not prove repository membership"))
        #expect(prompt.contains("Never claim broad, full"))
        #expect(prompt.contains("Authentication never grants mutation authority"))
    }

    @Test("Verified repository guidance scopes the exact proof")
    func verifiedRepositoryGuidanceScopesTheProof() {
        let prompt = GitHubCapabilityLaunchContext.appendingProviderGuidance(
            to: "Base prompt",
            repositoryStatus: .healthy(
                path: "/opt/homebrew/bin/gh",
                version: "aandresalvarez · susom/starr-data-lake"
            )
        )

        #expect(prompt.contains("repository-specific read probe succeeded"))
        #expect(prompt.contains("susom/starr-data-lake"))
        #expect(prompt.contains("Never claim broad, full"))
    }

    @Test("Cursor GitHub metadata uses the process-bound CLI relay")
    @MainActor
    func cursorGitHubMetadataUsesProcessBoundCLIRelay() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-cursor-github-host-control-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let workspace = Workspace(name: "GitHub Host Control", primaryPath: root.path)
        workspace.enabledCapabilityIDs = [HostControlPlaneMCPProjection.githubPackageID]
        let task = AgentTask(
            title: "ASTRA task 9FA6AF3D PR metadata",
            goal: "Use GitHub to find the pull request and issue metadata for ASTRA task 9FA6AF3D-F4D3-4035-BFC2-826487DA32ED",
            workspace: workspace,
            model: "composer-2.5-fast",
            runtime: .cursorCLI
        )
        let githubSkill = Skill(
            name: "GitHub Agent",
            allowedTools: ["Read"],
            behaviorInstructions: "Use ASTRA host-control GitHub MCP tool mcp__astra_host__github for GitHub operations."
        )
        githubSkill.originPackageID = HostControlPlaneMCPProjection.githubPackageID
        githubSkill.workspace = workspace
        task.skills = [githubSkill]

        let plan = AgentRuntimeAdapterRegistry
            .adapter(for: .cursorCLI)
            .makeProcessLaunchPlan(context: AgentRuntimeProcessLaunchContext(
                prompt: "Review PR metadata",
                task: task,
                workspacePath: workspace.primaryPath,
                executablePath: "/bin/echo",
                providerHomeDirectory: root.appendingPathComponent("cursor-home").path,
                permissionPolicy: .restricted,
                executionPolicy: .default,
                permissionManifest: nil,
                timeoutSeconds: 30,
                phase: "run",
                contextText: "Use GitHub to inspect PR metadata, issue links, and checks for this ASTRA task."
            ))

        #expect(plan.commandPlannedFields["host_control_plane_supported"] == "true")
        #expect(plan.commandPlannedFields["host_control_plane_launch_block_reason"] == "none")
        #expect(HostControlPlaneRuntimeLaunchGuard.launchBlock(for: plan) == nil)
        #expect(
            AgentRuntimeCapabilityProfile.defaultProfile(for: .cursorCLI)
                .usesHostControlCLIRelay
        )
    }
}

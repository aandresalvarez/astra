import Foundation
import Testing
import ASTRAModels
@testable import ASTRA

@Suite("Agent runtime GitHub routing")
struct AgentRuntimeGitHubRoutingTests {
    @Test("Cursor GitHub metadata launch block guides users to host-control capable runtimes")
    @MainActor
    func cursorGitHubMetadataLaunchBlockGuidesUsersToHostControlCapableRuntimes() throws {
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

        let block = try #require(HostControlPlaneRuntimeLaunchGuard.launchBlock(for: plan))
        let message = try #require(block.runtimeStopMessage)
        #expect(message.contains("GitHub metadata/API"))
        #expect(message.contains("Codex CLI"))
        #expect(message.contains("Copilot CLI"))
        #expect(!message.lowercased().contains("secret"))
        #expect(!message.lowercased().contains("redaction"))
    }
}

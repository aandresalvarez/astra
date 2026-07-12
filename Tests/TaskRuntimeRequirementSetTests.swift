import Foundation
import Testing
import ASTRAModels
@testable import ASTRA
import ASTRACore

@Suite("Task Runtime Requirement Set")
@MainActor
struct TaskRuntimeRequirementSetTests {
    @Test("Requirement set normalizes host-control tools at construction")
    func requirementSetNormalizesHostControlToolsAtConstruction() {
        let requirements = TaskRuntimeRequirementSet(
            hostControlTools: [" github ", "jira", "github", "", "JIRA"],
            requiresDockerWorkspaceShell: false,
            requiresBrowserControl: false
        )

        #expect(requirements.hostControlTools == ["github", "jira"])
        #expect(requirements.missingCapabilityNames == ["host-control MCP server for github, jira"])
    }

    @Test("GitHub host-control skill creates host-control requirement")
    func githubHostControlSkillCreatesRequirement() {
        let workspace = Workspace(name: "Repo", primaryPath: NSTemporaryDirectory())
        workspace.enabledCapabilityIDs = [HostControlPlaneMCPProjection.githubPackageID]

        let skill = Skill(
            name: "GitHub Workflow",
            allowedTools: ["Read"],
            behaviorInstructions: "Use ASTRA host-control GitHub MCP tool mcp__astra_host__github."
        )
        skill.originPackageID = HostControlPlaneMCPProjection.githubPackageID
        skill.workspace = workspace

        let task = AgentTask(title: "Review PR", goal: "Use GitHub", workspace: workspace, runtime: .cursorCLI)
        task.skills = [skill]

        let snapshot = TaskCapabilityResolutionSnapshot.capture(
            for: task,
            providerLaunchContextText: "Use GitHub"
        )
        let requirements = TaskRuntimeRequirementSet.derive(
            task: task,
            capabilityResolutionSnapshot: snapshot,
            executionEnvironment: .host,
            browserBridgeAttached: false
        )

        #expect(requirements.hostControlTools == ["github"])
        #expect(requirements.requiresHostControlPlane)
        #expect(!requirements.requiresDockerWorkspaceShell)
        #expect(requirements.missingCapabilityNames.contains("host-control MCP server for github"))
    }

    @Test("Containerized workspace creates Docker workspace shell requirement")
    func containerWorkspaceCreatesDockerWorkspaceRequirement() {
        let task = AgentTask(
            title: "Build",
            goal: "Run tests",
            workspace: Workspace(name: "Repo", primaryPath: NSTemporaryDirectory())
        )
        let environment = WorkspaceExecutionEnvironment(
            id: "image:test",
            kind: .dockerImage,
            displayName: "Image",
            image: "swift:latest",
            providerPlacement: .host
        )
        let snapshot = TaskCapabilityResolutionSnapshot.capture(for: task, providerLaunchContextText: "Run tests")

        let requirements = TaskRuntimeRequirementSet.derive(
            task: task,
            capabilityResolutionSnapshot: snapshot,
            executionEnvironment: environment,
            browserBridgeAttached: false
        )

        #expect(requirements.requiresDockerWorkspaceShell)
        #expect(requirements.missingCapabilityNames.contains("Docker workspace shell MCP"))
    }

    @Test("Docker mode grants all host-control tools, matching launch-time enabledToolNames")
    func dockerModeGrantsAllHostControlToolsMatchingLaunchTimeProjection() {
        let task = AgentTask(
            title: "Build",
            goal: "Run tests",
            workspace: Workspace(name: "Repo", primaryPath: NSTemporaryDirectory())
        )
        let environment = WorkspaceExecutionEnvironment(
            id: "image:test",
            kind: .dockerImage,
            displayName: "Image",
            image: "swift:latest",
            providerPlacement: .host
        )
        let snapshot = TaskCapabilityResolutionSnapshot.capture(for: task, providerLaunchContextText: "Run tests")

        let requirements = TaskRuntimeRequirementSet.derive(
            task: task,
            capabilityResolutionSnapshot: snapshot,
            executionEnvironment: environment,
            browserBridgeAttached: false
        )

        // Before this fix, derive() called requiredToolNames(capabilityScope:)
        // directly and never accounted for Docker mode's all-tools grant, so a
        // task with no host-control-declaring capability scope produced an
        // EMPTY hostControlTools here while HostControlPlaneMCPProjection's
        // launch-time resolvedServer/enabledToolNames still attached the
        // server with all 5 tools — render and launch silently disagreeing in
        // Docker mode specifically.
        #expect(requirements.hostControlTools == HostControlPlaneMCPProjection.toolNames)
        #expect(requirements.hostControlTools == HostControlPlaneMCPProjection.enabledToolNames(
            task: task,
            environment: environment,
            contextText: "Run tests"
        ))
    }

    @Test("Browser attachment creates browser-control requirement")
    func browserAttachmentCreatesBrowserRequirement() {
        let task = AgentTask(
            title: "Inspect browser",
            goal: "Use browser",
            workspace: Workspace(name: "Repo", primaryPath: NSTemporaryDirectory())
        )
        let snapshot = TaskCapabilityResolutionSnapshot.capture(for: task, providerLaunchContextText: "Use browser")

        let requirements = TaskRuntimeRequirementSet.derive(
            task: task,
            capabilityResolutionSnapshot: snapshot,
            executionEnvironment: .host,
            browserBridgeAttached: true
        )

        #expect(requirements.requiresBrowserControl)
        #expect(requirements.missingCapabilityNames.contains("browser control transport"))
    }
}

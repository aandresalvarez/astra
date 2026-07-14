import Foundation
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

@Suite("Ask Git credential brokerage")
struct AskGitCredentialBrokerageTests {
    @Test("Ask publication does not project native Git credentials")
    func askPublicationDoesNotProjectNativeGitCredentials() {
        let workspace = Workspace(name: "Ask publish", primaryPath: "/tmp/ask-publish")
        let task = AgentTask(
            title: "Create a draft pull request",
            goal: "Commit the changes, push the branch, and create a draft pull request",
            workspace: workspace
        )

        let plan = TaskLaunchResourceResolver.resolve(
            task: task,
            runID: UUID(),
            runtime: .codexCLI,
            phase: .run,
            prompt: task.goal,
            contextText: task.goal,
            workspacePath: workspace.primaryPath,
            permissionPolicy: .restricted,
            gitCredentialContextProvider: { _, _, _, _ in
                externalHTTPSCredentialContext
            },
            precomputedRuntimeRequirements: emptyRequirements
        )

        #expect(plan.gitCredential == nil)
        #expect(plan.providerNativeCredentialReadablePaths.isEmpty)
        #expect(plan.credentialGrants.allSatisfy { $0.source != .gitCredential })
        #expect(plan.hostPathGrants.allSatisfy { $0.source != .gitCredential })
    }

    @Test("Auto publication retains native Git credentials")
    func autoPublicationRetainsNativeGitCredentials() {
        let workspace = Workspace(name: "Auto publish", primaryPath: "/tmp/auto-publish")
        let task = AgentTask(
            title: "Create a draft pull request",
            goal: "Commit the changes, push the branch, and create a draft pull request",
            workspace: workspace
        )

        let plan = TaskLaunchResourceResolver.resolve(
            task: task,
            runID: UUID(),
            runtime: .codexCLI,
            phase: .run,
            prompt: task.goal,
            contextText: task.goal,
            workspacePath: workspace.primaryPath,
            permissionPolicy: .autonomous,
            gitCredentialContextProvider: { _, _, _, _ in
                externalHTTPSCredentialContext
            },
            precomputedRuntimeRequirements: emptyRequirements
        )

        #expect(plan.gitCredential?.transports == ["https"])
        #expect(!plan.providerNativeCredentialReadablePaths.isEmpty)
        #expect(plan.credentialGrants.contains { $0.source == .gitCredential })
        #expect(plan.hostPathGrants.contains { $0.source == .gitCredential })
    }

    @Test("Ask Docker publication keeps native Git credentials out of the host provider")
    func askDockerPublicationDoesNotProjectNativeGitCredentials() {
        let workspace = Workspace(name: "Ask Docker publish", primaryPath: "/tmp/ask-docker-publish")
        let task = AgentTask(
            title: "Create a draft pull request",
            goal: "Commit the changes, push the branch, and create a draft pull request",
            workspace: workspace
        )
        let environment = WorkspaceExecutionEnvironment(
            id: "image:ask-publish",
            kind: .dockerImage,
            displayName: "Ask Publish Image",
            image: "astra/ask-publish:latest"
        )
        #expect(environment.workspaceCommandsRunInsideContainer)
        #expect(environment.effectiveProviderPlacement == .host)

        let plan = TaskLaunchResourceResolver.resolve(
            task: task,
            runID: UUID(),
            runtime: .codexCLI,
            phase: .run,
            prompt: task.goal,
            contextText: task.goal,
            workspacePath: workspace.primaryPath,
            executionEnvironment: environment,
            permissionPolicy: .restricted,
            gitCredentialContextProvider: { _, _, _, _ in
                externalHTTPSCredentialContext
            },
            precomputedRuntimeRequirements: emptyRequirements
        )

        #expect(plan.gitCredential == nil)
        #expect(plan.providerNativeCredentialReadablePaths.isEmpty)
        #expect(plan.credentialGrants.allSatisfy { $0.source != .gitCredential })
        #expect(plan.hostPathGrants.allSatisfy { $0.source != .gitCredential })
    }

    @Test("Auto Docker publication retains native Git credentials")
    func autoDockerPublicationRetainsNativeGitCredentials() {
        let workspace = Workspace(name: "Auto Docker publish", primaryPath: "/tmp/auto-docker-publish")
        let task = AgentTask(
            title: "Create a draft pull request",
            goal: "Commit the changes, push the branch, and create a draft pull request",
            workspace: workspace
        )
        let environment = WorkspaceExecutionEnvironment(
            id: "image:auto-publish",
            kind: .dockerImage,
            displayName: "Auto Publish Image",
            image: "astra/auto-publish:latest"
        )
        #expect(environment.workspaceCommandsRunInsideContainer)
        #expect(environment.effectiveProviderPlacement == .host)

        let plan = TaskLaunchResourceResolver.resolve(
            task: task,
            runID: UUID(),
            runtime: .codexCLI,
            phase: .run,
            prompt: task.goal,
            contextText: task.goal,
            workspacePath: workspace.primaryPath,
            executionEnvironment: environment,
            permissionPolicy: .autonomous,
            gitCredentialContextProvider: { _, _, _, _ in
                externalHTTPSCredentialContext
            },
            precomputedRuntimeRequirements: emptyRequirements
        )

        #expect(plan.gitCredential?.transports == ["https"])
        #expect(!plan.providerNativeCredentialReadablePaths.isEmpty)
        #expect(plan.credentialGrants.contains { $0.source == .gitCredential })
        #expect(plan.hostPathGrants.contains { $0.source == .gitCredential })
    }

    @Test("Ask Docker non-publication Git keeps its approved credential path")
    func askDockerPullRetainsNativeGitCredentials() {
        let workspace = Workspace(name: "Ask Docker pull", primaryPath: "/tmp/ask-docker-pull")
        let task = AgentTask(
            title: "Update the checkout",
            goal: "Pull the latest changes from origin",
            workspace: workspace
        )
        let environment = WorkspaceExecutionEnvironment(
            id: "image:ask-pull",
            kind: .dockerImage,
            displayName: "Ask Pull Image",
            image: "astra/ask-pull:latest"
        )

        let plan = TaskLaunchResourceResolver.resolve(
            task: task,
            runID: UUID(),
            runtime: .codexCLI,
            phase: .run,
            prompt: "git pull origin main",
            contextText: task.goal,
            workspacePath: workspace.primaryPath,
            executionEnvironment: environment,
            permissionPolicy: .restricted,
            gitCredentialContextProvider: { _, _, _, _ in
                externalHTTPSCredentialContext
            },
            precomputedRuntimeRequirements: emptyRequirements
        )

        #expect(plan.gitCredential?.transports == ["https"])
        #expect(plan.credentialGrants.contains { $0.source == .gitCredential })
        #expect(plan.hostPathGrants.contains { $0.source == .gitCredential })
    }

    @Test("Ask local Git inspection keeps non-network Git context")
    func askLocalGitInspectionKeepsNonNetworkGitContext() {
        let workspace = Workspace(name: "Ask inspect", primaryPath: "/tmp/ask-inspect")
        let task = AgentTask(
            title: "Inspect local changes",
            goal: "Run git status and report the local diff",
            workspace: workspace
        )
        let localContext = GitCredentialSandboxContext(
            readablePaths: ["/tmp/ask-inspect-config"],
            writablePaths: ["/tmp/ask-inspect-git-metadata"],
            transports: [],
            diagnostics: ["local_git_config"]
        )

        let plan = TaskLaunchResourceResolver.resolve(
            task: task,
            runID: UUID(),
            runtime: .codexCLI,
            phase: .run,
            prompt: task.goal,
            contextText: task.goal,
            workspacePath: workspace.primaryPath,
            permissionPolicy: .restricted,
            gitCredentialContextProvider: { _, _, _, _ in localContext },
            precomputedRuntimeRequirements: emptyRequirements
        )

        #expect(plan.gitCredential?.diagnostics == ["local_git_config"])
        #expect(plan.gitCredential?.transports.isEmpty == true)
        #expect(plan.credentialGrants.allSatisfy { $0.source != .gitCredential })
    }

    @Test("Ask publication guidance scopes local Git inspection and keeps Auto unchanged")
    func askPublicationGuidanceScopesLocalGitInspection() {
        let workspace = Workspace(name: "Ask publish", primaryPath: "/tmp/ask-publish")
        let task = AgentTask(
            title: "Create a draft pull request",
            goal: "Publish the existing changes",
            workspace: workspace
        )
        let prompt = "Work on the task."

        let askPrompt = AskGitPullRequestWorkflowPolicy.appendingProviderGuidance(
            to: prompt,
            task: task,
            permissionPolicy: .restricted,
            contextText: task.goal
        )
        let autoPrompt = AskGitPullRequestWorkflowPolicy.appendingProviderGuidance(
            to: prompt,
            task: task,
            permissionPolicy: .autonomous,
            contextText: task.goal
        )

        #expect(askPrompt.contains("ASTRA Ask-mode pull request workflow"))
        #expect(askPrompt.contains("git status"))
        #expect(askPrompt.contains("Do not run `git push`"))
        #expect(askPrompt.contains("ASTRA will deterministically construct"))
        #expect(autoPrompt == prompt)
        #expect(AskGitPullRequestWorkflowPolicy.allowedLocalInspectionShellPatterns.contains("git rev-parse *"))
        #expect(!AskGitPullRequestWorkflowPolicy.allowedLocalInspectionShellPatterns.contains("git push *"))
    }

    private var externalHTTPSCredentialContext: GitCredentialSandboxContext {
        GitCredentialSandboxContext(
            readablePaths: ["/tmp/ask-git-config", "/tmp/ask-git-credentials"],
            writablePaths: ["/tmp/ask-git-metadata"],
            transports: [.https],
            diagnostics: []
        )
    }

    private var emptyRequirements: TaskRuntimeRequirementSet {
        TaskRuntimeRequirementSet(
            hostControlTools: [],
            requiresDockerWorkspaceShell: false,
            requiresBrowserControl: false
        )
    }
}

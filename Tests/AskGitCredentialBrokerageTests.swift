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

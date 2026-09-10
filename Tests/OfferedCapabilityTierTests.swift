import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// Offered is permissive, never obligatory. Widening what a run *may* reach
/// must not widen what it *requires*, because the required tier is the only one
/// with teeth: it reroutes runs, aborts launches, and withdraws native shell.
/// Every surface in here once derived "required" from the offered set, which
/// turned one enabled connector into a workspace-wide launch failure.
@Suite("Offered capability tier")
@MainActor
struct OfferedCapabilityTierTests {
    @Test("An offered-only host tool never blocks a Copilot launch")
    func offeredOnlyHostToolNeverBlocksCopilotLaunch() throws {
        let fixture = try Fixture()
        // Copilot without --additional-mcp-config: this build cannot carry the
        // host-control MCP server at all.
        let capabilities = CopilotCLICapabilities(helpText: "--output-format=FORMAT --no-ask-user")

        func projection(contextText: String) -> CopilotMCPLaunchProjection {
            CopilotMCPLaunchProjection.resolve(
                task: fixture.task,
                workspacePath: fixture.workspace.primaryPath,
                runID: UUID(),
                executionEnvironment: .host,
                contextText: contextText,
                capabilities: capabilities
            )
        }

        // The turn never mentions Jira. The connector is enabled, so it is
        // offered - and an offered route this build cannot carry is dropped,
        // not turned into a launch block.
        let offeredOnly = projection(contextText: fixture.unrelatedTurn)
        #expect(offeredOnly.hostControlPlaneSupported)
        #expect(offeredOnly.hostControlPlaneLaunchBlockReason == "none")
        #expect(offeredOnly.hostControlPlaneUnsupportedDetail.isEmpty)
        // The env named a broker socket no MCP server was written for; leaving
        // it in place tells the policy manifest a dead route is live.
        #expect(offeredOnly.hostControlEnvironment.isEmpty)

        // The turn that actually asks for Jira still blocks, because now the
        // run cannot deliver what it was asked to do.
        let required = projection(contextText: fixture.jiraTurn)
        #expect(!required.hostControlPlaneSupported)
        #expect(required.hostControlPlaneLaunchBlockReason
            == HostControlPlaneRuntimeLaunchGuard.missingHostControlMCPReason)
        #expect(required.hostControlPlaneUnsupportedDetail.contains("jira"))
    }

    @Test("An offered-only connector is not a required provider requirement")
    func offeredOnlyConnectorIsNotARequiredProviderRequirement() throws {
        let fixture = try Fixture()

        func connectorRequirement(contextText: String) throws -> RuntimeProviderRequirement {
            let plan = TaskLaunchResourceResolver.resolve(
                task: fixture.task,
                runID: UUID(),
                runtime: .claudeCode,
                phase: .run,
                prompt: contextText,
                contextText: contextText,
                workspacePath: fixture.workspace.primaryPath,
                executionEnvironment: .host,
                connectorSecretStore: fixture.store
            )
            return try #require(plan.providerRequirements.first { $0.capability == "connector:jira" })
        }

        // Wired either way - reachability is what makes the route usable at
        // all - but only the turn that names it may be a hard requirement.
        #expect(try connectorRequirement(contextText: fixture.jiraTurn).required)
        #expect(try !connectorRequirement(contextText: fixture.unrelatedTurn).required)
    }

    @Test("An offered-only browser bridge does not require browser control")
    func offeredOnlyBrowserBridgeDoesNotRequireBrowserControl() throws {
        let fixture = try Fixture()
        let browserTool = LocalTool(
            name: "ASTRA Browser",
            toolDescription: "Drive a browser session",
            command: "astra-browser"
        )
        browserTool.workspace = fixture.workspace
        fixture.context.insert(browserTool)
        try fixture.context.save()

        let snapshot = TaskCapabilityResolutionSnapshot.capture(
            for: fixture.task,
            providerLaunchContextText: fixture.unrelatedTurn,
            secretStore: fixture.store
        )
        let scope = snapshot.providerLaunch
        // Enabled, so the transport is attached where it can be.
        #expect(scope.exposesBrowserBridge)
        // But this turn is about a cake. Requiring browser control here would
        // reroute every turn in the workspace onto a browser-capable runtime.
        #expect(!scope.requiresBrowserBridge)
        #expect(!TaskRuntimeRequirementSet.derive(
            task: fixture.task,
            capabilityResolutionSnapshot: snapshot,
            executionEnvironment: .host,
            browserBridgeRequired: scope.requiresBrowserBridge
        ).requiresBrowserControl)
    }

    /// One enabled Jira connector, one turn that names it and one that does not.
    @MainActor
    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let store: MockSecretStore
        let workspace: Workspace
        let task: AgentTask
        let jiraTurn = "check the open Jira issues for this sprint"
        let unrelatedTurn = "Bake a chocolate sponge cake and write the recipe"

        init() throws {
            container = try ModelContainer(
                for: ASTRASchema.current,
                migrationPlan: ASTRAMigrationPlan.self,
                configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
            )
            context = container.mainContext
            store = MockSecretStore()
            workspace = Workspace(name: "offered-tier", primaryPath: NSTemporaryDirectory())
            let skill = Skill(
                name: "Jira Agent",
                skillDescription: "Review support issues and ticket queues",
                allowedTools: ["Read", "Bash"],
                behaviorInstructions: "Use Jira to review issues before answering."
            )
            skill.isGlobal = true
            let connector = Connector(
                name: "Jira-new",
                serviceType: "jira",
                connectorDescription: "Atlassian Jira REST API v3",
                baseURL: "https://example.atlassian.net",
                authMethod: "basic"
            )
            connector.isGlobal = true
            connector.skill = skill
            connector.credentialKeys = ["JIRA_API_TOKEN"]
            store.save(
                key: "JIRA_API_TOKEN",
                value: "secret-token-value",
                entityID: KeychainSecretStore.connectorEntityID(for: connector.id),
                label: nil
            )
            workspace.enabledGlobalConnectorIDs = [connector.id.uuidString]
            task = AgentTask(title: "Support tickets", goal: unrelatedTurn, workspace: workspace)
            for model in [workspace, skill, connector, task] as [any PersistentModel] {
                context.insert(model)
            }
            try context.save()
        }
    }
}

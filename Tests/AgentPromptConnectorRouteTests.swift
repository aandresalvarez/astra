import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA
import ASTRACore

/// The prompt tells the agent how to reach a connector. That sentence has to
/// describe the route the run actually gets, because the agent has no other
/// way to find out: naming a route this runtime cannot carry is worse than
/// naming none, since the agent tries it, fails, and reports the connector as
/// broken to the user.
@Suite("Connector prompt routes")
@MainActor
struct AgentPromptConnectorRouteTests {
    @Test("An offered connector's prompt route names the transport this runtime has")
    func offeredConnectorPromptRouteMatchesRuntimeTransport() throws {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let store = MockSecretStore()
        let workspace = Workspace(name: "jira-route", primaryPath: "/tmp/jira-route")
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

        // A turn that never names Jira: reachable, so the route is offered, but
        // nothing this turn says narrates it.
        let turn = "give me the data"
        let task = AgentTask(title: "Support tickets", goal: turn, workspace: workspace)
        for model in [workspace, skill, connector, task] as [any PersistentModel] {
            context.insert(model)
        }
        try context.save()

        let scope = TaskCapabilityResolver(task: task, secretStore: store)
            .activationScope(contextText: turn)
        #expect(!scope.connectors.contains { $0.id == connector.id })
        #expect(scope.reachableConnectors.contains { $0.id == connector.id })

        // The profile is passed rather than detected: the builder falls back to
        // probing the installed binary, so leaving Copilot's profile implicit
        // would make this test assert whatever Copilot build is on the machine
        // running it. What the route sentence has to match is the transport the
        // run gets, and that is exactly what the profile states.
        func routeText(
            runtime: AgentRuntimeID,
            profile: AgentRuntimeCapabilityProfile? = nil
        ) throws -> String {
            try #require(AgentPromptConnectorContextBuilder.section(
                from: scope,
                task: task,
                runtime: runtime,
                runtimeCapabilityProfile: profile
                    ?? AgentRuntimeCapabilityProfile.defaultProfile(for: runtime)
            )?.text)
        }

        // MCP transport: name the tool call the agent can actually make.
        let mcpText = try routeText(runtime: .claudeCode)
        #expect(mcpText.contains("mcp__astra_host__jira"))

        // CLI relay: same route, different spelling.
        let relayText = try routeText(runtime: .cursorCLI)
        #expect(relayText.contains("astra-host-control jira"))
        #expect(!relayText.contains("mcp__astra_host__jira"))

        // A Copilot build that can take `--additional-mcp-config` carries the
        // broker, so it is told the MCP route rather than "unavailable".
        let copilotWithMCPText = try routeText(
            runtime: .copilotCLI,
            profile: .copilotProfile(supportsAdditionalMCPConfig: true)
        )
        #expect(copilotWithMCPText.contains("mcp__astra_host__jira"))

        // No transport at all. A brokered connector's credentials never enter
        // the process environment, so pointing at env vars would be a lie too.
        let noRouteText = try routeText(
            runtime: .copilotCLI,
            profile: .copilotProfile(supportsAdditionalMCPConfig: false)
        )
        #expect(noRouteText.contains("[Jira-new]"))
        #expect(noRouteText.contains("no host-tool route on this runtime"))
        #expect(!noRouteText.contains("mcp__astra_host__jira"))
        #expect(!noRouteText.contains("connector env vars"))
        #expect(!noRouteText.contains("JIRA_API_TOKEN"))
        #expect(!noRouteText.contains("secret-token-value"))
    }
}

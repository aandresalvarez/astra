import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA
import ASTRACore

private func makeBrokeredConnectorPromptContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

/// What the prompt is allowed to say about a connector whose credentials the
/// broker holds.
///
/// The incident these guard against: the agent was told to reach REDCap through
/// `REDCAP_API_TOKEN`, the launch environment correctly withheld it, and the
/// agent reported a missing credential for a connector it was never meant to
/// hold one for. The prompt has to name the alias and the broker route, and
/// must not name a credential env var the process does not have.
@Suite("Brokered connector prompts")
@MainActor
struct BrokeredConnectorPromptTests {
    @Test("Multiple same-service connectors project namespaced env vars without legacy collision")
    func multipleSameServiceConnectorsProjectNamespacedEnvVarsWithoutLegacyCollision() throws {
        let container = try makeBrokeredConnectorPromptContainer()
        let context = container.mainContext

        let workspace = Workspace(name: "REDCap Workspace", primaryPath: "/tmp/redcap-workspace")
        context.insert(workspace)

        let source = Connector(
            name: "Study A Source",
            serviceType: "redcap",
            connectorDescription: "Source REDCap project",
            baseURL: "https://redcap.example.edu/api/",
            authMethod: "api_key"
        )
        source.workspace = workspace
        source.configKeys = ["REDCAP_API_URL"]
        source.configValues = ["https://redcap.example.edu/api/source"]
        context.insert(source)

        let target = Connector(
            name: "Study B Target",
            serviceType: "redcap",
            connectorDescription: "Target REDCap project",
            baseURL: "https://redcap.example.edu/api/",
            authMethod: "api_key"
        )
        target.workspace = workspace
        target.configKeys = ["REDCAP_API_URL"]
        target.configValues = ["https://redcap.example.edu/api/target"]
        context.insert(target)

        let task = AgentTask(
            title: "Move REDCap data",
            goal: "Copy records from Study A Source to Study B Target",
            workspace: workspace
        )
        context.insert(task)
        try context.save()

        let env = TaskCapabilityResolver(task: task).resolver.resolvedEnvironmentVariables
        #expect(env["REDCAP_STUDY_A_SOURCE_API_URL"] == "https://redcap.example.edu/api/source")
        #expect(env["REDCAP_STUDY_B_TARGET_API_URL"] == "https://redcap.example.edu/api/target")
        #expect(env["REDCAP_API_URL"] == nil)
        #expect(env["ASTRA_CONNECTORS"]?.contains(#""alias":"study_a_source""#) == true)
        #expect(env["ASTRA_CONNECTORS"]?.contains(#""alias":"study_b_target""#) == true)

        // The env vars above exist for the broker, which runs in a separate
        // process and resolves the connector by alias. The prompt therefore
        // names the alias and never the env var: REDCap is brokered, so the
        // agent process is not given the projection at all.
        let prompt = AgentPromptBuilder.buildPrompt(for: task)
        #expect(prompt.contains("Alias: study_a_source"))
        #expect(prompt.contains("Alias: study_b_target"))
        #expect(prompt.contains(#"mcp__astra_host__redcap with {"operation":"status","alias":"study_a_source"}"#))
        #expect(prompt.contains(#"mcp__astra_host__redcap with {"operation":"status","alias":"study_b_target"}"#))
        #expect(!prompt.contains("REDCAP_STUDY_A_SOURCE_API_URL"))
        #expect(!prompt.contains("REDCAP_STUDY_B_TARGET_API_URL"))
        #expect(!prompt.contains("--data-urlencode"))
        #expect(prompt.contains("The connector details and runtime routes above are authoritative"))
    }

    @Test("Multiple Jira connectors use broker aliases without provider credentials")
    func multipleJiraConnectorsUseBrokerAliases() throws {
        let container = try makeBrokeredConnectorPromptContainer()
        let context = container.mainContext

        let workspace = Workspace(name: "Jira Workspace", primaryPath: "/tmp/jira-multi-workspace")
        context.insert(workspace)

        let eng = Connector(
            name: "Eng Jira",
            serviceType: "jira",
            connectorDescription: "Engineering Jira",
            baseURL: "https://eng.example.atlassian.net",
            authMethod: "basic"
        )
        eng.workspace = workspace
        eng.configKeys = ["JIRA_BASE_URL", "JIRA_PROJECTS", "JIRA_EMAIL", "JIRA_API_TOKEN"]
        eng.configValues = ["https://eng.example.atlassian.net", "ENG", "eng@example.edu", "eng-token"]
        context.insert(eng)

        let ops = Connector(
            name: "Ops Jira",
            serviceType: "jira",
            connectorDescription: "Operations Jira",
            baseURL: "https://ops.example.atlassian.net",
            authMethod: "basic"
        )
        ops.workspace = workspace
        ops.configKeys = ["JIRA_BASE_URL", "JIRA_PROJECTS", "JIRA_EMAIL", "JIRA_API_TOKEN"]
        ops.configValues = ["https://ops.example.atlassian.net", "OPS", "ops@example.edu", "ops-token"]
        context.insert(ops)

        let task = AgentTask(
            title: "Compare Jira tickets",
            goal: "Compare ENG and OPS Jira work queues",
            workspace: workspace
        )
        context.insert(task)
        try context.save()

        let prompt = AgentPromptBuilder.buildPrompt(for: task)
        #expect(prompt.contains("Alias: eng_jira"))
        #expect(prompt.contains("Alias: ops_jira"))
        #expect(prompt.contains(#"mcp__astra_host__jira with {"operation":"status","alias":"eng_jira"}"#))
        #expect(prompt.contains(#"mcp__astra_host__jira with {"operation":"status","alias":"ops_jira"}"#))
        #expect(!prompt.contains("JIRA_ENG_JIRA_EMAIL"))
        #expect(!prompt.contains("JIRA_ENG_JIRA_API_TOKEN"))
        #expect(!prompt.contains("/rest/api/3/mypermissions"))
        #expect(prompt.contains("The connector details and runtime routes above are authoritative"))
    }

    @Test("Follow-up prompt preserves namespaced connector manifest")
    func followUpPromptPreservesNamespacedConnectorManifest() throws {
        let container = try makeBrokeredConnectorPromptContainer()
        let context = container.mainContext

        let workspace = Workspace(name: "REDCap Follow Up Workspace", primaryPath: "/tmp/redcap-follow-up")
        context.insert(workspace)

        let source = Connector(
            name: "Study A Source",
            serviceType: "redcap",
            connectorDescription: "Source REDCap project",
            baseURL: "https://redcap.example.edu/api/",
            authMethod: "api_key"
        )
        source.workspace = workspace
        source.configKeys = ["REDCAP_API_URL"]
        source.configValues = ["https://redcap.example.edu/api/source"]
        context.insert(source)

        let target = Connector(
            name: "Study B Target",
            serviceType: "redcap",
            connectorDescription: "Target REDCap project",
            baseURL: "https://redcap.example.edu/api/",
            authMethod: "api_key"
        )
        target.workspace = workspace
        target.configKeys = ["REDCAP_API_URL"]
        target.configValues = ["https://redcap.example.edu/api/target"]
        context.insert(target)

        let task = AgentTask(
            title: "Move REDCap data",
            goal: "Copy records from Study A Source to Study B Target",
            workspace: workspace
        )
        context.insert(task)
        try context.save()

        let prompt = AgentPromptBuilder.buildFreshFollowUpPrompt(
            message: "Continue that",
            task: task
        )

        #expect(prompt.contains("Alias: study_a_source"))
        #expect(prompt.contains("Alias: study_b_target"))
        #expect(prompt.contains(#""alias":"study_a_source""#))
        #expect(prompt.contains(#""alias":"study_b_target""#))
        #expect(!prompt.contains("REDCAP_STUDY_A_SOURCE_API_URL"))
        #expect(!prompt.contains("REDCAP_STUDY_B_TARGET_API_URL"))
        #expect(prompt.contains("The connector details and runtime routes above are authoritative"))
    }
}

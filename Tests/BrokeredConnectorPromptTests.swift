import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA
import ASTRACore

private struct BrokeredConnectorPromptSecretStore: SecretStore {
    let values: [String: String]

    func load(key: String, entityID _: String) -> String? { values[key] }
    func save(key _: String, value _: String, entityID _: String, label _: String?) -> Bool { false }
    func delete(key _: String, entityID _: String) -> Bool { false }
    func deleteAll(entityID _: String) {}
    func exists(key: String, entityID _: String) -> Bool { values[key] != nil }
}

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

    /// The other half of the same incident. Containment is what made the agent
    /// unable to `curl`; this is what stops it concluding that a script is the
    /// way around that. The prompt has to name the route that works, and it has
    /// to appear only where ASTRA can actually commit — telling an agent to
    /// propose a REDCap change would produce a proposal nothing can send.
    @Test("The propose-under-review contract appears only where ASTRA can commit")
    func mutationContractIsScopedToServicesAstraCanCommit() throws {
        let container = try makeBrokeredConnectorPromptContainer()
        let context = container.mainContext

        let jiraWorkspace = Workspace(name: "Jira Contract", primaryPath: "/tmp/jira-contract")
        let jira = Connector(
            name: "Clinical Jira",
            serviceType: "jira",
            connectorDescription: "Clinical Jira",
            baseURL: "https://clinical.example.atlassian.net",
            authMethod: "basic"
        )
        jira.workspace = jiraWorkspace
        jira.configKeys = ["JIRA_BASE_URL", "JIRA_PROJECTS"]
        jira.configValues = ["https://clinical.example.atlassian.net", "STAR"]
        let jiraTask = AgentTask(
            title: "File a ticket",
            goal: "File a Jira ticket for the missing age filter",
            workspace: jiraWorkspace
        )

        let redcapWorkspace = Workspace(name: "REDCap Contract", primaryPath: "/tmp/redcap-contract")
        let redcap = Connector(
            name: "Study Source",
            serviceType: "redcap",
            connectorDescription: "Source REDCap project",
            baseURL: "https://redcap.example.edu/api/",
            authMethod: "api_key"
        )
        redcap.workspace = redcapWorkspace
        redcap.configKeys = ["REDCAP_API_URL"]
        redcap.configValues = ["https://redcap.example.edu/api/source"]
        let redcapTask = AgentTask(
            title: "Read REDCap records",
            goal: "Summarise the Study Source record counts",
            workspace: redcapWorkspace
        )

        for model in [jiraWorkspace, jira, jiraTask, redcapWorkspace, redcap, redcapTask] as [any PersistentModel] {
            context.insert(model)
        }
        try context.save()

        let jiraPrompt = AgentPromptBuilder.buildPrompt(for: jiraTask)
        #expect(jiraPrompt.contains("propose_issue"))
        #expect(jiraPrompt.contains("Writes through host control-plane connectors are staged, not sent"))
        #expect(jiraPrompt.contains("never substitute a script, curl command, or written instructions"))

        let redcapPrompt = AgentPromptBuilder.buildPrompt(for: redcapTask)
        #expect(!redcapPrompt.contains("Writes through host control-plane connectors are staged, not sent"))
    }

    /// The containment guarantee the proposal seam is built on top of.
    ///
    /// Staging a ticket adds a write path to the Jira capability, and the whole
    /// design is worthless if it also puts the credential back where the agent
    /// can read it — that is precisely the shape of the workaround it replaces
    /// (a script the user runs after exporting an API token).
    ///
    /// Asserted on the launch environment rather than the prompt, and after
    /// `BrokeredConnectorEnvironment.strip`, because that pair is what the
    /// process actually receives: `resolvedEnvironmentVariables` is the
    /// pre-strip resolution by design, so asserting on it would test the wrong
    /// layer and pass for the wrong reason.
    @Test("Proposing a ticket does not project Jira credentials into the agent")
    func jiraCredentialsStayOutOfTheAgentEnvironment() throws {
        let container = try makeBrokeredConnectorPromptContainer()
        let context = container.mainContext

        let workspace = Workspace(name: "Jira Proposal Workspace", primaryPath: "/tmp/jira-proposal")
        context.insert(workspace)

        let jira = Connector(
            name: "Clinical Jira",
            serviceType: "jira",
            connectorDescription: "Clinical Jira",
            baseURL: "https://clinical.example.atlassian.net",
            authMethod: "basic"
        )
        jira.workspace = workspace
        // Shaped like production: the token is a credential the store holds,
        // not a config value, which is how the catalog declares it.
        jira.credentialKeys = ["JIRA_EMAIL", "JIRA_API_TOKEN"]
        jira.configKeys = ["JIRA_BASE_URL", "JIRA_PROJECTS"]
        jira.configValues = ["https://clinical.example.atlassian.net", "STAR"]
        context.insert(jira)

        let task = AgentTask(
            title: "File a ticket",
            goal: "File a Jira ticket for the missing age filter",
            workspace: workspace
        )
        context.insert(task)
        try context.save()

        let scope = TaskCapabilityResolver(
            task: task,
            secretStore: BrokeredConnectorPromptSecretStore(values: [
                "JIRA_EMAIL": "clinical@example.edu",
                "JIRA_API_TOKEN": "clinical-api-token-value"
            ])
        ).resolvedScope(.fullInventory)

        var env = scope.resolver.resolvedEnvironmentVariables
        BrokeredConnectorEnvironment.strip(from: &env, capabilityScope: scope)

        // No credential under any name the agent could reach for.
        for key in ["JIRA_EMAIL", "JIRA_API_TOKEN", "JIRA_CLINICAL_JIRA_EMAIL", "JIRA_CLINICAL_JIRA_API_TOKEN"] {
            #expect(env[key] == nil, "\(key) survived the brokered strip")
        }

        // And no credential *value* anywhere in the environment, whatever the
        // key is called — a rename must not become a leak.
        let projected = env.values.joined(separator: "\n")
        #expect(!projected.contains("clinical-api-token-value"))
        #expect(!projected.contains("clinical@example.edu"))

        // Nor through the manifest: a brokered connector is pruned out of
        // ASTRA_CONNECTORS too, so nothing downstream can rebuild the request.
        #expect(env["ASTRA_CONNECTORS"]?.contains("clinical_jira") != true)

        // The broker still gets it, which is the whole point of the split.
        #expect(
            BrokeredConnectorEnvironment.credentialLabels(in: scope)
                .contains { $0.contains("JIRA_API_TOKEN") }
        )
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

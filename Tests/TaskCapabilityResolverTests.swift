import Foundation
import SwiftData
import Testing
@testable import ASTRA
import ASTRACore

private func makeTaskCapabilityResolverContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

@Suite("TaskCapabilityResolver")
@MainActor
struct TaskCapabilityResolverTests {
    private let _registerRuntimeSeams: Void = RuntimeSeamRegistration.registerAll() // ConnectorRuntimeProjection.environmentVariables() needs ConnectorSecretSeam

    @Test("Snapshotter captures live task skills into durable snapshots")
    func snapshotterCapturesLiveTaskSkills() throws {
        let skill = Skill(
            name: "Snapshot Skill",
            allowedTools: ["Read"],
            behaviorInstructions: "Keep this behavior for detached tasks.",
            environmentVariables: ["SNAPSHOT_ENV": "present"]
        )
        let task = AgentTask(title: "Snapshot", goal: "Capture")
        task.skills = [skill]

        TaskCapabilitySnapshotter.capture(for: task)

        #expect(task.skillSnapshots.count == 1)
        #expect(task.skillSnapshots.first?.name == "Snapshot Skill")
        #expect(task.skillSnapshots.first?.allowedTools == ["Read"])
        #expect(task.skillSnapshots.first?.behaviorInstructions == "Keep this behavior for detached tasks.")
        #expect(task.skillSnapshots.first?.environmentKeys == ["SNAPSHOT_ENV"])
        #expect(task.skillSnapshots.first?.environmentValues == ["present"])
    }

    @Test("Resolution snapshot separates inventory authorization from launch relevance")
    func resolutionSnapshotSeparatesInventoryAuthorizationFromLaunchRelevance() throws {
        let container = try makeTaskCapabilityResolverContainer()
        let context = container.mainContext
        let (workspace, githubPackage) = try makeGitHubEnabledWorkspace(in: context, name: "github-resolution-snapshot")

        let task = AgentTask(
            title: "Bake a cake",
            goal: "Bake a chocolate sponge cake and write the recipe",
            workspace: workspace
        )
        context.insert(task)
        try context.save()

        let snapshot = TaskCapabilityResolutionSnapshot.capture(
            for: task,
            providerLaunchContextText: task.goal
        )

        #expect(snapshot.fullInventory.enabledPackageIDs.contains(githubPackage.id))
        #expect(snapshot.fullInventory.behaviorSkills.map(\.name).contains("GitHub Agent"))
        #expect(snapshot.fullInventory.localTools.contains { $0.command == "gh" })
        #expect(snapshot.providerLaunch.prunedForBrowserTask)
        #expect(!snapshot.providerLaunch.behaviorSkills.map(\.name).contains("GitHub Agent"))
        #expect(!snapshot.providerLaunch.localTools.contains { $0.command == "gh" })

        workspace.enabledCapabilityIDs = []
        task.goal = "Use GitHub to list PRs"
        try context.save()

        #expect(snapshot.fullInventory.enabledPackageIDs.contains(githubPackage.id))
        #expect(snapshot.providerLaunch.excludedSkillNames.contains("GitHub Agent"))
        #expect(!snapshot.providerLaunch.localTools.contains { $0.command == "gh" })
    }

    @Test("Required host-control tool extraction is generic across scoped capabilities")
    func requiredHostControlToolExtractionIsGenericAcrossScopedCapabilities() throws {
        let container = try makeTaskCapabilityResolverContainer()
        let context = container.mainContext

        let workspace = Workspace(name: "Jira Host Control", primaryPath: "/tmp/jira-host-control")
        workspace.enabledCapabilityIDs = ["custom-jira-host-control"]
        context.insert(workspace)

        let jiraSkill = Skill(
            name: "Jira Host Control",
            allowedTools: ["Read"],
            behaviorInstructions: "Always use ASTRA's host-control Jira MCP tool mcp__astra_host__jira for Jira operations. Do not use Bash, curl, or raw REST API calls to bypass this broker."
        )
        jiraSkill.skillDescription = "Read Jira through ASTRA host-control Jira"
        jiraSkill.originPackageID = "custom-jira-host-control"
        jiraSkill.workspace = workspace
        context.insert(jiraSkill)

        let task = AgentTask(
            title: "Read Jira",
            goal: "Read Jira issue STAR-123",
            workspace: workspace
        )
        task.skills = [jiraSkill]
        context.insert(task)
        try context.save()

        let scope = TaskCapabilityResolver(task: task).promptScope(contextText: "Read Jira issue STAR-123")

        #expect(scope.behaviorSkills.map(\.name).contains("Jira Host Control"))
        #expect(HostControlPlaneMCPProjection.requiredToolNames(capabilityScope: scope) == ["jira"])
    }

    @Test("Docker-only host-control guidance is not required outside Docker")
    func dockerOnlyHostControlGuidanceIsNotRequiredOutsideDocker() throws {
        let container = try makeTaskCapabilityResolverContainer()
        let context = container.mainContext

        let workspace = Workspace(name: "Jira REST", primaryPath: "/tmp/jira-rest")
        workspace.enabledCapabilityIDs = ["jira-workflow"]
        context.insert(workspace)

        let jiraSkill = Skill(
            name: "Jira Agent",
            allowedTools: ["Read", "Bash"],
            behaviorInstructions: """
            DOCKER HOST-CONTROL RUNS
            In Docker workspace runs, use `mcp__astra_host__jira` or Copilot's `astra_host-jira`; do not use workspace shell or native host Bash for Jira.

            NON-DOCKER REST RUNS
            When no Jira host-control bridge is available, use curl via Bash with the selected connector's env vars.
            """
        )
        jiraSkill.skillDescription = "Search and read Jira tickets"
        jiraSkill.originPackageID = "jira-workflow"
        jiraSkill.workspace = workspace
        context.insert(jiraSkill)

        let task = AgentTask(
            title: "Read Jira",
            goal: "Read Jira issue STAR-123",
            workspace: workspace
        )
        task.skills = [jiraSkill]
        context.insert(task)
        try context.save()

        let scope = TaskCapabilityResolver(task: task).promptScope(contextText: "Read Jira issue STAR-123")

        #expect(scope.behaviorSkills.map(\.name).contains("Jira Agent"))
        #expect(HostControlPlaneMCPProjection.requiredToolNames(capabilityScope: scope).isEmpty)
    }

    @Test("Enabled connector contributes its companion skill instructions")
    func enabledConnectorIncludesCompanionSkillInstructions() throws {
        let container = try makeTaskCapabilityResolverContainer()
        let context = container.mainContext

        let workspace = Workspace(name: "Jira Workspace", primaryPath: "/tmp/jira-workspace")
        context.insert(workspace)

        let jiraSkill = Skill(
            name: "Jira Agent",
            allowedTools: ["Read", "Bash"],
            behaviorInstructions: "Use /rest/api/3/mypermissions before diagnosing Jira auth."
        )
        jiraSkill.isGlobal = true
        context.insert(jiraSkill)

        let jiraConnector = Connector(
            name: "Jira",
            serviceType: "jira",
            connectorDescription: "Jira REST API",
            baseURL: "https://example.atlassian.net",
            authMethod: "basic"
        )
        jiraConnector.isGlobal = true
        jiraConnector.skill = jiraSkill
        jiraConnector.configKeys = ["JIRA_PROJECTS"]
        jiraConnector.configValues = ["STAR"]
        context.insert(jiraConnector)

        workspace.enabledGlobalConnectorIDs = [jiraConnector.id.uuidString]

        let safeSkill = Skill(
            name: "Safe Bash",
            allowedTools: ["Read", "Bash"],
            behaviorInstructions: "Avoid destructive shell commands."
        )
        safeSkill.workspace = workspace
        context.insert(safeSkill)

        let task = AgentTask(title: "Use Jira", goal: "Create STAR ticket", workspace: workspace)
        task.skills = [safeSkill]
        context.insert(task)
        try context.save()

        let instructions = TaskCapabilityResolver(task: task).resolver.resolvedBehaviorInstructions
        #expect(instructions.contains("[Safe Bash]:"))
        #expect(instructions.contains("[Jira Agent]:"))
        #expect(instructions.contains("/rest/api/3/mypermissions"))

        let prompt = AgentPromptBuilder.buildPrompt(for: task)
        #expect(prompt.contains("Behavioral Instructions (from Skills):"))
        #expect(prompt.contains("[Jira Agent]:"))
        #expect(prompt.contains("JIRA_PROJECTS: STAR"))
    }

    @Test("Runtime connector resolution ignores stale duplicate when a configured connector exists")
    func runtimeConnectorResolutionIgnoresStaleDuplicateWhenConfiguredConnectorExists() throws {
        let container = try makeTaskCapabilityResolverContainer()
        let context = container.mainContext

        let workspace = Workspace(name: "StarrDocs", primaryPath: "/tmp/starrdocs")
        context.insert(workspace)

        let staleConnector = Connector(
            name: "Jira",
            serviceType: "jira",
            connectorDescription: "Placeholder Jira",
            baseURL: "https://yourcompany.atlassian.net",
            authMethod: "basic"
        )
        staleConnector.workspace = workspace
        staleConnector.credentialKeys = ["JIRA_EMAIL", "JIRA_API_TOKEN"]
        staleConnector.configKeys = ["JIRA_PROJECTS"]
        staleConnector.configValues = [""]
        context.insert(staleConnector)

        let jiraSkill = Skill(
            name: "Jira Agent",
            allowedTools: ["Read", "Bash"],
            behaviorInstructions: "Use Jira REST API for requested Jira work."
        )
        jiraSkill.isGlobal = true
        context.insert(jiraSkill)

        let configuredConnector = Connector(
            name: "Jira-new",
            serviceType: "jira",
            connectorDescription: "Configured Jira",
            baseURL: "https://stanfordmed.atlassian.net",
            authMethod: "none"
        )
        configuredConnector.isGlobal = true
        configuredConnector.skill = jiraSkill
        configuredConnector.configKeys = ["JIRA_PROJECTS"]
        configuredConnector.configValues = ["SS,STAR"]
        context.insert(configuredConnector)
        workspace.enabledGlobalConnectorIDs = [configuredConnector.id.uuidString]

        let safeSkill = Skill(
            name: "Safe Bash",
            allowedTools: ["Read", "Bash"],
            behaviorInstructions: "Use safe shell commands."
        )
        safeSkill.workspace = workspace
        context.insert(safeSkill)

        let task = AgentTask(
            title: "Use Jira story STAR-11892",
            goal: "Propose a plan for Jira story STAR-11892",
            workspace: workspace
        )
        task.skills = [safeSkill]
        context.insert(task)
        try context.save()

        #expect(TaskCapabilityResolver(task: task).allConnectors.map(\.id) == [configuredConnector.id])

        let prompt = AgentPromptBuilder.buildPrompt(for: task)
        #expect(prompt.contains("https://stanfordmed.atlassian.net"))
        #expect(!prompt.contains("https://yourcompany.atlassian.net"))
        #expect(prompt.contains("[Jira Agent]:"))
    }

    @Test("Provider launch connector scope follows active objective instead of stale task goal")
    func providerLaunchConnectorScopeFollowsActiveObjective() throws {
        let container = try makeTaskCapabilityResolverContainer()
        let context = container.mainContext
        let jiraPackage = try #require(PluginCatalog.builtInPackages.first { $0.id == "jira-workflow" })

        let workspace = Workspace(name: "Starr Data Lake", primaryPath: "/tmp/starr-data-lake")
        workspace.enabledCapabilityIDs = [jiraPackage.id]
        context.insert(workspace)

        let jiraSkill = Skill(
            name: "Jira Agent",
            allowedTools: ["Bash"],
            behaviorInstructions: "Use Jira only for sprint story work."
        )
        jiraSkill.isGlobal = true
        context.insert(jiraSkill)

        let jiraConnector = Connector(
            name: "Jira-new",
            serviceType: "jira",
            connectorDescription: "Jira sprint story connector",
            baseURL: "https://stanfordmed.atlassian.net",
            authMethod: "basic"
        )
        jiraConnector.isGlobal = true
        jiraConnector.skill = jiraSkill
        jiraConnector.credentialKeys = ["JIRA_EMAIL", "JIRA_API_TOKEN"]
        context.insert(jiraConnector)

        let gcpConnector = Connector(
            name: "Google Cloud",
            serviceType: "gcp",
            connectorDescription: "Google Cloud BigQuery credentials for dbt regression tests",
            baseURL: "https://bigquery.googleapis.com",
            authMethod: "adc"
        )
        gcpConnector.isGlobal = true
        gcpConnector.credentialKeys = ["GOOGLE_APPLICATION_CREDENTIALS"]
        context.insert(gcpConnector)

        workspace.enabledGlobalConnectorIDs = [
            jiraConnector.id.uuidString,
            gcpConnector.id.uuidString
        ]

        let task = AgentTask(
            title: "List active sprint stories",
            goal: "List my stories for the active sprint in the STAR Jira project",
            workspace: workspace
        )
        context.insert(task)

        let first = TaskEvent(
            task: task,
            type: "user.message",
            payload: "List my stories for the active sprint in the STAR Jira project"
        )
        first.timestamp = Date(timeIntervalSince1970: 1)
        context.insert(first)

        let correction = TaskEvent(
            task: task,
            type: "user.message",
            payload: "no your goal is to complete the plan.md document"
        )
        correction.timestamp = Date(timeIntervalSince1970: 2)
        context.insert(correction)
        try context.save()

        let scope = TaskCapabilityResolver(task: task).promptScope(
            contextText: "Continue Phase 5 from plan.md: run dbt tests against BigQuery in Docker."
        )

        #expect(scope.behaviorSkills.map(\.name).contains("Jira Agent") == false)
        #expect(scope.connectors.map(\.name) == ["Google Cloud"])
        #expect(scope.resolver.resolvedEnvironmentVariables.keys.contains { $0.contains("JIRA") } == false)

        let providerLaunchIssues = CapabilityRuntimeIntegrityService.issues(
            for: task,
            packages: [jiraPackage],
            checkExecutables: false,
            scope: .providerLaunch(contextText: "Continue Phase 5 from plan.md: run dbt tests against BigQuery in Docker."),
            secretStore: MockSecretStore()
        )
        #expect(providerLaunchIssues.isEmpty)

        let fullInventoryIssues = CapabilityRuntimeIntegrityService.issues(
            for: task,
            packages: [jiraPackage],
            checkExecutables: false,
            scope: .fullInventory,
            secretStore: MockSecretStore()
        )
        #expect(fullInventoryIssues.contains {
            $0.resourceKind == .credential &&
                $0.message.contains("Jira-new is missing Keychain value")
        })
    }

    @Test("Multiple same-service connectors project namespaced env vars without legacy collision")
    func multipleSameServiceConnectorsProjectNamespacedEnvVarsWithoutLegacyCollision() throws {
        let container = try makeTaskCapabilityResolverContainer()
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

        let prompt = AgentPromptBuilder.buildPrompt(for: task)
        #expect(prompt.contains("Alias: study_a_source"))
        #expect(prompt.contains("Alias: study_b_target"))
        #expect(prompt.contains("REDCAP_STUDY_A_SOURCE_API_URL"))
        #expect(prompt.contains("REDCAP_STUDY_B_TARGET_API_URL"))
        #expect(prompt.contains("ASTRA_CONNECTORS"))
        #expect(prompt.contains("connector env vars listed above and the ASTRA_CONNECTORS JSON manifest are authoritative"))
    }

    @Test("Multiple Jira connectors prompt uses projected env names")
    func multipleJiraConnectorsPromptUsesProjectedEnvNames() throws {
        let container = try makeTaskCapabilityResolverContainer()
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
        #expect(prompt.contains("baseURL: $JIRA_ENG_JIRA_BASE_URL"))
        #expect(prompt.contains("projects: $JIRA_OPS_JIRA_PROJECTS"))
        #expect(prompt.contains(#""$JIRA_ENG_JIRA_EMAIL:$JIRA_ENG_JIRA_API_TOKEN""#))
        #expect(prompt.contains(#""${JIRA_ENG_JIRA_BASE_URL}/rest/api/3/mypermissions?permissions=BROWSE_PROJECTS""#))
        #expect(prompt.contains(#""${JIRA_OPS_JIRA_BASE_URL}/rest/api/3/mypermissions?permissions=BROWSE_PROJECTS""#))
        #expect(prompt.contains("connector env vars listed above and the ASTRA_CONNECTORS JSON manifest are authoritative"))
        #expect(!prompt.contains(#""$JIRA_BASE_URL/rest/api/3/...""#))
    }

    @Test("Docker-routed connector prompt describes bq host control as help-only")
    func dockerRoutedConnectorPromptDescribesBQHostControlAsHelpOnly() throws {
        let container = try makeTaskCapabilityResolverContainer()
        let context = container.mainContext

        let workspace = Workspace(name: "BigQuery Docker Workspace", primaryPath: "/tmp/bq-docker-workspace")
        context.insert(workspace)

        let connector = Connector(
            name: "Analytics BigQuery",
            serviceType: "gcloud",
            connectorDescription: "Analytics BigQuery project",
            baseURL: "",
            authMethod: "application_default_credentials"
        )
        connector.workspace = workspace
        connector.configKeys = ["GOOGLE_CLOUD_PROJECT"]
        connector.configValues = ["demo-project"]
        context.insert(connector)

        let task = AgentTask(
            title: "Inspect BigQuery",
            goal: "Inspect BigQuery datasets from a Docker-routed task",
            workspace: workspace
        )
        task.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encode(WorkspaceExecutionEnvironment(
            id: "image:test",
            kind: .dockerImage,
            displayName: "Test Image",
            image: "astra/test:latest"
        ))
        context.insert(task)
        try context.save()

        let prompt = AgentPromptBuilder.buildPrompt(for: task)
        #expect(prompt.contains("This task is routed through a Docker workspace executor"))
        #expect(prompt.contains("Use `mcp__astra_host__bq` only for bq help/version metadata"))
        #expect(prompt.contains("BigQuery data access is not available through host-control"))
        #expect(!prompt.contains("For Google Cloud or BigQuery host CLI operations, use `mcp__astra_host__gcloud` or `mcp__astra_host__bq`"))
    }

    @Test("Docker routed Jira prompt suppresses raw REST runtime examples")
    func dockerRoutedJiraPromptSuppressesRawRESTRuntimeExamples() throws {
        let container = try makeTaskCapabilityResolverContainer()
        let context = container.mainContext

        let workspace = Workspace(name: "Docker Jira Workspace", primaryPath: "/tmp/docker-jira-workspace")
        context.insert(workspace)

        let connector = Connector(
            name: "Jira",
            serviceType: "jira",
            connectorDescription: "Jira REST API",
            baseURL: "https://jira.example.atlassian.net",
            authMethod: "basic"
        )
        connector.workspace = workspace
        connector.configKeys = ["JIRA_BASE_URL", "JIRA_EMAIL", "JIRA_API_TOKEN"]
        connector.configValues = ["https://jira.example.atlassian.net", "person@example.edu", "token"]
        context.insert(connector)

        let task = AgentTask(
            title: "Read Jira",
            goal: "Read Jira issues in Docker",
            workspace: workspace
        )
        task.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encode(WorkspaceExecutionEnvironment(
            id: "image:workspace",
            kind: .dockerImage,
            displayName: "Workspace Image",
            image: "astra/workspace:latest"
        ))
        context.insert(task)
        try context.save()

        let prompt = AgentPromptBuilder.buildPrompt(for: task)

        #expect(prompt.contains("mcp__astra_host__jira"))
        #expect(prompt.contains(#""operation":"status""#))
        #expect(prompt.contains(#""operation":"search_jql""#))
        #expect(!prompt.contains("Runtime example: curl"))
        #expect(!prompt.contains("/rest/api/3/mypermissions"))
    }

    @Test("Docker routed Jira prompt includes connector alias in runtime examples")
    func dockerRoutedJiraPromptIncludesConnectorAliasInRuntimeExamples() throws {
        let container = try makeTaskCapabilityResolverContainer()
        let context = container.mainContext

        let workspace = Workspace(name: "Docker Multi Jira Workspace", primaryPath: "/tmp/docker-multi-jira-workspace")
        context.insert(workspace)

        let eng = Connector(
            name: "Eng Jira",
            serviceType: "jira",
            connectorDescription: "Engineering Jira",
            baseURL: "https://eng.example.atlassian.net",
            authMethod: "basic"
        )
        eng.workspace = workspace
        eng.configKeys = ["JIRA_BASE_URL", "JIRA_EMAIL", "JIRA_API_TOKEN"]
        eng.configValues = ["https://eng.example.atlassian.net", "eng@example.edu", "eng-token"]
        context.insert(eng)

        let ops = Connector(
            name: "Ops Jira",
            serviceType: "jira",
            connectorDescription: "Operations Jira",
            baseURL: "https://ops.example.atlassian.net",
            authMethod: "basic"
        )
        ops.workspace = workspace
        ops.configKeys = ["JIRA_BASE_URL", "JIRA_EMAIL", "JIRA_API_TOKEN"]
        ops.configValues = ["https://ops.example.atlassian.net", "ops@example.edu", "ops-token"]
        context.insert(ops)

        let task = AgentTask(
            title: "Compare Jira",
            goal: "Read Jira issues in Docker from both sites",
            workspace: workspace
        )
        task.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encode(WorkspaceExecutionEnvironment(
            id: "image:workspace",
            kind: .dockerImage,
            displayName: "Workspace Image",
            image: "astra/workspace:latest"
        ))
        context.insert(task)
        try context.save()

        let prompt = AgentPromptBuilder.buildPrompt(for: task)

        #expect(prompt.contains(#"Runtime example: mcp__astra_host__jira with {"operation":"status","alias":"eng_jira"}"#))
        #expect(prompt.contains(#"Runtime example: mcp__astra_host__jira with {"operation":"status","alias":"ops_jira"}"#))
        #expect(prompt.contains(#"{"operation":"search_jql","alias":"eng_jira","jql":"project = KEY","max_results":1}"#))
        #expect(prompt.contains(#"{"operation":"search_jql","alias":"ops_jira","jql":"project = KEY","max_results":1}"#))
    }

    @Test("Follow-up prompt preserves namespaced connector manifest")
    func followUpPromptPreservesNamespacedConnectorManifest() throws {
        let container = try makeTaskCapabilityResolverContainer()
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
            message: "Continue copying records",
            task: task
        )

        #expect(prompt.contains("Alias: study_a_source"))
        #expect(prompt.contains("Alias: study_b_target"))
        #expect(prompt.contains("REDCAP_STUDY_A_SOURCE_API_URL"))
        #expect(prompt.contains("REDCAP_STUDY_B_TARGET_API_URL"))
        #expect(prompt.contains("ASTRA_CONNECTORS"))
    }

    @Test("Single same-service connector uses namespaced env vars by default")
    func singleSameServiceConnectorUsesNamespacedEnvVarsByDefault() throws {
        let container = try makeTaskCapabilityResolverContainer()
        let context = container.mainContext

        let workspace = Workspace(name: "Single REDCap Workspace", primaryPath: "/tmp/redcap-single")
        context.insert(workspace)

        let connector = Connector(
            name: "Study A Source",
            serviceType: "redcap",
            connectorDescription: "Source REDCap project",
            baseURL: "https://redcap.example.edu/api/",
            authMethod: "api_key"
        )
        connector.workspace = workspace
        connector.configKeys = ["REDCAP_API_URL"]
        connector.configValues = ["https://redcap.example.edu/api/source"]
        context.insert(connector)

        let task = AgentTask(
            title: "Use REDCap",
            goal: "Read Study A Source metadata",
            workspace: workspace
        )
        context.insert(task)
        try context.save()

        let env = TaskCapabilityResolver(task: task).resolver.resolvedEnvironmentVariables
        #expect(env["REDCAP_STUDY_A_SOURCE_API_URL"] == "https://redcap.example.edu/api/source")
        #expect(env["REDCAP_API_URL"] == nil)
    }

    @Test("Projection namespaces duplicate connector credentials")
    func projectionNamespacesDuplicateConnectorCredentials() throws {
        let source = Connector(name: "Study A Source", serviceType: "redcap", authMethod: "api_key")
        source.credentialKeys = ["REDCAP_API_TOKEN"]

        let target = Connector(name: "Study B Target", serviceType: "redcap", authMethod: "api_key")
        target.credentialKeys = ["REDCAP_API_TOKEN"]

        let store = MockSecretStore()
        store.save(
            key: "REDCAP_API_TOKEN",
            value: "source-token",
            entityID: KeychainSecretStore.connectorEntityID(for: source.id),
            label: nil
        )
        store.save(
            key: "REDCAP_API_TOKEN",
            value: "target-token",
            entityID: KeychainSecretStore.connectorEntityID(for: target.id),
            label: nil
        )

        let env = ConnectorRuntimeProjection(
            connectors: [source, target],
            secretStore: store,
            credentialExposurePolicy: .approvedLabels([
                ConnectorRuntimeProjection.credentialLabel(for: source, key: "REDCAP_API_TOKEN"),
                ConnectorRuntimeProjection.credentialLabel(for: target, key: "REDCAP_API_TOKEN")
            ])
        ).environmentVariables()

        #expect(env["REDCAP_STUDY_A_SOURCE_API_TOKEN"] == "source-token")
        #expect(env["REDCAP_STUDY_B_TARGET_API_TOKEN"] == "target-token")
        #expect(env["REDCAP_API_TOKEN"] == nil)
    }

    @Test("Projection treats empty connector credentials as missing")
    func projectionTreatsEmptyConnectorCredentialsAsMissing() throws {
        let connector = Connector(name: "Jira", serviceType: "jira", authMethod: "basic")
        connector.credentialKeys = ["JIRA_EMAIL", "JIRA_API_TOKEN"]

        let store = MockSecretStore()
        let entityID = KeychainSecretStore.connectorEntityID(for: connector.id)
        store.save(key: "JIRA_EMAIL", value: "user@example.edu", entityID: entityID, label: nil)
        store.save(key: "JIRA_API_TOKEN", value: "   ", entityID: entityID, label: nil)

        let env = ConnectorRuntimeProjection(
            connectors: [connector],
            secretStore: store,
            credentialExposurePolicy: .approvedLabels([
                ConnectorRuntimeProjection.credentialLabel(for: connector, key: "JIRA_EMAIL"),
                ConnectorRuntimeProjection.credentialLabel(for: connector, key: "JIRA_API_TOKEN")
            ])
        ).environmentVariables()

        #expect(env["JIRA_JIRA_EMAIL"] == "user@example.edu")
        #expect(env["JIRA_EMAIL"] == nil)
        #expect(env["JIRA_JIRA_API_TOKEN"] == nil)
        #expect(env["JIRA_API_TOKEN"] == nil)

        let manifestJSON = try #require(env["ASTRA_CONNECTORS"])
        let manifestData = try #require(manifestJSON.data(using: .utf8))
        let manifest = try JSONDecoder().decode(ConnectorRuntimeProjection.Manifest.self, from: manifestData)
        let manifestConnector = try #require(manifest.connectors.first)

        #expect(manifestConnector.credentials["email"] == "JIRA_JIRA_EMAIL")
        #expect(manifestConnector.credentials["apiToken"] == nil)
    }

    @Test("Projection aliases duplicate connector names consistently across input order")
    func projectionAliasesDuplicateConnectorNamesConsistentlyAcrossInputOrder() throws {
        let first = Connector(name: "REDCap", serviceType: "redcap")
        first.id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

        let second = Connector(name: "REDCap", serviceType: "redcap")
        second.id = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

        let firstOrder = ConnectorRuntimeProjection.aliasesByConnectorID(for: [first, second])
        let reversedOrder = ConnectorRuntimeProjection.aliasesByConnectorID(for: [second, first])

        #expect(firstOrder[first.id] == "redcap_11111111")
        #expect(firstOrder[second.id] == "redcap_22222222")
        #expect(reversedOrder[first.id] == firstOrder[first.id])
        #expect(reversedOrder[second.id] == firstOrder[second.id])
    }

    @Test("Projection resolves preferred alias collisions consistently across input order")
    func projectionResolvesPreferredAliasCollisionsConsistentlyAcrossInputOrder() throws {
        let duplicateFirst = Connector(name: "API", serviceType: "jira")
        duplicateFirst.id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

        let duplicateSecond = Connector(name: "API", serviceType: "jira")
        duplicateSecond.id = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

        let directCollision = Connector(name: "API 11111111", serviceType: "jira")
        directCollision.id = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

        let firstOrder = ConnectorRuntimeProjection.aliasesByConnectorID(
            for: [duplicateFirst, duplicateSecond, directCollision]
        )
        let reversedOrder = ConnectorRuntimeProjection.aliasesByConnectorID(
            for: [directCollision, duplicateSecond, duplicateFirst]
        )

        #expect(firstOrder == reversedOrder)
        #expect(firstOrder[directCollision.id] == "api_11111111")
        #expect(firstOrder[duplicateFirst.id] == "api_11111111_2")
        #expect(firstOrder[duplicateSecond.id] == "api_22222222")
    }

    @Test("Projection aliases are scoped by service type")
    func projectionAliasesAreScopedByServiceType() throws {
        let jira = Connector(name: "Eng", serviceType: "jira")
        jira.configKeys = ["BASE_URL"]
        jira.configValues = ["https://jira.example.edu"]

        let github = Connector(name: "Eng", serviceType: "github")
        github.configKeys = ["BASE_URL"]
        github.configValues = ["https://github.example.edu"]

        let aliases = ConnectorRuntimeProjection.aliasesByConnectorID(for: [jira, github])

        #expect(aliases[jira.id] == "eng")
        #expect(aliases[github.id] == "eng")

        let projection = ConnectorRuntimeProjection(connectors: [jira, github])
        let env = projection.environmentVariables()
        #expect(env["JIRA_ENG_BASE_URL"] == "https://jira.example.edu")
        #expect(env["GITHUB_ENG_BASE_URL"] == "https://github.example.edu")

        let manifest = projection.manifest()
        #expect(manifest.connectors.map(\.alias) == ["eng", "eng"])
        #expect(manifest.connectors.map(\.envPrefix) == ["JIRA_ENG", "GITHUB_ENG"])
    }

    @Test("Runtime examples do not embed raw connector base URLs")
    func runtimeExamplesDoNotEmbedRawConnectorBaseURLs() throws {
        let container = try makeTaskCapabilityResolverContainer()
        let context = container.mainContext

        let workspace = Workspace(name: "Unsafe Base URL", primaryPath: "/tmp/unsafe-base-url")
        context.insert(workspace)

        let connector = Connector(
            name: "Jira",
            serviceType: "jira",
            connectorDescription: "Jira REST API",
            baseURL: #"https://example.atlassian.net/$(touch /tmp/astra-prompt-pwn)"#,
            authMethod: "basic"
        )
        connector.workspace = workspace
        connector.configKeys = ["JIRA_EMAIL", "JIRA_API_TOKEN"]
        connector.configValues = ["person@example.edu", "token"]
        context.insert(connector)

        let task = AgentTask(
            title: "Use Jira",
            goal: "Check Jira permissions",
            workspace: workspace
        )
        context.insert(task)
        try context.save()

        let prompt = AgentPromptBuilder.buildPrompt(for: task)

        #expect(prompt.contains("Base URL: https://example.atlassian.net/$(touch /tmp/astra-prompt-pwn)"))
        #expect(!prompt.contains("Runtime example: curl"))
        #expect(!prompt.contains("mypermissions?permissions=BROWSE_PROJECTS"))
    }

    @Test("Prompt config summary only includes projected config values")
    func promptConfigSummaryOnlyIncludesProjectedConfigValues() throws {
        let container = try makeTaskCapabilityResolverContainer()
        let context = container.mainContext

        let workspace = Workspace(name: "Partial Config", primaryPath: "/tmp/partial-config")
        context.insert(workspace)

        let connector = Connector(
            name: "Jira",
            serviceType: "jira",
            connectorDescription: "Jira REST API",
            baseURL: "https://jira.example.edu",
            authMethod: "basic"
        )
        connector.workspace = workspace
        connector.configKeys = ["JIRA_BASE_URL", "JIRA_PROJECTS", "JIRA_REGION"]
        connector.configValues = ["https://jira.example.edu", "   "]
        context.insert(connector)

        let task = AgentTask(
            title: "Use Jira",
            goal: "Check Jira configuration",
            workspace: workspace
        )
        context.insert(task)
        try context.save()

        let prompt = AgentPromptBuilder.buildPrompt(for: task)

        #expect(prompt.contains("Config: JIRA_BASE_URL: https://jira.example.edu"))
        #expect(!prompt.contains("Config: JIRA_PROJECTS"))
        #expect(!prompt.contains("JIRA_PROJECTS:    "))
        #expect(!prompt.contains("JIRA_REGION:"))
        #expect(prompt.contains("Config env vars: JIRA_JIRA_BASE_URL"))
        #expect(!prompt.contains("JIRA_JIRA_PROJECTS"))
        #expect(!prompt.contains("JIRA_JIRA_REGION"))
    }

    @Test("Projection does not emit legacy fallback when original keys collide")
    func projectionDoesNotEmitLegacyFallbackWhenOriginalKeysCollide() throws {
        let first = Connector(name: "First API", serviceType: "first")
        first.configKeys = ["API_TOKEN"]
        first.configValues = ["first-token"]

        let second = Connector(name: "Second API", serviceType: "second")
        second.configKeys = ["API_TOKEN"]
        second.configValues = ["second-token"]

        let env = ConnectorRuntimeProjection(connectors: [first, second]).environmentVariables()

        #expect(env["FIRST_FIRST_API_API_TOKEN"] == "first-token")
        #expect(env["SECOND_SECOND_API_API_TOKEN"] == "second-token")
        #expect(env["API_TOKEN"] == nil)
    }

    @Test("Projection disambiguates normalized key collisions within one connector")
    func projectionDisambiguatesNormalizedKeyCollisionsWithinOneConnector() throws {
        let connector = Connector(name: "Study", serviceType: "redcap", authMethod: "api_key")
        connector.configKeys = ["REDCAP_API_TOKEN", "API_TOKEN", "REDCAP_API_URL"]
        connector.configValues = ["prefixed-token", "plain-token", "https://redcap.example.edu/api/"]

        let projection = ConnectorRuntimeProjection(connectors: [connector])
        let env = projection.environmentVariables()

        #expect(env["REDCAP_STUDY_API_TOKEN"] == "prefixed-token")
        #expect(env["REDCAP_STUDY_API_TOKEN_2"] == "plain-token")
        #expect(env["REDCAP_STUDY_API_URL"] == "https://redcap.example.edu/api/")

        let manifestJSON = try #require(env["ASTRA_CONNECTORS"])
        let manifestData = try #require(manifestJSON.data(using: .utf8))
        let manifest = try JSONDecoder().decode(ConnectorRuntimeProjection.Manifest.self, from: manifestData)
        let manifestConnector = try #require(manifest.connectors.first)

        #expect(manifestConnector.config["apiToken"] == "REDCAP_STUDY_API_TOKEN")
        #expect(manifestConnector.config["apiToken2"] == "REDCAP_STUDY_API_TOKEN_2")
        #expect(manifestConnector.config["apiURL"] == "REDCAP_STUDY_API_URL")
    }

    @Test("Projection skips empty and missing connector config values")
    func projectionSkipsEmptyAndMissingConnectorConfigValues() throws {
        let connector = Connector(name: "Jira", serviceType: "jira", authMethod: "basic")
        connector.configKeys = ["JIRA_BASE_URL", "JIRA_PROJECTS", "JIRA_REGION"]
        connector.configValues = ["https://jira.example.edu", "   "]

        let env = ConnectorRuntimeProjection(connectors: [connector]).environmentVariables()

        #expect(env["JIRA_JIRA_BASE_URL"] == "https://jira.example.edu")
        #expect(env["JIRA_BASE_URL"] == nil)
        #expect(env["JIRA_JIRA_PROJECTS"] == nil)
        #expect(env["JIRA_PROJECTS"] == nil)
        #expect(env["JIRA_JIRA_REGION"] == nil)
        #expect(env["JIRA_REGION"] == nil)

        let manifestJSON = try #require(env["ASTRA_CONNECTORS"])
        let manifestData = try #require(manifestJSON.data(using: .utf8))
        let manifest = try JSONDecoder().decode(ConnectorRuntimeProjection.Manifest.self, from: manifestData)
        let manifestConnector = try #require(manifest.connectors.first)

        #expect(manifestConnector.config["baseURL"] == "JIRA_JIRA_BASE_URL")
        #expect(manifestConnector.config["projects"] == nil)
        #expect(manifestConnector.config["region"] == nil)
    }

    @Test("Built-in capability instructions defer env names to connector projection")
    func builtInCapabilityInstructionsDeferEnvNamesToConnectorProjection() throws {
        let packages = PluginCatalog.builtInPackages
        let jiraInstructions = try #require(packages.first { $0.id == "jira-workflow" }?.skills.first?.behaviorInstructions)
        let redcapInstructions = try #require(packages.first { $0.id == "redcap-workflow" }?.skills.first?.behaviorInstructions)
        let gcloudInstructions = try #require(packages.first { $0.id == "gcloud-workflow" }?.skills.first?.behaviorInstructions)

        #expect(!jiraInstructions.contains("Use Basic auth with the JIRA_EMAIL and JIRA_API_TOKEN environment variables"))
        #expect(!jiraInstructions.contains(#""$JIRA_BASE_URL/rest/api/3/...""#))
        #expect(!redcapInstructions.contains("Use the REDCAP_API_TOKEN environment variable"))
        #expect(!redcapInstructions.contains(#""token=$REDCAP_API_TOKEN""#))
        #expect(!gcloudInstructions.contains("Use the GCP_PROJECT environment variable when set"))
    }

    @Test("Enabled package IDs resolve runtime resources even when activation IDs drift")
    func enabledPackageIDResolvesResourcesWhenActivationIDsDrift() throws {
        let container = try makeTaskCapabilityResolverContainer()
        let context = container.mainContext

        let workspace = Workspace(name: "Package Drift", primaryPath: "/tmp/package-drift")
        workspace.enabledCapabilityIDs = ["jira-workflow"]
        context.insert(workspace)

        let jiraSkill = Skill(
            name: "Jira Agent",
            allowedTools: ["Read", "Bash"],
            behaviorInstructions: "Use Jira REST API."
        )
        jiraSkill.isGlobal = true
        context.insert(jiraSkill)

        let jiraConnector = Connector(
            name: "Jira-new",
            serviceType: "jira",
            connectorDescription: "Configured Jira",
            baseURL: "https://stanfordmed.atlassian.net",
            authMethod: "none"
        )
        jiraConnector.isGlobal = true
        jiraConnector.skill = jiraSkill
        context.insert(jiraConnector)

        let task = AgentTask(
            title: "Use Jira",
            goal: "List Jira tickets",
            workspace: workspace
        )
        context.insert(task)
        try context.save()

        let resolver = TaskCapabilityResolver(task: task)
        #expect(resolver.allBehaviorSkills.map(\.name) == ["Jira Agent"])
        #expect(resolver.allConnectors.map(\.id) == [jiraConnector.id])

        let prompt = AgentPromptBuilder.buildPrompt(for: task)
        #expect(prompt.contains("[Jira Agent]:"))
        #expect(prompt.contains("https://stanfordmed.atlassian.net"))
    }

    @Test("Enabled DevOps pack does not activate GitHub runtime resources")
    func enabledDevOpsPackDoesNotActivateGitHubRuntimeResources() throws {
        let manifest = try #require(
            AstraPackCatalog(localStorageRoot: nil).load().packs.first { $0.id == "astra.pack.devops" }
        )
        #expect(manifest.capabilityPackageIDs == ["github-workflow"])

        let container = try makeTaskCapabilityResolverContainer()
        let context = container.mainContext

        let workspace = Workspace(name: "DevOps Pack Only", primaryPath: "/tmp/devops-pack-only")
        workspace.enabledPackIDs = [manifest.id]
        context.insert(workspace)

        let githubSkill = Skill(
            name: "GitHub Agent",
            allowedTools: ["Read", "Bash"],
            behaviorInstructions: "Use the GitHub CLI for pull request and CI work."
        )
        githubSkill.isGlobal = true
        context.insert(githubSkill)

        let githubTool = LocalTool(
            name: "gh — GitHub CLI",
            toolDescription: "Run GitHub CLI commands",
            toolType: "cli",
            command: "gh"
        )
        githubTool.isGlobal = true
        context.insert(githubTool)

        let task = AgentTask(
            title: "Review PR Queue",
            goal: "Summarize the PR Queue and CI Review app template.",
            workspace: workspace
        )
        context.insert(task)
        try context.save()

        let resolver = TaskCapabilityResolver(task: task)
        #expect(resolver.allBehaviorSkills.map(\.name).isEmpty)
        #expect(resolver.allLocalTools.map(\.command).isEmpty)

        let prompt = AgentPromptBuilder.buildPrompt(for: task)
        #expect(!prompt.contains("[GitHub Agent]:"))
        #expect(!prompt.contains("gh — GitHub CLI"))
        #expect(!prompt.contains("Use the GitHub CLI for pull request and CI work."))
    }

    @Test("Provider launch keeps connector owned by selected skill")
    func providerLaunchKeepsConnectorOwnedBySelectedSkill() throws {
        let container = try makeTaskCapabilityResolverContainer()
        let context = container.mainContext

        let workspace = Workspace(name: "Jira Issue Review", primaryPath: "/tmp/jira-issue-review")
        context.insert(workspace)

        let jiraSkill = Skill(
            name: "Jira Agent",
            skillDescription: "Review support issues and ticket queues",
            allowedTools: ["Read", "Bash"],
            behaviorInstructions: "Use Jira REST APIs to review issues before answering."
        )
        jiraSkill.isGlobal = true
        context.insert(jiraSkill)

        let jiraConnector = Connector(
            name: "Jira-new",
            serviceType: "jira",
            connectorDescription: "Atlassian Jira REST API v3",
            baseURL: "https://stanfordmed.atlassian.net",
            authMethod: "basic"
        )
        jiraConnector.isGlobal = true
        jiraConnector.skill = jiraSkill
        jiraConnector.configKeys = ["JIRA_BASE_URL", "JIRA_PROJECTS"]
        jiraConnector.configValues = ["https://stanfordmed.atlassian.net", "SS"]
        context.insert(jiraConnector)

        let gcloudSkill = Skill(
            name: "GCloud Agent",
            skillDescription: "Inspect Google Cloud projects",
            allowedTools: ["Read", "Bash"],
            behaviorInstructions: "Use gcloud for cloud inventory."
        )
        gcloudSkill.isGlobal = true
        context.insert(gcloudSkill)

        let gcloudConnector = Connector(
            name: "Google Cloud",
            serviceType: "gcloud",
            connectorDescription: "Google Cloud API",
            baseURL: "https://cloud.google.com",
            authMethod: "none"
        )
        gcloudConnector.isGlobal = true
        gcloudConnector.skill = gcloudSkill
        context.insert(gcloudConnector)

        workspace.enabledGlobalConnectorIDs = [jiraConnector.id.uuidString, gcloudConnector.id.uuidString]

        let task = AgentTask(
            title: "review if i have open issues to address",
            goal: "review if i have open issues to address",
            workspace: workspace
        )
        task.skills = [jiraSkill]
        context.insert(task)
        try context.save()

        let scope = TaskCapabilityResolver(task: task)
            .resolvedScope(.providerLaunch(contextText: task.goal))

        #expect(scope.prunedForBrowserTask)
        #expect(scope.behaviorSkills.map(\.name) == ["Jira Agent"])
        #expect(scope.connectors.map(\.id) == [jiraConnector.id])
        #expect(scope.excludedSkillNames.contains("GCloud Agent"))

        let env = scope.resolver.resolvedEnvironmentVariables
        #expect(env["JIRA_JIRA_NEW_BASE_URL"] == "https://stanfordmed.atlassian.net")
        #expect(env["JIRA_JIRA_NEW_PROJECTS"] == "SS")
        #expect(env["JIRA_PROJECTS"] == nil)
        #expect(env["ASTRA_CONNECTORS"]?.contains(#""name":"Jira-new""#) == true)

        let prompt = AgentPromptBuilder.buildPrompt(for: task)
        #expect(prompt.contains("[Jira Agent]:"))
        #expect(prompt.contains("Jira-new"))
        #expect(prompt.contains("ASTRA_CONNECTORS"))
        #expect(!prompt.contains("[GCloud Agent]:"))
    }

    @Test("Provider launch includes every connector of a kept skill, but none of an excluded skill")
    func providerLaunchOverShareBoundaryIsSkillMembershipNotConnectorText() throws {
        // Pins the intentional credential-scope boundary established when the
        // per-connector text gate was removed: a connector ships iff its OWNING
        // skill is kept — even a connector whose own text is irrelevant to the
        // task (over-share within a kept skill is accepted in the single-user
        // trust model) — while connectors of excluded skills never ship.
        let container = try makeTaskCapabilityResolverContainer()
        let context = container.mainContext

        let workspace = Workspace(name: "Issue Review", primaryPath: "/tmp/issue-review-overshare")
        context.insert(workspace)

        let jiraSkill = Skill(
            name: "Jira Agent",
            skillDescription: "Review support issues and ticket queues",
            allowedTools: ["Read", "Bash"],
            behaviorInstructions: "Use Jira and Confluence REST APIs to review issues."
        )
        jiraSkill.isGlobal = true
        context.insert(jiraSkill)

        // Task-relevant connector owned by the kept skill.
        let jiraConnector = Connector(
            name: "Jira-new",
            serviceType: "jira",
            connectorDescription: "Atlassian Jira REST API v3",
            baseURL: "https://stanfordmed.atlassian.net",
            authMethod: "basic"
        )
        jiraConnector.isGlobal = true
        jiraConnector.skill = jiraSkill
        context.insert(jiraConnector)

        // Task-IRRELEVANT connector owned by the SAME kept skill. Its text does
        // not match "open issues" — pre-fix it was pruned, post-fix it ships
        // because the owning skill is kept.
        let confluenceConnector = Connector(
            name: "Confluence Wiki",
            serviceType: "confluence",
            connectorDescription: "Atlassian Confluence wiki page authoring",
            baseURL: "https://wiki.example.com",
            authMethod: "basic"
        )
        confluenceConnector.isGlobal = true
        confluenceConnector.skill = jiraSkill
        context.insert(confluenceConnector)

        // Connector owned by a skill the task does NOT keep — must stay excluded.
        let gcloudSkill = Skill(
            name: "GCloud Agent",
            skillDescription: "Inspect Google Cloud projects",
            allowedTools: ["Read", "Bash"],
            behaviorInstructions: "Use gcloud for cloud inventory."
        )
        gcloudSkill.isGlobal = true
        context.insert(gcloudSkill)

        let gcloudConnector = Connector(
            name: "Google Cloud",
            serviceType: "gcloud",
            connectorDescription: "Google Cloud API",
            baseURL: "https://cloud.google.com",
            authMethod: "none"
        )
        gcloudConnector.isGlobal = true
        gcloudConnector.skill = gcloudSkill
        context.insert(gcloudConnector)

        workspace.enabledGlobalConnectorIDs = [
            jiraConnector.id.uuidString,
            confluenceConnector.id.uuidString,
            gcloudConnector.id.uuidString
        ]

        let task = AgentTask(
            title: "review if i have open issues to address",
            goal: "review if i have open issues to address",
            workspace: workspace
        )
        task.skills = [jiraSkill]
        context.insert(task)
        try context.save()

        let scope = TaskCapabilityResolver(task: task)
            .resolvedScope(.providerLaunch(contextText: task.goal))

        let connectorIDs = Set(scope.connectors.map(\.id))
        // Both connectors of the kept skill ship (intentional over-share)...
        #expect(connectorIDs.contains(jiraConnector.id))
        #expect(connectorIDs.contains(confluenceConnector.id))
        // ...the excluded skill's connector never does (the security boundary).
        #expect(!connectorIDs.contains(gcloudConnector.id))
        #expect(scope.excludedSkillNames.contains("GCloud Agent"))

        let connectorsEnv = scope.resolver.resolvedEnvironmentVariables["ASTRA_CONNECTORS"] ?? ""
        #expect(connectorsEnv.contains(#""name":"Jira-new""#))
        #expect(connectorsEnv.contains(#""name":"Confluence Wiki""#))
        #expect(!connectorsEnv.contains(#""name":"Google Cloud""#))
    }

    @Test("Enabled package uses matched local tool owner when package skill name changed")
    func enabledPackageUsesMatchedLocalToolOwnerWhenPackageSkillNameChanged() throws {
        let container = try makeTaskCapabilityResolverContainer()
        let context = container.mainContext
        let graphPackage = try #require(PluginCatalog.builtInPackages.first { $0.id == "stanford-healthcare-graph-mail" })

        let workspace = Workspace(name: "Graph Mail Rename", primaryPath: "/tmp/graph-mail-rename")
        workspace.enabledCapabilityIDs = [graphPackage.id]
        context.insert(workspace)

        let legacySkill = Skill(
            name: "Stanford Graph Mail Agent",
            allowedTools: ["Read", "Bash"],
            behaviorInstructions: "Use the stanford-graph-mail helper."
        )
        legacySkill.isGlobal = true
        context.insert(legacySkill)

        let graphTool = LocalTool(
            name: "stanford-graph-mail",
            toolDescription: "Read SHC mail through Graph",
            toolType: "cli",
            command: "stanford-graph-mail"
        )
        graphTool.isGlobal = true
        graphTool.skill = legacySkill
        context.insert(graphTool)

        let task = AgentTask(
            title: "Read mail",
            goal: "Summarize recent SHC mail",
            workspace: workspace
        )
        context.insert(task)
        try context.save()

        let resolver = TaskCapabilityResolver(task: task)
        #expect(resolver.allBehaviorSkills.map(\.name) == ["Stanford Graph Mail Agent"])
        #expect(resolver.allLocalTools.map(\.command) == ["stanford-graph-mail"])

        let issues = CapabilityRuntimeIntegrityService.issues(
            for: task,
            packages: [graphPackage],
            checkExecutables: false
        )
        #expect(issues.isEmpty)
    }

    @Test("Runtime integrity reports selected package skill missing companion connector")
    func runtimeIntegrityReportsSelectedPackageSkillMissingConnector() throws {
        let container = try makeTaskCapabilityResolverContainer()
        let context = container.mainContext
        let jiraPackage = try #require(PluginCatalog.builtInPackages.first { $0.id == "jira-workflow" })

        let workspace = Workspace(name: "Legacy Jira Skill", primaryPath: "/tmp/legacy-jira-skill")
        context.insert(workspace)

        let jiraSkill = Skill(
            name: "Jira Agent",
            allowedTools: ["Read", "Bash"],
            behaviorInstructions: "Use Jira REST API."
        )
        jiraSkill.workspace = workspace
        context.insert(jiraSkill)

        let task = AgentTask(
            title: "Use Jira",
            goal: "List Jira tickets",
            workspace: workspace
        )
        task.skills = [jiraSkill]
        context.insert(task)
        try context.save()

        let issues = CapabilityRuntimeIntegrityService.issues(
            for: task,
            packages: [jiraPackage],
            checkExecutables: false
        )

        #expect(issues.map(\.source) == [.selectedPackageSkill])
        #expect(issues.map(\.resourceKind) == [.connector])
        #expect(issues.first?.resourceName == "Jira")
    }

    @Test("Runtime integrity does not require GitHub browser adapter for host-control package")
    func runtimeIntegrityDoesNotRequireGitHubBrowserAdapterForHostControlPackage() throws {
        let container = try makeTaskCapabilityResolverContainer()
        let context = container.mainContext
        let githubPackage = try #require(PluginCatalog.builtInPackages.first { $0.id == "github-workflow" })
        let packageSkill = try #require(githubPackage.skills.first)

        let workspace = Workspace(name: "GitHub Workspace", primaryPath: "/tmp/github-workspace")
        context.insert(workspace)

        let githubSkill = Skill(
            name: packageSkill.name,
            allowedTools: packageSkill.allowedTools,
            disallowedTools: packageSkill.disallowedTools,
            behaviorInstructions: packageSkill.behaviorInstructions
        )
        githubSkill.workspace = workspace
        context.insert(githubSkill)

        let task = AgentTask(
            title: "Use GitHub",
            goal: "List pull requests",
            workspace: workspace
        )
        task.skills = [githubSkill]
        context.insert(task)
        try context.save()

        let issues = CapabilityRuntimeIntegrityService.issues(
            for: task,
            packages: [githubPackage],
            checkExecutables: false
        )

        #expect(issues.isEmpty)
    }

    @Test("Runtime integrity checks selected GitHub host-control skill prerequisites")
    func runtimeIntegrityChecksSelectedGitHubHostControlSkillPrerequisites() throws {
        let container = try makeTaskCapabilityResolverContainer()
        let context = container.mainContext
        let githubPackage = try #require(PluginCatalog.builtInPackages.first { $0.id == "github-workflow" })
        let packageSkill = try #require(githubPackage.skills.first)

        let workspace = Workspace(name: "Selected GitHub Workspace", primaryPath: "/tmp/selected-github-workspace")
        context.insert(workspace)

        let githubSkill = Skill(
            name: packageSkill.name,
            allowedTools: packageSkill.allowedTools,
            disallowedTools: packageSkill.disallowedTools,
            behaviorInstructions: packageSkill.behaviorInstructions
        )
        githubSkill.workspace = workspace
        context.insert(githubSkill)

        let task = AgentTask(
            title: "Review PRs",
            goal: "List GitHub pull requests",
            workspace: workspace
        )
        task.skills = [githubSkill]
        context.insert(task)
        try context.save()

        let issues = CapabilityRuntimeIntegrityService.issues(
            for: task,
            packages: [githubPackage],
            checkExecutables: false,
            prerequisiteStatuses: [CommonCLIPrerequisites.githubAuth.id: .unauthenticated(detail: "not logged in")]
        )

        #expect(issues.map(\.source) == [.selectedPackageSkill])
        #expect(issues.map(\.resourceKind) == [.credential])
        #expect(issues.first?.resourceName == "GitHub login")
    }

    @Test("Runtime integrity ignores stale package skill snapshots")
    func runtimeIntegrityIgnoresStalePackageSkillSnapshots() throws {
        let container = try makeTaskCapabilityResolverContainer()
        let context = container.mainContext
        let githubPackage = try #require(PluginCatalog.builtInPackages.first { $0.id == "github-workflow" })

        let workspace = Workspace(name: "Email Workspace", primaryPath: "/tmp/email-workspace")
        context.insert(workspace)

        let liveSkill = Skill(
            name: "Jira Agent",
            allowedTools: ["Read", "Bash"],
            behaviorInstructions: "Use Jira REST API."
        )
        liveSkill.workspace = workspace
        context.insert(liveSkill)

        let task = AgentTask(
            title: "Summarize email",
            goal: "Summarize my emails from today",
            workspace: workspace
        )
        task.skills = [liveSkill]
        task.skillSnapshots = [
            SkillSnapshotConfig(
                id: UUID().uuidString,
                name: "GitHub Agent",
                icon: "chevron.left.forwardslash.chevron.right",
                description: "Old GitHub capability snapshot",
                allowedTools: ["Read", "Bash"],
                disallowedTools: [],
                customTools: [],
                behaviorInstructions: "Use GitHub CLI for GitHub work.",
                environmentKeys: [],
                environmentValues: [],
                isGlobal: false,
                connectorIDs: nil,
                localToolIDs: nil,
                connectorSnapshots: nil,
                localToolSnapshots: nil,
                createdAt: Date(),
                updatedAt: Date()
            )
        ]
        context.insert(task)
        try context.save()

        let issues = CapabilityRuntimeIntegrityService.issues(
            for: task,
            packages: [githubPackage],
            checkExecutables: false
        )

        #expect(issues.isEmpty)
    }

    @Test("Runtime integrity ignores stale snapshots for arbitrary package resources")
    func runtimeIntegrityIgnoresStaleSnapshotsForArbitraryPackageResources() throws {
        let container = try makeTaskCapabilityResolverContainer()
        let context = container.mainContext
        let futurePackage = PluginPackage(
            id: "future-workflow",
            name: "Future Workflow",
            icon: "sparkles",
            description: "Synthetic future capability package",
            author: "ASTRA",
            category: "Custom",
            tags: ["future"],
            version: "1.0.0",
            skills: [
                PluginSkill(
                    name: "Future Agent",
                    icon: "sparkles",
                    description: "Synthetic future package skill",
                    allowedTools: ["Read", "Bash"],
                    disallowedTools: [],
                    customTools: [],
                    behaviorInstructions: "Use future workflow resources.",
                    environmentKeys: [],
                    environmentValues: []
                )
            ],
            connectors: [
                PluginConnector(
                    name: "Future API",
                    serviceType: "future-api",
                    icon: "link",
                    description: "Synthetic future connector",
                    baseURL: "https://future.example.test",
                    authMethod: "apiKey",
                    credentialHints: [
                        .init(key: "FUTURE_API_KEY", hint: "API key")
                    ],
                    configHints: [],
                    notes: ""
                )
            ],
            localTools: [
                PluginLocalTool(
                    name: "futurectl",
                    description: "Synthetic future CLI",
                    icon: "terminal",
                    toolType: "cli",
                    command: "futurectl",
                    arguments: ""
                )
            ],
            templates: []
        )

        let workspace = Workspace(name: "Future Workspace", primaryPath: "/tmp/future-workspace")
        context.insert(workspace)

        let liveSkill = Skill(
            name: "Unrelated Agent",
            allowedTools: ["Read"],
            behaviorInstructions: "Handle unrelated work."
        )
        liveSkill.workspace = workspace
        context.insert(liveSkill)

        let task = AgentTask(
            title: "Unrelated work",
            goal: "Do work that no longer uses the future capability",
            workspace: workspace
        )
        task.skills = [liveSkill]
        task.skillSnapshots = [
            SkillSnapshotConfig(
                id: UUID().uuidString,
                name: "Future Agent",
                icon: "sparkles",
                description: "Old future capability snapshot",
                allowedTools: ["Read", "Bash"],
                disallowedTools: [],
                customTools: [],
                behaviorInstructions: "Use future workflow resources.",
                environmentKeys: [],
                environmentValues: [],
                isGlobal: false,
                connectorIDs: nil,
                localToolIDs: nil,
                connectorSnapshots: nil,
                localToolSnapshots: nil,
                createdAt: Date(),
                updatedAt: Date()
            )
        ]
        context.insert(task)
        try context.save()

        let issues = CapabilityRuntimeIntegrityService.issues(
            for: task,
            packages: [futurePackage],
            checkExecutables: false
        )

        #expect(issues.isEmpty)
    }

    @Test("Runtime integrity names disabled shared connector candidates")
    func runtimeIntegrityNamesDisabledSharedConnectorCandidate() throws {
        let container = try makeTaskCapabilityResolverContainer()
        let context = container.mainContext
        let jiraPackage = try #require(PluginCatalog.builtInPackages.first { $0.id == "jira-workflow" })

        let workspace = Workspace(name: "Disabled Shared Jira", primaryPath: "/tmp/disabled-shared-jira")
        context.insert(workspace)

        let jiraSkill = Skill(
            name: "Jira Agent",
            allowedTools: ["Read", "Bash"],
            behaviorInstructions: "Use Jira REST API."
        )
        jiraSkill.workspace = workspace
        context.insert(jiraSkill)

        let sharedJira = Connector(
            name: "Jira-new",
            serviceType: "jira",
            connectorDescription: "Configured Jira",
            baseURL: "https://stanfordmed.atlassian.net",
            authMethod: "none"
        )
        sharedJira.isGlobal = true
        context.insert(sharedJira)

        let task = AgentTask(
            title: "Use Jira",
            goal: "List Jira tickets",
            workspace: workspace
        )
        task.skills = [jiraSkill]
        context.insert(task)
        try context.save()

        let issues = CapabilityRuntimeIntegrityService.issues(
            for: task,
            packages: [jiraPackage],
            checkExecutables: false
        )

        let issue = try #require(issues.first)
        #expect(issue.resourceKind == .connector)
        #expect(issue.message.contains("Jira-new"))
        #expect(issue.message.contains("disabled in this workspace"))
    }

    @Test("Runtime integrity passes when enabled package resources resolve through package ID")
    func runtimeIntegrityPassesForResolvedEnabledPackageResources() throws {
        let container = try makeTaskCapabilityResolverContainer()
        let context = container.mainContext
        let jiraPackage = try #require(PluginCatalog.builtInPackages.first { $0.id == "jira-workflow" })

        let workspace = Workspace(name: "Resolved Package", primaryPath: "/tmp/resolved-package")
        workspace.enabledCapabilityIDs = ["jira-workflow"]
        context.insert(workspace)

        let jiraSkill = Skill(
            name: "Jira Agent",
            allowedTools: ["Read", "Bash"],
            behaviorInstructions: "Use Jira REST API."
        )
        jiraSkill.isGlobal = true
        context.insert(jiraSkill)

        let jiraConnector = Connector(
            name: "Configured Jira",
            serviceType: "jira",
            connectorDescription: "Configured Jira",
            baseURL: "https://stanfordmed.atlassian.net",
            authMethod: "none"
        )
        jiraConnector.isGlobal = true
        jiraConnector.skill = jiraSkill
        context.insert(jiraConnector)

        let task = AgentTask(
            title: "Use Jira",
            goal: "List Jira tickets",
            workspace: workspace
        )
        context.insert(task)
        try context.save()

        let issues = CapabilityRuntimeIntegrityService.issues(
            for: task,
            packages: [jiraPackage],
            checkExecutables: false
        )

        #expect(issues.isEmpty)
    }

    @Test("Runtime integrity blocks enabled package denied by catalog policy")
    func runtimeIntegrityBlocksPolicyDeniedEnabledPackage() throws {
        let container = try makeTaskCapabilityResolverContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Policy Runtime", primaryPath: "/tmp/policy-runtime")
        let package = PluginPackage(
            id: "runtime-draft",
            name: "Runtime Draft",
            icon: "puzzlepiece.extension",
            description: "Draft package",
            author: "Tests",
            category: "Tests",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: [],
            governance: .localDraft()
        )
        workspace.enabledCapabilityIDs = [package.id]
        context.insert(workspace)
        let task = AgentTask(title: "Use draft", goal: "Run draft capability", workspace: workspace)
        context.insert(task)
        try context.save()

        let issues = CapabilityRuntimeIntegrityService.issues(
            for: task,
            packages: [package],
            checkExecutables: false,
            policyContext: CapabilityCatalogPolicyContext.workspaceUser(
                workspace: workspace,
                currentAppVersion: SemanticVersion(1, 0, 0)
            )
        )

        #expect(issues.map(\.resourceKind) == [.policy])
        #expect(issues.first?.message.contains("catalog policy blocks runtime activation") == true)
    }

    // Shared setup: an enabled github-workflow capability whose workspace skill +
    // tool instances exist but carry MINIMAL text, so launch-time pruning drops
    // them for any task that doesn't literally mention "github"/"gh". The package
    // definition itself stays rich, so packageMatchesTaskIntent can still fire.
    private func makeGitHubEnabledWorkspace(in context: ModelContext, name: String) throws -> (Workspace, PluginPackage) {
        let githubPackage = try #require(PluginCatalog.builtInPackages.first { $0.id == "github-workflow" })
        let workspace = Workspace(name: name, primaryPath: "/tmp/\(name)")
        workspace.enabledCapabilityIDs = [githubPackage.id]
        context.insert(workspace)

        let githubSkill = Skill(
            name: "GitHub Agent",
            skillDescription: "x",
            allowedTools: ["Read", "Bash"],
            behaviorInstructions: "x"
        )
        githubSkill.workspace = workspace
        context.insert(githubSkill)

        let githubTool = LocalTool(
            name: "gh — GitHub CLI",
            toolDescription: "x",
            toolType: "cli",
            command: "gh"
        )
        githubTool.workspace = workspace
        context.insert(githubTool)
        return (workspace, githubPackage)
    }

    @Test("Launch pruning drops an enabled capability that an unrelated task doesn't need")
    func enabledCapabilityPrunedFromUnrelatedTaskScope() throws {
        let container = try makeTaskCapabilityResolverContainer()
        let context = container.mainContext
        let (workspace, _) = try makeGitHubEnabledWorkspace(in: context, name: "github-prune")

        let task = AgentTask(
            title: "Bake a cake",
            goal: "Bake a chocolate sponge cake and write the recipe",
            workspace: workspace
        )
        context.insert(task)
        try context.save()

        let scope = TaskCapabilityResolver(task: task)
            .resolvedScope(.providerLaunch(contextText: task.goal))

        // Advisory pruning (focus): the enabled capability is reachable in the
        // workspace but, since this task doesn't need it, its verbose instructions
        // and tool are kept out of the launch scope — least privilege by default.
        #expect(scope.prunedForBrowserTask)
        #expect(!scope.behaviorSkills.map(\.name).contains("GitHub Agent"))
        #expect(!scope.localTools.contains { $0.command == "gh" })
        #expect(scope.excludedSkillNames.contains("GitHub Agent"))
    }

    @Test("Provider launch context activates CLI tools for follow-up scoped requests")
    func providerLaunchContextActivatesCLIToolsForFollowUpScopedRequests() throws {
        let container = try makeTaskCapabilityResolverContainer()
        let context = container.mainContext
        let (workspace, _) = try makeGitHubEnabledWorkspace(in: context, name: "github-followup-scope")

        let task = AgentTask(
            title: "Bake a cake",
            goal: "Bake a chocolate sponge cake and write the recipe",
            workspace: workspace
        )
        context.insert(task)
        try context.save()

        #expect(AgentRuntimeProcessRunner.runtimeLocalToolCommands(for: task).isEmpty)
        #expect(!AgentRuntimeProcessRunner.hasActiveCLITools(task))

        let followUpContext = "Use GitHub to list the open pull requests for this repository."
        #expect(AgentRuntimeProcessRunner.runtimeLocalToolCommands(for: task, contextText: followUpContext) == ["gh"])
        #expect(AgentRuntimeProcessRunner.hasActiveCLITools(task, contextText: followUpContext))
    }

    @Test("Provider launch context activates GitHub package for terminal PR abbreviations")
    func providerLaunchContextActivatesGitHubPackageForTerminalPRAbbreviations() throws {
        let container = try makeTaskCapabilityResolverContainer()
        let context = container.mainContext
        let (workspace, githubPackage) = try makeGitHubEnabledWorkspace(in: context, name: "github-pr-abbreviation-scope")

        let task = AgentTask(
            title: "Bake a cake",
            goal: "Bake a chocolate sponge cake and write the recipe",
            workspace: workspace
        )
        context.insert(task)
        try context.save()

        let terminalPluralContext = "Review PRs"
        let scope = TaskCapabilityResolver(task: task)
            .resolvedScope(.providerLaunch(contextText: terminalPluralContext))
        #expect(scope.enabledPackageIDs.contains(githubPackage.id))
        #expect(HostControlPlaneMCPProjection.enabledToolNames(
            task: task,
            environment: .host,
            contextText: terminalPluralContext
        ) == ["github"])
    }

    @Test("GitHub package intent ignores ci substrings and generic UI issues")
    func githubPackageIntentIgnoresCISubstringsAndGenericUIIssues() throws {
        let container = try makeTaskCapabilityResolverContainer()
        let context = container.mainContext
        let (workspace, githubPackage) = try makeGitHubEnabledWorkspace(in: context, name: "github-token-scope")

        let unrelatedTasks = [
            AgentTask(
                title: "Fix special case",
                goal: "Fix the special-case regression in local validation",
                workspace: workspace
            ),
            AgentTask(
                title: "Fix UI issue",
                goal: "Fix a UI issue in the settings screen",
                workspace: workspace
            )
        ]
        let ciTask = AgentTask(
            title: "Review CI",
            goal: "Review the CI failure for this branch",
            workspace: workspace
        )
        for task in unrelatedTasks + [ciTask] {
            context.insert(task)
        }
        try context.save()

        for task in unrelatedTasks {
            let scope = TaskCapabilityResolver(task: task)
                .resolvedScope(.providerLaunch(contextText: task.goal))
            #expect(!scope.enabledPackageIDs.contains(githubPackage.id), "Unexpected GitHub activation for: \(task.goal)")
            #expect(HostControlPlaneMCPProjection.enabledToolNames(
                task: task,
                environment: .host,
                contextText: task.goal
            ).isEmpty)
        }

        #expect(HostControlPlaneMCPProjection.enabledToolNames(
            task: ciTask,
            environment: .host,
            contextText: ciTask.goal
        ) == ["github"])
    }

    @Test("A pruned-but-existing enabled capability is not a launch failure")
    func prunedEnabledCapabilityIsNotALaunchFailure() throws {
        let container = try makeTaskCapabilityResolverContainer()
        let context = container.mainContext
        let (workspace, githubPackage) = try makeGitHubEnabledWorkspace(in: context, name: "github-integrity")

        // Matches the github-workflow package intent ("pull requests") but NOT the
        // minimal workspace skill/tool text — so the package is enforced while its
        // skill + tool get pruned from scope. This is the exact shape that used to
        // hard-fail with capability_runtime_resources_missing.
        let task = AgentTask(
            title: "List pull requests",
            goal: "list open pull requests for me",
            workspace: workspace
        )
        context.insert(task)
        try context.save()

        // Precondition: the skill + tool really are pruned from the launch scope.
        let scope = TaskCapabilityResolver(task: task)
            .resolvedScope(.providerLaunch(contextText: task.goal))
        #expect(!scope.behaviorSkills.map(\.name).contains("GitHub Agent"))
        #expect(!scope.localTools.contains { $0.command == "gh" })

        let issues = CapabilityRuntimeIntegrityService.issues(
            for: task,
            packages: [githubPackage],
            checkExecutables: false,
            scope: .providerLaunch(contextText: task.goal)
        )

        // The regression: the real failure reported missing resource_kinds=skill,
        // local_tool. Because the skill + tool exist in the workspace (reachable),
        // pruning them for focus must not be reported as missing.
        #expect(!issues.contains { $0.resourceKind == .skill })
        #expect(!issues.contains { $0.resourceKind == .localTool })
    }

    @Test("Provider launch checks Google Drive browser package by product intent")
    func providerLaunchChecksGoogleDriveBrowserPackageByProductIntent() throws {
        let container = try makeTaskCapabilityResolverContainer()
        let context = container.mainContext
        let package = PluginPackage(
            id: "local-google-drive-browser",
            name: "Google Drive Browser",
            icon: "folder.badge.gearshape",
            description: "Adds Google Drive browser policy checks",
            author: "ASTRA",
            category: "Browser",
            tags: ["google-drive"],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: [],
            browserAdapters: [BrowserSiteAdapterID.googleDrive],
            governance: .localDraft()
        )

        let workspace = Workspace(name: "Google Drive Integrity", primaryPath: "/tmp/google-drive-integrity")
        workspace.enabledCapabilityIDs = [package.id]
        context.insert(workspace)

        let task = AgentTask(
            title: "Read Drive file",
            goal: "read a Google Drive file",
            workspace: workspace
        )
        context.insert(task)
        try context.save()

        let issues = CapabilityRuntimeIntegrityService.issues(
            for: task,
            packages: [package],
            checkExecutables: false,
            policyContext: CapabilityCatalogPolicyContext.workspaceUser(
                workspace: workspace,
                currentAppVersion: SemanticVersion(1, 0, 0)
            ),
            scope: .providerLaunch(contextText: task.goal)
        )

        #expect(issues.contains {
            $0.packageID == package.id &&
                $0.resourceKind == CapabilityRuntimeIntegrityIssue.ResourceKind.policy &&
                $0.message.contains("catalog policy blocks runtime activation")
        })
    }

    @Test("Capability roster advertises enabled capabilities with an invocation hint")
    func capabilityRosterAdvertisesEnabledCapabilities() throws {
        let container = try makeTaskCapabilityResolverContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "github-roster", primaryPath: "/tmp/github-roster")
        workspace.enabledCapabilityIDs = ["github-workflow"]
        context.insert(workspace)
        try context.save()

        let roster = try #require(CapabilityRosterBuilder.roster(for: workspace))
        #expect(roster.contains("GitHub"))
        // GitHub capability now routes through the GitHub Agent skill (host-control MCP),
        // not a direct `gh` Bash command, so the invocation hint reflects the skill path.
        #expect(roster.contains("GitHub Agent"))
        // Awareness must instruct the agent to surface, not silently skip, gaps.
        #expect(roster.lowercased().contains("do not silently skip"))
    }

    @Test("Capability roster is nil when no capabilities are enabled")
    func capabilityRosterNilWhenNothingEnabled() throws {
        let container = try makeTaskCapabilityResolverContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "empty-roster", primaryPath: "/tmp/empty-roster")
        context.insert(workspace)
        try context.save()

        #expect(CapabilityRosterBuilder.roster(for: workspace) == nil)
    }

    @Test("Runtime integrity checks MCP stdio command readiness")
    func runtimeIntegrityChecksMCPStdioCommandReadiness() throws {
        let container = try makeTaskCapabilityResolverContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "MCP Runtime", primaryPath: "/tmp/mcp-runtime")
        var package = PluginPackage(
            id: "runtime-mcp",
            name: "Runtime MCP",
            icon: "server.rack",
            description: "MCP package",
            author: "Tests",
            category: "Tests",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: [],
            governance: .builtInApproved(riskLevel: .high)
        )
        package.mcpServers = [
            PluginMCPServer(
                id: "missing",
                displayName: "Missing MCP",
                transport: .stdio,
                command: "astra-test-missing-mcp-binary-\(UUID().uuidString)"
            )
        ]
        workspace.enabledCapabilityIDs = [package.id]
        context.insert(workspace)
        let task = AgentTask(title: "Use MCP", goal: "Run MCP capability", workspace: workspace)
        context.insert(task)
        try context.save()

        let issues = CapabilityRuntimeIntegrityService.issues(
            for: task,
            packages: [package]
        )

        #expect(issues.map(\.resourceKind) == [.mcpServer])
        #expect(issues.first?.message.contains("not installed or not executable") == true)
    }

    @Test("Browser task prompt prunes unrelated selected capabilities")
    func browserTaskPromptPrunesUnrelatedSelectedCapabilities() throws {
        let container = try makeTaskCapabilityResolverContainer()
        let context = container.mainContext

        let workspace = Workspace(name: "Browser Workspace", primaryPath: "/tmp/browser-workspace")
        context.insert(workspace)

        let gcloudSkill = Skill(
            name: "GCloud Agent",
            skillDescription: "Manage GCP resources and deployments",
            allowedTools: ["Read", "Bash"],
            behaviorInstructions: "GCloud must inspect projects and deployment regions before doing cloud work.",
            environmentVariables: ["GCP_PROJECT": "prod-project"]
        )
        gcloudSkill.isBuiltIn = true
        gcloudSkill.workspace = workspace
        context.insert(gcloudSkill)

        let gcloudTool = LocalTool(
            name: "gcloud",
            toolDescription: "Google Cloud CLI",
            command: "gcloud"
        )
        gcloudTool.skill = gcloudSkill
        context.insert(gcloudTool)

        let mailSkill = Skill(
            name: "Stanford Mail via Apple Mail Agent",
            skillDescription: "Read Stanford email through Apple Mail",
            allowedTools: ["Read", "Bash"],
            behaviorInstructions: "Stanford mail tasks must use the Apple Mail mailbox bridge."
        )
        mailSkill.isBuiltIn = true
        mailSkill.workspace = workspace
        context.insert(mailSkill)

        let task = AgentTask(
            title: "Translate Alvaro1 t",
            goal: "open the doccument called 'Alvaro1 t' and translate all text to Spanish",
            workspace: workspace
        )
        task.skills = [gcloudSkill, mailSkill]
        context.insert(task)
        try context.save()

        ShelfBrowserBridgeRegistry.shared.update(
            endpoint: "http://127.0.0.1:49152",
            currentURL: "https://drive.google.com/drive/home",
            currentTitle: "Google Drive",
            taskID: task.id,
            isPresented: true,
            isEnabled: true
        )
        defer { ShelfBrowserBridgeRegistry.shared.reset() }

        let scope = TaskCapabilityResolver(task: task).promptScope()
        #expect(scope.prunedForBrowserTask)
        #expect(scope.excludedSkillNames.contains("GCloud Agent"))
        #expect(scope.excludedSkillNames.contains("Stanford Mail via Apple Mail Agent"))

        let prompt = AgentPromptBuilder.buildPrompt(for: task)
        #expect(prompt.contains("Shelf Browser Session:"))
        #expect(prompt.contains("astra-browser google-drive-open"))
        #expect(!prompt.contains("[GCloud Agent]:"))
        #expect(!prompt.contains("GCloud must inspect projects"))
        #expect(!prompt.contains("Available CLI/Script Tools"))
        #expect(!prompt.contains("`gcloud`"))
        #expect(!prompt.contains("[Stanford Mail via Apple Mail Agent]:"))
        #expect(!prompt.contains("Apple Mail mailbox bridge"))
        #expect(!prompt.contains("GCP_PROJECT"))
    }

    @Test("Browser artifact task prunes unrelated disallowing skill instructions")
    func browserArtifactTaskPrunesUnrelatedDisallowingSkillInstructions() throws {
        let container = try makeTaskCapabilityResolverContainer()
        let context = container.mainContext

        let workspace = Workspace(name: "Masterball Workspace", primaryPath: "/tmp/masterball-workspace")
        context.insert(workspace)

        let mailSkill = Skill(
            name: "Stanford Graph Mail Agent",
            skillDescription: "Read Stanford email through Microsoft Graph",
            allowedTools: ["Read", "Bash"],
            disallowedTools: ["Write", "Edit"],
            behaviorInstructions: "Do NOT use Write or Edit. Only inspect mailbox content."
        )
        mailSkill.workspace = workspace
        context.insert(mailSkill)

        let task = AgentTask(
            title: "Create a masterball web page",
            goal: "create a web page with a masterball solver in javascript",
            workspace: workspace
        )
        task.skills = [mailSkill]
        context.insert(task)
        try context.save()

        ShelfBrowserBridgeRegistry.shared.update(
            endpoint: "http://127.0.0.1:49152",
            currentURL: "about:blank",
            currentTitle: "Preview",
            taskID: task.id,
            isPresented: true,
            isEnabled: true
        )
        defer { ShelfBrowserBridgeRegistry.shared.reset() }

        let scope = TaskCapabilityResolver(task: task).promptScope()
        #expect(scope.prunedForBrowserTask)
        #expect(scope.excludedSkillNames.contains("Stanford Graph Mail Agent"))
        #expect(scope.behaviorSkills.isEmpty)

        let prompt = AgentPromptBuilder.buildPrompt(for: task)
        #expect(prompt.contains("Shelf Browser Session:"))
        #expect(!prompt.contains("[Stanford Graph Mail Agent]:"))
        #expect(!prompt.contains("Do NOT use Write or Edit"))
    }

    @Test("Standalone artifact task prunes unrelated disallowing skills from prompt and runtime scope")
    func standaloneArtifactTaskPrunesUnrelatedDisallowingSkillsFromPromptAndRuntimeScope() throws {
        ShelfBrowserBridgeRegistry.shared.reset()
        let container = try makeTaskCapabilityResolverContainer()
        let context = container.mainContext

        let workspace = Workspace(name: "Masterball Workspace", primaryPath: "/tmp/masterball-standalone-workspace")
        context.insert(workspace)

        let mailSkill = Skill(
            name: "Stanford Graph Mail Agent",
            skillDescription: "Read Stanford email through Microsoft Graph",
            allowedTools: ["Read", "Bash"],
            disallowedTools: ["Write", "Edit"],
            behaviorInstructions: "Do NOT use Write or Edit. Only inspect mailbox content.",
            environmentVariables: ["MAIL_PROFILE": "stanford"]
        )
        mailSkill.workspace = workspace
        context.insert(mailSkill)

        let mailTool = LocalTool(
            name: "stanford-graph-mail",
            toolDescription: "Read Stanford mail",
            command: "stanford-graph-mail"
        )
        mailTool.skill = mailSkill
        context.insert(mailTool)

        let task = AgentTask(
            title: "Create Masterball puzzle solver webpage",
            goal: "create a web page with a masterball solver in javascript",
            workspace: workspace
        )
        task.skills = [mailSkill]
        context.insert(task)
        try context.save()

        TaskCapabilitySnapshotter.capture(for: task)

        let scope = TaskCapabilityResolver(task: task).promptScope()
        #expect(scope.prunedForBrowserTask)
        #expect(scope.excludedSkillNames.contains("Stanford Graph Mail Agent"))
        #expect(scope.behaviorSkills.isEmpty)
        #expect(scope.localTools.isEmpty)

        let prompt = AgentPromptBuilder.buildPrompt(for: task)
        #expect(!prompt.contains("[Stanford Graph Mail Agent]:"))
        #expect(!prompt.contains("Do NOT use Write or Edit"))
        #expect(!prompt.contains("stanford-graph-mail"))

        #expect(AgentRuntimeProcessRunner.runtimeLocalToolCommands(for: task).isEmpty)
        let env = AgentRuntimeProcessRunner.scopedEnvironmentVariables(for: task)
        #expect(env["MAIL_PROFILE"] == nil)
        #expect(env["ASTRA_MAIL_REGISTRY_PATH"] == nil)
    }

    @Test("Masterball artifact task prunes live Graph Mail skill despite create safety text")
    func masterballArtifactTaskPrunesLiveGraphMailSkillDespiteCreateSafetyText() throws {
        ShelfBrowserBridgeRegistry.shared.reset()
        let container = try makeTaskCapabilityResolverContainer()
        let context = container.mainContext

        let workspace = Workspace(name: "Masterball Workspace", primaryPath: "/tmp/masterball-live-mail-workspace")
        context.insert(workspace)

        let mailSkill = Skill(
            name: "Stanford Graph Mail Agent",
            skillDescription: "Search and read locally signed-in Microsoft 365 mail via Graph PowerShell",
            allowedTools: ["Read", "Bash"],
            disallowedTools: ["Write", "Edit"],
            behaviorInstructions: """
            You are a Stanford Graph Mail assistant. Use the `stanford-graph-mail` CLI via Bash to work with the locally signed-in Stanford-family Microsoft 365 mailbox.
            SAFETY
            - Read only. Do not send, reply, forward, delete, move, archive, mark read/unread, create rules, download attachments, or modify mailbox state.
            - Treat email content as sensitive.
            Do NOT use these tools: Write, Edit.
            """
        )
        mailSkill.workspace = workspace
        context.insert(mailSkill)

        let mailTool = LocalTool(
            name: "stanford-graph-mail",
            toolDescription: "Read the locally signed-in Microsoft 365 mailbox through Microsoft Graph PowerShell",
            command: "stanford-graph-mail"
        )
        mailTool.skill = mailSkill
        context.insert(mailTool)

        let task = AgentTask(
            title: "Create Masterball puzzle web solver",
            goal: "createa web page wit a masterball (similar to rubicks cube but as aball ) with a solver in javascript",
            workspace: workspace
        )
        task.skills = [mailSkill]
        context.insert(task)
        try context.save()

        TaskCapabilitySnapshotter.capture(for: task)

        let scope = TaskCapabilityResolver(task: task).promptScope()
        #expect(scope.prunedForBrowserTask)
        #expect(scope.behaviorSkills.isEmpty)
        #expect(scope.localTools.isEmpty)
        #expect(scope.excludedSkillNames.contains("Stanford Graph Mail Agent"))

        let prompt = AgentPromptBuilder.buildPrompt(for: task)
        #expect(!prompt.contains("[Stanford Graph Mail Agent]:"))
        #expect(!prompt.contains("stanford-graph-mail"))
        #expect(!prompt.contains("create rules"))
        #expect(AgentRuntimeProcessRunner.runtimeLocalToolCommands(for: task).isEmpty)
    }

    @Test("Activation scope prunes irrelevant selected mail skill")
    func activationScopePrunesIrrelevantSelectedMailSkill() throws {
        ShelfBrowserBridgeRegistry.shared.reset()
        let container = try makeTaskCapabilityResolverContainer()
        let context = container.mainContext

        let workspace = Workspace(name: "General Workspace", primaryPath: "/tmp/general-mail-workspace")
        context.insert(workspace)

        let mailSkill = Skill(
            name: "Stanford Graph Mail Agent",
            skillDescription: "Search and read locally signed-in Microsoft 365 mail via Graph PowerShell",
            allowedTools: ["Read", "Bash"],
            behaviorInstructions: "Read only. Do not create rules or modify mailbox state."
        )
        mailSkill.workspace = workspace
        context.insert(mailSkill)

        let task = AgentTask(
            title: "Explain identity",
            goal: "explain who you are",
            workspace: workspace
        )
        task.skills = [mailSkill]
        context.insert(task)
        try context.save()

        let scope = TaskCapabilityResolver(task: task).activationScope(contextText: task.goal)
        #expect(scope.prunedForBrowserTask)
        #expect(scope.behaviorSkills.isEmpty)
        #expect(scope.excludedSkillNames.contains("Stanford Graph Mail Agent"))
    }

    @Test("Plain non-mail task prompt prunes irrelevant live Graph Mail capability")
    func plainNonMailTaskPromptPrunesIrrelevantLiveGraphMailCapability() throws {
        ShelfBrowserBridgeRegistry.shared.reset()
        let container = try makeTaskCapabilityResolverContainer()
        let context = container.mainContext

        let workspace = Workspace(name: "Plain Workspace", primaryPath: "/tmp/plain-mail-workspace")
        context.insert(workspace)

        let mailSkill = Skill(
            name: "Stanford Graph Mail Agent",
            skillDescription: "Search and read locally signed-in Microsoft 365 mail via Graph PowerShell",
            allowedTools: ["Read", "Bash"],
            disallowedTools: ["Write", "Edit"],
            behaviorInstructions: """
            You are a Stanford Graph Mail assistant. Use the `stanford-graph-mail` CLI via Bash to work with the locally signed-in Stanford-family Microsoft 365 mailbox.
            SAFETY
            - Read only. Do not send, reply, forward, delete, move, archive, mark read/unread, create rules, download attachments, or modify mailbox state.
            - Treat email content as sensitive.
            Do NOT use these tools: Write, Edit.
            """
        )
        mailSkill.workspace = workspace
        context.insert(mailSkill)

        let mailTool = LocalTool(
            name: "stanford-graph-mail",
            toolDescription: "Read the locally signed-in Microsoft 365 mailbox through Microsoft Graph PowerShell",
            command: "stanford-graph-mail"
        )
        mailTool.skill = mailSkill
        context.insert(mailTool)

        let task = AgentTask(
            title: "Reply exactly",
            goal: "Without creating files or using tools, reply with exactly ASTRA_REAL_MASTERBALL_OK and nothing else.",
            workspace: workspace
        )
        task.skills = [mailSkill]
        context.insert(task)
        try context.save()

        TaskCapabilitySnapshotter.capture(for: task)

        let scope = TaskCapabilityResolver(task: task).promptScope()
        #expect(scope.prunedForBrowserTask)
        #expect(scope.behaviorSkills.isEmpty)
        #expect(scope.localTools.isEmpty)
        #expect(scope.excludedSkillNames.contains("Stanford Graph Mail Agent"))

        let prompt = AgentPromptBuilder.buildPrompt(for: task)
        #expect(!prompt.contains("[Stanford Graph Mail Agent]:"))
        #expect(!prompt.contains("stanford-graph-mail"))
        #expect(!prompt.contains("create rules"))
        #expect(AgentRuntimeProcessRunner.runtimeLocalToolCommands(for: task).isEmpty)
    }

    @Test("Mail task keeps matching Graph Mail skill")
    func mailTaskKeepsMatchingGraphMailSkill() throws {
        ShelfBrowserBridgeRegistry.shared.reset()
        let container = try makeTaskCapabilityResolverContainer()
        let context = container.mainContext

        let workspace = Workspace(name: "Mail Workspace", primaryPath: "/tmp/matching-mail-workspace")
        context.insert(workspace)

        let mailSkill = Skill(
            name: "Stanford Graph Mail Agent",
            skillDescription: "Search and read locally signed-in Microsoft 365 email and mail via Graph PowerShell",
            allowedTools: ["Read", "Bash"],
            behaviorInstructions: "Use stanford-graph-mail for email search and message summaries."
        )
        mailSkill.workspace = workspace
        context.insert(mailSkill)

        let mailTool = LocalTool(
            name: "stanford-graph-mail",
            toolDescription: "Read Stanford email through Graph",
            command: "stanford-graph-mail"
        )
        mailTool.skill = mailSkill
        context.insert(mailTool)

        let task = AgentTask(
            title: "Summarize email",
            goal: "summarize my last email",
            workspace: workspace
        )
        task.skills = [mailSkill]
        context.insert(task)
        try context.save()

        let scope = TaskCapabilityResolver(task: task).promptScope()
        #expect(scope.prunedForBrowserTask)
        #expect(scope.behaviorSkills.map(\.name) == ["Stanford Graph Mail Agent"])
        #expect(scope.localTools.map(\.command) == ["stanford-graph-mail"])
        #expect(scope.excludedSkillNames.isEmpty)

        let activationScope = TaskCapabilityResolver(task: task).activationScope(contextText: task.goal)
        #expect(activationScope.prunedForBrowserTask)
        #expect(activationScope.behaviorSkills.map(\.name) == ["Stanford Graph Mail Agent"])
        #expect(activationScope.localTools.map(\.command) == ["stanford-graph-mail"])
        #expect(activationScope.excludedSkillNames.isEmpty)
    }

    @Test("Standalone artifact task keeps matching artifact skills")
    func standaloneArtifactTaskKeepsMatchingArtifactSkills() throws {
        ShelfBrowserBridgeRegistry.shared.reset()
        let container = try makeTaskCapabilityResolverContainer()
        let context = container.mainContext

        let workspace = Workspace(name: "Website Workspace", primaryPath: "/tmp/website-workspace")
        context.insert(workspace)

        let websiteSkill = Skill(
            name: "Website Builder",
            skillDescription: "Build websites, webpages, HTML, CSS, and JavaScript demos",
            allowedTools: ["Read", "Write", "Edit"],
            behaviorInstructions: "Create polished standalone website artifacts."
        )
        websiteSkill.workspace = workspace
        context.insert(websiteSkill)

        let task = AgentTask(
            title: "Create homepage",
            goal: "create a responsive web page in html and javascript",
            workspace: workspace
        )
        task.skills = [websiteSkill]
        context.insert(task)
        try context.save()

        let scope = TaskCapabilityResolver(task: task).promptScope()
        #expect(scope.prunedForBrowserTask)
        #expect(scope.behaviorSkills.map(\.name) == ["Website Builder"])

        let prompt = AgentPromptBuilder.buildPrompt(for: task)
        #expect(prompt.contains("[Website Builder]:"))
        #expect(prompt.contains("Create polished standalone website artifacts."))
    }

    @Test("Runtime local tool resolution ignores unsafe persisted tools")
    func runtimeLocalToolResolutionIgnoresUnsafePersistedTools() throws {
        let container = try makeTaskCapabilityResolverContainer()
        let context = container.mainContext

        let workspace = Workspace(name: "Unsafe Tool Workspace", primaryPath: "/tmp/unsafe-tool-workspace")
        context.insert(workspace)

        let unsafeTool = LocalTool(
            name: "Unsafe",
            toolDescription: "Shell-shaped persisted tool",
            toolType: "cli",
            command: "sh -c curl https://evil.example",
            arguments: ""
        )
        unsafeTool.workspace = workspace
        context.insert(unsafeTool)

        let task = AgentTask(title: "Use tools", goal: "Run available tools", workspace: workspace)
        context.insert(task)
        try context.save()

        #expect(TaskCapabilityResolver(task: task).allLocalTools.isEmpty)
        #expect(!AgentPromptBuilder.buildPrompt(for: task).contains("Unsafe"))
    }

    @Test("Browser prompt exposes enabled site adapter commands")
    func browserPromptExposesEnabledSiteAdapterCommands() throws {
        let container = try makeTaskCapabilityResolverContainer()
        let context = container.mainContext

        let workspace = Workspace(name: "Drive Browser Workspace", primaryPath: "/tmp/drive-browser-workspace")
        workspace.enabledCapabilityIDs = ["google-drive-browser"]
        context.insert(workspace)

        let task = AgentTask(
            title: "Open Drive file",
            goal: "Open the Drive file named Untitled document",
            workspace: workspace
        )
        context.insert(task)
        try context.save()

        let adapters = TaskCapabilityResolver.enabledBrowserAdapters(
            for: workspace,
            packages: [
                PluginPackage(
                    id: "google-drive-browser",
                    name: "Google Drive Browser",
                    icon: "folder",
                    description: "Drive browser adapter",
                    author: "ASTRA",
                    category: "Browser",
                    tags: [],
                    version: "1.0.0",
                    skills: [],
                    connectors: [],
	                localTools: [],
	                templates: [],
	                browserAdapters: [BrowserSiteAdapterID.googleDrive],
	                governance: .builtInApproved(riskLevel: .high)
	            )
	        ]
	    )
        #expect(adapters == [BrowserSiteAdapterID.googleDrive])

        ShelfBrowserBridgeRegistry.shared.update(
            endpoint: "http://127.0.0.1:49152",
            currentURL: "https://drive.google.com/drive/home",
            currentTitle: "Google Drive",
            taskID: task.id,
            isPresented: true,
            isEnabled: true,
            enabledBrowserAdapters: adapters
        )
        defer { ShelfBrowserBridgeRegistry.shared.reset() }

        let prompt = ShelfBrowserBridgeRegistry.shared.promptContext(for: task.id)
        #expect(prompt?.contains("Enabled browser site adapters: googleDrive") == true)
        #expect(prompt?.contains("astra-browser google-drive-open") == true)
    }

    @Test("Hidden adapter-only browser state does not expose browser bridge to unrelated tasks")
    func hiddenAdapterOnlyBrowserStateDoesNotExposeBrowserBridgeToUnrelatedTasks() throws {
        let container = try makeTaskCapabilityResolverContainer()
        let context = container.mainContext

        let workspace = Workspace(name: "Docker Browser Adapter Workspace", primaryPath: "/tmp/docker-browser-adapter-workspace")
        context.insert(workspace)

        let task = AgentTask(
            title: "Summarize folder contents",
            goal: "summarize the contents of this folder using the configured Docker image",
            workspace: workspace
        )
        context.insert(task)
        try context.save()

        ShelfBrowserBridgeRegistry.shared.update(
            endpoint: "http://127.0.0.1:49152",
            currentURL: nil,
            currentTitle: nil,
            taskID: task.id,
            isPresented: false,
            isEnabled: true,
            enabledBrowserAdapters: [BrowserSiteAdapterID.github]
        )
        defer { ShelfBrowserBridgeRegistry.shared.reset() }

        let contextText = "summarize the contents of this folder using the configured Docker image"

        #expect(!TaskCapabilityResolver.shouldExposeBrowserBridge(for: task, contextText: contextText))
        #expect(AgentRuntimeProcessRunner.scopedEnvironmentVariables(for: task, contextText: contextText)["ASTRA_BROWSER_URL"] == nil)
    }

    @Test("Pack-hidden browser shelf suppresses runtime browser bridge")
    func packHiddenBrowserShelfSuppressesRuntimeBrowserBridge() throws {
        let container = try makeTaskCapabilityResolverContainer()
        let context = container.mainContext

        let workspace = Workspace(name: "DevOps Browser Hidden Workspace", primaryPath: "/tmp/devops-browser-hidden")
        workspace.enabledPackIDs = ["astra.pack.devops"]
        context.insert(workspace)

        let task = AgentTask(
            title: "Inspect current browser page",
            goal: "Use the ASTRA browser to inspect the current page.",
            workspace: workspace
        )
        context.insert(task)
        try context.save()

        let policy = AstraPackWorkspaceProfileProvider.shelfAvailabilityPolicy(for: workspace)
        let shelfContext = ShelfAvailabilityPolicy.Context(
            hasOpenTaskThread: true,
            hasWorkspaceContext: true,
            hasPlanContent: false,
            hasFilesShelfContent: false,
            hasQueryShelfContent: false,
            isComposingWorkspaceApp: false,
            activeShelfID: nil
        )
        #expect(!policy.canPresent(.browser, in: shelfContext))

        ShelfBrowserBridgeRegistry.shared.update(
            endpoint: "http://127.0.0.1:49152",
            currentURL: "https://example.com/dashboard",
            currentTitle: "Dashboard",
            taskID: task.id,
            isPresented: true,
            isEnabled: true
        )
        defer { ShelfBrowserBridgeRegistry.shared.reset() }

        let contextText = "Use the ASTRA browser to inspect the current page."

        #expect(!TaskCapabilityResolver.shouldExposeBrowserBridge(for: task, contextText: contextText))
        let scope = TaskCapabilityResolver(task: task).promptScope(contextText: contextText)
        #expect(!scope.localTools.contains { $0.command == "astra-browser" })
        #expect(AgentRuntimeProcessRunner.scopedEnvironmentVariables(for: task, contextText: contextText)["ASTRA_BROWSER_URL"] == nil)
    }

    @Test("Supplied shelf policy controls runtime browser bridge exposure")
    func suppliedShelfPolicyControlsRuntimeBrowserBridgeExposure() throws {
        let container = try makeTaskCapabilityResolverContainer()
        let context = container.mainContext

        let workspace = Workspace(name: "Browser Policy Workspace", primaryPath: "/tmp/browser-policy")
        context.insert(workspace)
        let task = AgentTask(
            title: "Inspect current browser page",
            goal: "Use the ASTRA browser to inspect the current page.",
            workspace: workspace
        )
        context.insert(task)
        try context.save()

        ShelfBrowserBridgeRegistry.shared.update(
            endpoint: "http://127.0.0.1:49152",
            currentURL: "https://example.com/dashboard",
            currentTitle: "Dashboard",
            taskID: task.id,
            isPresented: true,
            isEnabled: true
        )
        defer { ShelfBrowserBridgeRegistry.shared.reset() }

        let contextText = "Use the ASTRA browser to inspect the current page."
        let disabledBrowserPolicy = ShelfAvailabilityPolicy(disabledShelfIDs: [.browser])

        #expect(TaskCapabilityResolver.shouldExposeBrowserBridge(for: task, contextText: contextText))
        #expect(!TaskCapabilityResolver.shouldExposeBrowserBridge(
            for: task,
            contextText: contextText,
            shelfAvailabilityPolicy: disabledBrowserPolicy
        ))
    }

    @Test("Browser adapters require runnable catalog policy")
    func browserAdaptersRequireRunnableCatalogPolicy() throws {
        let workspace = Workspace(name: "Draft Browser Workspace", primaryPath: "/tmp/draft-browser-workspace")
        workspace.enabledCapabilityIDs = ["draft-drive-browser"]
        var draftPackage = PluginPackage(
            id: "draft-drive-browser",
            name: "Draft Drive Browser",
            icon: "folder",
            description: "Draft Drive browser adapter",
            author: "Tests",
            category: "Browser",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: [],
            browserAdapters: [BrowserSiteAdapterID.googleDrive],
            governance: .localDraft()
        )

        let blocked = TaskCapabilityResolver.enabledBrowserAdapters(
            for: workspace,
            packages: [draftPackage]
        )
        #expect(blocked.isEmpty)

        let approval = CapabilityApprovalRecord(
            packageID: draftPackage.id,
            packageVersion: draftPackage.version,
            status: .approved,
            approvedBy: "Security",
            approvedAt: Date(),
            reviewNotes: "Reviewed",
            sourceDigest: try CapabilityApprovalDigest.digest(for: draftPackage)
        )
        let approved = TaskCapabilityResolver.enabledBrowserAdapters(
            for: workspace,
            packages: [draftPackage],
            approvalRecords: [approval]
        )
        #expect(approved == [BrowserSiteAdapterID.googleDrive])

        draftPackage.governance.approvalStatus = .blocked
        let explicitlyBlocked = TaskCapabilityResolver.enabledBrowserAdapters(
            for: workspace,
            packages: [draftPackage]
        )
        #expect(explicitlyBlocked.isEmpty)
    }

    @Test("Pack capability filters load approval store when package governance can be approval-overridden")
    func packCapabilityFiltersLoadApprovalStoreWhenPackageGovernanceCanBeApprovalOverridden() throws {
        let workspace = Workspace(name: "Approved Draft Workspace", primaryPath: "/tmp/approved-draft-workspace")
        workspace.enabledCapabilityIDs = ["draft-approved-tool"]
        let draftPackage = PluginPackage(
            id: "draft-approved-tool",
            name: "Draft Approved Tool",
            icon: "terminal",
            description: "Draft tool approved outside pack policy.",
            author: "Tests",
            category: "Tools",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [
                PluginLocalTool(
                    name: "Echo",
                    description: "Echo",
                    icon: "terminal",
                    toolType: "cli",
                    command: "echo",
                    arguments: ""
                )
            ],
            templates: [],
            governance: .localDraft()
        )
        let approval = CapabilityApprovalRecord(
            packageID: draftPackage.id,
            packageVersion: draftPackage.version,
            status: .approved,
            approvedBy: "Security",
            approvedAt: Date(),
            reviewNotes: "Reviewed",
            sourceDigest: try CapabilityApprovalDigest.digest(for: draftPackage)
        )
        let packPolicy = AstraPackPolicyResolver.resolve(
            composition: AstraPackComposition.resolve(packs: [
                AstraPackManifest(
                    id: "astra.pack.disables-other-tool",
                    name: "Disables Other Tool",
                    version: "1.0.0",
                    coreAPIVersion: "1.0",
                    description: "Disables a different package without requiring review gates.",
                    policyRestrictions: [
                        AstraPackPolicyRestriction(
                            id: "disable-other",
                            contributionKind: "capabilityPackage",
                            action: "disableCapability",
                            effect: "restrict",
                            targetID: "other-tool"
                        )
                    ]
                )
            ])
        )
        var didLoadApprovals = false
        let enabled = CapabilityRuntimeResourceMatcher.withApprovalRecordsLoaderForTesting({
            didLoadApprovals = true
            return [approval]
        }) {
            CapabilityRuntimeResourceMatcher.enabledPackages(
                for: workspace,
                in: [draftPackage],
                approvalRecords: nil,
                packPolicy: packPolicy
            )
        }

        #expect(didLoadApprovals)
        #expect(enabled.map(\.id) == ["draft-approved-tool"])
    }

    @Test("Runtime integrity reports unknown browser adapter IDs")
    func runtimeIntegrityReportsUnknownBrowserAdapterIDs() throws {
        let container = try makeTaskCapabilityResolverContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Unknown Adapter", primaryPath: "/tmp/unknown-adapter")
        let package = PluginPackage(
            id: "unknown-browser-package",
            name: "Unknown Browser Package",
            icon: "safari",
            description: "Unknown browser adapter",
            author: "Tests",
            category: "Browser",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: [],
            browserAdapters: ["unknownAdapter"],
            governance: .builtInApproved(riskLevel: .high)
        )
        workspace.enabledCapabilityIDs = [package.id]
        context.insert(workspace)
        let task = AgentTask(title: "Use browser", goal: "Use unknown adapter", workspace: workspace)
        context.insert(task)
        try context.save()

        let issues = CapabilityRuntimeIntegrityService.issues(
            for: task,
            packages: [package],
            checkExecutables: false
        )

        #expect(issues.map(\.resourceKind) == [.browserAdapter])
        #expect(issues.first?.resourceName == "unknownAdapter")
        #expect(issues.first?.message.contains("not known to ASTRA") == true)
    }

    @Test("Browser task prompt keeps capability referenced by the user goal")
    func browserTaskPromptKeepsReferencedCapability() throws {
        let container = try makeTaskCapabilityResolverContainer()
        let context = container.mainContext

        let workspace = Workspace(name: "Jira Browser Workspace", primaryPath: "/tmp/jira-browser-workspace")
        context.insert(workspace)

        let jiraSkill = Skill(
            name: "Jira Agent",
            skillDescription: "Work with Jira tickets and issues",
            allowedTools: ["Read", "Bash"],
            behaviorInstructions: "Use Jira REST APIs for ticket lookup before summarizing issue state."
        )
        jiraSkill.isGlobal = true
        context.insert(jiraSkill)

        let jiraConnector = Connector(
            name: "Jira",
            serviceType: "jira",
            connectorDescription: "Jira REST API",
            baseURL: "https://example.atlassian.net",
            authMethod: "basic"
        )
        jiraConnector.isGlobal = true
        jiraConnector.skill = jiraSkill
        jiraConnector.configKeys = ["JIRA_PROJECTS"]
        jiraConnector.configValues = ["STAR"]
        context.insert(jiraConnector)
        workspace.enabledGlobalConnectorIDs = [jiraConnector.id.uuidString]

        let mailSkill = Skill(
            name: "Stanford Mail via Apple Mail Agent",
            skillDescription: "Read Stanford email through Apple Mail",
            allowedTools: ["Read", "Bash"],
            behaviorInstructions: "Stanford mail tasks must use the Apple Mail mailbox bridge."
        )
        mailSkill.workspace = workspace
        context.insert(mailSkill)

        let task = AgentTask(
            title: "Open Jira ticket STAR-123",
            goal: "Open Jira ticket STAR-123 and summarize it",
            workspace: workspace
        )
        task.skills = [mailSkill]
        context.insert(task)
        try context.save()

        ShelfBrowserBridgeRegistry.shared.update(
            endpoint: "http://127.0.0.1:49152",
            currentURL: "https://example.atlassian.net/browse/STAR-123",
            currentTitle: "STAR-123 - Jira",
            taskID: task.id,
            isPresented: true,
            isEnabled: true
        )
        defer { ShelfBrowserBridgeRegistry.shared.reset() }

        let scope = TaskCapabilityResolver(task: task).promptScope()
        #expect(scope.prunedForBrowserTask)
        #expect(scope.connectors.map(\.id) == [jiraConnector.id])
        #expect(scope.excludedSkillNames.contains("Stanford Mail via Apple Mail Agent"))

        let prompt = AgentPromptBuilder.buildPrompt(for: task)
        #expect(prompt.contains("Shelf Browser Session:"))
        #expect(prompt.contains("[Jira Agent]:"))
        #expect(prompt.contains("https://example.atlassian.net"))
        #expect(prompt.contains("JIRA_PROJECTS: STAR"))
        #expect(!prompt.contains("[Stanford Mail via Apple Mail Agent]:"))
        #expect(!prompt.contains("Apple Mail mailbox bridge"))
    }

    @Test("Browser mail task prompt prunes unrelated capabilities but keeps mail tools")
    func browserMailTaskPromptPrunesUnrelatedCapabilitiesButKeepsMailTools() throws {
        let container = try makeTaskCapabilityResolverContainer()
        let context = container.mainContext

        let workspace = Workspace(name: "Mail Browser Workspace", primaryPath: "/tmp/mail-browser-workspace")
        context.insert(workspace)

        let jiraSkill = Skill(
            name: "Jira Agent",
            skillDescription: "Work with Jira tickets and issues",
            allowedTools: ["Read", "Bash"],
            behaviorInstructions: "Use Jira REST APIs for ticket lookup."
        )
        jiraSkill.workspace = workspace
        context.insert(jiraSkill)

        let mailSkill = Skill(
            name: "Stanford Mail via Apple Mail Agent",
            skillDescription: "Read Stanford email through Apple Mail",
            allowedTools: ["Read", "Bash"],
            behaviorInstructions: "Stanford mail tasks must use the Apple Mail mailbox bridge."
        )
        mailSkill.workspace = workspace
        context.insert(mailSkill)

        let mailTool = LocalTool(
            name: "stanford-apple-mail",
            toolDescription: "Read Stanford email through Apple Mail",
            command: "stanford-apple-mail"
        )
        mailTool.skill = mailSkill
        context.insert(mailTool)

        let task = AgentTask(
            title: "Summarize my last email",
            goal: "summarize my last email",
            workspace: workspace
        )
        task.skills = [jiraSkill, mailSkill]
        context.insert(task)
        try context.save()

        ShelfBrowserBridgeRegistry.shared.update(
            endpoint: "http://127.0.0.1:49152",
            currentURL: "https://outlook.cloud.microsoft/mail/inbox/id/example",
            currentTitle: "Outlook",
            taskID: task.id,
            isPresented: true,
            isEnabled: true
        )
        defer { ShelfBrowserBridgeRegistry.shared.reset() }

        let scope = TaskCapabilityResolver(task: task).promptScope()
        #expect(scope.prunedForBrowserTask)
        #expect(scope.excludedSkillNames.contains("Jira Agent"))
        #expect(scope.behaviorSkills.map(\.name) == ["Stanford Mail via Apple Mail Agent"])
        #expect(scope.localTools.map(\.command).contains("stanford-apple-mail"))

        let prompt = AgentPromptBuilder.buildPrompt(for: task)
        #expect(prompt.contains("[Stanford Mail via Apple Mail Agent]:"))
        #expect(prompt.contains("stanford-apple-mail"))
        #expect(!prompt.contains("[Jira Agent]:"))
        #expect(prompt.contains("Mail Read Safety:"))
    }
}

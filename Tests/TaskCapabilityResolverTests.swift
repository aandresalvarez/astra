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
    }

    @Test("Single same-service connector keeps legacy env vars during deprecation window")
    func singleSameServiceConnectorKeepsLegacyEnvVarsDuringDeprecationWindow() throws {
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
        #expect(env["REDCAP_API_URL"] == "https://redcap.example.edu/api/source")
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
            secretStore: store
        ).environmentVariables()

        #expect(env["REDCAP_STUDY_A_SOURCE_API_TOKEN"] == "source-token")
        #expect(env["REDCAP_STUDY_B_TARGET_API_TOKEN"] == "target-token")
        #expect(env["REDCAP_API_TOKEN"] == nil)
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
                    browserAdapters: [BrowserSiteAdapterID.googleDrive]
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
}

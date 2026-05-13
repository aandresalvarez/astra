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

        let instructions = task.resolvedBehaviorInstructions
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

        #expect(task.allConnectors.map(\.id) == [configuredConnector.id])

        let prompt = AgentPromptBuilder.buildPrompt(for: task)
        #expect(prompt.contains("https://stanfordmed.atlassian.net"))
        #expect(!prompt.contains("https://yourcompany.atlassian.net"))
        #expect(prompt.contains("[Jira Agent]:"))
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
        mailSkill.workspace = workspace
        context.insert(mailSkill)

        let task = AgentTask(
            title: "Open the untitled document",
            goal: "Open the untitled document",
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
        #expect(!prompt.contains("astra-browser google-drive-open"))
        #expect(!prompt.contains("[GCloud Agent]:"))
        #expect(!prompt.contains("GCloud must inspect projects"))
        #expect(!prompt.contains("Available CLI/Script Tools"))
        #expect(!prompt.contains("`gcloud`"))
        #expect(!prompt.contains("[Stanford Mail via Apple Mail Agent]:"))
        #expect(!prompt.contains("Apple Mail mailbox bridge"))
        #expect(!prompt.contains("GCP_PROJECT"))
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

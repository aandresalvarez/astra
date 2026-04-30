import Foundation
import SwiftData
import Testing
@testable import ASTRA
import ASTRACore

private func makeCapabilitiesPersistenceContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

@Suite("Workspace Capabilities")
struct WorkspaceCapabilitiesTests {
    @Test("active skills merge workspace and enabled shared skills")
    @MainActor
    func activeSkillsMergeWorkspaceAndEnabledShared() {
        let workspace = Workspace(name: "Capabilities", primaryPath: "/tmp/capabilities")
        let local = Skill(name: "Local Analyst", allowedTools: ["Read"])
        local.workspace = workspace

        let shared = Skill(name: "Shared Analyst", allowedTools: ["Read", "Bash"])
        shared.isGlobal = true
        workspace.enabledGlobalSkillIDs = [shared.id.uuidString]

        let disabledShared = Skill(name: "Disabled Shared", allowedTools: ["Read"])
        disabledShared.isGlobal = true

        let builtIn = Skill(name: "Read-Only", allowedTools: ["Read"])
        builtIn.isGlobal = true
        builtIn.isBuiltIn = true
        workspace.enabledGlobalSkillIDs.append(builtIn.id.uuidString)

        let capabilities = WorkspaceCapabilities(
            workspace: workspace,
            globalSkills: [shared, disabledShared, builtIn]
        )

        #expect(capabilities.workspaceSkills.map(\.name) == ["Local Analyst"])
        #expect(capabilities.enabledGlobalSkills.map(\.name) == ["Shared Analyst"])
        #expect(capabilities.activeSkills.map(\.name) == ["Local Analyst", "Shared Analyst"])
        #expect(capabilities.availableGlobalSkills.map(\.name) == ["Disabled Shared", "Shared Analyst"])
    }

    @Test("active connectors include local, enabled shared, and enabled skill attachments")
    @MainActor
    func activeConnectorsMergeAllSources() {
        let workspace = Workspace(name: "Connectors", primaryPath: "/tmp/connectors")

        let localConnector = Connector(name: "Local Jira", serviceType: "jira")
        localConnector.workspace = workspace

        let sharedConnector = Connector(name: "Shared GCP", serviceType: "custom")
        sharedConnector.isGlobal = true
        workspace.enabledGlobalConnectorIDs = [sharedConnector.id.uuidString]

        let attachedConnector = Connector(name: "Attached API", serviceType: "rest_api")
        attachedConnector.isGlobal = true

        let sharedSkill = Skill(name: "Shared Skill", allowedTools: ["Read"])
        sharedSkill.isGlobal = true
        sharedSkill.connectors = [attachedConnector]
        workspace.enabledGlobalSkillIDs = [sharedSkill.id.uuidString]

        let capabilities = WorkspaceCapabilities(
            workspace: workspace,
            globalSkills: [sharedSkill],
            globalConnectors: [sharedConnector, attachedConnector]
        )

        #expect(capabilities.workspaceConnectors.map(\.name) == ["Local Jira"])
        #expect(capabilities.enabledGlobalConnectors.map(\.name) == ["Shared GCP"])
        #expect(capabilities.activeConnectors.map(\.name) == ["Attached API", "Local Jira", "Shared GCP"])
    }

    @Test("active tools include local, enabled shared, and enabled skill attachments")
    @MainActor
    func activeToolsMergeAllSources() {
        let workspace = Workspace(name: "Tools", primaryPath: "/tmp/tools")

        let localTool = LocalTool(name: "Local Tool", command: "local-tool")
        localTool.workspace = workspace

        let sharedTool = LocalTool(name: "Shared Tool", command: "shared-tool")
        sharedTool.isGlobal = true
        workspace.enabledGlobalToolIDs = [sharedTool.id.uuidString]

        let attachedTool = LocalTool(name: "Attached Tool", command: "attached-tool")
        attachedTool.isGlobal = true

        let sharedSkill = Skill(name: "Shared Skill", allowedTools: ["Read"])
        sharedSkill.isGlobal = true
        sharedSkill.localTools = [attachedTool]
        workspace.enabledGlobalSkillIDs = [sharedSkill.id.uuidString]

        let capabilities = WorkspaceCapabilities(
            workspace: workspace,
            globalSkills: [sharedSkill],
            globalTools: [sharedTool, attachedTool]
        )

        #expect(capabilities.workspaceTools.map(\.name) == ["Local Tool"])
        #expect(capabilities.enabledGlobalTools.map(\.name) == ["Shared Tool"])
        #expect(capabilities.activeTools.map(\.name) == ["Attached Tool", "Local Tool", "Shared Tool"])
    }

    @Test("package state treats enabled linked elements as enabled capability")
    @MainActor
    func packageStateDetectsEnabledLinkedElements() {
        let workspace = Workspace(name: "Package State", primaryPath: "/tmp/package-state")

        let connector = Connector(name: "Jira", serviceType: "jira")
        connector.isGlobal = true
        connector.authMethod = "basic"
        connector.credentialKeys = ["JIRA_EMAIL", "JIRA_API_TOKEN"]

        let skill = Skill(name: "Jira Agent", allowedTools: ["Read"])
        skill.isGlobal = true
        skill.connectors = [connector]
        workspace.enabledGlobalSkillIDs = [skill.id.uuidString]

        let package = PluginPackage(
            id: "jira-workflow",
            name: "Jira Workflow",
            icon: "list.clipboard",
            description: "Query and update Jira tickets",
            author: "ASTRA",
            category: "Integrations",
            tags: [],
            version: "1.0.0",
            skills: [PluginSkill(
                name: "Jira Agent",
                icon: "list.clipboard",
                description: "Jira behavior",
                allowedTools: ["Read"],
                disallowedTools: [],
                customTools: [],
                behaviorInstructions: "Use Jira carefully.",
                environmentKeys: [],
                environmentValues: []
            )],
            connectors: [PluginConnector(
                name: "Jira",
                serviceType: "jira",
                icon: "list.clipboard",
                description: "Jira API",
                baseURL: "",
                authMethod: "bearer",
                credentialHints: [],
                configHints: [],
                notes: ""
            )],
            localTools: [],
            templates: []
        )

        let capabilities = WorkspaceCapabilities(
            workspace: workspace,
            globalSkills: [skill],
            globalConnectors: [connector]
        )
        let state = CapabilityPackageState(
            package: package,
            workspace: workspace,
            capabilities: capabilities
        )

        #expect(state.isEnabled)
        #expect(state.linkedSkills.map(\.name) == ["Jira Agent"])
        #expect(state.linkedConnectors.map(\.name) == ["Jira"])
        #expect(state.skillIDStrings == [skill.id.uuidString])
        #expect(state.connectorIDStrings == [connector.id.uuidString])
        #expect(state.readiness.level == .needsAttention)
        #expect(state.readiness.messages == ["Jira: missing JIRA_EMAIL, JIRA_API_TOKEN"])
    }

    @Test("catalog inventory includes workspace-only capabilities")
    @MainActor
    func catalogInventoryIncludesWorkspaceOnlyCapabilities() {
        let workspace = Workspace(name: "Catalog Inventory", primaryPath: "/tmp/catalog-inventory")

        let connector = Connector(name: "Google Cloud", serviceType: "gcloud")
        let tool = LocalTool(name: "bq — BigQuery CLI", toolType: "cli", command: "bq")
        let skill = Skill(
            name: "Bigquery Analyst",
            icon: "folder.fill",
            skillDescription: "queries - no write permissions",
            allowedTools: ["Read", "Bash"]
        )
        skill.workspace = workspace
        skill.connectors = [connector]
        skill.localTools = [tool]

        let capabilities = WorkspaceCapabilities(workspace: workspace)
        let packages = CapabilityCatalogInventory.packages(catalogPackages: [], capabilities: capabilities)
        guard let package = packages.first else {
            Issue.record("Expected a workspace capability package")
            return
        }
        let state = CapabilityPackageState(package: package, workspace: workspace, capabilities: capabilities)

        #expect(packages.map(\.name) == ["Bigquery Analyst"])
        #expect(package.category == "Workspace")
        #expect(package.sourceMetadata?.kind == "workspace")
        #expect(package.skills.map(\.name) == ["Bigquery Analyst"])
        #expect(package.connectors.map(\.name) == ["Google Cloud"])
        #expect(package.localTools.map(\.name) == ["bq — BigQuery CLI"])
        #expect(state.isEnabled)
    }

    @Test("catalog inventory does not duplicate capabilities represented by approved packages")
    @MainActor
    func catalogInventorySkipsSkillsRepresentedByApprovedPackages() {
        let workspace = Workspace(name: "Catalog Dedupe", primaryPath: "/tmp/catalog-dedupe")
        let skill = Skill(name: "Jira Agent", allowedTools: ["Read"])
        skill.workspace = workspace

        let package = PluginPackage(
            id: "jira-workflow",
            name: "Jira Workflow",
            icon: "list.clipboard",
            description: "Query and update Jira tickets",
            author: "ASTRA",
            category: "Integrations",
            tags: [],
            version: "1.0.0",
            skills: [PluginSkill(
                name: "Jira Agent",
                icon: "list.clipboard",
                description: "Jira behavior",
                allowedTools: ["Read"],
                disallowedTools: [],
                customTools: [],
                behaviorInstructions: "Use Jira carefully.",
                environmentKeys: [],
                environmentValues: []
            )],
            connectors: [],
            localTools: [],
            templates: []
        )

        let capabilities = WorkspaceCapabilities(workspace: workspace)
        let packages = CapabilityCatalogInventory.packages(catalogPackages: [package], capabilities: capabilities)

        #expect(packages.map(\.id) == ["jira-workflow"])
        #expect(packages.map(\.name) == ["Jira Workflow"])
    }

    @Test("promoting a workspace connector to shared keeps it enabled here")
    @MainActor
    func promotingConnectorKeepsCurrentWorkspaceEnabled() {
        let workspace = Workspace(name: "Promote Connector", primaryPath: "/tmp/promote-connector")
        let connector = Connector(name: "Local Jira", serviceType: "jira")
        connector.workspace = workspace

        CapabilitySharing.promoteToShared(connector, in: workspace)

        #expect(connector.isGlobal)
        #expect(connector.workspace == nil)
        #expect(workspace.enabledGlobalConnectorIDs == [connector.id.uuidString])
    }

    @Test("duplicating a shared connector creates a local copy without removing the shared definition")
    @MainActor
    func duplicateSharedConnectorForWorkspace() {
        let workspace = Workspace(name: "Duplicate Connector", primaryPath: "/tmp/duplicate-connector")
        let connector = Connector(name: "Shared Jira", serviceType: "jira", connectorDescription: "Shared")
        connector.isGlobal = true
        connector.credentialKeys = ["JIRA_TOKEN"]
        connector.configKeys = ["JIRA_PROJECT"]
        connector.configValues = ["ASTRA"]
        workspace.enabledGlobalConnectorIDs = [connector.id.uuidString]

        let copy = CapabilitySharing.duplicateForWorkspace(connector, in: workspace)

        #expect(connector.isGlobal)
        #expect(connector.workspace == nil)
        #expect(!workspace.enabledGlobalConnectorIDs.contains(connector.id.uuidString))
        #expect(copy.workspace === workspace)
        #expect(!copy.isGlobal)
        #expect(copy.id != connector.id)
        #expect(copy.credentialKeys == ["JIRA_TOKEN"])
        #expect(copy.config == ["JIRA_PROJECT": "ASTRA"])
    }

    @Test("duplicating a shared tool creates a local copy without removing the shared definition")
    @MainActor
    func duplicateSharedToolForWorkspace() {
        let workspace = Workspace(name: "Duplicate Tool", primaryPath: "/tmp/duplicate-tool")
        let tool = LocalTool(name: "Shared bq", toolType: "cli", command: "bq", arguments: "--format=json")
        tool.isGlobal = true
        workspace.enabledGlobalToolIDs = [tool.id.uuidString]

        let copy = CapabilitySharing.duplicateForWorkspace(tool, in: workspace)

        #expect(tool.isGlobal)
        #expect(tool.workspace == nil)
        #expect(!workspace.enabledGlobalToolIDs.contains(tool.id.uuidString))
        #expect(copy.workspace === workspace)
        #expect(!copy.isGlobal)
        #expect(copy.id != tool.id)
        #expect(copy.displayCommand == "bq --format=json")
    }

    @Test("workspace export includes enabled standalone shared connector definitions")
    @MainActor
    func exportIncludesEnabledSharedConnectors() throws {
        let container = try makeCapabilitiesPersistenceContainer()
        let context = container.mainContext

        let workspace = Workspace(name: "Export Shared Connector", primaryPath: "/tmp/export-shared")
        context.insert(workspace)

        let connector = Connector(
            name: "Shared BigQuery",
            serviceType: "custom",
            icon: "cloud",
            connectorDescription: "Shared GCP config",
            baseURL: "https://bigquery.googleapis.com",
            authMethod: "bearer"
        )
        connector.isGlobal = true
        connector.credentialKeys = ["GCP_TOKEN"]
        connector.credentialValues = ["plaintext-secret-should-not-export"]
        connector.configKeys = ["GCP_PROJECT"]
        connector.configValues = ["astra-dev"]
        context.insert(connector)

        workspace.enabledGlobalConnectorIDs = [connector.id.uuidString]
        try context.save()

        let config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: context))
        let exportedConnector = try #require(config.connectors?.first { $0.id == connector.id.uuidString })
        #expect(exportedConnector.isGlobal == true)
        #expect(exportedConnector.credentialKeys == ["GCP_TOKEN"])

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = String(data: try encoder.encode(config), encoding: .utf8) ?? ""
        #expect(!json.contains("plaintext-secret-should-not-export"))

        let importedContainer = try makeCapabilitiesPersistenceContainer()
        let importedContext = importedContainer.mainContext
        let importedWorkspace = WorkspaceConfigManager.importWorkspace(from: config, modelContext: importedContext)
        let descriptor = FetchDescriptor<Connector>(predicate: #Predicate { $0.isGlobal == true })
        let importedGlobals = try importedContext.fetch(descriptor)

        #expect(importedWorkspace.connectors.isEmpty)
        #expect(importedWorkspace.enabledGlobalConnectorIDs.contains(connector.id.uuidString))
        #expect(importedGlobals.contains { $0.id == connector.id && $0.name == "Shared BigQuery" })
    }

    @Test("workspace export includes enabled standalone shared tool definitions")
    @MainActor
    func exportIncludesEnabledSharedTools() throws {
        let container = try makeCapabilitiesPersistenceContainer()
        let context = container.mainContext

        let workspace = Workspace(name: "Export Shared Tool", primaryPath: "/tmp/export-shared-tool")
        context.insert(workspace)

        let tool = LocalTool(
            name: "Shared bq",
            toolDescription: "BigQuery CLI",
            icon: "terminal",
            toolType: "cli",
            command: "bq",
            arguments: "--project_id astra-dev"
        )
        tool.isGlobal = true
        context.insert(tool)

        workspace.enabledGlobalToolIDs = [tool.id.uuidString]
        try context.save()

        let config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: context))
        let exportedTool = try #require(config.localTools?.first { $0.id == tool.id.uuidString })
        #expect(exportedTool.isGlobal == true)
        #expect(exportedTool.command == "bq")
        #expect(config.enabledGlobalToolIDs == [tool.id.uuidString])

        let importedContainer = try makeCapabilitiesPersistenceContainer()
        let importedContext = importedContainer.mainContext
        let importedWorkspace = WorkspaceConfigManager.importWorkspace(from: config, modelContext: importedContext)
        let descriptor = FetchDescriptor<LocalTool>(predicate: #Predicate { $0.isGlobal == true })
        let importedGlobals = try importedContext.fetch(descriptor)

        #expect(importedWorkspace.localTools.isEmpty)
        #expect(importedWorkspace.enabledGlobalToolIDs.contains(tool.id.uuidString))
        #expect(importedGlobals.contains { $0.id == tool.id && $0.name == "Shared bq" })
    }

    @Test("default workspace export uses model context to include enabled shared definitions")
    @MainActor
    func defaultExportIncludesEnabledSharedDefinitions() throws {
        let container = try makeCapabilitiesPersistenceContainer()
        let context = container.mainContext

        let workspace = Workspace(name: "Default Export", primaryPath: "/tmp/default-export")
        context.insert(workspace)

        let connector = Connector(name: "Shared API", serviceType: "rest_api")
        connector.isGlobal = true
        context.insert(connector)

        let tool = LocalTool(name: "Shared Tool", command: "shared-tool")
        tool.isGlobal = true
        context.insert(tool)

        workspace.enabledGlobalConnectorIDs = [connector.id.uuidString]
        workspace.enabledGlobalToolIDs = [tool.id.uuidString]
        try context.save()

        let config = try #require(WorkspaceConfigManager.export(workspace: workspace))

        #expect(config.connectors?.contains { $0.id == connector.id.uuidString && $0.isGlobal == true } == true)
        #expect(config.localTools?.contains { $0.id == tool.id.uuidString && $0.isGlobal == true } == true)
    }

    @Test("task runtime resolves enabled shared standalone tools")
    @MainActor
    func taskRuntimeResolvesEnabledSharedTools() throws {
        let container = try makeCapabilitiesPersistenceContainer()
        let context = container.mainContext

        let workspace = Workspace(name: "Runtime Shared Tool", primaryPath: "/tmp/runtime-shared-tool")
        context.insert(workspace)

        let tool = LocalTool(name: "Shared jq", toolType: "cli", command: "jq")
        tool.isGlobal = true
        context.insert(tool)

        workspace.enabledGlobalToolIDs = [tool.id.uuidString]

        let task = AgentTask(title: "Use jq", goal: "Filter JSON", workspace: workspace)
        context.insert(task)
        try context.save()

        #expect(task.allLocalTools.map(\.name) == ["Shared jq"])
        #expect(task.resolvedAllowedTools.contains("jq"))
        #expect(task.resolvedAllowedTools.contains("Bash"))
        #expect(!task.resolvedClaudeAllowedTools.contains("jq"))
    }

    @Test("workspace import reuses existing shared connector by ID")
    @MainActor
    func importReusesExistingSharedConnector() throws {
        let container = try makeCapabilitiesPersistenceContainer()
        let context = container.mainContext

        let connectorID = UUID()
        let existing = Connector(
            name: "Shared Jira",
            serviceType: "jira",
            icon: "list.bullet.rectangle",
            connectorDescription: "Existing shared connector",
            baseURL: "https://stanfordmed.atlassian.net",
            authMethod: "basic"
        )
        existing.id = connectorID
        existing.isGlobal = true
        context.insert(existing)

        let config = WorkspaceConfigManager.WorkspaceConfig(
            id: UUID().uuidString,
            name: "Uses Shared Jira",
            primaryPath: "/tmp/uses-shared-jira",
            additionalPaths: [],
            icon: "folder.fill",
            instructions: "",
            enabledGlobalConnectorIDs: [connectorID.uuidString],
            skills: [],
            connectors: [
                WorkspaceConfigManager.ConnectorConfig(
                    id: connectorID.uuidString,
                    name: "Shared Jira",
                    serviceType: "jira",
                    icon: "list.bullet.rectangle",
                    description: "Imported shared connector",
                    baseURL: "https://stanfordmed.atlassian.net",
                    authMethod: "basic",
                    credentialKeys: ["JIRA_TOKEN"],
                    configKeys: [],
                    configValues: [],
                    isGlobal: true,
                    notes: "",
                    createdAt: nil,
                    updatedAt: nil
                )
            ],
            sshConnections: [],
            exportedAt: Date()
        )

        let imported = WorkspaceConfigManager.importWorkspace(from: config, modelContext: context)
        let descriptor = FetchDescriptor<Connector>(predicate: #Predicate { $0.id == connectorID && $0.isGlobal })
        let matchingConnectors = try context.fetch(descriptor)

        #expect(matchingConnectors.count == 1)
        #expect(matchingConnectors.first?.name == "Shared Jira")
        #expect(imported.enabledGlobalConnectorIDs == [connectorID.uuidString])
    }

    @Test("workspace import reuses existing shared tool by ID")
    @MainActor
    func importReusesExistingSharedTool() throws {
        let container = try makeCapabilitiesPersistenceContainer()
        let context = container.mainContext

        let toolID = UUID()
        let existing = LocalTool(
            name: "Shared gcloud",
            toolDescription: "Existing shared tool",
            toolType: "cli",
            command: "gcloud"
        )
        existing.id = toolID
        existing.isGlobal = true
        context.insert(existing)

        let config = WorkspaceConfigManager.WorkspaceConfig(
            id: UUID().uuidString,
            name: "Uses Shared gcloud",
            primaryPath: "/tmp/uses-shared-gcloud",
            additionalPaths: [],
            icon: "folder.fill",
            instructions: "",
            enabledGlobalToolIDs: [toolID.uuidString],
            skills: [],
            localTools: [
                WorkspaceConfigManager.LocalToolConfig(
                    id: toolID.uuidString,
                    name: "Shared gcloud",
                    description: "Imported shared tool",
                    icon: "terminal",
                    toolType: "cli",
                    command: "gcloud",
                    arguments: "",
                    isGlobal: true,
                    createdAt: nil,
                    updatedAt: nil
                )
            ],
            sshConnections: [],
            exportedAt: Date()
        )

        let imported = WorkspaceConfigManager.importWorkspace(from: config, modelContext: context)
        let descriptor = FetchDescriptor<LocalTool>(predicate: #Predicate { $0.id == toolID && $0.isGlobal })
        let matchingTools = try context.fetch(descriptor)

        #expect(matchingTools.count == 1)
        #expect(matchingTools.first?.name == "Shared gcloud")
        #expect(imported.enabledGlobalToolIDs == [toolID.uuidString])
    }
}

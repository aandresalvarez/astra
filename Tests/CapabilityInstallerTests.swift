import Foundation
import SwiftData
import Testing
@testable import ASTRA
import ASTRACore

private func makeCapabilityInstallerContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

private func makeCapabilityInstallerLibrary() -> (CapabilityLibrary, URL) {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("astra-capability-installer-\(UUID().uuidString)", isDirectory: true)
    return (CapabilityLibrary(directory: root), root)
}

private func makeAnalystCapabilityPackage() -> PluginPackage {
    PluginPackage(
        id: "stanford.bigquery.analyst",
        name: "BigQuery Analyst",
        icon: "chart.bar.doc.horizontal",
        description: "Analyze BigQuery datasets",
        author: "Stanford",
        category: "Data",
        tags: ["bigquery", "gcp"],
        version: "1.0.0",
        skills: [
            PluginSkill(
                name: "BigQuery Analyst",
                icon: "chart.bar.doc.horizontal",
                description: "BigQuery analysis behavior",
                allowedTools: ["Read", "Grep"],
                disallowedTools: [],
                customTools: [],
                behaviorInstructions: "Use BigQuery carefully.",
                environmentKeys: ["GCP_PROJECT"],
                environmentValues: [""]
            )
        ],
        connectors: [
            PluginConnector(
                name: "Google Cloud",
                serviceType: "google_cloud",
                icon: "cloud",
                description: "GCP connector",
                baseURL: "https://bigquery.googleapis.com",
                authMethod: "bearer",
                credentialHints: [
                    .init(key: "GCP_TOKEN", hint: "GCP access token")
                ],
                configHints: [
                    .init(key: "GCP_PROJECT", hint: "Project ID", isList: false)
                ],
                notes: "Shared GCP configuration."
            )
        ],
        localTools: [
            PluginLocalTool(
                name: "bq",
                description: "BigQuery CLI",
                icon: "terminal",
                toolType: "cli",
                command: "bq",
                arguments: ""
            )
        ],
        templates: []
    )
}

@Suite("Capability Installer")
@MainActor
struct CapabilityInstallerTests {
    @Test("install writes app-local package and enables shared definitions")
    func installWritesLibraryAndEnablesSharedDefinitions() throws {
        let container = try makeCapabilityInstallerContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Capability Workspace", primaryPath: "/tmp/capability-workspace")
        context.insert(workspace)

        let (library, root) = makeCapabilityInstallerLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let package = makeAnalystCapabilityPackage()
        let installer = CapabilityInstaller(library: library)
        let result = try installer.install(
            package,
            into: workspace,
            modelContext: context,
            configInputs: ["GCP_PROJECT": "astra-dev"]
        )

        let skills = try context.fetch(FetchDescriptor<Skill>(predicate: #Predicate { $0.isGlobal == true }))
        let globalConnectors = try context.fetch(FetchDescriptor<Connector>(predicate: #Predicate { $0.isGlobal == true }))
        let tools = try context.fetch(FetchDescriptor<LocalTool>(predicate: #Predicate { $0.isGlobal == true }))

        #expect(library.installedPackages().map(\.id) == [package.id])
        #expect(workspace.skills.isEmpty)
        #expect(workspace.connectors.map(\.name) == ["Google Cloud"])
        #expect(workspace.localTools.isEmpty)
        #expect(workspace.enabledGlobalSkillIDs == result.skillIDs.map(\.uuidString))
        #expect(workspace.enabledGlobalConnectorIDs.isEmpty)
        #expect(workspace.enabledGlobalToolIDs.isEmpty)
        #expect(workspace.enabledCapabilityIDs == [package.id])
        #expect(workspace.installedVersion(of: package.id) == package.version)

        let skill = try #require(skills.first)
        #expect(globalConnectors.isEmpty)
        let connector = try #require(workspace.connectors.first)
        let tool = try #require(tools.first)
        #expect(skill.name == "BigQuery Analyst")
        #expect(skill.environmentVariables["GCP_PROJECT"] == "")
        #expect(connector.skill == nil)
        #expect(connector.config == ["GCP_PROJECT": "astra-dev"])
        #expect(tool.skill?.id == skill.id)
        #expect(result.connectorIDs == [connector.id])
        #expect(result.localToolIDs == [tool.id])

        let capabilities = WorkspaceCapabilities(
            workspace: workspace,
            globalSkills: skills,
            globalConnectors: globalConnectors,
            globalTools: tools
        )
        #expect(capabilities.activeSkills.map(\.name) == ["BigQuery Analyst"])
        #expect(capabilities.activeConnectors.map(\.name) == ["Google Cloud"])
        #expect(capabilities.activeTools.map(\.name) == ["bq"])

        let task = AgentTask(title: "Use GCP", goal: "List projects", workspace: workspace)
        task.skills = [skill]
        let resolver = TaskCapabilityResolver(task: task).resolver
        #expect(resolver.resolvedEnvironmentVariables["GCP_PROJECT"] == "astra-dev")
    }

    @Test("install records exact origin metadata on package resources")
    func installRecordsOriginMetadataOnResources() throws {
        let container = try makeCapabilityInstallerContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Origin", primaryPath: "/tmp/capability-origin")
        context.insert(workspace)

        let (library, root) = makeCapabilityInstallerLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        var package = makeAnalystCapabilityPackage()
        package.version = "1.2.3"
        package.templates = [
            PluginTemplate(
                name: "BQ Summary",
                icon: "doc.text",
                description: "Summarize BigQuery",
                mainGoal: "Summarize BigQuery cost",
                beforeGoal: "",
                afterGoal: "",
                mainBudget: 1000,
                beforeBudget: 0,
                afterBudget: 0,
                variablesJSON: "[]",
                passContextToMain: true,
                passContextToAfter: false
            )
        ]

        try CapabilityInstaller(library: library).install(package, into: workspace, modelContext: context)

        let skill = try #require(try context.fetch(FetchDescriptor<Skill>(
            predicate: #Predicate { $0.isGlobal == true && $0.name == "BigQuery Analyst" }
        )).first)
        let connector = try #require(try context.fetch(FetchDescriptor<Connector>(
            predicate: #Predicate { $0.isGlobal == true && $0.name == "Google Cloud" }
        )).first)
        let tool = try #require(try context.fetch(FetchDescriptor<LocalTool>(
            predicate: #Predicate { $0.isGlobal == true && $0.name == "bq" }
        )).first)
        let template = try #require(workspace.templates.first { $0.name == "BQ Summary" })

        #expect(skill.originPackageID == package.id)
        #expect(skill.originPackageVersion == "1.2.3")
        #expect(skill.originComponentID == "skill:bigquery-analyst")
        #expect(skill.originComponentKind == "skill")
        #expect(skill.originSourceKind == "local")

        #expect(connector.originPackageID == package.id)
        #expect(connector.originComponentID == "connector:google_cloud:google-cloud")
        #expect(connector.originComponentKind == "connector")

        #expect(tool.originPackageID == package.id)
        #expect(tool.originComponentID == "tool:cli:bq:bq")
        #expect(tool.originComponentKind == "local_tool")

        #expect(template.originPackageID == package.id)
        #expect(template.originComponentID == "template:bq-summary")
        #expect(template.originComponentKind == "template")
    }

    @Test("install stores configured source env values on the connector")
    func installStoresConfiguredSourceEnvValuesOnConnector() throws {
        let container = try makeCapabilityInstallerContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Jira Config", primaryPath: "/tmp/jira-config")
        context.insert(workspace)

        let (library, root) = makeCapabilityInstallerLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let package = try #require(PluginCatalog.builtInPackages.first { $0.id == "jira-workflow" })
        let baseURL = "https://example.atlassian.net"
        try CapabilityInstaller(library: library).install(
            package,
            into: workspace,
            modelContext: context,
            configInputs: [
                "JIRA_BASE_URL": baseURL,
                "JIRA_PROJECTS": "ENG, OPS"
            ],
            baseURLOverrides: ["Jira": baseURL]
        )

        let skill = try #require(try context.fetch(FetchDescriptor<Skill>(
            predicate: #Predicate { $0.isGlobal == true && $0.name == "Jira Agent" }
        )).first)
        let connector = try #require(workspace.connectors.first { $0.name == "Jira" })

        #expect(skill.environmentVariables["JIRA_BASE_URL"] == "")
        #expect(connector.baseURL == baseURL)
        #expect(connector.config == [
            "JIRA_PROJECTS": "ENG, OPS",
            "JIRA_BASE_URL": baseURL
        ])

        let task = AgentTask(title: "Use Jira", goal: "List tickets", workspace: workspace)
        task.skills = [skill]
        let resolver = TaskCapabilityResolver(task: task).resolver
        #expect(resolver.resolvedEnvironmentVariables["JIRA_BASE_URL"] == baseURL)
        #expect(resolver.resolvedEnvironmentVariables["JIRA_PROJECTS"] == "ENG, OPS")
    }

    @Test("configured source values stay scoped to their workspace")
    func configuredSourceValuesStayScopedToWorkspace() throws {
        let container = try makeCapabilityInstallerContainer()
        let context = container.mainContext
        let firstWorkspace = Workspace(name: "First Jira", primaryPath: "/tmp/first-jira")
        let secondWorkspace = Workspace(name: "Second Jira", primaryPath: "/tmp/second-jira")
        context.insert(firstWorkspace)
        context.insert(secondWorkspace)

        let (library, root) = makeCapabilityInstallerLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let package = try #require(PluginCatalog.builtInPackages.first { $0.id == "jira-workflow" })
        let installer = CapabilityInstaller(library: library)
        try installer.install(
            package,
            into: firstWorkspace,
            modelContext: context,
            configInputs: [
                "JIRA_BASE_URL": "https://first.atlassian.net",
                "JIRA_PROJECTS": "ONE"
            ],
            baseURLOverrides: ["Jira": "https://first.atlassian.net"]
        )
        try installer.install(
            package,
            into: secondWorkspace,
            modelContext: context,
            configInputs: [
                "JIRA_BASE_URL": "https://second.atlassian.net",
                "JIRA_PROJECTS": "TWO"
            ],
            baseURLOverrides: ["Jira": "https://second.atlassian.net"]
        )

        let skill = try #require(try context.fetch(FetchDescriptor<Skill>(
            predicate: #Predicate { $0.isGlobal == true && $0.name == "Jira Agent" }
        )).first)
        let firstConnector = try #require(firstWorkspace.connectors.first { $0.name == "Jira" })
        let secondConnector = try #require(secondWorkspace.connectors.first { $0.name == "Jira" })
        let globalConnectors = try context.fetch(FetchDescriptor<Connector>(
            predicate: #Predicate { $0.isGlobal == true && $0.name == "Jira" }
        ))

        #expect(globalConnectors.isEmpty)
        #expect(firstConnector.id != secondConnector.id)
        #expect(firstConnector.config["JIRA_BASE_URL"] == "https://first.atlassian.net")
        #expect(secondConnector.config["JIRA_BASE_URL"] == "https://second.atlassian.net")

        let firstTask = AgentTask(title: "First", goal: "List tickets", workspace: firstWorkspace)
        firstTask.skills = [skill]
        let secondTask = AgentTask(title: "Second", goal: "List tickets", workspace: secondWorkspace)
        secondTask.skills = [skill]

        let firstEnv = TaskCapabilityResolver(task: firstTask).resolver.resolvedEnvironmentVariables
        let secondEnv = TaskCapabilityResolver(task: secondTask).resolver.resolvedEnvironmentVariables
        #expect(firstEnv["JIRA_BASE_URL"] == "https://first.atlassian.net")
        #expect(firstEnv["JIRA_PROJECTS"] == "ONE")
        #expect(secondEnv["JIRA_BASE_URL"] == "https://second.atlassian.net")
        #expect(secondEnv["JIRA_PROJECTS"] == "TWO")
    }

    @Test("install once can enable the same shared capability in multiple workspaces")
    func installReusesSharedDefinitionsAcrossWorkspaces() throws {
        let container = try makeCapabilityInstallerContainer()
        let context = container.mainContext
        let firstWorkspace = Workspace(name: "First", primaryPath: "/tmp/first-capability")
        let secondWorkspace = Workspace(name: "Second", primaryPath: "/tmp/second-capability")
        context.insert(firstWorkspace)
        context.insert(secondWorkspace)

        let (library, root) = makeCapabilityInstallerLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let package = makeAnalystCapabilityPackage()
        let installer = CapabilityInstaller(library: library)
        let firstResult = try installer.install(package, into: firstWorkspace, modelContext: context)
        let secondResult = try installer.install(package, into: secondWorkspace, modelContext: context)

        let skills = try context.fetch(FetchDescriptor<Skill>(predicate: #Predicate { $0.isGlobal == true }))
        let connectors = try context.fetch(FetchDescriptor<Connector>(predicate: #Predicate { $0.isGlobal == true }))
        let tools = try context.fetch(FetchDescriptor<LocalTool>(predicate: #Predicate { $0.isGlobal == true }))

        #expect(skills.count == 1)
        #expect(connectors.count == 1)
        #expect(tools.count == 1)
        #expect(firstResult.skillIDs == secondResult.skillIDs)
        #expect(firstWorkspace.enabledGlobalSkillIDs == secondWorkspace.enabledGlobalSkillIDs)
        #expect(firstWorkspace.enabledCapabilityIDs == [package.id])
        #expect(secondWorkspace.enabledCapabilityIDs == [package.id])
        #expect(library.installedPackages().count == 1)
    }

    @Test("updating a capability refreshes shared definitions without duplicating them")
    func updateRefreshesSharedDefinitionsWithoutDuplicates() throws {
        let container = try makeCapabilityInstallerContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Update", primaryPath: "/tmp/update-capability")
        context.insert(workspace)

        let (library, root) = makeCapabilityInstallerLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let package = makeAnalystCapabilityPackage()
        var updatedPackage = package
        updatedPackage.version = "1.1.0"
        updatedPackage.skills[0].behaviorInstructions = "Use BigQuery carefully and explain cost."
        updatedPackage.localTools[0].arguments = "--format=json"

        let installer = CapabilityInstaller(library: library)
        let firstResult = try installer.install(package, into: workspace, modelContext: context)
        let updatedResult = try installer.install(updatedPackage, into: workspace, modelContext: context)

        let skills = try context.fetch(FetchDescriptor<Skill>(predicate: #Predicate { $0.isGlobal == true }))
        let tools = try context.fetch(FetchDescriptor<LocalTool>(predicate: #Predicate { $0.isGlobal == true }))

        #expect(skills.count == 1)
        #expect(tools.count == 1)
        #expect(firstResult.skillIDs == updatedResult.skillIDs)
        #expect(skills.first?.behaviorInstructions == "Use BigQuery carefully and explain cost.")
        #expect(tools.first?.arguments == "--format=json")
        #expect(skills.first?.originPackageVersion == "1.1.0")
        #expect(tools.first?.originPackageVersion == "1.1.0")
        #expect(library.installedVersion(of: package.id) == "1.1.0")
        #expect(workspace.enabledCapabilityIDs == [package.id])
    }

    @Test("connector-only and tool-only packages enable standalone shared elements")
    func standaloneElementPackagesEnableGlobalIDs() throws {
        let container = try makeCapabilityInstallerContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Standalone", primaryPath: "/tmp/standalone-capability")
        context.insert(workspace)

        let (library, root) = makeCapabilityInstallerLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        var package = makeAnalystCapabilityPackage()
        package.id = "stanford.gcp.tools"
        package.skills = []
        package.templates = []

        let installer = CapabilityInstaller(library: library)
        let result = try installer.install(package, into: workspace, modelContext: context)

        let connectors = try context.fetch(FetchDescriptor<Connector>(predicate: #Predicate { $0.isGlobal == true }))
        let tools = try context.fetch(FetchDescriptor<LocalTool>(predicate: #Predicate { $0.isGlobal == true }))

        #expect(workspace.enabledGlobalSkillIDs.isEmpty)
        #expect(workspace.enabledGlobalConnectorIDs == result.connectorIDs.map(\.uuidString))
        #expect(workspace.enabledGlobalToolIDs == result.localToolIDs.map(\.uuidString))
        #expect(workspace.enabledCapabilityIDs == [package.id])

        let capabilities = WorkspaceCapabilities(workspace: workspace, globalConnectors: connectors, globalTools: tools)
        #expect(capabilities.activeConnectors.map(\.name) == ["Google Cloud"])
        #expect(capabilities.activeTools.map(\.name) == ["bq"])
    }

    @Test("installer blocks packages with unsatisfied dependencies")
    func installerBlocksUnsatisfiedDependencies() throws {
        let container = try makeCapabilityInstallerContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Blocked", primaryPath: "/tmp/blocked-capability")
        context.insert(workspace)

        let (library, root) = makeCapabilityInstallerLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        var package = makeAnalystCapabilityPackage()
        package.requires = ["missing-base"]

        let installer = CapabilityInstaller(library: library)

        do {
            try installer.install(package, into: workspace, modelContext: context)
            Issue.record("Install should have failed")
        } catch let error as CapabilityInstaller.InstallationError {
            #expect(error.localizedDescription.contains("missing-base"))
            #expect(library.installedPackages().isEmpty)
            #expect(workspace.enabledCapabilityIDs.isEmpty)
        }
    }

    @Test("installer blocks packages denied by catalog policy context")
    func installerBlocksPolicyDeniedPackages() throws {
        let container = try makeCapabilityInstallerContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Policy Blocked", primaryPath: "/tmp/policy-blocked-capability")
        context.insert(workspace)

        let (library, root) = makeCapabilityInstallerLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        var package = makeAnalystCapabilityPackage()
        package.id = "stanford.bigquery.draft"
        package.governance = .localDraft()

        let policyContext = CapabilityCatalogPolicyContext.workspaceUser(
            workspace: workspace,
            currentAppVersion: SemanticVersion(1, 0, 0)
        )

        do {
            try CapabilityInstaller(library: library).install(
                package,
                into: workspace,
                modelContext: context,
                policyContext: policyContext
            )
            Issue.record("Install should have failed")
        } catch let error as CapabilityInstaller.InstallationError {
            #expect(error.localizedDescription.contains("draft review"))
            #expect(library.installedPackages().isEmpty)
            #expect(workspace.enabledCapabilityIDs.isEmpty)
        }
    }

    @Test("installer blocks local tool commands that embed shell syntax")
    func installerBlocksUnsafeLocalToolCommands() throws {
        let container = try makeCapabilityInstallerContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Unsafe Tool", primaryPath: "/tmp/unsafe-tool")
        context.insert(workspace)

        let (library, root) = makeCapabilityInstallerLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        var package = makeAnalystCapabilityPackage()
        package.id = "stanford.unsafe.tool"
        package.localTools = [
            PluginLocalTool(
                name: "unsafe",
                description: "Unsafe shell-shaped command",
                icon: "terminal",
                toolType: "cli",
                command: "sh -c curl https://evil.example",
                arguments: ""
            )
        ]

        do {
            try CapabilityInstaller(library: library).install(package, into: workspace, modelContext: context)
            Issue.record("Install should have failed")
        } catch let error as CapabilityInstaller.InstallationError {
            #expect(error.localizedDescription.contains("unsafe command"))
            #expect(library.installedPackages().isEmpty)
            #expect(workspace.enabledCapabilityIDs.isEmpty)
        }
    }

    @Test("installer blocks local tool default arguments that embed shell syntax")
    func installerBlocksUnsafeLocalToolArguments() throws {
        let container = try makeCapabilityInstallerContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Unsafe Tool Arguments", primaryPath: "/tmp/unsafe-tool-args")
        context.insert(workspace)

        let (library, root) = makeCapabilityInstallerLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        var package = makeAnalystCapabilityPackage()
        package.id = "stanford.unsafe.tool.args"
        package.localTools = [
            PluginLocalTool(
                name: "unsafe",
                description: "Unsafe shell-shaped arguments",
                icon: "terminal",
                toolType: "cli",
                command: "curl",
                arguments: "https://allowed.example ; curl https://evil.example"
            )
        ]

        do {
            try CapabilityInstaller(library: library).install(package, into: workspace, modelContext: context)
            Issue.record("Install should have failed")
        } catch let error as CapabilityInstaller.InstallationError {
            #expect(error.localizedDescription.contains("unsafe default arguments"))
            #expect(library.installedPackages().isEmpty)
            #expect(workspace.enabledCapabilityIDs.isEmpty)
        }
    }

    @Test("installer blocks credentialed connectors over remote cleartext HTTP")
    func installerBlocksCredentialedHTTPConnectors() throws {
        let container = try makeCapabilityInstallerContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Unsafe Connector", primaryPath: "/tmp/unsafe-connector")
        context.insert(workspace)

        let (library, root) = makeCapabilityInstallerLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        var package = makeAnalystCapabilityPackage()
        package.id = "stanford.unsafe.connector"
        package.connectors[0] = PluginConnector(
            name: "Unsafe API",
            serviceType: "rest_api",
            icon: "network",
            description: "Remote cleartext API",
            baseURL: "http://evil.example/api",
            authMethod: "bearer",
            credentialHints: [.init(key: "API_TOKEN", hint: "API token")],
            configHints: [],
            notes: ""
        )

        do {
            try CapabilityInstaller(library: library).install(package, into: workspace, modelContext: context)
            Issue.record("Install should have failed")
        } catch let error as CapabilityInstaller.InstallationError {
            #expect(error.localizedDescription.contains("unsafe credential transport"))
            #expect(library.installedPackages().isEmpty)
            #expect(workspace.enabledCapabilityIDs.isEmpty)
        }
    }

    @Test("installer accepts safe MCP server declarations")
    func installerAcceptsSafeMCPServerDeclarations() throws {
        let container = try makeCapabilityInstallerContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Safe MCP", primaryPath: "/tmp/safe-mcp")
        context.insert(workspace)

        let (library, root) = makeCapabilityInstallerLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        var package = makeAnalystCapabilityPackage()
        package.id = "stanford.safe.mcp"
        package.mcpServers = [
            PluginMCPServer(
                id: "github",
                displayName: "GitHub MCP",
                transport: .stdio,
                command: "github-mcp-server",
                arguments: ["stdio"],
                allowedTools: ["issues.list"],
                excludedTools: ["repo.delete"]
            )
        ]

        try CapabilityInstaller(library: library).install(package, into: workspace, modelContext: context)

        #expect(library.installedPackage(id: package.id)?.mcpServers.map(\.id) == ["github"])
        #expect(workspace.enabledCapabilityIDs == [package.id])
    }

    @Test("installer blocks unsafe MCP server declarations")
    func installerBlocksUnsafeMCPServerDeclarations() throws {
        let container = try makeCapabilityInstallerContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Unsafe MCP", primaryPath: "/tmp/unsafe-mcp")
        context.insert(workspace)

        let (library, root) = makeCapabilityInstallerLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        var package = makeAnalystCapabilityPackage()
        package.id = "stanford.unsafe.mcp"
        package.mcpServers = [
            PluginMCPServer(
                id: "unsafe",
                displayName: "Unsafe MCP",
                transport: .stdio,
                command: "npx",
                arguments: ["server", ";", "rm"]
            )
        ]

        do {
            try CapabilityInstaller(library: library).install(package, into: workspace, modelContext: context)
            Issue.record("Install should have failed")
        } catch let error as CapabilityInstaller.InstallationError {
            #expect(error.localizedDescription.contains("unsafe default arguments"))
            #expect(library.installedPackages().isEmpty)
            #expect(workspace.enabledCapabilityIDs.isEmpty)
        }
    }

    @Test("uninstall removes local package and owned shared resources")
    func uninstallRemovesLocalPackageAndOwnedSharedResources() throws {
        let container = try makeCapabilityInstallerContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Remove", primaryPath: "/tmp/remove-capability")
        context.insert(workspace)

        let (library, root) = makeCapabilityInstallerLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        var package = makeAnalystCapabilityPackage()
        package.templates = [
            PluginTemplate(
                name: "BQ Summary",
                icon: "doc.text",
                description: "Summarize BigQuery",
                mainGoal: "Summarize BigQuery cost",
                beforeGoal: "",
                afterGoal: "",
                mainBudget: 1000,
                beforeBudget: 0,
                afterBudget: 0,
                variablesJSON: "[]",
                passContextToMain: true,
                passContextToAfter: false
            )
        ]

        try CapabilityInstaller(library: library).install(package, into: workspace, modelContext: context)
        let skill = try #require(try context.fetch(FetchDescriptor<Skill>(
            predicate: #Predicate { $0.isGlobal == true && $0.name == "BigQuery Analyst" }
        )).first)
        let connector = try #require(try context.fetch(FetchDescriptor<Connector>(
            predicate: #Predicate { $0.isGlobal == true && $0.name == "Google Cloud" }
        )).first)
        connector.saveCredential(key: "GCP_TOKEN", value: "secret")
        let connectorID = connector.id
        let skillID = skill.id
        defer {
            KeychainService.deleteAll(connectorID: connectorID)
            KeychainService.deleteAll(skillID: skillID)
        }
        #expect(KeychainService.exists(key: "GCP_TOKEN", connectorID: connectorID))
        #expect(workspace.templates.map(\.name) == ["BQ Summary"])

        let result = try CapabilityUninstaller(library: library).remove(package, modelContext: context)

        #expect(result.packageID == package.id)
        #expect(result.disabledWorkspaceIDs == [workspace.id])
        #expect(result.removedSkillIDs == [skillID])
        #expect(result.removedConnectorIDs == [connectorID])
        #expect(result.removedToolIDs.count == 1)
        #expect(result.removedTemplateIDs.count == 1)
        #expect(library.installedPackage(id: package.id) == nil)
        #expect(workspace.enabledCapabilityIDs.isEmpty)
        #expect(workspace.installedPluginIDs.isEmpty)
        #expect(workspace.enabledGlobalSkillIDs.isEmpty)
        #expect(workspace.enabledGlobalConnectorIDs.isEmpty)
        #expect(workspace.enabledGlobalToolIDs.isEmpty)
        #expect(workspace.templates.isEmpty)
        #expect(try context.fetch(FetchDescriptor<Skill>(predicate: #Predicate { $0.isGlobal == true })).isEmpty)
        #expect(try context.fetch(FetchDescriptor<Connector>(predicate: #Predicate { $0.isGlobal == true })).isEmpty)
        #expect(try context.fetch(FetchDescriptor<LocalTool>(predicate: #Predicate { $0.isGlobal == true })).isEmpty)
        #expect(!KeychainService.exists(key: "GCP_TOKEN", connectorID: connectorID))
    }

    @Test("uninstall prefers origin metadata before legacy name matching")
    func uninstallPrefersOriginMetadataBeforeLegacyNameMatching() throws {
        let container = try makeCapabilityInstallerContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Remove Origin", primaryPath: "/tmp/remove-origin")
        context.insert(workspace)

        let (library, root) = makeCapabilityInstallerLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let package = makeAnalystCapabilityPackage()
        try CapabilityInstaller(library: library).install(package, into: workspace, modelContext: context)

        let ownedSkill = try #require(try context.fetch(FetchDescriptor<Skill>(
            predicate: #Predicate { $0.isGlobal == true && $0.name == "BigQuery Analyst" }
        )).first)
        let legacySkill = Skill(name: "BigQuery Analyst", allowedTools: ["Read"])
        legacySkill.isGlobal = true
        context.insert(legacySkill)

        let result = try CapabilityUninstaller(library: library).remove(package, modelContext: context)

        #expect(result.removedSkillIDs == [ownedSkill.id])
        #expect(try context.fetch(FetchDescriptor<Skill>()).contains { $0.id == legacySkill.id })
        #expect(try context.fetch(FetchDescriptor<Skill>()).contains { $0.id == ownedSkill.id } == false)
    }

    @Test("uninstall rejects built-in packages")
    func uninstallRejectsBuiltInPackages() throws {
        let container = try makeCapabilityInstallerContainer()
        let context = container.mainContext
        let (library, root) = makeCapabilityInstallerLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let package = try #require(PluginCatalog.builtInPackages.first { $0.id == "security-auditor" })
        try library.install(package, sourceMetadata: .builtIn())

        do {
            _ = try CapabilityUninstaller(library: library).remove(package, modelContext: context)
            Issue.record("Built-in package uninstall should fail")
        } catch let error as CapabilityLibrary.RemovalError {
            #expect(error == .builtInPackage(package.name))
        }

        #expect(library.installedPackage(id: package.id) != nil)
    }

    @Test("uninstall keeps shared resources claimed by another package")
    func uninstallKeepsResourcesClaimedByAnotherPackage() throws {
        let container = try makeCapabilityInstallerContainer()
        let context = container.mainContext
        let firstWorkspace = Workspace(name: "First", primaryPath: "/tmp/remove-first")
        let secondWorkspace = Workspace(name: "Second", primaryPath: "/tmp/remove-second")
        context.insert(firstWorkspace)
        context.insert(secondWorkspace)

        let (library, root) = makeCapabilityInstallerLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        var firstPackage = makeAnalystCapabilityPackage()
        firstPackage.id = "stanford.bigquery.first"
        var secondPackage = makeAnalystCapabilityPackage()
        secondPackage.id = "stanford.bigquery.second"

        try CapabilityInstaller(library: library).install(firstPackage, into: firstWorkspace, modelContext: context)
        try CapabilityInstaller(library: library).install(secondPackage, into: secondWorkspace, modelContext: context)

        let skill = try #require(try context.fetch(FetchDescriptor<Skill>(
            predicate: #Predicate { $0.isGlobal == true && $0.name == "BigQuery Analyst" }
        )).first)
        let connector = try #require(try context.fetch(FetchDescriptor<Connector>(
            predicate: #Predicate { $0.isGlobal == true && $0.name == "Google Cloud" }
        )).first)
        let tool = try #require(try context.fetch(FetchDescriptor<LocalTool>(
            predicate: #Predicate { $0.isGlobal == true && $0.name == "bq" }
        )).first)

        let result = try CapabilityUninstaller(library: library).remove(firstPackage, modelContext: context)

        #expect(result.removedSkillIDs.isEmpty)
        #expect(result.removedConnectorIDs.isEmpty)
        #expect(result.removedToolIDs.isEmpty)
        #expect(firstWorkspace.enabledCapabilityIDs.isEmpty)
        #expect(firstWorkspace.enabledGlobalSkillIDs.isEmpty)
        #expect(firstWorkspace.enabledGlobalConnectorIDs.isEmpty)
        #expect(firstWorkspace.enabledGlobalToolIDs.isEmpty)
        #expect(secondWorkspace.enabledCapabilityIDs == [secondPackage.id])
        #expect(secondWorkspace.enabledGlobalSkillIDs == [skill.id.uuidString])
        #expect(secondWorkspace.enabledGlobalConnectorIDs == [connector.id.uuidString])
        #expect(secondWorkspace.enabledGlobalToolIDs.isEmpty)
        #expect(library.installedPackage(id: firstPackage.id) == nil)
        #expect(library.installedPackage(id: secondPackage.id) != nil)
        #expect(try context.fetch(FetchDescriptor<Skill>()).filter { $0.id == skill.id }.count == 1)
        #expect(try context.fetch(FetchDescriptor<Connector>()).filter { $0.id == connector.id }.count == 1)
        #expect(try context.fetch(FetchDescriptor<LocalTool>()).filter { $0.id == tool.id }.count == 1)
    }
}

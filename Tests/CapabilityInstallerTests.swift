import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRAPersistence
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
        templates: [],
        governance: .builtInApproved(riskLevel: .medium)
    )
}

@Suite("Capability Installer")
@MainActor
struct CapabilityInstallerTests {
    @Test("install writes the package to the library and records an activation, not plugin rows")
    func installWritesLibraryAndRecordsActivation() throws {
        let container = try makeCapabilityInstallerContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Capability Workspace", primaryPath: "/tmp/capability-workspace")
        context.insert(workspace)

        let (library, root) = makeCapabilityInstallerLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let package = makeAnalystCapabilityPackage()
        let result = try CapabilityInstaller(library: library).install(
            package,
            into: workspace,
            modelContext: context,
            configInputs: ["GCP_PROJECT": "astra-dev"]
        )

        #expect(library.installedPackages().map(\.id) == [package.id])
        #expect(try context.fetch(FetchDescriptor<Skill>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<LocalTool>()).isEmpty)
        #expect(workspace.enabledGlobalSkillIDs.isEmpty)
        #expect(workspace.enabledGlobalConnectorIDs.isEmpty)
        #expect(workspace.enabledGlobalToolIDs.isEmpty)
        #expect(workspace.enabledCapabilityIDs == [package.id])
        #expect(workspace.installedVersion(of: package.id) == package.version)

        // The connector component's account is a workspace row bound to the
        // activation; the configured value lives on it.
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: workspace))
        let connector = try #require(workspace.connectors.first)
        #expect(workspace.connectors.map(\.name) == ["Google Cloud"])
        #expect(activation.accounts(forComponent: "connector:google_cloud:google-cloud").map(\.id) == [connector.id])
        #expect(connector.skill == nil)
        #expect(connector.config == ["GCP_PROJECT": "astra-dev"])
        #expect(result.connectorIDs == [connector.id])

        let capabilities = WorkspaceCapabilities(workspace: workspace, packageDefinitions: library.installedPackages())
        let skill = try #require(capabilities.activeSkills.first)
        let tool = try #require(capabilities.activeTools.first)
        #expect(capabilities.activeSkills.map(\.name) == ["BigQuery Analyst"])
        #expect(capabilities.activeConnectors.map(\.name) == ["Google Cloud"])
        #expect(capabilities.activeTools.map(\.name) == ["bq"])
        #expect(skill.modelContext == nil)
        #expect(result.skillIDs == [skill.id])
        #expect(result.localToolIDs == [tool.id])
        #expect(tool.skill?.id == skill.id)
        // The value went to the account, not the skill: the package has a
        // connector, so the skill's own setting stays at its default.
        #expect(skill.environmentVariables["GCP_PROJECT"] == "")
        #expect(activation.configKeys.isEmpty)
    }

    @Test("Add takes a template only by its component stamp, never an authored row by its name")
    func addMatchesTemplatesByStampNotName() throws {
        let container = try makeCapabilityInstallerContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Templates", primaryPath: "/tmp/capability-templates")
        context.insert(workspace)
        let (library, root) = makeCapabilityInstallerLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        var package = makeAnalystCapabilityPackage()
        let spec = PluginTemplate(
            name: "BQ Summary", icon: "doc.text", description: "Summarize BigQuery", mainGoal: "Summarize BigQuery cost",
            beforeGoal: "", afterGoal: "", mainBudget: 1000, beforeBudget: 0, afterBudget: 0, variablesJSON: "[]",
            passContextToMain: true, passContextToAfter: false
        )
        package.templates = [spec]
        // The person's own template has the plugin template's name.
        let authored = TaskTemplate(name: "BQ Summary", mainGoal: "My own goal", workspace: workspace, icon: "star", templateDescription: "")
        context.insert(authored)
        try context.save()

        try CapabilityInstaller(library: library).install(package, into: workspace, modelContext: context)
        #expect(authored.mainGoal == "My own goal")
        #expect(authored.originPackageID == nil)
        let stamped = try #require(workspace.templates.first { $0.id != authored.id })
        #expect(stamped.originPackageID == package.id)
        #expect(stamped.originComponentID == CapabilityResourceOrigin.componentID(for: spec))
        #expect(workspace.templates.count == 2)

        // A row kept with its component's stamp (as while the plugin was
        // missing) is the component's template when it is added again, even
        // renamed: Add adopts it rather than make another.
        stamped.name = "Renamed by me"
        try context.save()
        try CapabilityInstaller(library: library).enable(package, in: workspace, modelContext: context)
        #expect(workspace.templates.count == 2)
        #expect(authored.mainGoal == "My own goal")
        #expect(stamped.originComponentID == CapabilityResourceOrigin.componentID(for: spec))
        withExtendedLifetime(container) {}
    }

    @Test("install records exact origin metadata on projected resources, accounts and templates")
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

        let capabilities = WorkspaceCapabilities(workspace: workspace, packageDefinitions: library.installedPackages())
        let skill = try #require(capabilities.activeSkills.first { $0.name == "BigQuery Analyst" })
        let connector = try #require(workspace.connectors.first { $0.name == "Google Cloud" })
        let tool = try #require(capabilities.activeTools.first { $0.name == "bq" })
        let template = try #require(workspace.templates.first { $0.name == "BQ Summary" })

        #expect(skill.originPackageID == package.id)
        #expect(skill.originPackageVersion == "1.2.3")
        #expect(skill.originComponentID == "skill:bigquery-analyst")
        #expect(skill.originComponentKind == "skill")
        #expect(skill.originSourceKind == PluginRuntimeProjection.projectedSourceKind)
        #expect(PluginRuntimeProjection.isProjected(skill))

        #expect(connector.originPackageID == package.id)
        #expect(connector.originComponentID == "connector:google_cloud:google-cloud")
        #expect(connector.originComponentKind == "connector")

        #expect(tool.originPackageID == package.id)
        #expect(tool.originComponentID == "tool:cli:bq:bq")
        #expect(tool.originComponentKind == "local_tool")
        #expect(PluginRuntimeProjection.isProjected(tool))

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

        let skill = try #require(WorkspaceCapabilities(workspace: workspace, packageDefinitions: library.installedPackages()).activeSkills.first { $0.name == "Jira Agent" })
        let connector = try #require(workspace.connectors.first { $0.name == "Jira" })

        #expect(skill.environmentVariables["JIRA_BASE_URL"] == "")
        #expect(connector.baseURL == baseURL)
        #expect(connector.config == [
            "JIRA_PROJECTS": "ENG, OPS",
            "JIRA_BASE_URL": baseURL
        ])

        let task = AgentTask(title: "Use Jira", goal: "List tickets", workspace: workspace)
        let resolver = TaskCapabilityResolver(task: task).resolver
        #expect(resolver.resolvedEnvironmentVariables["JIRA_JIRA_BASE_URL"] == baseURL)
        #expect(resolver.resolvedEnvironmentVariables["JIRA_JIRA_PROJECTS"] == "ENG, OPS")
        #expect(resolver.resolvedEnvironmentVariables["JIRA_BASE_URL"] == "")
        #expect(resolver.resolvedEnvironmentVariables["JIRA_PROJECTS"] == nil)
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
        let secondTask = AgentTask(title: "Second", goal: "List tickets", workspace: secondWorkspace)
        let firstEnv = TaskCapabilityResolver(task: firstTask).resolver.resolvedEnvironmentVariables
        let secondEnv = TaskCapabilityResolver(task: secondTask).resolver.resolvedEnvironmentVariables
        #expect(firstEnv["JIRA_JIRA_BASE_URL"] == "https://first.atlassian.net")
        #expect(firstEnv["JIRA_JIRA_PROJECTS"] == "ONE")
        #expect(secondEnv["JIRA_JIRA_BASE_URL"] == "https://second.atlassian.net")
        #expect(secondEnv["JIRA_JIRA_PROJECTS"] == "TWO")
        #expect(firstEnv["JIRA_PROJECTS"] == nil)
        #expect(secondEnv["JIRA_PROJECTS"] == nil)
        #expect(Set(TaskCapabilityResolver(task: firstTask).allConnectors.map(\.id)) == [firstConnector.id])
        #expect(Set(TaskCapabilityResolver(task: secondTask).allConnectors.map(\.id)) == [secondConnector.id])
    }

    @Test("one library entry serves every workspace, each with its own activation")
    func installSharesLibraryEntryAcrossWorkspaces() throws {
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

        #expect(try context.fetch(FetchDescriptor<Skill>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<LocalTool>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<Connector>(predicate: #Predicate { $0.isGlobal == true })).isEmpty)
        #expect(try context.fetch(FetchDescriptor<PluginActivation>()).count == 2)
        // Projected IDs are per activation, so settings and secrets never
        // cross workspaces.
        #expect(Set(firstResult.skillIDs).isDisjoint(with: secondResult.skillIDs))
        #expect(firstResult.connectorIDs != secondResult.connectorIDs)
        #expect(firstWorkspace.enabledCapabilityIDs == [package.id])
        #expect(secondWorkspace.enabledCapabilityIDs == [package.id])
        #expect(library.installedPackages().count == 1)
    }

    @Test("adding a newer version refreshes the projection and keeps the activation")
    func updateRefreshesProjectionWithoutRows() throws {
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

        let capabilities = WorkspaceCapabilities(workspace: workspace, packageDefinitions: [updatedPackage])
        let skill = try #require(capabilities.activeSkills.first)
        let tool = try #require(capabilities.activeTools.first)
        #expect(try context.fetch(FetchDescriptor<Skill>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<PluginActivation>()).count == 1)
        #expect(firstResult.skillIDs == updatedResult.skillIDs)
        #expect(firstResult.connectorIDs == updatedResult.connectorIDs)
        #expect(skill.behaviorInstructions == "Use BigQuery carefully and explain cost.")
        #expect(tool.arguments == "--format=json")
        #expect(skill.originPackageVersion == "1.1.0")
        #expect(library.installedVersion(of: package.id) == "1.1.0")
        #expect(workspace.installedVersion(of: package.id) == "1.1.0")
        #expect(workspace.enabledCapabilityIDs == [package.id])
    }

    @Test("Add ignores legacy plugin rows instead of rewriting them")
    func addLeavesLegacyRowsAlone() throws {
        let container = try makeCapabilityInstallerContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Legacy rows", primaryPath: "/tmp/duplicate-update")
        context.insert(workspace)

        let (library, root) = makeCapabilityInstallerLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        var package = makeAnalystCapabilityPackage()
        package.version = "1.1.0"
        let pluginSkill = try #require(package.skills.first)
        let legacy = Skill(name: pluginSkill.name, behaviorInstructions: "Legacy")
        legacy.isGlobal = true
        legacy.originPackageID = package.id
        legacy.originPackageVersion = "1.0.0"
        legacy.originComponentID = CapabilityResourceOrigin.componentID(for: pluginSkill)
        context.insert(legacy)
        try context.save()

        let result = try CapabilityInstaller(library: library).install(package, into: workspace, modelContext: context)

        #expect(!result.skillIDs.contains(legacy.id))
        #expect(legacy.originPackageVersion == "1.0.0")
        #expect(legacy.behaviorInstructions == "Legacy")
        #expect(!workspace.enabledGlobalSkillIDs.contains(legacy.id.uuidString))
    }

    @Test("Add creates its own account instead of taking over an authored row with the same name and service")
    func addLeavesMatchingAuthoredConnectorAlone() throws {
        let container = try makeCapabilityInstallerContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Authored account", primaryPath: "/tmp/authored-account")
        context.insert(workspace)
        let (library, root) = makeCapabilityInstallerLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let package = makeAnalystCapabilityPackage()
        let pluginConnector = try #require(package.connectors.first)
        let attachedSkill = Skill(name: "Authored skill", behaviorInstructions: "Mine")
        context.insert(attachedSkill)
        let authored = Connector(
            name: pluginConnector.name,
            serviceType: pluginConnector.serviceType,
            icon: "cloud",
            connectorDescription: "Mine",
            baseURL: "https://authored.example.com",
            authMethod: "none"
        )
        authored.configKeys = ["MY_PROJECT"]
        authored.configValues = ["authored"]
        authored.workspace = workspace
        authored.skill = attachedSkill
        context.insert(authored)
        try context.save()

        let result = try CapabilityInstaller(library: library).install(package, into: workspace, modelContext: context)

        #expect(authored.baseURL == "https://authored.example.com")
        #expect(authored.config == ["MY_PROJECT": "authored"])
        #expect(authored.skill?.id == attachedSkill.id)
        #expect(!CapabilityResourceOrigin.hasOrigin(authored))
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: workspace))
        let account = try #require(activation.accounts(forComponent: CapabilityResourceOrigin.componentID(for: pluginConnector)).first)
        #expect(account.id != authored.id)
        #expect(result.connectorIDs == [account.id])
    }

    @Test("connector-only and tool-only packages project standalone elements")
    func standaloneElementPackagesProject() throws {
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

        let result = try CapabilityInstaller(library: library).install(package, into: workspace, modelContext: context)

        #expect(workspace.enabledGlobalSkillIDs.isEmpty)
        #expect(workspace.enabledGlobalConnectorIDs.isEmpty)
        #expect(workspace.enabledGlobalToolIDs.isEmpty)
        #expect(workspace.enabledCapabilityIDs == [package.id])

        let capabilities = WorkspaceCapabilities(workspace: workspace, packageDefinitions: library.installedPackages())
        #expect(capabilities.activeConnectors.map(\.id) == result.connectorIDs)
        #expect(capabilities.activeTools.map(\.name) == ["bq"])
        #expect(capabilities.activeTools.first?.skill == nil)
        #expect(capabilities.activeTools.map(\.id) == result.localToolIDs)
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

    @Test("installer applies default workspace policy when context is omitted")
    func installerAppliesDefaultPolicyWhenContextIsOmitted() throws {
        let container = try makeCapabilityInstallerContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Default Policy Blocked", primaryPath: "/tmp/default-policy-blocked")
        context.insert(workspace)

        let (library, root) = makeCapabilityInstallerLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        var package = makeAnalystCapabilityPackage()
        package.id = "stanford.bigquery.default-draft"
        package.governance = .localDraft()

        do {
            try CapabilityInstaller(library: library).install(
                package,
                into: workspace,
                modelContext: context
            )
            Issue.record("Install should have failed")
        } catch let error as CapabilityInstaller.InstallationError {
            #expect(error.localizedDescription.contains("draft review"))
            #expect(library.installedPackages().isEmpty)
            #expect(workspace.enabledCapabilityIDs.isEmpty)
        }
    }

    @Test("installer enforces role scoped policy contexts")
    func installerEnforcesRoleScopedPolicyContexts() throws {
        let deniedContainer = try makeCapabilityInstallerContainer()
        let deniedContext = deniedContainer.mainContext
        let deniedWorkspace = Workspace(name: "Denied Role", primaryPath: "/tmp/denied-role")
        deniedContext.insert(deniedWorkspace)

        let (deniedLibrary, deniedRoot) = makeCapabilityInstallerLibrary()
        defer { try? FileManager.default.removeItem(at: deniedRoot) }

        var package = makeAnalystCapabilityPackage()
        package.id = "stanford.bigquery.researcher"
        package.governance = .builtInApproved(
            riskLevel: .medium,
            allowedRoles: ["researcher"],
            visibility: .roleScoped
        )

        let deniedPolicy = CapabilityCatalogPolicyContext.workspaceUser(
            workspace: deniedWorkspace,
            userRoleIDs: ["engineer"],
            currentAppVersion: SemanticVersion(1, 0, 0)
        )
        do {
            try CapabilityInstaller(library: deniedLibrary).install(
                package,
                into: deniedWorkspace,
                modelContext: deniedContext,
                policyContext: deniedPolicy
            )
            Issue.record("Role-scoped install should have failed")
        } catch let error as CapabilityInstaller.InstallationError {
            #expect(error.localizedDescription.contains("researcher"))
            #expect(deniedWorkspace.enabledCapabilityIDs.isEmpty)
        }

        let allowedContainer = try makeCapabilityInstallerContainer()
        let allowedContext = allowedContainer.mainContext
        let allowedWorkspace = Workspace(name: "Allowed Role", primaryPath: "/tmp/allowed-role")
        allowedContext.insert(allowedWorkspace)
        let (allowedLibrary, allowedRoot) = makeCapabilityInstallerLibrary()
        defer { try? FileManager.default.removeItem(at: allowedRoot) }

        let allowedPolicy = CapabilityCatalogPolicyContext.workspaceUser(
            workspace: allowedWorkspace,
            userRoleIDs: ["Researcher"],
            currentAppVersion: SemanticVersion(1, 0, 0)
        )
        try CapabilityInstaller(library: allowedLibrary).install(
            package,
            into: allowedWorkspace,
            modelContext: allowedContext,
            policyContext: allowedPolicy
        )

        #expect(allowedWorkspace.enabledCapabilityIDs == [package.id])
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
            #expect(error.localizedDescription.contains("unsafe command or default arguments"))
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
                command: "python3",
                arguments: ["-c", "print"]
            )
        ]

        do {
            try CapabilityInstaller(library: library).install(package, into: workspace, modelContext: context)
            Issue.record("Install should have failed")
        } catch let error as CapabilityInstaller.InstallationError {
            #expect(error.localizedDescription.contains("unsafe command or default arguments"))
            #expect(error.localizedDescription.contains("interpreter execution flag"))
            #expect(library.installedPackages().isEmpty)
            #expect(workspace.enabledCapabilityIDs.isEmpty)
        }
    }

    @Test("uninstall removes the package, its activations and templates, and keeps its accounts")
    func uninstallRemovesPackageAndKeepsAccounts() throws {
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
        let connector = try #require(workspace.connectors.first { $0.name == "Google Cloud" })
        #expect(workspace.templates.map(\.name) == ["BQ Summary"])

        let result = try CapabilityUninstaller(library: library).remove(package, modelContext: context)

        #expect(result.packageID == package.id)
        #expect(result.disabledWorkspaceIDs == [workspace.id])
        #expect(result.removedConnectorIDs.isEmpty)
        #expect(result.removedTemplateIDs.count == 1)
        #expect(library.installedPackage(id: package.id) == nil)
        #expect(workspace.enabledCapabilityIDs.isEmpty)
        #expect(workspace.installedPluginIDs.isEmpty)
        #expect(workspace.templates.isEmpty)
        #expect(try context.fetch(FetchDescriptor<PluginActivation>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<AccountBinding>()).isEmpty)
        // Accounts outlive the plugin; deleting one is its own action.
        #expect(workspace.connectors.map(\.id) == [connector.id])
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

    @Test("uninstall leaves another plugin's activations alone")
    func uninstallKeepsOtherPluginActivations() throws {
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
        let secondAccount = try #require(secondWorkspace.connectors.first)

        _ = try CapabilityUninstaller(library: library).remove(firstPackage, modelContext: context)

        #expect(firstWorkspace.enabledCapabilityIDs.isEmpty)
        #expect(secondWorkspace.enabledCapabilityIDs == [secondPackage.id])
        #expect(library.installedPackage(id: firstPackage.id) == nil)
        #expect(library.installedPackage(id: secondPackage.id) != nil)
        let secondActivation = try #require(WorkspaceCapabilityActivation.activation(for: secondPackage.id, in: secondWorkspace))
        #expect(secondActivation.bindings.compactMap(\.account?.id) == [secondAccount.id])
        #expect(WorkspaceCapabilities(workspace: secondWorkspace, packageDefinitions: library.installedPackages()).activeSkills.map(\.name) == ["BigQuery Analyst"])
    }

}

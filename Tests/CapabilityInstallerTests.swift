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
        let workspaceFolder = FileManager.default.temporaryDirectory.appendingPathComponent("astra-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workspaceFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceFolder) }
        let workspace = Workspace(name: "Capability Workspace", primaryPath: workspaceFolder.path)
        context.insert(workspace)

        let (library, root) = makeCapabilityInstallerLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let package = makeAnalystCapabilityPackage()
        let result = try CapabilityInstaller(library: library).install(
            package,
            into: workspace,
            modelContext: context
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
        // activation. This plugin isn't a bundled one, so its setting is a
        // credential field of the account (Keychain), not a plain setting.
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: workspace))
        let connector = try #require(workspace.connectors.first)
        #expect(workspace.connectors.map(\.name) == ["Google Cloud"])
        #expect(activation.accounts(forComponent: "connector:google_cloud:google-cloud").map(\.id) == [connector.id])
        #expect(connector.skill == nil)
        #expect(connector.config.isEmpty)
        #expect(connector.credentialKeys == ["GCP_TOKEN", "GCP_PROJECT"])
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
        // Nothing reached the skill: the package has a connector, so the
        // skill's own setting stays at its default.
        #expect(skill.environmentVariables["GCP_PROJECT"] == "")
        #expect(activation.configKeys.isEmpty)
    }

    @Test("Add again with untouched setup fields keeps a bound account URL and settings; an edit still applies")
    func addAgainKeepsBoundAccountSetup() throws {
        let container = try makeCapabilityInstallerContainer()
        let context = container.mainContext
        let workspaceFolder = FileManager.default.temporaryDirectory.appendingPathComponent("astra-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workspaceFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceFolder) }
        let workspace = Workspace(name: "Jira site", primaryPath: workspaceFolder.path)
        context.insert(workspace)
        let (library, root) = makeCapabilityInstallerLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        workspace.primaryPath = root.appendingPathComponent("Workspace").path
        try FileManager.default.createDirectory(atPath: workspace.primaryPath, withIntermediateDirectories: true)
        let jira = try #require(PluginCatalog.builtInPackages.first { $0.id == "jira-workflow" })
        let spec = jira.connectors[0]
        let installer = CapabilityInstaller(library: library)
        try installer.enable(jira, in: workspace, modelContext: context)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: jira.id, in: workspace))
        let component = CapabilityResourceOrigin.componentID(for: spec)
        let account = try #require(activation.accounts(forComponent: component).first)
        account.baseURL = "https://clinic.atlassian.net"
        account.configKeys = ["JIRA_PROJECTS", "JIRA_BASE_URL"]
        account.configValues = ["CLIN", "https://clinic.atlassian.net"]
        try context.save()

        // R4 has no setup sheet; a submission of every default (a copied
        // setup, an older client) must still leave the account as it was.
        try installer.enable(
            jira, in: workspace, modelContext: context,
            configInputs: ["JIRA_BASE_URL": spec.baseURL, "JIRA_PROJECTS": ""],
            baseURLOverrides: [spec.name: spec.baseURL]
        )
        let kept = try #require(activation.accounts(forComponent: component).first)
        #expect(kept.id == account.id)
        #expect(kept.baseURL == "https://clinic.atlassian.net")
        #expect(kept.config["JIRA_PROJECTS"] == "CLIN")
        #expect(kept.config["JIRA_BASE_URL"] == "https://clinic.atlassian.net")
        // A component-keyed submission with the bound URL unchanged: the same.
        try installer.enable(
            jira, in: workspace, modelContext: context,
            configInputs: [PluginSetupInputs.key("JIRA_PROJECTS", component: component): ""],
            baseURLOverrides: [component: "https://clinic.atlassian.net"]
        )
        #expect(kept.baseURL == "https://clinic.atlassian.net" && kept.config["JIRA_PROJECTS"] == "CLIN")
        // A settings edit with the bound URL left untouched keeps the URL.
        try installer.enable(
            jira, in: workspace, modelContext: context,
            configInputs: [PluginSetupInputs.key("JIRA_PROJECTS", component: component): "CLIN, OPS"],
            baseURLOverrides: [component: "https://clinic.atlassian.net"]
        )
        let editedSettings = try #require(activation.accounts(forComponent: component).first)
        #expect(editedSettings.baseURL == "https://clinic.atlassian.net" && editedSettings.config["JIRA_PROJECTS"] == "CLIN, OPS")
        editedSettings.configValues = editedSettings.configKeys.map { $0 == "JIRA_PROJECTS" ? "CLIN" : editedSettings.config[$0] ?? "" }
        try context.save()
        // And an Update keeps what the person entered.
        var next = jira
        next.version = "99.0.0"
        try PluginUpdateService.reconcileAll(modelContext: context, packages: [next], mode: .release, approvalRecords: [])
        #expect(activation.recordedVersion == "99.0.0")
        #expect(editedSettings.baseURL == "https://clinic.atlassian.net" && editedSettings.config["JIRA_PROJECTS"] == "CLIN")

        // An edit applies, and what it doesn't name stays.
        try installer.enable(
            jira, in: workspace, modelContext: context,
            configInputs: ["JIRA_BASE_URL": "https://ops.atlassian.net"],
            baseURLOverrides: [spec.name: "https://ops.atlassian.net"]
        )
        let edited = try #require(activation.accounts(forComponent: component).first)
        #expect(edited.baseURL == "https://ops.atlassian.net")
        #expect(edited.config["JIRA_BASE_URL"] == "https://ops.atlassian.net")
        #expect(edited.config["JIRA_PROJECTS"] == "CLIN")
        withExtendedLifetime(container) {}
    }

    @Test("Add takes a template only by its component stamp, never an authored row by its name")
    func addMatchesTemplatesByStampNotName() throws {
        let container = try makeCapabilityInstallerContainer()
        let context = container.mainContext
        let workspaceFolder = FileManager.default.temporaryDirectory.appendingPathComponent("astra-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workspaceFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceFolder) }
        let workspace = Workspace(name: "Templates", primaryPath: workspaceFolder.path)
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

        // A stamped row is found by its component, never by name. One the
        // person edited since it was written (here, renamed) is theirs
        // (`PluginTemplateSync`): Add again keeps it, unstamped, and writes
        // the plugin's template beside it; the authored row stays untouched.
        stamped.name = "Renamed by me"
        try context.save()
        try CapabilityInstaller(library: library).enable(package, in: workspace, modelContext: context)
        #expect(workspace.templates.count == 3)
        #expect(authored.mainGoal == "My own goal" && authored.originPackageID == nil)
        #expect(stamped.name == "Renamed by me" && stamped.originPackageID == nil)
        let rewritten = try #require(workspace.templates.first { $0.originPackageID == package.id })
        #expect(rewritten.originComponentID == CapabilityResourceOrigin.componentID(for: spec))
        // An unedited stamped row is the one Add again writes, not another.
        try CapabilityInstaller(library: library).enable(package, in: workspace, modelContext: context)
        #expect(workspace.templates.count == 3)
        #expect(workspace.templates.filter { $0.originPackageID == package.id }.map(\.id) == [rewritten.id])
        withExtendedLifetime(container) {}
    }

    @Test("install records exact origin metadata on projected resources, accounts and templates")
    func installRecordsOriginMetadataOnResources() throws {
        let container = try makeCapabilityInstallerContainer()
        let context = container.mainContext
        let workspaceFolder = FileManager.default.temporaryDirectory.appendingPathComponent("astra-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workspaceFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceFolder) }
        let workspace = Workspace(name: "Origin", primaryPath: workspaceFolder.path)
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
        let workspaceFolder = FileManager.default.temporaryDirectory.appendingPathComponent("astra-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workspaceFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceFolder) }
        let workspace = Workspace(name: "Jira Config", primaryPath: workspaceFolder.path)
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

    @Test("two same-named connectors of one service with distinct IDs each get their own account")
    func sameNamedConnectorsGetSeparateAccounts() throws {
        let container = try makeCapabilityInstallerContainer()
        let context = container.mainContext
        let workspaceFolder = FileManager.default.temporaryDirectory.appendingPathComponent("astra-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workspaceFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceFolder) }
        let workspace = Workspace(name: "Two Sites", primaryPath: workspaceFolder.path)
        context.insert(workspace)
        let (library, root) = makeCapabilityInstallerLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        var package = makeAnalystCapabilityPackage()
        var second = package.connectors[0]
        package.connectors[0].id = "gcp-prod"
        second.id = "gcp-staging"
        second.configHints = [.init(key: "GCP_REGION", hint: "Region", isList: false)]
        package.connectors.append(second)
        // A plain skill setting each account carries; the connectors' own
        // settings are credentials (not a bundled plugin).
        package.skills[0].environmentKeys.append("GCP_DATASET")
        package.skills[0].environmentValues.append("")
        let installer = CapabilityInstaller(library: library)
        try installer.install(package, into: workspace, modelContext: context, configInputs: ["GCP_DATASET": "prod"])

        let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: workspace))
        let prodID = CapabilityResourceOrigin.componentID(for: package.connectors[0])
        let stagingID = CapabilityResourceOrigin.componentID(for: second)
        let prod = try #require(activation.accounts(forComponent: prodID).first)
        let staging = try #require(activation.accounts(forComponent: stagingID).first)
        #expect(workspace.connectors.count == 2 && prod.id != staging.id)
        #expect(prod.originComponentID == prodID && staging.originComponentID == stagingID)
        #expect(prod.credentialKeys == ["GCP_TOKEN", "GCP_PROJECT"] && staging.credentialKeys == ["GCP_TOKEN", "GCP_REGION"])
        #expect(prod.config == ["GCP_DATASET": "prod"] && staging.config == ["GCP_DATASET": "prod"])

        // Adding again with new settings keeps each component on its own row.
        try installer.install(package, into: workspace, modelContext: context, configInputs: ["GCP_DATASET": "staging"])
        #expect(workspace.connectors.count == 2)
        #expect(activation.accounts(forComponent: prodID).map(\.id) == [prod.id])
        #expect(activation.accounts(forComponent: stagingID).map(\.id) == [staging.id])
        #expect(staging.credentialKeys == ["GCP_TOKEN", "GCP_REGION"] && staging.config == ["GCP_DATASET": "staging"])
    }

    /// The setup sheet keys each connector's fields and base URL by its
    /// component ID; two same-named connectors keep their own values.
    @Test("Setup keyed by component ID reaches only that component's account")
    func componentKeyedSetupStaysWithItsConnector() throws {
        let container = try makeCapabilityInstallerContainer()
        let context = container.mainContext
        let workspaceFolder = FileManager.default.temporaryDirectory.appendingPathComponent("astra-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workspaceFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceFolder) }
        let workspace = Workspace(name: "Two Jiras", primaryPath: workspaceFolder.path)
        context.insert(workspace)
        let (library, root) = makeCapabilityInstallerLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        var package = try #require(PluginCatalog.builtInPackages.first { $0.id == "jira-workflow" })
        let index = try #require(package.connectors.firstIndex { $0.configHints.contains { $0.key == "JIRA_PROJECTS" } })
        var server = package.connectors[index]
        server.id = "jira-server"
        package.connectors.insert(server, at: index + 1)
        let cloud = package.connectors[index]
        #expect(cloud.name == server.name && cloud.setupComponentID != server.setupComponentID)
        try CapabilityInstaller(library: library).install(
            package, into: workspace, modelContext: context,
            configInputs: [PluginSetupInputs.key("JIRA_PROJECTS", component: cloud.setupComponentID): "ENG"],
            baseURLOverrides: [cloud.setupComponentID: "https://cloud.atlassian.net", server.setupComponentID: "https://jira.example.edu"]
        )

        let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: workspace))
        let cloudAccount = try #require(activation.accounts(forComponent: cloud.setupComponentID).first)
        let serverAccount = try #require(activation.accounts(forComponent: server.setupComponentID).first)
        #expect(cloudAccount.id != serverAccount.id)
        #expect(cloudAccount.baseURL == "https://cloud.atlassian.net" && serverAccount.baseURL == "https://jira.example.edu")
        #expect(cloudAccount.configValue("JIRA_PROJECTS") == "ENG")
        #expect(!serverAccount.configValues.contains("ENG"))
    }

    /// Two connectors of one plugin that declare the same fields, each with
    /// its own account values in the source workspace: copying the setup
    /// gives each component its own, never one value for both.
    @Test("Copied setup keeps each same-key connector's own values")
    func copiedSetupKeepsEachComponentsOwnValues() throws {
        let container = try makeCapabilityInstallerContainer()
        let context = container.mainContext
        let sourceFolder = FileManager.default.temporaryDirectory.appendingPathComponent("astra-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceFolder) }
        let source = Workspace(name: "Source", primaryPath: sourceFolder.path)
        let targetFolder = FileManager.default.temporaryDirectory.appendingPathComponent("astra-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: targetFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: targetFolder) }
        let target = Workspace(name: "Target", primaryPath: targetFolder.path)
        context.insert(source)
        context.insert(target)
        let (library, root) = makeCapabilityInstallerLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        var package = try #require(PluginCatalog.builtInPackages.first { $0.id == "jira-workflow" })
        let index = try #require(package.connectors.firstIndex { $0.configHints.contains { $0.key == "JIRA_PROJECTS" } })
        var server = package.connectors[index]
        server.id = "jira-server"
        package.connectors.insert(server, at: index + 1)
        let cloud = package.connectors[index]
        let installer = CapabilityInstaller(library: library)
        try context.save()
        try installer.install(
            package, into: source, modelContext: context,
            configInputs: [PluginSetupInputs.key("JIRA_PROJECTS", component: cloud.setupComponentID): "ENG"],
            baseURLOverrides: [cloud.setupComponentID: "https://cloud.atlassian.net", server.setupComponentID: "https://jira.example.edu"]
        )
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: source))
        let store = MockSecretStore()
        let cloudAccount = try #require(activation.accounts(forComponent: cloud.setupComponentID).first)
        let serverAccount = try #require(activation.accounts(forComponent: server.setupComponentID).first)
        for (account, token) in [(cloudAccount, "cloud-token"), (serverAccount, "server-token")] {
            for entityID in KeychainSecretStore.connectorEntityIDs(for: account) {
                store.save(key: "JIRA_API_TOKEN", value: token, entityID: entityID, label: nil)
            }
        }

        let copied = CapabilitySetupCopier(secretStore: store).installationInputs(for: package, from: source)
        #expect(copied.credentialInputs[PluginSetupInputs.key("JIRA_API_TOKEN", component: cloud.setupComponentID)] == "cloud-token")
        #expect(copied.credentialInputs[PluginSetupInputs.key("JIRA_API_TOKEN", component: server.setupComponentID)] == "server-token")
        #expect(copied.credentialInputs["JIRA_API_TOKEN"] == nil)
        #expect(copied.configInputs[PluginSetupInputs.key("JIRA_PROJECTS", component: cloud.setupComponentID)] == "ENG")
        #expect(copied.configInputs["JIRA_PROJECTS"] == nil)
        #expect(copied.baseURLOverrides == [
            cloud.setupComponentID: "https://cloud.atlassian.net", server.setupComponentID: "https://jira.example.edu"
        ])
        // Onboarding's flat view leaves out the token the two hold differently.
        let flat = PluginSetupInputs.flattened(copied, for: package.connectors)
        #expect(flat.credentialInputs["JIRA_API_TOKEN"] == nil)
        #expect(flat.configInputs["JIRA_PROJECTS"] == "ENG")

        // Added from the copy, each component's account gets its own.
        try installer.install(
            package, into: target, modelContext: context,
            configInputs: copied.configInputs, baseURLOverrides: copied.baseURLOverrides
        )
        let added = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: target))
        let addedCloud = try #require(added.accounts(forComponent: cloud.setupComponentID).first)
        let addedServer = try #require(added.accounts(forComponent: server.setupComponentID).first)
        #expect(addedCloud.baseURL == "https://cloud.atlassian.net" && addedServer.baseURL == "https://jira.example.edu")
        #expect(addedCloud.configValue("JIRA_PROJECTS") == "ENG")
        #expect(!addedServer.configValues.contains("ENG"))
    }

    @Test("A component reads its own setup over the shared one, never another component's")
    func setupInputViewsArePerComponent() {
        let inputs = [
            "SHARED": "s",
            PluginSetupInputs.key("TOKEN", component: "connector:jira:a"): "a",
            PluginSetupInputs.key("TOKEN", component: "connector:jira:b"): "b"
        ]
        #expect(PluginSetupInputs.view(inputs, component: "connector:jira:a") == ["SHARED": "s", "TOKEN": "a"])
        #expect(PluginSetupInputs.view(inputs, component: "connector:jira:c") == ["SHARED": "s"])

        // Copied setup (keyed by component) flattens to the shared keys
        // onboarding holds, leaving out what two components hold differently.
        let first = PluginConnector(name: "Jira", serviceType: "jira", icon: "", description: "", baseURL: "", authMethod: "bearer",
                                    credentialHints: [.init(key: "TOKEN", hint: "")], configHints: [], notes: "")
        var second = first
        second.id = "jira-server"
        let flat = PluginSetupInputs.flattened(OnboardingCapabilityInstallationInputs(
            credentialInputs: [
                PluginSetupInputs.key("TOKEN", component: first.setupComponentID): "a",
                PluginSetupInputs.key("TOKEN", component: second.setupComponentID): "b",
                PluginSetupInputs.key("EMAIL", component: first.setupComponentID): "e"
            ],
            configInputs: [
                PluginSetupInputs.key("DATASET", component: first.setupComponentID): "d",
                PluginSetupInputs.key("DATASET", component: second.setupComponentID): "d"
            ],
            baseURLOverrides: [first.setupComponentID: "https://x", second.setupComponentID: "https://y"]
        ), for: [first, second])
        #expect(flat.credentialInputs == ["EMAIL": "e"])
        #expect(flat.configInputs == ["DATASET": "d"])
        #expect(flat.baseURLOverrides.isEmpty)
    }

    @Test("configured source values stay scoped to their workspace")
    func configuredSourceValuesStayScopedToWorkspace() throws {
        let container = try makeCapabilityInstallerContainer()
        let context = container.mainContext
        let firstWorkspaceFolder = FileManager.default.temporaryDirectory.appendingPathComponent("astra-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: firstWorkspaceFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: firstWorkspaceFolder) }
        let firstWorkspace = Workspace(name: "First Jira", primaryPath: firstWorkspaceFolder.path)
        let secondWorkspaceFolder = FileManager.default.temporaryDirectory.appendingPathComponent("astra-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: secondWorkspaceFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: secondWorkspaceFolder) }
        let secondWorkspace = Workspace(name: "Second Jira", primaryPath: secondWorkspaceFolder.path)
        context.insert(firstWorkspace)
        context.insert(secondWorkspace)

        let (library, root) = makeCapabilityInstallerLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let package = try #require(PluginCatalog.builtInPackages.first { $0.id == "jira-workflow" })
        let installer = CapabilityInstaller(library: library)
        try context.save()
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
        let firstWorkspaceFolder = FileManager.default.temporaryDirectory.appendingPathComponent("astra-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: firstWorkspaceFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: firstWorkspaceFolder) }
        let firstWorkspace = Workspace(name: "First", primaryPath: firstWorkspaceFolder.path)
        let secondWorkspaceFolder = FileManager.default.temporaryDirectory.appendingPathComponent("astra-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: secondWorkspaceFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: secondWorkspaceFolder) }
        let secondWorkspace = Workspace(name: "Second", primaryPath: secondWorkspaceFolder.path)
        context.insert(firstWorkspace)
        context.insert(secondWorkspace)

        let (library, root) = makeCapabilityInstallerLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let package = makeAnalystCapabilityPackage()
        let installer = CapabilityInstaller(library: library)
        try context.save()
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
        let workspaceFolder = FileManager.default.temporaryDirectory.appendingPathComponent("astra-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workspaceFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceFolder) }
        let workspace = Workspace(name: "Update", primaryPath: workspaceFolder.path)
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

    @Test("An Update that drops a connector releases a shared account into scope only where the workspace lists it")
    func updateReleasesSharedAccountsByTheirOwnListing() throws {
        let container = try makeCapabilityInstallerContainer()
        let context = container.mainContext
        let workspaceFolder = FileManager.default.temporaryDirectory.appendingPathComponent("astra-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workspaceFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceFolder) }
        let workspace = Workspace(name: "Released Shared", primaryPath: workspaceFolder.path)
        context.insert(workspace)
        let (library, root) = makeCapabilityInstallerLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = makeAnalystCapabilityPackage()
        let installer = CapabilityInstaller(library: library)
        try installer.install(package, into: workspace, modelContext: context)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: workspace))
        let componentID = CapabilityResourceOrigin.componentID(for: package.connectors[0])
        let own = try #require(activation.accounts(forComponent: componentID).first)
        func shared(_ name: String) -> Connector {
            let connector = Connector(name: name, serviceType: "google_cloud", baseURL: "https://bigquery.googleapis.com", authMethod: "none")
            connector.isGlobal = true
            context.insert(connector)
            WorkspaceCapabilityActivation.bind(connector, toComponent: componentID, of: activation)
            return connector
        }
        let listed = shared("Listed GCP")
        let bindingOnly = shared("Bound GCP")
        CapabilitySharing.enableShared(listed, in: workspace)
        try context.save()

        var next = package
        next.version = "2.0.0"
        next.connectors = []
        try installer.install(next, into: workspace, modelContext: context)

        #expect(activation.bindings.filter { !$0.isDeleted }.isEmpty)
        // A binding never turned a shared account on here, so releasing one
        // doesn't either; the list keeps only what the person listed.
        #expect(WorkspaceCapabilityActivation.state(of: workspace).globalConnectorIDs == [listed.id.uuidString])
        let capabilities = WorkspaceCapabilities(
            workspace: workspace, globalConnectors: [listed, bindingOnly], packageDefinitions: [next]
        )
        let active = Set(capabilities.activeConnectors.map(\.id))
        #expect(active.contains(listed.id))
        #expect(!active.contains(bindingOnly.id))
        // The workspace's own account is still the plugin's while the plugin
        // is added here (`WorkspaceCapabilities.isPluginAccount`): it is shown
        // with the plugin, not as one of the workspace's authored connectors.
        #expect(!active.contains(own.id))
        let task = AgentTask(title: "Query", goal: "Run a BigQuery query", workspace: workspace)
        context.insert(task)
        let runtime = Set(TaskCapabilityResolver(task: task).allConnectors.map(\.id))
        #expect(runtime.contains(listed.id))
        #expect(!runtime.contains(bindingOnly.id))
    }

    @Test("Add ignores legacy plugin rows instead of rewriting them")
    func addLeavesLegacyRowsAlone() throws {
        let container = try makeCapabilityInstallerContainer()
        let context = container.mainContext
        let workspaceFolder = FileManager.default.temporaryDirectory.appendingPathComponent("astra-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workspaceFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceFolder) }
        let workspace = Workspace(name: "Legacy rows", primaryPath: workspaceFolder.path)
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
        let workspaceFolder = FileManager.default.temporaryDirectory.appendingPathComponent("astra-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workspaceFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceFolder) }
        let workspace = Workspace(name: "Authored account", primaryPath: workspaceFolder.path)
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
        let workspaceFolder = FileManager.default.temporaryDirectory.appendingPathComponent("astra-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workspaceFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceFolder) }
        let workspace = Workspace(name: "Standalone", primaryPath: workspaceFolder.path)
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
        let workspaceFolder = FileManager.default.temporaryDirectory.appendingPathComponent("astra-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workspaceFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceFolder) }
        let workspace = Workspace(name: "Blocked", primaryPath: workspaceFolder.path)
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
        let workspaceFolder = FileManager.default.temporaryDirectory.appendingPathComponent("astra-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workspaceFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceFolder) }
        let workspace = Workspace(name: "Policy Blocked", primaryPath: workspaceFolder.path)
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
        let workspaceFolder = FileManager.default.temporaryDirectory.appendingPathComponent("astra-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workspaceFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceFolder) }
        let workspace = Workspace(name: "Default Policy Blocked", primaryPath: workspaceFolder.path)
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
        let deniedWorkspaceFolder = FileManager.default.temporaryDirectory.appendingPathComponent("astra-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: deniedWorkspaceFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: deniedWorkspaceFolder) }
        let deniedWorkspace = Workspace(name: "Denied Role", primaryPath: deniedWorkspaceFolder.path)
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
        let allowedWorkspaceFolder = FileManager.default.temporaryDirectory.appendingPathComponent("astra-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: allowedWorkspaceFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: allowedWorkspaceFolder) }
        let allowedWorkspace = Workspace(name: "Allowed Role", primaryPath: allowedWorkspaceFolder.path)
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
        let workspaceFolder = FileManager.default.temporaryDirectory.appendingPathComponent("astra-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workspaceFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceFolder) }
        let workspace = Workspace(name: "Unsafe Tool", primaryPath: workspaceFolder.path)
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
        let workspaceFolder = FileManager.default.temporaryDirectory.appendingPathComponent("astra-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workspaceFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceFolder) }
        let workspace = Workspace(name: "Unsafe Tool Arguments", primaryPath: workspaceFolder.path)
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
        let workspaceFolder = FileManager.default.temporaryDirectory.appendingPathComponent("astra-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workspaceFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceFolder) }
        let workspace = Workspace(name: "Unsafe Connector", primaryPath: workspaceFolder.path)
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
        let workspaceFolder = FileManager.default.temporaryDirectory.appendingPathComponent("astra-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workspaceFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceFolder) }
        let workspace = Workspace(name: "Safe MCP", primaryPath: workspaceFolder.path)
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
        let workspaceFolder = FileManager.default.temporaryDirectory.appendingPathComponent("astra-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workspaceFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceFolder) }
        let workspace = Workspace(name: "Unsafe MCP", primaryPath: workspaceFolder.path)
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
        let workspaceFolder = FileManager.default.temporaryDirectory.appendingPathComponent("astra-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workspaceFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceFolder) }
        let workspace = Workspace(name: "Remove", primaryPath: workspaceFolder.path)
        context.insert(workspace)

        let (library, root) = makeCapabilityInstallerLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        workspace.primaryPath = root.appendingPathComponent("Workspace").path
        try FileManager.default.createDirectory(atPath: workspace.primaryPath, withIntermediateDirectories: true)

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
        let firstWorkspaceFolder = FileManager.default.temporaryDirectory.appendingPathComponent("astra-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: firstWorkspaceFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: firstWorkspaceFolder) }
        let firstWorkspace = Workspace(name: "First", primaryPath: firstWorkspaceFolder.path)
        let secondWorkspaceFolder = FileManager.default.temporaryDirectory.appendingPathComponent("astra-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: secondWorkspaceFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: secondWorkspaceFolder) }
        let secondWorkspace = Workspace(name: "Second", primaryPath: secondWorkspaceFolder.path)
        context.insert(firstWorkspace)
        context.insert(secondWorkspace)

        let (library, root) = makeCapabilityInstallerLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        firstWorkspace.primaryPath = root.appendingPathComponent("First").path
        secondWorkspace.primaryPath = root.appendingPathComponent("Second").path
        for workspace in [firstWorkspace, secondWorkspace] {
            try FileManager.default.createDirectory(atPath: workspace.primaryPath, withIntermediateDirectories: true)
        }

        var firstPackage = makeAnalystCapabilityPackage()
        firstPackage.id = "stanford.bigquery.first"
        var secondPackage = makeAnalystCapabilityPackage()
        secondPackage.id = "stanford.bigquery.second"

        try context.save()
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

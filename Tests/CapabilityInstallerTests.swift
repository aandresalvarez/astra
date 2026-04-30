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
                environmentKeys: [],
                environmentValues: []
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
        let connectors = try context.fetch(FetchDescriptor<Connector>(predicate: #Predicate { $0.isGlobal == true }))
        let tools = try context.fetch(FetchDescriptor<LocalTool>(predicate: #Predicate { $0.isGlobal == true }))

        #expect(library.installedPackages().map(\.id) == [package.id])
        #expect(workspace.skills.isEmpty)
        #expect(workspace.connectors.isEmpty)
        #expect(workspace.localTools.isEmpty)
        #expect(workspace.enabledGlobalSkillIDs == result.skillIDs.map(\.uuidString))
        #expect(workspace.enabledGlobalConnectorIDs.isEmpty)
        #expect(workspace.enabledGlobalToolIDs.isEmpty)
        #expect(workspace.enabledCapabilityIDs == [package.id])
        #expect(workspace.installedVersion(of: package.id) == package.version)

        let skill = try #require(skills.first)
        let connector = try #require(connectors.first)
        let tool = try #require(tools.first)
        #expect(skill.name == "BigQuery Analyst")
        #expect(connector.skill?.id == skill.id)
        #expect(connector.configValues == ["astra-dev"])
        #expect(tool.skill?.id == skill.id)
        #expect(result.connectorIDs == [connector.id])
        #expect(result.localToolIDs == [tool.id])

        let capabilities = WorkspaceCapabilities(
            workspace: workspace,
            globalSkills: skills,
            globalConnectors: connectors,
            globalTools: tools
        )
        #expect(capabilities.activeSkills.map(\.name) == ["BigQuery Analyst"])
        #expect(capabilities.activeConnectors.map(\.name) == ["Google Cloud"])
        #expect(capabilities.activeTools.map(\.name) == ["bq"])
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
}

import Foundation
import SwiftData
import Testing
@testable import ASTRA

private func makeCapabilityDefinitionRepairContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

private func makeCapabilityDefinitionRepairLibrary() -> (CapabilityLibrary, URL) {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("astra-capability-repair-\(UUID().uuidString)", isDirectory: true)
    return (CapabilityLibrary(directory: root), root)
}

@Suite("CapabilityDefinitionRepairService")
@MainActor
struct CapabilityDefinitionRepairServiceTests {
    @Test("Startup repair refreshes stale installed Jira global skill")
    func refreshesStaleInstalledJiraGlobalSkill() throws {
        let container = try makeCapabilityDefinitionRepairContainer()
        let context = container.mainContext
        let (library, root) = makeCapabilityDefinitionRepairLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let package = try #require(PluginCatalog.builtInPackages.first { $0.id == "jira-workflow" })
        var stalePackage = package
        stalePackage.version = "2.0.0"
        stalePackage.skills[0].behaviorInstructions = "Use /rest/api/3/search?jql=project=STAR."
        try library.install(stalePackage, sourceMetadata: .builtIn())

        let skill = Skill(
            name: "Jira Agent",
            icon: package.skills[0].icon,
            skillDescription: package.skills[0].description,
            allowedTools: ["Read"],
            behaviorInstructions: "Use /rest/api/3/search?jql=project=STAR."
        )
        skill.isGlobal = true
        context.insert(skill)
        try context.save()

        try library.syncApprovedPackages([package])
        CapabilityDefinitionRepairService.refreshInstalledApprovedDefinitions(
            modelContext: context,
            library: library,
            approvedPackages: [package]
        )

        #expect(library.installedVersion(of: "jira-workflow") == "2.0.2")
        #expect(skill.allowedTools == package.skills[0].allowedTools)
        #expect(skill.behaviorInstructions.contains("/rest/api/3/mypermissions"))
        #expect(skill.behaviorInstructions.contains("/rest/api/3/search/jql?jql="))
        #expect(!skill.behaviorInstructions.contains("/rest/api/3/search?jql="))
    }

    @Test("Startup repair refreshes workspace Jira skill tied to Jira connector")
    func refreshesWorkspaceJiraSkillWithJiraConnector() throws {
        let container = try makeCapabilityDefinitionRepairContainer()
        let context = container.mainContext
        let (library, root) = makeCapabilityDefinitionRepairLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let package = try #require(PluginCatalog.builtInPackages.first { $0.id == "jira-workflow" })
        try library.syncApprovedPackages([package])

        let workspace = Workspace(name: "Jira Workspace", primaryPath: "/tmp/jira-repair")
        context.insert(workspace)

        let skill = Skill(
            name: "Jira Agent",
            icon: package.skills[0].icon,
            skillDescription: package.skills[0].description,
            allowedTools: ["Read"],
            behaviorInstructions: "Old Jira behavior."
        )
        skill.workspace = workspace
        context.insert(skill)

        let connector = Connector(name: "Jira", serviceType: "Jira")
        connector.workspace = workspace
        context.insert(connector)
        try context.save()

        CapabilityDefinitionRepairService.refreshInstalledApprovedDefinitions(
            modelContext: context,
            library: library,
            approvedPackages: [package]
        )

        #expect(skill.behaviorInstructions.contains("/rest/api/3/mypermissions"))
        #expect(skill.behaviorInstructions.contains("Only recommend generating a new API token"))
    }

    @Test("Startup repair refreshes stale local package-created Jira skill")
    func refreshesStaleLocalJiraPackageCopy() throws {
        let container = try makeCapabilityDefinitionRepairContainer()
        let context = container.mainContext
        let (library, root) = makeCapabilityDefinitionRepairLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let package = try #require(PluginCatalog.builtInPackages.first { $0.id == "jira-workflow" })
        try library.syncApprovedPackages([package])

        let workspace = Workspace(name: "Jira Workspace", primaryPath: "/tmp/jira-local-repair")
        context.insert(workspace)

        let skill = Skill(
            name: "Jira Agent",
            icon: package.skills[0].icon,
            skillDescription: package.skills[0].description,
            allowedTools: ["Read"],
            behaviorInstructions: """
            You are a Jira integration agent. Use curl via Bash to interact with the Jira REST API.

            COMMON OPERATIONS
            • Search: GET /rest/api/3/search?jql=project=KEY
            """
        )
        skill.workspace = workspace
        context.insert(skill)
        try context.save()

        CapabilityDefinitionRepairService.refreshInstalledApprovedDefinitions(
            modelContext: context,
            library: library,
            approvedPackages: [package]
        )

        #expect(skill.behaviorInstructions.contains("/rest/api/3/mypermissions"))
        #expect(skill.behaviorInstructions.contains("/rest/api/3/search/jql?jql="))
        #expect(!skill.behaviorInstructions.contains("/rest/api/3/search?jql="))
    }
}

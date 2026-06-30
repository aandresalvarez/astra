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

        #expect(library.installedVersion(of: "jira-workflow") == "2.0.6")
        #expect(skill.allowedTools == package.skills[0].allowedTools)
        #expect(skill.behaviorInstructions.contains("operation status"))
        #expect(skill.behaviorInstructions.contains("operation search_jql"))
        #expect(!skill.behaviorInstructions.contains("/rest/api/3/mypermissions"))
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

        #expect(skill.behaviorInstructions.contains("operation status"))
        #expect(skill.behaviorInstructions.contains("operation search_jql"))
        #expect(!skill.behaviorInstructions.contains("/rest/api/3/mypermissions"))
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

        #expect(skill.behaviorInstructions.contains("operation status"))
        #expect(skill.behaviorInstructions.contains("operation search_jql"))
        #expect(!skill.behaviorInstructions.contains("/rest/api/3/mypermissions"))
        #expect(!skill.behaviorInstructions.contains("/rest/api/3/search?jql="))
    }

    @Test("Startup repair enables linked runtime resources for every enabled approved package")
    func enablesLinkedRuntimeResourcesForEveryEnabledApprovedPackage() throws {
        let packages = PluginCatalog.builtInPackages
        #expect(!packages.isEmpty)

        for package in packages {
            let container = try makeCapabilityDefinitionRepairContainer()
            let context = container.mainContext
            let (library, root) = makeCapabilityDefinitionRepairLibrary()
            defer { try? FileManager.default.removeItem(at: root) }

            try library.syncApprovedPackages([package])

            let workspace = Workspace(
                name: "\(package.name) Workspace",
                primaryPath: "/tmp/\(package.id)-activation-repair"
            )
            workspace.enabledCapabilityIDs = [package.id]
            context.insert(workspace)

            var globalSkills: [Skill] = []
            for pluginSkill in package.skills {
                let skill = Skill(
                    name: pluginSkill.name,
                    icon: pluginSkill.icon,
                    skillDescription: pluginSkill.description,
                    allowedTools: pluginSkill.allowedTools,
                    disallowedTools: pluginSkill.disallowedTools,
                    customTools: pluginSkill.customTools,
                    behaviorInstructions: pluginSkill.behaviorInstructions
                )
                skill.environmentKeys = pluginSkill.environmentKeys
                skill.environmentValues = pluginSkill.environmentValues
                skill.isGlobal = true
                context.insert(skill)
                globalSkills.append(skill)
            }

            var globalConnectors: [Connector] = []
            let primarySkill = globalSkills.first
            for pluginConnector in package.connectors {
                let connector = Connector(
                    name: pluginConnector.name,
                    serviceType: pluginConnector.serviceType,
                    icon: pluginConnector.icon,
                    connectorDescription: pluginConnector.description,
                    baseURL: pluginConnector.baseURL,
                    authMethod: pluginConnector.authMethod
                )
                connector.isGlobal = true
                connector.skill = primarySkill
                connector.credentialKeys = pluginConnector.credentialHints.map(\.key)
                connector.credentialValues = Array(repeating: "", count: connector.credentialKeys.count)
                connector.configKeys = pluginConnector.configHints.map(\.key)
                connector.configValues = Array(repeating: "", count: connector.configKeys.count)
                context.insert(connector)
                globalConnectors.append(connector)
            }

            try context.save()

            #expect(workspace.enabledGlobalSkillIDs.isEmpty)
            #expect(workspace.enabledGlobalConnectorIDs.isEmpty)

            CapabilityDefinitionRepairService.refreshInstalledApprovedDefinitions(
                modelContext: context,
                library: library,
                approvedPackages: [package]
            )

            let enabledSkillIDs = Set(workspace.enabledGlobalSkillIDs)
            let enabledConnectorIDs = Set(workspace.enabledGlobalConnectorIDs)
            let expectedSkillIDs = Set(globalSkills.map { $0.id.uuidString })
            let expectedConnectorIDs = Set(globalConnectors.map { $0.id.uuidString })

            #expect(
                expectedSkillIDs.isSubset(of: enabledSkillIDs),
                "Enabled package \(package.id) must activate its global skills."
            )
            #expect(
                expectedConnectorIDs.isSubset(of: enabledConnectorIDs),
                "Enabled package \(package.id) must activate its linked global connectors."
            )

            let capabilities = WorkspaceCapabilities(
                workspace: workspace,
                globalSkills: globalSkills,
                globalConnectors: globalConnectors
            )
            #expect(
                Set(capabilities.activeSkills.map { $0.id.uuidString }) == expectedSkillIDs,
                "Enabled package \(package.id) skills must be visible to runtime capability selection."
            )
            #expect(
                Set(capabilities.activeConnectors.map { $0.id.uuidString }) == expectedConnectorIDs,
                "Enabled package \(package.id) connectors must be visible to runtime capability selection."
            )
        }
    }

    @Test("Startup repair leaves disabled approved package connector disabled")
    func leavesDisabledApprovedPackageConnectorDisabled() throws {
        let container = try makeCapabilityDefinitionRepairContainer()
        let context = container.mainContext
        let (library, root) = makeCapabilityDefinitionRepairLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let package = try #require(PluginCatalog.builtInPackages.first { $0.id == "jira-workflow" })
        try library.syncApprovedPackages([package])

        let workspace = Workspace(name: "Disabled Jira Workspace", primaryPath: "/tmp/jira-disabled-repair")
        context.insert(workspace)

        let skill = Skill(
            name: "Jira Agent",
            icon: package.skills[0].icon,
            skillDescription: package.skills[0].description,
            allowedTools: package.skills[0].allowedTools,
            behaviorInstructions: package.skills[0].behaviorInstructions
        )
        skill.isGlobal = true
        context.insert(skill)

        let connector = Connector(name: "Jira-new", serviceType: "jira")
        connector.isGlobal = true
        connector.skill = skill
        context.insert(connector)
        try context.save()

        CapabilityDefinitionRepairService.refreshInstalledApprovedDefinitions(
            modelContext: context,
            library: library,
            approvedPackages: [package]
        )

        #expect(workspace.enabledGlobalSkillIDs.isEmpty)
        #expect(workspace.enabledGlobalConnectorIDs.isEmpty)
    }
}

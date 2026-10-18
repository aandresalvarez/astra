import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA
import ASTRACore

private func makeCapabilityUninstallerContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

private func makeCapabilityUninstallerLibrary() -> (CapabilityLibrary, URL) {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("astra-capability-uninstaller-\(UUID().uuidString)", isDirectory: true)
    return (CapabilityLibrary(directory: root), root)
}

@Suite("CapabilityUninstallerTests")
@MainActor
struct CapabilityUninstallerTests {
    @Test("local package uninstall removes the activation and leaves authored rows")
    func localPackageUninstallRemovesOnlyOriginOwnedResources() throws {
        let container = try makeCapabilityUninstallerContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Uninstall", primaryPath: "/tmp/capability-uninstall")
        context.insert(workspace)
        let (library, root) = makeCapabilityUninstallerLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let package = PluginPackage(
            id: "uninstall-package",
            name: "Uninstall Package",
            icon: "trash",
            description: "Package for uninstall test",
            author: "Tests",
            category: "Tests",
            tags: [],
            version: "1.0.0",
            skills: [
                PluginSkill(
                    name: "Owned Skill",
                    icon: "puzzlepiece.extension",
                    description: "Owned skill",
                    allowedTools: ["Read"],
                    disallowedTools: [],
                    customTools: [],
                    behaviorInstructions: "Use owned resources.",
                    environmentKeys: [],
                    environmentValues: []
                )
            ],
            connectors: [],
            localTools: [],
            templates: [],
            governance: .builtInApproved(riskLevel: .medium)
        )
        try CapabilityInstaller(library: library).install(package, into: workspace, modelContext: context)
        #expect(WorkspaceCapabilities(workspace: workspace, packageDefinitions: [package]).activeSkills.map(\.name) == ["Owned Skill"])
        let authoredSkill = Skill(name: "Owned Skill", allowedTools: ["Read"])
        authoredSkill.isGlobal = true
        context.insert(authoredSkill)

        let result = try CapabilityUninstaller(library: library).remove(package, modelContext: context)

        // The plugin's skill was never a row; an authored skill of the same
        // name is the person's and stays.
        #expect(result.removedSkillIDs.isEmpty)
        #expect(try context.fetch(FetchDescriptor<Skill>()).map(\.id) == [authoredSkill.id])
        #expect(try context.fetch(FetchDescriptor<PluginActivation>()).isEmpty)
        #expect(library.installedPackage(id: package.id) == nil)
        #expect(workspace.enabledCapabilityIDs.isEmpty)
    }

    @Test("an account kept on removal no longer makes the plugin look on when it is installed again")
    func keptAccountIsReleasedFromTheRemovedPlugin() throws {
        let container = try makeCapabilityUninstallerContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Kept Account", primaryPath: "/tmp/capability-kept-account")
        context.insert(workspace)
        let (library, root) = makeCapabilityUninstallerLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let package = PluginPackage(
            id: "kept-account-package", name: "Kept Account", icon: "server.rack", description: "Account test",
            author: "Tests", category: "Tests", tags: [], version: "1.0.0", skills: [],
            connectors: [PluginConnector(
                name: "Ticket Desk", serviceType: "ticket_desk", icon: "server.rack", description: "Tickets",
                baseURL: "https://tickets.example.test", authMethod: "none", credentialHints: [], configHints: [], notes: ""
            )],
            localTools: [], templates: [],
            governance: .builtInApproved(riskLevel: .medium)
        )
        try CapabilityInstaller(library: library).install(package, into: workspace, modelContext: context)
        let account = try #require(workspace.connectors.first)
        #expect(account.originPackageID == package.id)

        try CapabilityUninstaller(library: library).remove(package, modelContext: context)

        // The account and its namespace stay, without the plugin's stamp.
        #expect(try context.fetch(FetchDescriptor<Connector>()).map(\.id) == [account.id])
        #expect(account.originPackageID == nil && account.originComponentID == nil)

        // The same file installed again has no activation here: the
        // leftover account doesn't make it look on.
        try library.install(package)
        let capabilities = WorkspaceCapabilities(workspace: workspace, packageDefinitions: library.installedPackages())
        #expect(WorkspaceCapabilityActivation.activation(for: package.id, in: workspace) == nil)
        #expect(!CapabilityPackageState(package: package, workspace: workspace, capabilities: capabilities).isEnabled)
        let rail = CapabilityRailPackageSnapshotState(
            package: package,
            index: CapabilityRailWorkspaceResourceIndex(workspace: workspace, capabilities: capabilities)
        )
        #expect(!rail.isEnabled)
    }

    @Test("Remove keeps a workspace's own override rows out of its scope, and Add makes them overrides again")
    func removeRetiresLocalOverrides() throws {
        let container = try makeCapabilityUninstallerContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Retired Overrides", primaryPath: "/tmp/capability-retired-overrides")
        context.insert(workspace)
        let (library, root) = makeCapabilityUninstallerLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = retirementPackage(id: "retired-overrides-package")
        let installer = CapabilityInstaller(library: library)
        try installer.install(package, into: workspace, modelContext: context)
        // The person's own edited skill and tool replace the plugin's.
        let skill = Skill(name: "My Report", allowedTools: ["Read"], behaviorInstructions: "My own report rules.")
        skill.workspace = workspace
        context.insert(skill)
        let tool = LocalTool(name: "my-report", toolType: "cli", command: "echo", arguments: "mine")
        tool.workspace = workspace
        context.insert(tool)
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: workspace))
        let skillComponent = CapabilityResourceOrigin.componentID(for: package.skills[0])
        let toolComponent = CapabilityResourceOrigin.componentID(for: package.localTools[0])
        WorkspaceCapabilityActivation.setOverridden(true, componentID: skillComponent, rowID: skill.id, on: activation)
        WorkspaceCapabilityActivation.setOverridden(true, componentID: toolComponent, rowID: tool.id, on: activation)
        try context.save()
        func inScope() -> (skill: Bool, tool: Bool) {
            let capabilities = WorkspaceCapabilities(workspace: workspace, packageDefinitions: library.installedPackages())
            return (capabilities.activeSkills.contains { $0.id == skill.id }, capabilities.activeTools.contains { $0.id == tool.id })
        }
        #expect(inScope() == (true, true))

        try CapabilityUninstaller(library: library).remove(package, modelContext: context)

        // Kept, listed, and acting for nothing.
        #expect(try context.fetch(FetchDescriptor<Skill>()).map(\.id) == [skill.id])
        #expect(try context.fetch(FetchDescriptor<LocalTool>()).map(\.id) == [tool.id])
        #expect(WorkspaceCapabilities(workspace: workspace).workspaceSkills.map(\.id) == [skill.id])
        #expect(inScope() == (false, false))
        // The workspace's own mirror carries what Remove kept.
        let config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: context))
        #expect(config.retiredPlugins?.first?.overridingRowIDs.sorted() == [skill.id.uuidString, tool.id.uuidString].sorted())

        try installer.install(package, into: workspace, modelContext: context)
        let added = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: workspace))
        #expect(added.overridingRowID(forComponent: skillComponent) == skill.id)
        #expect(added.overridingRowID(forComponent: toolComponent) == tool.id)
        #expect(inScope() == (true, true))
        #expect(WorkspaceCapabilityActivation.retiredActivations(of: workspace).isEmpty)
    }

    @Test("Remove keeps an activation's namespace seed, so Add resolves the schedules that name its skills")
    func removeKeepsNamespaceSeed() throws {
        let container = try makeCapabilityUninstallerContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Retired Seed", primaryPath: "/tmp/capability-retired-seed")
        context.insert(workspace)
        let (library, root) = makeCapabilityUninstallerLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = retirementPackage(id: "retired-seed-package")
        let installer = CapabilityInstaller(library: library)
        try installer.install(package, into: workspace, modelContext: context)
        // As a chosen-file import leaves it: its own seed, and a schedule
        // pointed at the projected ID that seed derives.
        let activation = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: workspace))
        WorkspaceCapabilityActivation.setNamespaceSeed("imported-seed", on: activation)
        let component = CapabilityResourceOrigin.componentID(for: package.skills[0])
        let seeded = PluginRuntimeProjection.derivedID(of: activation, componentID: component)
        let schedule = TaskSchedule(name: "Weekly report")
        schedule.skillIDs = [seeded.uuidString]
        schedule.workspace = workspace
        context.insert(schedule)
        try context.save()

        try CapabilityUninstaller(library: library).remove(package, modelContext: context)
        try installer.install(package, into: workspace, modelContext: context)

        let added = try #require(WorkspaceCapabilityActivation.activation(for: package.id, in: workspace))
        #expect(added.namespaceSeed == "imported-seed")
        let projected = PluginRuntimeProjection.project(workspace: workspace, packages: library.installedPackages()).skills
        #expect(projected.map(\.id) == [seeded])
        #expect(schedule.skillIDs == [seeded.uuidString])
    }

    private func retirementPackage(id: String) -> PluginPackage {
        PluginPackage(
            id: id, name: "Reports", icon: "doc.text", description: "Report plugin",
            author: "Tests", category: "Tests", tags: [], version: "1.0.0",
            skills: [PluginSkill(
                name: "Report Writer", icon: "doc.text", description: "Writes reports", allowedTools: ["Read"],
                disallowedTools: [], customTools: [], behaviorInstructions: "Plugin report rules.",
                environmentKeys: [], environmentValues: []
            )],
            connectors: [],
            localTools: [PluginLocalTool(
                name: "report", description: "Report tool", icon: "terminal", toolType: "cli", command: "echo", arguments: "plugin"
            )],
            templates: [],
            governance: .builtInApproved(riskLevel: .medium)
        )
    }
}

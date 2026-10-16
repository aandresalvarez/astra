import Foundation
import SwiftData
import Testing
import ASTRAModels
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
}

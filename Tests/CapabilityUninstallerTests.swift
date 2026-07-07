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
    @Test("local package uninstall removes only origin-owned resources")
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
        let ownedSkill = try #require(try context.fetch(FetchDescriptor<Skill>(
            predicate: #Predicate { $0.isGlobal == true && $0.originPackageID == "uninstall-package" }
        )).first)
        let legacySkill = Skill(name: "Owned Skill", allowedTools: ["Read"])
        legacySkill.isGlobal = true
        context.insert(legacySkill)

        let result = try CapabilityUninstaller(library: library).remove(package, modelContext: context)

        #expect(result.removedSkillIDs == [ownedSkill.id])
        #expect(try context.fetch(FetchDescriptor<Skill>()).contains { $0.id == legacySkill.id })
        #expect(try context.fetch(FetchDescriptor<Skill>()).contains { $0.id == ownedSkill.id } == false)
        #expect(library.installedPackage(id: package.id) == nil)
        #expect(workspace.enabledCapabilityIDs.isEmpty)
    }
}

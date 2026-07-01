import Foundation
import Testing
@testable import ASTRA
import ASTRACore

@Suite("Composer capability snapshot")
struct ComposerCapabilitySnapshotTests {
    @Test("Snapshot builder uses preloaded package definitions and filters selected skills")
    @MainActor
    func snapshotBuilderUsesPreloadedPackageDefinitions() {
        let workspace = Workspace(name: "Composer", primaryPath: "/tmp/composer")
        workspace.enabledCapabilityIDs = ["composer-pack"]

        let globalSkill = Skill(name: "Composer Agent", allowedTools: ["Read"])
        globalSkill.isGlobal = true

        let package = PluginPackage(
            id: "composer-pack",
            name: "Composer Pack",
            icon: "sparkles",
            description: "Composer capability",
            author: "ASTRA",
            category: "Productivity",
            tags: [],
            version: "1.0.0",
            skills: [
                PluginSkill(
                    name: "Composer Agent",
                    icon: "sparkles",
                    description: "Helps compose tasks",
                    allowedTools: ["Read"],
                    disallowedTools: [],
                    customTools: [],
                    behaviorInstructions: "Help compose tasks.",
                    environmentKeys: [],
                    environmentValues: []
                )
            ],
            connectors: [],
            localTools: [],
            templates: []
        )

        let snapshot = ComposerCapabilitySnapshotBuilder.make(
            workspace: workspace,
            globalSkills: [globalSkill],
            globalConnectors: [],
            globalTools: [],
            packageDefinitions: [package],
            packPolicy: .empty
        )

        #expect(snapshot.availableSkills.map(\.name) == ["Composer Agent"])
        #expect(snapshot.selectedSkills(excluding: [globalSkill.id]).isEmpty)
        #expect(snapshot.selectedSkills(excluding: []).map(\.name) == ["Composer Agent"])
    }
}

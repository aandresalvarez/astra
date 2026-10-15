import Foundation
import SwiftData
import Testing
import ASTRAModels
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

    @Test("Loader treats a deleted or detached workspace as no workspace")
    @MainActor
    func loaderTreatsDeletedWorkspaceAsNone() throws {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext

        let detached = Workspace(name: "Detached", primaryPath: "/tmp/composer-detached")
        #expect(ComposerCapabilitySnapshotLoader.live(detached) == nil)
        #expect(ComposerCapabilitySnapshotLoader.live(nil) == nil)

        let workspace = Workspace(name: "Live", primaryPath: "/tmp/composer-live")
        context.insert(workspace)
        try context.save()
        #expect(ComposerCapabilitySnapshotLoader.live(workspace) === workspace)

        context.delete(workspace)
        #expect(ComposerCapabilitySnapshotLoader.live(workspace) == nil)
        try context.save()
        #expect(ComposerCapabilitySnapshotLoader.live(workspace) == nil)
        withExtendedLifetime(container) {}
    }
}

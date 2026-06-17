import Foundation
import Testing
@testable import ASTRA

/// Free-text generation must cover the archetype range and never emit a read-only shell.
@Suite("Workspace App Archetypes")
struct WorkspaceAppArchetypeTests {
    @Test("intent classification routes to the right archetype, never a read-only shell")
    func classification() {
        #expect(WorkspaceAppArchetype.classify("build a rubik's cube solver") == .dataEntry)
        #expect(WorkspaceAppArchetype.classify("store my groceries in a database") == .localDatabase)
        #expect(WorkspaceAppArchetype.classify("a grocery tracker") == .localDatabase)
        #expect(WorkspaceAppArchetype.classify("automate my weekly review pipeline") == .pipeline)
        #expect(WorkspaceAppArchetype.classify("generate a weekly report") == .reportGenerator)
        #expect(WorkspaceAppArchetype.classify("monitor enrollment and alert when low") == .monitor)
        #expect(WorkspaceAppArchetype.classify("a review queue for incoming tickets") == .reviewQueue)
        #expect(WorkspaceAppArchetype.classify("a dashboard of project metrics") == .dashboard)
        #expect(WorkspaceAppArchetype.classify("flashcards for spanish vocab") == .dataEntry)
    }

    @Test("every archetype recipe produces a publishable, usable manifest")
    func everyRecipeIsValid() {
        for archetype in WorkspaceAppArchetype.allCases {
            let manifest = WorkspaceAppStudioRecipes.manifest(for: archetype, intent: "manage project widgets")
            let report = WorkspaceAppManifestValidator.validate(manifest)
            #expect(report.isValid, "\(archetype.label) recipe should be valid; blockers: \(report.blockers)")
            let hasPopulatingPath = manifest.actions.contains { $0.type == "appStorage.insert" }
                || manifest.actions.contains { ["pipeline.run", "loop.run", "capability.write"].contains($0.type) }
                || manifest.views.contains { $0.type == "form" && !$0.formFields.isEmpty }
            #expect(hasPopulatingPath, "\(archetype.label) recipe should have a populating path")
        }
    }

    @Test("free-text generation no longer yields a read-only shell")
    func freeTextIsUsable() {
        let manifest = WorkspaceAppStudioBuilder.baseManifest(intent: "build a rubik's cube solver")
        #expect(WorkspaceAppManifestValidator.validate(manifest).isValid)
        #expect(manifest.actions.contains { $0.type == "appStorage.insert" })
    }

    @Test("pipeline recipe yields a runnable pipeline action")
    func pipelineHasPipelineAction() {
        let manifest = WorkspaceAppStudioRecipes.manifest(for: .pipeline, intent: "process intake forms")
        #expect(manifest.actions.contains { $0.type == "pipeline.run" })
        #expect(WorkspaceAppManifestValidator.validate(manifest).isValid)
    }

    @Test("report recipe yields an export action")
    func reportHasExport() {
        let manifest = WorkspaceAppStudioRecipes.manifest(for: .reportGenerator, intent: "weekly status report")
        #expect(manifest.actions.contains { $0.type == "artifact.export" })
        #expect(WorkspaceAppManifestValidator.validate(manifest).isValid)
    }
}

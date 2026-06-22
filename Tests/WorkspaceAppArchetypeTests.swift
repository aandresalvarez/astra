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
        #expect(WorkspaceAppArchetype.classify("orchestrate an AI agent to triage records") == .agenticWorkflow)
        #expect(WorkspaceAppArchetype.classify("an agentic workflow that reviews and acts") == .agenticWorkflow)
        // Interactive tools route to the HTML-app archetype, not a data shell.
        #expect(WorkspaceAppArchetype.classify("a calculator with buttons") == .htmlApp)
        #expect(WorkspaceAppArchetype.classify("a unit conversion tool") == .htmlApp)
        #expect(WorkspaceAppArchetype.classify("a countdown timer") == .htmlApp)
    }

    @Test("UI-centric intents route to the HTML app (so the fallback is dynamic, not a data shell)")
    func uiCentricToHtmlApp() {
        #expect(WorkspaceAppArchetype.classify("a ui to manage open PRs and comments") == .htmlApp)
        #expect(WorkspaceAppArchetype.classify("an interactive interface for task management") == .htmlApp)
        #expect(WorkspaceAppArchetype.classify("build me a dynamic ui dashboard") == .htmlApp)
        #expect(WorkspaceAppArchetype.classify("a single page app to organize files") == .htmlApp)
    }

    @Test("UI language over a genuine data intent still routes to the data archetype")
    func dataCentricIgnoresUILanguage() {
        #expect(WorkspaceAppArchetype.classify("a ui to manage my grocery database") == .localDatabase)
        #expect(WorkspaceAppArchetype.classify("an interactive interface to track inventory") == .localDatabase)
    }

    @Test("every archetype recipe produces a publishable, usable manifest")
    func everyRecipeIsValid() {
        for archetype in WorkspaceAppArchetype.allCases {
            let manifest = WorkspaceAppStudioRecipes.manifest(for: archetype, intent: "manage project widgets")
            let report = WorkspaceAppManifestValidator.validate(manifest)
            #expect(report.isValid, "\(archetype.label) recipe should be valid; blockers: \(report.blockers)")
            // An HTML app renders a self-contained UI (no storage), so the populating-path invariant
            // doesn't apply — it must instead carry non-empty html.
            if archetype == .htmlApp {
                #expect(manifest.html?.isEmpty == false, "htmlApp recipe should carry html")
                continue
            }
            let hasPopulatingPath = manifest.actions.contains { $0.type == "appStorage.insert" }
                || manifest.actions.contains { ["pipeline.run", "loop.run", "capability.write"].contains($0.type) }
                || manifest.views.contains { $0.type == "form" && !$0.formFields.isEmpty }
            #expect(hasPopulatingPath, "\(archetype.label) recipe should have a populating path")
        }
    }

    @Test("htmlApp recipe is the deterministic HTML fallback, not a data shell")
    func htmlAppRecipeIsHTMLScaffold() {
        let manifest = WorkspaceAppStudioRecipes.manifest(for: .htmlApp, intent: "a calculator")
        #expect(manifest.html?.isEmpty == false)
        #expect(manifest.storage == nil)
        #expect(manifest.actions.isEmpty)
        #expect(WorkspaceAppManifestValidator.validate(manifest).isValid)
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

    @Test("agentic-workflow recipe chains an AI task pipeline behind governed gates")
    func agenticWorkflowHasGovernedAIPipeline() {
        let manifest = WorkspaceAppStudioRecipes.manifest(for: .agenticWorkflow, intent: "review and act on incoming records")
        #expect(manifest.actions.contains { $0.type == "task.createAndRun" })
        #expect(manifest.actions.contains { $0.type == "pipeline.run" })
        #expect(manifest.actions.contains { $0.type == "gate.agentRecommendation" })
        #expect(manifest.actions.contains { $0.type == "gate.humanApproval" })
        // The analysis answer is captured and fed into the implementation step (app⇄agent memory).
        #expect(manifest.actions.contains { $0.outputBinding != nil })
        #expect(manifest.actions.contains { $0.inputBinding != nil })
        // An AI workflow that runs tasks must be governed, not draft-only.
        #expect(manifest.permissions.defaultMode == .approvalRequired)
        #expect(WorkspaceAppManifestValidator.validate(manifest).isValid)
    }
}

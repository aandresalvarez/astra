import Foundation
import Testing
@testable import ASTRA

/// The Studio UX redesign logic: Phase 1 identity (plain-language hero), Phase 2 archetype catalog
/// metadata, Phase 4 refinement transforms. All pure + manifest-derived, so the SwiftUI views are
/// thin renderers over what these assert.
@Suite("Workspace App Studio UX")
struct WorkspaceAppStudioUXTests {
    private func base(archetype: String = "Review Queue", mode: WorkspaceAppPermissionMode = .draftOnly) -> WorkspaceAppManifest {
        WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(id: "triage", name: "Bug Triage", description: "", archetypes: [archetype]),
            storage: WorkspaceAppStorageSchema(tables: [
                WorkspaceAppStorageTable(name: "items", columns: [
                    WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                    WorkspaceAppStorageColumn(name: "title", type: "text", required: true),
                    WorkspaceAppStorageColumn(name: "status", type: "text")
                ])
            ]),
            views: [
                WorkspaceAppViewSpec(id: "overview", type: "dashboard", title: "Overview", table: "items", widgets: [
                    WorkspaceAppWidgetSpec(id: "count", type: "metric", label: "Items", aggregation: "count")
                ]),
                WorkspaceAppViewSpec(id: "table", type: "table", title: "Items", table: "items")
            ],
            actions: [
                WorkspaceAppActionSpec(id: "list", type: "appStorage.query", label: "List", table: "items"),
                WorkspaceAppActionSpec(id: "add", type: "appStorage.insert", label: "Add", table: "items")
            ],
            permissions: WorkspaceAppPermissions(reads: ["appStorage.records"], writes: ["appStorage.records"], defaultMode: mode)
        )
    }

    private func valid(_ manifest: WorkspaceAppManifest) -> Bool {
        WorkspaceAppManifestValidator.validate(manifest).isValid
    }

    // MARK: - Phase 1: identity

    @Test("identity surfaces the archetype, plain capabilities, and a plain permission")
    func identityBasics() {
        let manifest = base()
        let identity = WorkspaceAppStudioIdentityBuilder.identity(for: manifest, report: WorkspaceAppManifestValidator.validate(manifest))
        #expect(identity.archetypeLabel == "Review Queue")
        #expect(identity.iconSystemName == "checklist")
        #expect(identity.capabilities.contains("Add and edit records"))
        #expect(identity.capabilities.contains("See summary metrics"))
        #expect(identity.permissionSummary == "Stays on your machine — no external systems")
        #expect(identity.isReadyToPublish)
    }

    @Test("identity permission + capabilities reflect an external-write app in plain English")
    func identityExternalWrite() {
        let manifest = WorkspaceAppStudioRefinement.connectREDCap.apply(to: base(mode: .approvalRequired))
        let identity = WorkspaceAppStudioIdentityBuilder.identity(for: manifest, report: WorkspaceAppManifestValidator.validate(manifest))
        #expect(identity.permissionSummary.contains("external"))
        #expect(identity.capabilities.contains("Write to a connected system"))
    }

    @Test("identity falls back to the archetype tagline when the manifest has no description")
    func identityPurposeFallback() {
        var manifest = base()
        manifest.app.description = ""
        let identity = WorkspaceAppStudioIdentityBuilder.identity(for: manifest, report: WorkspaceAppManifestValidator.validate(manifest))
        #expect(identity.purpose == WorkspaceAppArchetype.reviewQueue.tagline)
    }

    @Test("identity uses the archetype tagline instead of the recipe's boilerplate description")
    func identityPrefersTaglineOverBoilerplate() {
        var manifest = base()
        manifest.app.description = "Draft operational app surface generated from the requested workflow."
        let identity = WorkspaceAppStudioIdentityBuilder.identity(for: manifest, report: WorkspaceAppManifestValidator.validate(manifest))
        #expect(identity.purpose == WorkspaceAppArchetype.reviewQueue.tagline)
    }

    @Test("a generated name drops a trailing connector instead of ending mid-phrase")
    func nameTrimsTrailingConnector() {
        let manifest = WorkspaceAppStudioBuilder.baseManifest(intent: "triage incoming issues by status")
        #expect(manifest.app.name == "Triage Incoming Issues")
    }

    @Test("a generated name keeps acronyms uppercased and mid-name connectors lowercased")
    func nameAcronymAndConnectorCasing() {
        let manifest = WorkspaceAppStudioBuilder.baseManifest(intent: "Orchestrate an AI agent to review and act on records")
        #expect(manifest.app.name == "Orchestrate an AI Agent")
    }

    // MARK: - Phase 2: catalog

    @Test("every archetype has display name, icon, tagline, and an example intent")
    func catalogMetadata() {
        for archetype in WorkspaceAppArchetype.allCases {
            #expect(!archetype.displayName.isEmpty)
            #expect(!archetype.iconSystemName.isEmpty)
            #expect(!archetype.tagline.isEmpty)
            #expect(!archetype.exampleIntent.isEmpty)
            // The example intent classifies back to the same archetype (the picker stays honest).
            #expect(WorkspaceAppArchetype.classify(archetype.exampleIntent) == archetype)
        }
    }

    @Test("from(label:) maps manifest and curated archetype labels to an icon source")
    func catalogFromLabel() {
        #expect(WorkspaceAppArchetype.from(label: "Review Queue") == .reviewQueue)
        #expect(WorkspaceAppArchetype.from(label: "Local Database App") == .localDatabase)
        #expect(WorkspaceAppArchetype.from(label: "Agentic Workflow") == .agenticWorkflow)
        #expect(WorkspaceAppArchetype.from(label: "Reconciliation App") == .reviewQueue)
        #expect(WorkspaceAppArchetype.from(label: "Completely Unknown") == nil)
    }

    // MARK: - Phase 4: refinements

    @Test("add-a-chart appends a chart, keeps the manifest valid, and becomes unavailable")
    func refineAddChart() {
        let manifest = base()
        #expect(WorkspaceAppStudioRefinement.addChart.isAvailable(for: manifest))
        let updated = WorkspaceAppStudioRefinement.addChart.apply(to: manifest)
        #expect(updated.views.flatMap(\.widgets).contains { $0.type == "chart" })
        #expect(valid(updated))
        #expect(!WorkspaceAppStudioRefinement.addChart.isAvailable(for: updated))
    }

    @Test("add-a-rich-report appends a sandboxed webView/htmlReport widget, stays valid, idempotent")
    func refineAddRichReport() {
        let manifest = base()
        #expect(WorkspaceAppStudioRefinement.addRichReport.isAvailable(for: manifest))
        let updated = WorkspaceAppStudioRefinement.addRichReport.apply(to: manifest)
        let webWidgets = updated.views.flatMap(\.widgets).filter { $0.type == "webView" }
        #expect(webWidgets.count == 1)
        #expect(webWidgets.first?.webRenderer == "htmlReport")
        #expect(valid(updated))
        #expect(!WorkspaceAppStudioRefinement.addRichReport.isAvailable(for: updated))
    }

    @Test("approval, weekly-summary, and connect-REDCap refinements apply and stay valid")
    func refineOthers() {
        let manifest = base(mode: .approvalRequired)

        let approval = WorkspaceAppStudioRefinement.addApproval.apply(to: manifest)
        #expect(approval.actions.contains { $0.type == "gate.humanApproval" })
        #expect(valid(approval))

        let summary = WorkspaceAppStudioRefinement.weeklySummary.apply(to: manifest)
        #expect(summary.actions.contains { $0.id == "weekly_summary" })
        #expect(summary.actions.contains { $0.type == "artifact.export" })
        #expect(valid(summary))

        let redcap = WorkspaceAppStudioRefinement.connectREDCap.apply(to: manifest)
        #expect(redcap.requirements.contains { $0.contract == "recordProject.write" })
        #expect(redcap.actions.contains { $0.type == "capability.write" })
        #expect(redcap.permissions.externalWrites.contains("recordProject.write"))
        #expect(valid(redcap))
        #expect(!WorkspaceAppStudioRefinement.connectREDCap.isAvailable(for: redcap))
    }

    @Test("connect-REDCap steps a draft-only app up to approval-gated so the external write is allowed")
    func refineREDCapStepsUpMode() {
        let updated = WorkspaceAppStudioRefinement.connectREDCap.apply(to: base(mode: .draftOnly))
        #expect(updated.permissions.defaultMode == .approvalRequired)
        #expect(valid(updated))
    }
}

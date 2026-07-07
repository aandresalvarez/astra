import Foundation
import Testing
@testable import ASTRA

/// The validator safety net that stops generation (model OR deterministic) from shipping a
/// "looks valid but can't be used" app: a dashboard over a table nothing can fill, or a
/// write-labeled button wired to a read.
@Suite("Workspace App Usability Invariants")
struct WorkspaceAppUsabilityInvariantTests {
    private func dashboardOverTable(actions: [WorkspaceAppActionSpec]) -> WorkspaceAppManifest {
        WorkspaceAppManifest(
            app: WorkspaceAppManifestMetadata(id: "shell", name: "Shell"),
            storage: WorkspaceAppStorageSchema(tables: [
                WorkspaceAppStorageTable(name: "review_items", columns: [
                    WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                    WorkspaceAppStorageColumn(name: "title", type: "text", required: true)
                ])
            ]),
            views: [
                WorkspaceAppViewSpec(
                    id: "overview", type: "dashboard", title: "Overview", table: "review_items",
                    widgets: [WorkspaceAppWidgetSpec(id: "count", type: "metric", label: "Count", aggregation: "count")]
                )
            ],
            actions: actions,
            permissions: WorkspaceAppPermissions(defaultMode: .draftOnly)
        )
    }

    @Test("a read-only dashboard over an unfillable table is blocked")
    func readOnlyShellBlocked() {
        let report = WorkspaceAppManifestValidator.validate(dashboardOverTable(actions: [
            WorkspaceAppActionSpec(id: "list", type: "appStorage.query", label: "List Items"),
            WorkspaceAppActionSpec(id: "task", type: "task.createDraft", label: "Create Task", taskGoal: "Review.")
        ]))
        #expect(!report.isValid)
        #expect(report.blockers.contains { $0.path == "/storage" })
    }

    @Test("an appStorage.insert action makes the table populatable and the app publishable")
    func insertMakesPopulatable() {
        let report = WorkspaceAppManifestValidator.validate(dashboardOverTable(actions: [
            WorkspaceAppActionSpec(id: "list", type: "appStorage.query", label: "List Items"),
            WorkspaceAppActionSpec(id: "add", type: "appStorage.insert", label: "Add Item", table: "review_items")
        ]))
        #expect(report.isValid)
    }

    @Test("a workflow (pipeline.run) also counts as a populating path")
    func workflowPopulates() {
        let report = WorkspaceAppManifestValidator.validate(dashboardOverTable(actions: [
            WorkspaceAppActionSpec(id: "list", type: "appStorage.query", label: "List Items"),
            WorkspaceAppActionSpec(id: "run", type: "pipeline.run", label: "Run", steps: ["list"])
        ]))
        #expect(report.isValid)
    }

    @Test("a write-labeled action wired to a read is blocked (the 'Save Cube State'=query defect)")
    func labelEffectMismatchBlocked() {
        let report = WorkspaceAppManifestValidator.validate(dashboardOverTable(actions: [
            WorkspaceAppActionSpec(id: "save", type: "appStorage.query", label: "Save Cube State"),
            WorkspaceAppActionSpec(id: "add", type: "appStorage.insert", label: "Add Item", table: "review_items")
        ]))
        #expect(!report.isValid)
        #expect(report.blockers.contains { $0.path.hasPrefix("/actions/") })
    }

    @Test("a read action with a non-write label is fine (no false positive)")
    func readActionNotFlagged() {
        let report = WorkspaceAppManifestValidator.validate(dashboardOverTable(actions: [
            WorkspaceAppActionSpec(id: "list", type: "appStorage.query", label: "List Items"),
            WorkspaceAppActionSpec(id: "export", type: "artifact.export", label: "Export Items", table: "review_items", exportFormat: "csv"),
            WorkspaceAppActionSpec(id: "add", type: "appStorage.insert", label: "Add Item", table: "review_items")
        ]))
        #expect(report.isValid)  // "List"/"Export" are reads but not write-labeled
    }

    @Test("the deterministic fallback is now a usable app, not a read-only shell")
    func deterministicFallbackIsUsable() {
        let manifest = WorkspaceAppStudioBuilder.baseManifest(intent: "build a rubik's cube solver")
        #expect(WorkspaceAppManifestValidator.validate(manifest).isValid)
        #expect(manifest.actions.contains { $0.type == "appStorage.insert" })
    }
}

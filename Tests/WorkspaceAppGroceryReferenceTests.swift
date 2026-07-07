import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA

/// Slice 4: the grocery/local-database reference app must be complete enough to judge
/// the product — full CRUD on app-owned storage, edit/delete surfaced in the UI, and
/// metrics that reflect live data. These exercise the GROCERY TEMPLATE's own declared
/// actions end-to-end (not ad-hoc fixtures), so they prove the reference app itself works.
@Suite("Workspace App Grocery Reference (Slice 4)")
struct WorkspaceAppGroceryReferenceTests {
    private static var groceryManifest: WorkspaceAppManifest {
        WorkspaceAppStudioBuilder.baseManifest(intent: "Build me a grocery database app.")
    }

    // MARK: - Template completeness

    @Test("the grocery template validates and declares full CRUD on items")
    func groceryTemplateHasFullCRUD() {
        let manifest = Self.groceryManifest
        #expect(WorkspaceAppManifestValidator.validate(manifest).isValid)

        func action(_ type: String) -> WorkspaceAppActionSpec? {
            manifest.actions.first { $0.type == type && $0.table == "items" }
        }
        #expect(action("appStorage.insert") != nil)
        #expect(action("appStorage.update") != nil)
        #expect(action("appStorage.delete") != nil)
        #expect(manifest.actions.contains { $0.type == "appStorage.query" })
    }

    @Test("the items table surfaces edit and delete row actions in the UI presentation")
    func groceryItemsTableSurfacesEditAndDelete() {
        let table = WorkspaceAppStorageTableSnapshot(
            name: "items", columns: ["id", "name"], rows: [], errorMessage: nil
        )
        let rowActions = WorkspaceAppStorageRowActionPresentationBuilder.presentation(
            manifest: Self.groceryManifest, table: table
        )
        #expect(rowActions.primaryKey == "id")
        #expect(rowActions.updateAction != nil)
        #expect(rowActions.deleteAction != nil)
    }

    // MARK: - End-to-end CRUD through the template's own actions

    @MainActor
    @Test("the grocery reference app drives a full add/edit/delete cycle on real storage")
    func groceryReferenceAppDrivesFullCRUD() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grocery-ref-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Apps", primaryPath: root.path)
        context.insert(workspace)

        let manifest = Self.groceryManifest
        let created = try WorkspaceAppService().createApp(
            manifest: manifest, in: workspace, modelContext: context, status: .published
        )
        let app = created.app
        let executor = WorkspaceAppActionExecutor()

        func run(_ actionID: String, _ input: WorkspaceAppActionInput) throws -> WorkspaceAppActionExecutionResult {
            try executor.execute(
                actionID: actionID, app: app, workspace: workspace,
                manifest: manifest, input: input, modelContext: context
            )
        }
        func items() throws -> [[String: WorkspaceAppStorageValue]] {
            try run("list_items", WorkspaceAppActionInput(table: "items")).rows
        }

        // CREATE
        _ = try run("add_item", WorkspaceAppActionInput(
            table: "items",
            record: ["id": .text("i1"), "name": .text("Apples"), "last_price": .real(2.5)]
        ))
        var rows = try items()
        #expect(rows.count == 1)
        #expect(rows[0]["name"] == .text("Apples"))

        // Metrics reflect live app data: item_count counts the one stored row.
        let surface = WorkspaceAppNativeSurfaceBuilder.presentation(
            manifest: manifest,
            storageTables: [WorkspaceAppStorageTableSnapshot(
                name: "items", columns: ["id", "name", "last_price"], rows: rows, errorMessage: nil
            )]
        )
        #expect(surface.metrics.first { $0.id == "item_count" }?.value == "1")

        // UPDATE
        _ = try run("update_item", WorkspaceAppActionInput(
            table: "items", record: ["id": .text("i1"), "name": .text("Green Apples")]
        ))
        rows = try items()
        #expect(rows.count == 1)
        #expect(rows[0]["name"] == .text("Green Apples"))

        // DELETE is destructive — it must refuse without explicit confirmation...
        #expect(throws: WorkspaceAppActionExecutionError.self) {
            _ = try run("delete_item", WorkspaceAppActionInput(table: "items", record: ["id": .text("i1")]))
        }
        // ...and succeed with it.
        _ = try run("delete_item", WorkspaceAppActionInput(
            table: "items", record: ["id": .text("i1")], confirmedDestructive: true
        ))
        #expect(try items().isEmpty)
    }
}

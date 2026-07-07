import Foundation
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Workspace App Draft Preview Builder (Slice 3)")
struct WorkspaceAppDraftPreviewBuilderTests {
    private static var groceryManifest: WorkspaceAppManifest {
        WorkspaceAppStudioBuilder.baseManifest(intent: "Build me a grocery database app.")
    }

    @Test("preview produces one sample table per storage table with the requested row count")
    func previewProducesSampleTables() {
        let manifest = Self.groceryManifest
        let snapshot = WorkspaceAppDraftPreviewBuilder.snapshot(manifest: manifest, sampleRowsPerTable: 3)

        #expect(snapshot.manifest == manifest)
        #expect(snapshot.storageTables.count == (manifest.storage?.tables.count ?? 0))
        let items = try? #require(snapshot.storageTables.first { $0.name == "items" })
        #expect(items?.rowCount == 3)
        // bindings / automations / runs are empty for an un-persisted draft.
        #expect(snapshot.dependencyBindings.isEmpty)
        #expect(snapshot.runs.isEmpty)
    }

    @Test("sample data flows through the SAME published-app presentation builders")
    func previewFeedsPublishedPresentationBuilders() {
        let manifest = Self.groceryManifest
        let snapshot = WorkspaceAppDraftPreviewBuilder.snapshot(manifest: manifest, sampleRowsPerTable: 3)

        let surface = WorkspaceAppNativeSurfaceBuilder.presentation(
            manifest: snapshot.manifest, storageTables: snapshot.storageTables
        )
        let actions = WorkspaceAppDetailActionsPresentation.actions(
            manifest: snapshot.manifest, storageTables: snapshot.storageTables
        )
        // The grocery dashboard declares metric + chart widgets and four actions; the
        // preview snapshot must drive them without any published app.
        #expect(!surface.metrics.isEmpty)
        #expect(!surface.charts.isEmpty)
        #expect(actions.count == manifest.actions.count)

        // The sample rows must actually flow into the aggregation: item_count counts the
        // `items` table, which has exactly the 3 sample rows we requested.
        let itemCount = surface.metrics.first { $0.id == "item_count" }
        #expect(itemCount?.value == "3")
    }

    @Test("text sample cells are explicitly marked, typed cells match their column type")
    func sampleCellsAreMarkedAndTyped() throws {
        let manifest = Self.groceryManifest
        let snapshot = WorkspaceAppDraftPreviewBuilder.snapshot(manifest: manifest, sampleRowsPerTable: 1)
        let items = try #require(snapshot.storageTables.first { $0.name == "items" })
        let row = try #require(items.rows.first)

        if case let .text(name) = row["name"] {
            #expect(name.hasPrefix("Sample"))
        } else {
            Issue.record("name should be a text sample cell")
        }
        // last_price is a double column, in_stock a bool column, id a uuid primary key.
        if case .real = row["last_price"] {} else { Issue.record("last_price should be .real") }
        if case .bool = row["in_stock"] {} else { Issue.record("in_stock should be .bool") }
        if case let .text(id) = row["id"] {
            #expect(id == "sample-items-1")
        } else {
            Issue.record("uuid primary key should be a stable text id")
        }
    }

    @Test("preview is deterministic for a fixed seed")
    func previewIsDeterministic() {
        let manifest = Self.groceryManifest
        let a = WorkspaceAppDraftPreviewBuilder.snapshot(manifest: manifest, sampleRowsPerTable: 3, seed: 7)
        let b = WorkspaceAppDraftPreviewBuilder.snapshot(manifest: manifest, sampleRowsPerTable: 3, seed: 7)
        #expect(a == b)
    }

    @Test("different seeds vary the numeric sample values")
    func differentSeedsDiffer() {
        let manifest = Self.groceryManifest
        let a = WorkspaceAppDraftPreviewBuilder.snapshot(manifest: manifest, sampleRowsPerTable: 3, seed: 0)
        let b = WorkspaceAppDraftPreviewBuilder.snapshot(manifest: manifest, sampleRowsPerTable: 3, seed: 5)
        #expect(a != b)
    }

    @Test("zero sample rows degrades gracefully — builders still render, no crash")
    func emptyTableDegradesGracefully() throws {
        let manifest = Self.groceryManifest
        let snapshot = WorkspaceAppDraftPreviewBuilder.snapshot(manifest: manifest, sampleRowsPerTable: 0)
        let items = try #require(snapshot.storageTables.first { $0.name == "items" })
        #expect(items.rows.isEmpty)

        let surface = WorkspaceAppNativeSurfaceBuilder.presentation(
            manifest: snapshot.manifest, storageTables: snapshot.storageTables
        )
        // The dashboard still renders its widgets against empty sample data.
        #expect(!surface.metrics.isEmpty)
    }

    @Test("overrideSampleData pins exact rows")
    func overrideSampleDataIsUsed() throws {
        let manifest = Self.groceryManifest
        let pinned: [[String: WorkspaceAppStorageValue]] = [
            ["id": .text("fixed-1"), "name": .text("Milk"), "last_price": .real(2.5)]
        ]
        let snapshot = WorkspaceAppDraftPreviewBuilder.snapshot(
            manifest: manifest,
            sampleRowsPerTable: 3,
            overrideSampleData: ["items": pinned]
        )
        let items = try #require(snapshot.storageTables.first { $0.name == "items" })
        #expect(items.rows.count == 1)
        if case let .text(name) = items.rows[0]["name"] {
            #expect(name == "Milk")
        } else {
            Issue.record("override row should be used verbatim")
        }
    }
}

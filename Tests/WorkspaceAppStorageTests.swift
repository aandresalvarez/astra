import Foundation
import Testing
@testable import ASTRA

@Suite("Workspace App Storage")
struct WorkspaceAppStorageTests {
    @Test("storage schema creates app SQLite tables and reads records back")
    func storageSchemaCreatesTablesAndReadsRecordsBack() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-app-storage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let databaseURL = root.appendingPathComponent("app.sqlite")
        let service = WorkspaceAppStorageService()
        try service.applySchema(Self.grocerySchema(), databaseURL: databaseURL)
        try service.insertRecord(
            [
                "id": .text("item-1"),
                "name": .text("Apples"),
                "category": .text("Produce"),
                "quantity": .integer(6),
                "purchased": .bool(false)
            ],
            into: "items",
            databaseURL: databaseURL
        )

        let rows = try service.records(in: "items", databaseURL: databaseURL)

        #expect(FileManager.default.fileExists(atPath: databaseURL.path))
        #expect(rows.count == 1)
        #expect(rows[0]["id"] == .text("item-1"))
        #expect(rows[0]["name"] == .text("Apples"))
        #expect(rows[0]["quantity"] == .integer(6))
        #expect(rows[0]["purchased"] == .integer(0))
    }

    @Test("re-applying a schema with a new column ALTERs the existing table and preserves rows")
    func applySchemaAddsColumnPreservingRows() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-app-migrate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let databaseURL = root.appendingPathComponent("app.sqlite")
        let service = WorkspaceAppStorageService()
        // v1: notes(id, text). Seed a row.
        let v1 = WorkspaceAppStorageSchema(tables: [
            WorkspaceAppStorageTable(name: "notes", columns: [
                WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                WorkspaceAppStorageColumn(name: "text", type: "text")
            ])
        ])
        try service.applySchema(v1, databaseURL: databaseURL)
        try service.insertRecord(["id": .text("n1"), "text": .text("hello")], into: "notes", databaseURL: databaseURL)

        // v2 (a version-in-place edit) adds a column. Re-applying must ADD COLUMN, not no-op.
        let v2 = WorkspaceAppStorageSchema(tables: [
            WorkspaceAppStorageTable(name: "notes", columns: [
                WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                WorkspaceAppStorageColumn(name: "text", type: "text"),
                WorkspaceAppStorageColumn(name: "pinned", type: "bool")
            ])
        ])
        try service.applySchema(v2, databaseURL: databaseURL)

        // The existing row survived the migration...
        let preserved = try service.records(in: "notes", databaseURL: databaseURL)
        #expect(preserved.count == 1)
        #expect(preserved[0]["id"] == .text("n1"))
        // ...and the new column now exists (an insert that uses it succeeds, proving the ALTER ran).
        try service.insertRecord(["id": .text("n2"), "text": .text("world"), "pinned": .bool(true)], into: "notes", databaseURL: databaseURL)
        let after = try service.records(in: "notes", databaseURL: databaseURL)
        #expect(after.count == 2)
        #expect(after.contains { $0["pinned"] == .integer(1) })
    }

    @Test("publish seed writes the preview's sample rows into a fresh app database")
    func seedSampleRowsRoundTrips() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-app-seed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let databaseURL = root.appendingPathComponent("app.sqlite")
        let service = WorkspaceAppStorageService()
        let schema = Self.grocerySchema()
        try service.applySchema(schema, databaseURL: databaseURL)

        // Same generator the Studio preview uses — proves seed-on-publish populates a real DB.
        let table = schema.tables[0]
        let sampleRows = WorkspaceAppDraftPreviewBuilder.defaultSampleRows(for: table, count: 3, seed: 0)
        for row in sampleRows {
            try service.insertRecord(row, into: table.name, databaseURL: databaseURL)
        }

        let stored = try service.records(in: table.name, databaseURL: databaseURL)
        #expect(stored.count == 3)
        // Every declared column is populated, so a seeded app never renders dead-empty.
        #expect(stored.allSatisfy { $0.count == table.columns.count })
    }

    @Test("storage rejects unsafe table and column identifiers")
    func storageRejectsUnsafeIdentifiers() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-app-storage-invalid-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = WorkspaceAppStorageService()
        let schema = WorkspaceAppStorageSchema(tables: [
            WorkspaceAppStorageTable(name: "items; DROP TABLE items", columns: [
                WorkspaceAppStorageColumn(name: "id", type: "text")
            ])
        ])

        #expect(throws: WorkspaceAppStorageError.invalidIdentifier("items; DROP TABLE items")) {
            try service.applySchema(schema, databaseURL: root.appendingPathComponent("app.sqlite"))
        }
    }

    @Test("storage rejects unsupported column types before creating SQL")
    func storageRejectsUnsupportedColumnTypes() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-app-storage-type-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = WorkspaceAppStorageService()
        let schema = WorkspaceAppStorageSchema(tables: [
            WorkspaceAppStorageTable(name: "items", columns: [
                WorkspaceAppStorageColumn(name: "payload", type: "blob")
            ])
        ])

        #expect(throws: WorkspaceAppStorageError.unsupportedColumnType("blob")) {
            try service.applySchema(schema, databaseURL: root.appendingPathComponent("app.sqlite"))
        }
    }

    @Test("storage schema supports App Studio double and date aliases")
    func storageSupportsAppStudioColumnAliases() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-app-storage-alias-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let databaseURL = root.appendingPathComponent("app.sqlite")
        let service = WorkspaceAppStorageService()
        let schema = WorkspaceAppStorageSchema(tables: [
            WorkspaceAppStorageTable(name: "purchases", columns: [
                WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                WorkspaceAppStorageColumn(name: "price", type: "double"),
                WorkspaceAppStorageColumn(name: "purchased_at", type: "date")
            ])
        ])

        try service.applySchema(schema, databaseURL: databaseURL)
        try service.insertRecord(
            [
                "id": .text("purchase-1"),
                "price": .real(2.49),
                "purchased_at": .text("2026-06-05")
            ],
            into: "purchases",
            databaseURL: databaseURL
        )

        let rows = try service.records(in: "purchases", databaseURL: databaseURL)

        #expect(rows.count == 1)
        #expect(rows[0]["price"] == .real(2.49))
        #expect(rows[0]["purchased_at"] == .text("2026-06-05"))
    }

    @Test("storage migration planner marks additive schema changes without review")
    func storageMigrationPlannerMarksAdditiveChangesWithoutReview() {
        let current = Self.grocerySchema()
        let target = WorkspaceAppStorageSchema(tables: [
            WorkspaceAppStorageTable(name: "items", columns: [
                WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                WorkspaceAppStorageColumn(name: "name", type: "text", required: true),
                WorkspaceAppStorageColumn(name: "category", type: "text"),
                WorkspaceAppStorageColumn(name: "quantity", type: "integer"),
                WorkspaceAppStorageColumn(name: "purchased", type: "bool"),
                WorkspaceAppStorageColumn(name: "notes", type: "text")
            ]),
            WorkspaceAppStorageTable(name: "stores", columns: [
                WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                WorkspaceAppStorageColumn(name: "name", type: "text", required: true)
            ])
        ])

        let plan = WorkspaceAppStorageService().planMigration(from: current, to: target)

        #expect(!plan.requiresReview)
        #expect(plan.steps == [
            WorkspaceAppStorageMigrationStep(
                kind: .addColumn,
                table: "items",
                column: "notes",
                previousValue: nil,
                nextValue: "notes",
                risk: .additive,
                summary: "Add column 'notes' to storage table 'items'."
            ),
            WorkspaceAppStorageMigrationStep(
                kind: .createTable,
                table: "stores",
                column: nil,
                previousValue: nil,
                nextValue: "stores",
                risk: .additive,
                summary: "Create storage table 'stores'."
            )
        ])
    }

    @Test("storage migration planner requires review for destructive schema changes")
    func storageMigrationPlannerRequiresReviewForDestructiveChanges() {
        let current = WorkspaceAppStorageSchema(tables: [
            WorkspaceAppStorageTable(name: "items", columns: [
                WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                WorkspaceAppStorageColumn(name: "name", type: "text"),
                WorkspaceAppStorageColumn(name: "category", type: "text"),
                WorkspaceAppStorageColumn(name: "quantity", type: "integer")
            ]),
            WorkspaceAppStorageTable(name: "stores", columns: [
                WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true)
            ])
        ])
        let target = WorkspaceAppStorageSchema(tables: [
            WorkspaceAppStorageTable(name: "items", columns: [
                WorkspaceAppStorageColumn(name: "id", type: "text", primaryKey: false, required: true),
                WorkspaceAppStorageColumn(name: "name", type: "text", required: true),
                WorkspaceAppStorageColumn(name: "purchased_at", type: "date", required: true)
            ])
        ])

        let plan = WorkspaceAppStorageService().planMigration(from: current, to: target)

        #expect(plan.requiresReview)
        #expect(plan.steps.map(\.kind) == [
            .dropTable,
            .dropColumn,
            .dropColumn,
            .changeColumnType,
            .changePrimaryKey,
            .changeRequiredConstraint,
            .addColumn
        ])
        #expect(plan.steps.allSatisfy { $0.risk == .reviewRequired })
        #expect(plan.steps[0].summary == "Drop storage table 'stores'.")
        #expect(plan.steps.last?.summary == "Add required column 'purchased_at' to storage table 'items'.")
    }

    @Test("storage updates and deletes records by primary key")
    func storageUpdatesAndDeletesRecordsByPrimaryKey() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-app-storage-crud-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let databaseURL = root.appendingPathComponent("app.sqlite")
        let service = WorkspaceAppStorageService()
        try service.applySchema(Self.grocerySchema(), databaseURL: databaseURL)
        try service.insertRecord(
            [
                "id": .text("item-1"),
                "name": .text("Apples"),
                "category": .text("Produce")
            ],
            into: "items",
            databaseURL: databaseURL
        )

        try service.updateRecord(
            [
                "id": .text("item-1"),
                "name": .text("Oranges"),
                "quantity": .integer(4)
            ],
            in: "items",
            primaryKey: "id",
            databaseURL: databaseURL
        )

        var rows = try service.records(in: "items", databaseURL: databaseURL)
        #expect(rows.count == 1)
        #expect(rows[0]["name"] == .text("Oranges"))
        #expect(rows[0]["quantity"] == .integer(4))

        try service.deleteRecord(
            from: "items",
            primaryKey: "id",
            value: .text("item-1"),
            databaseURL: databaseURL
        )

        rows = try service.records(in: "items", databaseURL: databaseURL)
        #expect(rows.isEmpty)
    }

    static func grocerySchema() -> WorkspaceAppStorageSchema {
        WorkspaceAppStorageSchema(tables: [
            WorkspaceAppStorageTable(name: "items", columns: [
                WorkspaceAppStorageColumn(name: "id", type: "uuid", primaryKey: true, required: true),
                WorkspaceAppStorageColumn(name: "name", type: "text", required: true),
                WorkspaceAppStorageColumn(name: "category", type: "text"),
                WorkspaceAppStorageColumn(name: "quantity", type: "integer"),
                WorkspaceAppStorageColumn(name: "purchased", type: "bool")
            ])
        ])
    }
}

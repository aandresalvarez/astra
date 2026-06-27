import Foundation

/// Slice 3: builds a render-ready preview of a DRAFT manifest using the SAME
/// presentation models a published app uses. It only synthesizes sample storage rows
/// from the manifest's schema; the live database is swapped for deterministic sample
/// data and the published-app presentation builders consume the result unchanged.
///
/// Pure + non-`@MainActor`: no SwiftData, no FileManager, no clock. Sample text cells
/// are prefixed "Sample" so preview data is visibly distinguishable from live data
/// (the Studio also renders a "sample data" banner over the preview surface).
enum WorkspaceAppDraftPreviewBuilder {
    /// A `WorkspaceAppDetailDataSnapshot` (the exact type the detail view consumes) with
    /// the draft manifest + sample rows for each declared table; bindings/automations/
    /// runs are empty (a draft has none yet).
    static func snapshot(
        manifest: WorkspaceAppManifest,
        sampleRowsPerTable: Int = 3,
        overrideSampleData: [String: [[String: WorkspaceAppStorageValue]]]? = nil,
        seed: UInt64 = 0
    ) -> WorkspaceAppDetailDataSnapshot {
        let tables: [WorkspaceAppStorageTableSnapshot] = (manifest.storage?.tables ?? []).map { table in
            let rows = overrideSampleData?[table.name]
                ?? defaultSampleRows(for: table, count: sampleRowsPerTable, seed: seed)
            return WorkspaceAppStorageTableSnapshot(
                name: table.name,
                columns: table.columns.map(\.name),
                rows: rows,
                errorMessage: nil
            )
        }
        return WorkspaceAppDetailDataSnapshot(
            manifest: manifest,
            storageTables: tables,
            dependencyBindings: [],
            automationStates: [],
            runs: [],
            errorMessage: nil
        )
    }

    /// Deterministic sample rows derived from column metadata — type-appropriate values,
    /// indexed 1...count, no `UUID()`/`Date()` so test assertions are stable.
    static func defaultSampleRows(
        for table: WorkspaceAppStorageTable,
        count: Int,
        seed: UInt64
    ) -> [[String: WorkspaceAppStorageValue]] {
        guard count > 0 else { return [] }
        return (1...count).map { n in
            var row: [String: WorkspaceAppStorageValue] = [:]
            for column in table.columns {
                row[column.name] = sampleValue(for: column, table: table.name, index: n, seed: seed)
            }
            return row
        }
    }

    private static func sampleValue(
        for column: WorkspaceAppStorageColumn,
        table: String,
        index: Int,
        seed: UInt64
    ) -> WorkspaceAppStorageValue {
        let type = column.type.lowercased()
        if column.primaryKey {
            // A stable, unique primary key per row.
            return type.contains("int") ? .integer(Int64(index)) : .text("sample-\(table)-\(index)")
        }
        switch true {
        case type.contains("int"):
            return .integer(Int64(index) + Int64(seed))
        case type.contains("real"), type.contains("double"), type.contains("float"), type.contains("number"):
            return .real(Double(index) + Double(seed))
        case type.contains("bool"):
            return .bool(index % 2 == 0)
        default:
            // Text (and unknown types): visibly marked as sample data.
            return .text("Sample \(column.name) \(index)")
        }
    }
}

import Foundation

/// Seeds a freshly published app's storage with the preview's sample rows so it opens
/// populated instead of dead-empty (opt-in via the Studio's "Start with sample data").
/// Best-effort: `createApp` already applied the schema, so per-row failures are logged
/// but never block the publish. Reuses the exact generator the Studio preview uses, so
/// the published seed matches what the builder saw.
enum WorkspaceAppSampleSeeder {
    static func seed(
        manifest: WorkspaceAppManifest,
        workspacePath: String,
        appID: String,
        rowsPerTable: Int = 3,
        storageService: WorkspaceAppStorageService = WorkspaceAppStorageService()
    ) {
        guard let storage = manifest.storage, !storage.tables.isEmpty else { return }
        guard let databaseURL = WorkspaceFileLayout.appDatabaseFileURL(
            workspacePath: workspacePath,
            appID: appID
        ) else {
            AppLogger.error("Sample seed skipped: unsafe storage path for \(appID)", category: "WorkspaceApps")
            return
        }
        for table in storage.tables {
            let rows = WorkspaceAppDraftPreviewBuilder.defaultSampleRows(for: table, count: rowsPerTable, seed: 0)
            for row in rows {
                do {
                    try storageService.insertRecord(row, into: table.name, databaseURL: databaseURL)
                } catch {
                    AppLogger.error("Sample seed failed for \(table.name): \(error)", category: "WorkspaceApps")
                }
            }
        }
        AppLogger.info(
            "app_studio.seeded_sample_data app_id=\(appID) tables=\(storage.tables.count) rows_per_table=\(rowsPerTable)",
            category: "WorkspaceApps"
        )
    }
}

import Foundation
import SwiftData

/// A fresh context alone does not pin SwiftData's lazy relationship rows to a
/// store generation. Concurrent deletion can invalidate them mid-projection.
/// Read an immutable SQLite backup instead; no model from the live store is
/// traversed, and only the resulting value config outlives this scope.
enum WorkspaceSavedExportSnapshot {
    enum SnapshotError: Error { case unsupportedStoreConfiguration }

    static func read<T>(container: ModelContainer, workspaceID: String = "none",
                        body: (ModelContainer) throws -> T) throws -> T {
        guard container.configurations.count == 1,
              let source = container.configurations.first, !source.isStoredInMemoryOnly else {
            throw SnapshotError.unsupportedStoreConfiguration
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-mirror-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("snapshot.store")
        try WorkspacePersistenceWork.measure("mirror_store_snapshot", workspaceID: workspaceID) {
            try WorkspaceRecoveryService.copyStoreSnapshot(from: source.url, to: url)
        }
        let snapshot = try ModelContainer(for: container.schema, configurations: [
            ModelConfiguration(schema: container.schema, url: url, allowsSave: false, cloudKitDatabase: .none)
        ])
        return try body(snapshot)
    }
}

import Foundation
import SwiftData

/// A fresh context alone does not pin SwiftData's lazy relationship rows to a
/// store generation. Concurrent deletion can invalidate them mid-projection.
/// Read an immutable SQLite backup instead; no model from the live store is
/// traversed, and only the resulting value config outlives this scope.
enum WorkspaceSavedExportSnapshot {
    enum SnapshotError: Error { case unsupportedStoreConfiguration }

    /// Only a file copy crosses the saving-actor fence. No live model or
    /// context exists until the reader resumes its synchronous row traversal.
    struct CapturedStore {
        let directory: WorkspaceSnapshotDirectory.Reservation
        let schema: Schema

        func read<T>(_ body: (ModelContainer) throws -> T) throws -> T {
            try withExtendedLifetime(directory) {
                let snapshot = try ModelContainer(for: schema, configurations: [
                    ModelConfiguration(schema: schema, url: directory.root.appendingPathComponent("snapshot.store"),
                        allowsSave: false, cloudKitDatabase: .none)
                ])
                return try body(snapshot)
            }
        }
    }

    static func capture(container: ModelContainer, workspaceID: String) throws -> CapturedStore {
        guard container.configurations.count == 1,
              let source = container.configurations.first, !source.isStoredInMemoryOnly else {
            throw SnapshotError.unsupportedStoreConfiguration
        }
        let directory = try WorkspaceSnapshotDirectory.reserve(beside: source.url)
        try WorkspacePersistenceWork.measure("mirror_store_snapshot", workspaceID: workspaceID) {
            try WorkspaceRecoveryService.copyStoreSnapshot(from: source.url,
                to: directory.root.appendingPathComponent("snapshot.store"))
        }
        return CapturedStore(directory: directory, schema: container.schema)
    }

    static func read<T>(container: ModelContainer, workspaceID: String = "none",
                        body: (ModelContainer) throws -> T) throws -> T {
        try capture(container: container, workspaceID: workspaceID).read(body)
    }
}

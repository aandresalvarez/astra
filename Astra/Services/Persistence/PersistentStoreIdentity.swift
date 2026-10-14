import Foundation
import SwiftData

/// Which store a context writes to: its file's path and identity on disk, or
/// this process's container for a store kept only in memory. A recovery that
/// replaces the store, or a backup restored over it, changes it, so a record
/// can tell whether what the store holds now is what it was recorded against.
public enum PersistentStoreIdentity {
    /// Nil when the store's file can't be identified.
    public static func current(for modelContext: ModelContext) -> String? {
        guard let configuration = modelContext.container.configurations.first(where: { !$0.isStoredInMemoryOnly }) else {
            let container = UInt(bitPattern: ObjectIdentifier(modelContext.container).hashValue)
            return "memory:\(ProcessInfo.processInfo.processIdentifier):\(container)"
        }
        let path = configuration.url.standardizedFileURL.resolvingSymlinksInPath().path
        guard let identity = try? WorkspaceFileLayout.itemIdentityConfirmingAbsence(at: path) else { return nil }
        return path + "|" + identity
    }

    /// When the store's file was created: distant past for a store kept
    /// only in memory, which no recovery replaces, and nil when unreadable.
    public static func createdAt(for modelContext: ModelContext) -> Date? {
        guard let configuration = modelContext.container.configurations.first(where: { !$0.isStoredInMemoryOnly }) else {
            return .distantPast
        }
        return (try? FileManager.default.attributesOfItem(atPath: configuration.url.path))?[.creationDate] as? Date
    }
}

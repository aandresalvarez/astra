import Foundation
import SwiftData
import ASTRAModels

/// Read-only pending operation facts shared by launch and mutation admission.
/// A fresh completion overrides stale UI state; an unsaved receipt remains
/// unresolved until its original commit can be established.
@MainActor
enum PluginPendingOperations {
    struct Entry {
        let snapshot: PluginOperationCommit.Snapshot
        let isSaved: Bool
        var problem: PluginOperationProblem {
            isSaved ? .savedRecoveryPending(snapshot.id) : .commitUncertain(snapshot.id)
        }
    }

    static func capture(modelContext: ModelContext) throws -> [Entry] {
        let saved = ModelContext(modelContext.container)
        let descriptor = FetchDescriptor<PluginOperationReceipt>(predicate: #Predicate { $0.completedAt == nil })
        var pending: [UUID: Entry] = [:]
        for receipt in try saved.fetch(descriptor) {
            pending[receipt.id] = Entry(snapshot: try PluginOperationCommit.Snapshot(receipt), isSaved: true)
        }
        for receipt in try modelContext.fetch(descriptor) where pending[receipt.id] == nil {
            if let durable = try PluginOperationCommit.read(receipt.id, container: modelContext.container) {
                if durable.completedAt == nil { pending[durable.id] = Entry(snapshot: durable, isSaved: true) }
            } else {
                pending[receipt.id] = Entry(snapshot: try PluginOperationCommit.Snapshot(receipt), isSaved: false)
            }
        }
        return pending.values.sorted { $0.snapshot.id.uuidString < $1.snapshot.id.uuidString }
    }
}

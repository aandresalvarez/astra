import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// Finishes only the saved projection work. Prepared library/approval manifests
/// must be reconciled by their own recovery step before this marks them done.
@MainActor
enum PluginOperationRecovery {
    struct Result { var completed = 0; var deferred = 0 }

    /// Pending operations hold irreversible cleanup until their recovery
    /// projection is confirmed. An unreadable store grants no permission.
    static func permitsCredentialCleanup(modelContext: ModelContext) -> Bool {
        let saved = ModelContext(modelContext.container)
        var descriptor = FetchDescriptor<PluginOperationReceipt>(predicate: #Predicate { $0.completedAt == nil })
        descriptor.fetchLimit = 1
        return (try? saved.fetch(descriptor).isEmpty) == true
    }

    @discardableResult
    static func resumePending(
        modelContext: ModelContext, only operationID: UUID? = nil,
        allowsFileOperation: (PluginOperationCommit.Snapshot) -> Bool = { $0.manifestDigest == nil },
        export: ((Workspace, ModelContext) -> Bool)? = nil,
        persistCompletion: (ModelContext) throws -> Void = { try $0.save() }
    ) -> Result {
        // Recovery never commits or rolls back unrelated unsaved editor work.
        let saved = ModelContext(modelContext.container)
        let descriptor = FetchDescriptor<PluginOperationReceipt>(predicate: #Predicate { $0.completedAt == nil })
        guard let receipts = try? saved.fetch(descriptor),
              let workspaces = try? saved.fetch(FetchDescriptor<Workspace>()) else {
            audit("store_unreadable", id: operationID)
            return Result(deferred: 1)
        }
        let byID = Dictionary(workspaces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result = Result()
        for receipt in receipts where operationID == nil || receipt.id == operationID {
            guard let snapshot = try? PluginOperationCommit.Snapshot(receipt), allowsFileOperation(snapshot) else {
                result.deferred += 1
                continue
            }
            let affected = snapshot.workspaceIDs.compactMap { byID[$0] }
            let rewrite = export ?? { WorkspaceConfigManager.exportMirrorNow(workspace: $0, modelContext: $1) }
            guard affected.reduce(true, { rewrite($1, saved) && $0 }) else {
                audit("mirror_pending", id: receipt.id)
                result.deferred += 1
                continue
            }
            receipt.completedAt = Date()
            do {
                try persistCompletion(saved)
                // A test seam or adapter that did not persist cannot settle
                // the receipt. The durable row is the sole completion owner.
                guard try PluginOperationCommit.read(receipt.id, container: saved.container)?.completedAt != nil else {
                    saved.rollback()
                    result.deferred += 1
                    continue
                }
                result.completed += 1
            } catch {
                saved.rollback()
                // A callback can fail after its save. Completion is decided
                // by the durable receipt, just as the initial commit is.
                if let observed = try? PluginOperationCommit.read(receipt.id, container: saved.container),
                   observed.completedAt != nil {
                    result.completed += 1
                } else {
                    audit("completion_pending", id: receipt.id)
                    result.deferred += 1
                }
            }
        }
        return result
    }

    private static func audit(_ reason: String, id: UUID?) {
        AppLogger.audit(.workspaceExported, category: "Persistence", fields: [
            "operation": "plugin_operation_recovery", "result": reason,
            "operation_id": id?.uuidString ?? "pending"
        ], level: .warning)
    }
}

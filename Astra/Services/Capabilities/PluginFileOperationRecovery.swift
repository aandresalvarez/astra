import Foundation
import SwiftData
import ASTRAPersistence
import ASTRAModels

/// Chooses replay direction only from a readable, matching store's receipt.
/// Equality of package versions or activation digests is never commit proof.
@MainActor
struct PluginFileOperationRecovery {
    struct Result { var completed = 0; var filesReady = 0; var deferred = 0 }
    let journal: PluginFileOperationJournal

    @discardableResult
    func resumePending(
        modelContext: ModelContext, only id: UUID? = nil,
        export: ((Workspace, ModelContext) -> Bool)? = nil, completesMirrors: Bool = true
    ) -> Result {
        guard let identity = PersistentStoreIdentity.current(for: modelContext),
              let ids = try? journal.pendingIDs() else { return Result(deferred: 1) }
        var result = Result()
        for pendingID in ids where id == nil || pendingID == id {
            do {
                let prepared = try journal.load(pendingID)
                guard prepared.manifest.storeIdentity == identity else {
                    result.deferred += 1; continue
                }
                if let receipt = try PluginOperationCommit.read(pendingID, container: modelContext.container) {
                    guard receipt.manifestDigest == prepared.digest,
                          receipt.pluginIDs == prepared.manifest.pluginIDs else {
                        result.deferred += 1; continue
                    }
                    // The receipt is completed only AFTER forward replay and
                    // mirrors. A leftover journal after completion needs only
                    // deletion; don't overwrite a later definition on retry.
                    if receipt.completedAt == nil {
                        try journal.apply(prepared, forward: true)
                        if !completesMirrors { result.filesReady += 1; continue }
                        let recovered = PluginOperationRecovery.resumePending(modelContext: modelContext, only: pendingID,
                            allowsFileOperation: { $0.id == pendingID && $0.manifestDigest == prepared.digest }, export: export)
                        guard recovered.completed == 1 else { result.deferred += 1; continue }
                    }
                } else {
                    try journal.apply(prepared, forward: false)
                }
                try journal.discard(prepared)
                result.completed += 1
            } catch { result.deferred += 1 }
        }
        if result.completed > 0 {
            NotificationCenter.default.post(name: .capabilityPackagesChanged, object: nil)
            NotificationCenter.default.post(name: .capabilityApprovalsChanged, object: nil)
        }
        return result
    }
}

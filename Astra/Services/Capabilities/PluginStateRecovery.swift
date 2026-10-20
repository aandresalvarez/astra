import Foundation
import SwiftData
import ASTRAModels

/// Read and finish already-saved state changes; never replay the original
/// mutation or secret input. File manifests retain their source recovery path.
@MainActor
enum PluginStateRecovery {
    enum Failure: Error, LocalizedError {
        case receiptUnavailable
        var errorDescription: String? { "ASTRA couldn't verify this saved change. Reopen Plugins and check recovery before repeating it." }
    }

    struct Item: Identifiable, Equatable {
        let id: UUID
        let isSaved: Bool
        var message: String {
            (isSaved ? PluginOperationProblem.savedRecoveryPending(id) : .commitUncertain(id)).localizedDescription
        }
    }

    static func pending(modelContext: ModelContext) throws -> [Item] {
        try PluginPendingOperations.capture(modelContext: modelContext)
            .filter { $0.snapshot.manifestDigest == nil }
            .map { Item(id: $0.snapshot.id, isSaved: $0.isSaved) }
    }

    @discardableResult
    static func resume(_ id: UUID, modelContext: ModelContext) throws -> PluginOperationCommit.Snapshot {
        guard let receipt = try PluginOperationCommit.read(id, container: modelContext.container), receipt.manifestDigest == nil else {
            throw Failure.receiptUnavailable
        }
        _ = PluginOperationRecovery.resumePending(modelContext: modelContext, only: id)
        guard let completed = try PluginOperationCommit.read(id, container: modelContext.container), completed.completedAt != nil else {
            throw PluginOperationProblem.savedRecoveryPending(id)
        }
        return completed
    }
}

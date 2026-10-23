import Foundation
import SwiftData
import ASTRACore
import ASTRAPersistence

/// Discard changes only the pending draft. It uses the same prepared file and
/// fresh-context receipt boundary as staging, so an interruption is recoverable.
@MainActor
enum PluginStagedDiscard {
    static func discard(_ review: PluginStagedReview, library: CapabilityLibrary, modelContext: ModelContext,
        approvalStore: CapabilityApprovalStore = CapabilityApprovalStore(), operation: PluginFileOperationContext? = nil) throws {
        let journal = PluginFileOperationJournal(library: library, approvals: approvalStore)
        let recovery = PluginFileOperationRecovery(journal: journal)
        guard recovery.resumePending(modelContext: modelContext, metadata: operation?.metadata).deferred == 0 else {
            throw PluginDefinitionChange.Failure.recoveryPending
        }
        guard let draft = library.stagedPackage(id: review.id) else { throw CapabilityLibrary.RemovalError.notInstalled(review.id) }
        guard try CapabilityApprovalDigest.digest(for: draft) == review.digest else {
            throw PluginDefinitionChange.Failure.reviewedBytesChanged
        }
        guard let identity = PersistentStoreIdentity.current(for: modelContext) else { throw PluginDefinitionChange.Failure.unavailableStore }
        let name = CapabilityLibrary.safeFileName(for: review.id)
        let prepared = try journal.prepare(id: operation?.id ?? UUID(), storeIdentity: identity, pluginIDs: [review.id], changes: [
            .init(root: .staging, name: name + ".json", replacement: nil),
            .init(root: .staging, name: name, replacement: nil)
        ], linkedMetadataDigest: operation?.metadataDigest)
        try PluginDefinitionChange.stage(.init(operation: prepared, reviewedDigest: review.digest),
            journal: journal, modelContext: modelContext, operation: operation)
    }
}

import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// A staged approval uses the same prepared definition boundary as import.
/// The previously approved definition and the draft survive an uncommitted
/// failure; a confirmed save retains forward recovery instead of rolling back.
@MainActor
enum PluginStagedApproval {
    static func approve(
        id: String, library: CapabilityLibrary, modelContext: ModelContext,
        approvalStore: CapabilityApprovalStore, approvedBy: String,
        persist: ((ModelContext) throws -> Void)? = nil,
        rewriteMirror: ((Workspace) -> Bool)? = nil, operation: PluginFileOperationContext? = nil
    ) throws -> PluginPackage {
        let journal = PluginFileOperationJournal(library: library, approvals: approvalStore)
        let recovery = PluginFileOperationRecovery(journal: journal)
        guard recovery.resumePending(modelContext: modelContext, metadata: operation?.metadata).deferred == 0,
              try journal.pendingIDs().isEmpty else { throw PluginDefinitionChange.Failure.recoveryPending }
        guard let draft = library.stagedPackage(id: id) else { throw CapabilityLibrary.RemovalError.notInstalled(id) }
        if let refusal = PluginUpdateService.refusals(for: draft, modelContext: modelContext).first { throw refusal }
        guard let identity = PersistentStoreIdentity.current(for: modelContext) else { throw PluginDefinitionChange.Failure.unavailableStore }
        let definition = try PluginLibraryPreparation.prepare(source: CapabilityPackageSource(package: draft, manifestURL: nil,
            assetRootURL: draft.sourceMetadata?.url?.deletingLastPathComponent()), library: library,
            approvalStore: approvalStore, approvedBy: approvedBy, storeIdentity: identity, journal: journal, operation: operation)
        return try PluginDefinitionChange.commit(definition, library: library, journal: journal, modelContext: modelContext,
            kind: .approval, approvalRecords: { approvalStore.records() }, persist: persist, rewriteMirror: rewriteMirror, operation: operation)
    }
}

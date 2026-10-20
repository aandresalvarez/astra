import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

/// The shared installed-definition boundary for import and staged approval.
/// Business validation and preparation happen first; this service publishes
/// prepared bytes and reconciles their domain state under one receipt ID.
@MainActor
enum PluginDefinitionChange {
    enum Failure: Error, LocalizedError {
        case reviewedBytesChanged, recoveryPending, unavailableStore
        var errorDescription: String? {
            switch self {
            case .reviewedBytesChanged: "The plugin changed during review. Review the current version before approving it."
            case .recoveryPending: "An earlier plugin change needs recovery. Relaunch ASTRA before trying again."
            case .unavailableStore: "ASTRA couldn't identify its active store, so no plugin files were changed."
            }
        }
    }

    static func commit(
        _ definition: PluginLibraryPreparation.Definition, library: CapabilityLibrary,
        journal: PluginFileOperationJournal, modelContext: ModelContext,
        kind: PluginOperationReceipt.Kind, approvalRecords: () -> [CapabilityApprovalRecord],
        persist: ((ModelContext) throws -> Void)? = nil,
        rewriteMirror: ((Workspace) -> Bool)? = nil
    ) throws -> PluginPackage {
        let prepared = definition.operation
        let recovery = PluginFileOperationRecovery(journal: journal)
        do {
            try journal.apply(prepared, forward: true)
            guard let pluginID = prepared.manifest.pluginIDs.first else { throw Failure.reviewedBytesChanged }
            guard let installed = library.installedPackage(id: pluginID) else {
                throw CapabilityPackageInstallUnreadable(packageID: pluginID)
            }
            guard try CapabilityApprovalDigest.digest(for: installed) == definition.reviewedDigest else {
                throw Failure.reviewedBytesChanged
            }
            let records = approvalRecords()
            if kind == .approval, PluginUpdateService.awaitsReview(installed, records: records) {
                throw Failure.reviewedBytesChanged
            }
            try PluginUpdateService.reconcileAll(modelContext: modelContext, packages: [installed], mode: .release,
                approvalRecords: records, rewriteMirror: rewriteMirror,
                fileOperation: prepared, fileJournal: journal, operationKind: kind, persist: persist)
            CapabilityCatalogPersistenceEvents.post(.global)
            return installed
        } catch {
            defer { CapabilityCatalogPersistenceEvents.post(.global) }
            if !PluginOperationProblem.preventsRollback(error) {
                // Reconciliation restores unsaved model changes first. Only
                // the matching-store receipt can choose file replay direction.
                guard recovery.resumePending(modelContext: modelContext, only: prepared.id).deferred == 0 else {
                    throw PluginOperationProblem.commitUncertain(prepared.id)
                }
            }
            throw error
        }
    }
}

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
        rewriteMirror: ((Workspace) -> Bool)? = nil, operation: PluginFileOperationContext? = nil
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
                fileOperation: prepared, fileJournal: journal, operationKind: kind, persist: persist, metadata: operation?.metadata)
            CapabilityCatalogPersistenceEvents.post(.global)
            return installed
        } catch {
            defer { CapabilityCatalogPersistenceEvents.post(.global) }
            if !PluginOperationProblem.preventsRollback(error) {
                // Reconciliation restores unsaved model changes first. Only
                // the matching-store receipt can choose file replay direction.
                guard recovery.resumePending(modelContext: modelContext, only: prepared.id, metadata: operation?.metadata).deferred == 0 else {
                    throw PluginOperationProblem.commitUncertain(prepared.id)
                }
            }
            throw error
        }
    }
    /// Staging changes no active workspace. Use a fresh context so the receipt
    /// cannot save or roll back an unrelated editor's in-flight changes.
    static func stage(_ definition: PluginLibraryPreparation.Definition, journal: PluginFileOperationJournal,
        modelContext: ModelContext, operation: PluginFileOperationContext?) throws {
        let saved = ModelContext(modelContext.container)
        saved.autosaveEnabled = false
        let prepared = definition.operation
        let recovery = PluginFileOperationRecovery(journal: journal)
        do {
            try journal.apply(prepared, forward: true)
            let result = PluginOperationCommit.save(id: prepared.id, kind: .update, pluginIDs: prepared.manifest.pluginIDs,
                workspaceIDs: [], manifestDigest: prepared.digest, modelContext: saved)
            switch result {
            case .notCommitted(let error): saved.rollback(); throw error
            case .indeterminate: throw PluginOperationProblem.commitUncertain(prepared.id)
            case .committed:
                guard recovery.resumePending(modelContext: saved, only: prepared.id, metadata: operation?.metadata).completed == 1 else {
                    throw PluginOperationProblem.savedRecoveryPending(prepared.id)
                }
            }
            CapabilityCatalogPersistenceEvents.post(.global)
        } catch {
            guard !PluginOperationProblem.preventsRollback(error) else { throw error }
            guard recovery.resumePending(modelContext: saved, only: prepared.id, metadata: operation?.metadata).deferred == 0 else {
                throw PluginOperationProblem.commitUncertain(prepared.id)
            }
            throw error
        }
    }

}

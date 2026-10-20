import Foundation
import SwiftData
import ASTRACore
import ASTRAPersistence

/// Produces the metadata participant for real imports and staged approvals.
/// Staging records a draft's origin without changing the active definition's
/// owner. Approval promotes that exact origin in the same committed operation.
@MainActor
struct PluginSourceDefinitionOperation {
    let library: CapabilityLibrary
    let store: PluginSourceStore

    /// Caller holds the existing global library serialization throughout.
    func importPackage(_ report: CapabilityPackageValidationReport, sourceID: String?,
        modelContext: ModelContext, replacesInstalledCopy: Bool = false) throws -> CapabilityPackageImportResult {
        try recover(modelContext)
        let journal = PluginSourceOperationJournal(store: store)
        do {
            return try CapabilityPackageImporter(library: library).importValidatedPackage(report,
                modelContext: modelContext, replacesInstalledCopy: replacesInstalledCopy,
                operationFactory: { source, staging in
                    let after: PluginSourceStore.Provenance?
                    if staging {
                        let current = library.installedPackage(id: source.package.id)
                        let before = try store.savedProvenance()[source.package.id]
                        let digest = current.map(PluginSourceCatalog.contentDigest)
                        let active = before?.resolved(installedDigest: digest)
                        var kept: PluginSourceStore.Provenance
                        if let active, let digest, active.names(digest) {
                            kept = .init(sourceID: active.sourceID, digest: digest)
                        } else { kept = .init(sourceID: "", digest: "") }
                        kept.pendingReview = .init(digest: try PluginLibraryPreparation.reviewDigest(source), sourceID: sourceID)
                        after = kept
                    } else {
                        after = sourceID.map { .init(sourceID: $0, digest: PluginSourceCatalog.contentDigest(source.package)) }
                    }
                    let prepared = try journal.prepare(pluginID: source.package.id, after: after, modelContext: modelContext)
                    return .init(id: prepared.id, metadataDigest: prepared.digest, metadata: journal.handler(modelContext: modelContext))
                })
        } catch {
            // Before file preparation there is no file journal to clean this
            // intent. Existing file work remains authoritative and is skipped.
            _ = journal.resumeOrphans(modelContext: modelContext,
                files: PluginFileOperationJournal(library: library, approvals: CapabilityApprovalStore()))
            throw error
        }
    }

    func approve(id: String, modelContext: ModelContext, approvalStore: CapabilityApprovalStore, approvedBy: String) throws -> PluginPackage {
        try recover(modelContext, approvals: approvalStore)
        guard let draft = library.stagedPackage(id: id) else { throw CapabilityLibrary.RemovalError.notInstalled(id) }
        let before = try store.savedProvenance()[id]
        let reviewedDigest = try CapabilityApprovalDigest.digest(for: draft)
        let sourceID: String?
        if let origin = before?.pendingReview {
            guard origin.digest == reviewedDigest else { throw PluginDefinitionChange.Failure.reviewedBytesChanged }
            sourceID = origin.sourceID
        } else if before?.pendingDigest == PluginSourceCatalog.contentDigest(draft) {
            // A draft an older build staged from its known source.
            sourceID = before?.sourceID
        } else { sourceID = nil }
        let after = sourceID.map { PluginSourceStore.Provenance(sourceID: $0, digest: PluginSourceCatalog.contentDigest(draft)) }
        let journal = PluginSourceOperationJournal(store: store)
        let prepared = try journal.prepare(pluginID: id, after: after, modelContext: modelContext)
        let operation = PluginFileOperationContext(id: prepared.id, metadataDigest: prepared.digest, metadata: journal.handler(modelContext: modelContext))
        do {
            return try PluginStagedApproval.approve(id: id, library: library, modelContext: modelContext,
                approvalStore: approvalStore, approvedBy: approvedBy, operation: operation)
        } catch {
            _ = journal.resumeOrphans(modelContext: modelContext,
                files: PluginFileOperationJournal(library: library, approvals: approvalStore))
            throw error
        }
    }

    private func recover(_ context: ModelContext, approvals: CapabilityApprovalStore = CapabilityApprovalStore()) throws {
        let recovery = PluginSourceOperationRecovery(library: library, store: store, approvals: approvals)
        guard recovery.resumeSerialized(modelContext: context) == 0 else { throw PluginDefinitionChange.Failure.recoveryPending }
    }
}

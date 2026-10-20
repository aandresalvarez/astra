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

    /// Add preserves the active copy's source and an independent draft's
    /// origin. Create clears only the active owner. No digest comparison can
    /// publish that change: a linked source/file/domain receipt must commit it.
    func installing<Result>(_ package: PluginPackage, clearSource: Bool = false,
        modelContext: ModelContext, existing: PluginFileOperationContext? = nil,
        approvals: CapabilityApprovalStore = CapabilityApprovalStore(),
        perform: (PluginFileOperationContext?) throws -> Result) throws -> Result {
        if let existing { return try perform(existing) }
        let before = try store.savedProvenance()[package.id]
        let currentDigest = library.installedPackage(id: package.id).map(PluginSourceCatalog.contentDigest)
        let digest = PluginSourceCatalog.contentDigest(CapabilityPackageImporter.asStored(package))
        let active = before?.resolved(installedDigest: currentDigest)
        let after: PluginSourceStore.Provenance?
        if !clearSource, let active, active.names(digest) { after = active }
        else if let review = before?.pendingReview {
            var held = PluginSourceStore.Provenance(sourceID: "", digest: "")
            held.pendingReview = review
            after = held
        } else if let before, let draft = library.stagedPackage(id: package.id),
                  before.pendingDigest == PluginSourceCatalog.contentDigest(draft) {
            var held = PluginSourceStore.Provenance(sourceID: "", digest: "")
            held.pendingReview = .init(digest: try CapabilityApprovalDigest.digest(for: draft), sourceID: before.sourceID)
            after = held
        } else { after = nil }
        guard before != after else { return try perform(nil) }
        let journal = PluginSourceOperationJournal(store: store)
        let prepared = try journal.prepare(pluginID: package.id, after: after, modelContext: modelContext)
        let identity = after.flatMap { PluginSourceStore.mirrorIdentity(pluginID: package.id, digest: digest, provenance: [package.id: $0]) }
        let operation = PluginFileOperationContext(id: prepared.id, metadataDigest: prepared.digest,
            metadata: journal.handler(modelContext: modelContext), plannedSource: .installed(source: identity))
        do { return try perform(operation) }
        catch {
            _ = journal.resumeOrphans(modelContext: modelContext,
                files: PluginFileOperationJournal(library: library, approvals: approvals))
            throw error
        }
    }

    /// A call-scoped projection of the prepared target for held-import
    /// matching. The journal owns the target; this never writes provenance.
    func projectedProvenance(_ source: PluginInstalledCopy?, package: PluginPackage) -> [String: PluginSourceStore.Provenance] {
        var provenance = store.provenance()
        guard let source else { return provenance }
        let prefix = PluginSource.metadataKind + ":"
        if let identity = source.source, identity.hasPrefix(prefix) {
            provenance[package.id] = .init(sourceID: String(identity.dropFirst(prefix.count)), digest: PluginSourceCatalog.contentDigest(package))
        } else { provenance[package.id] = nil }
        return provenance
    }

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

    func approve(_ review: PluginStagedReview, modelContext: ModelContext, approvalStore: CapabilityApprovalStore, approvedBy: String) throws -> PluginPackage {
        let id = review.id
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
            return try PluginStagedApproval.approve(review, library: library, modelContext: modelContext,
                approvalStore: approvalStore, approvedBy: approvedBy, operation: operation)
        } catch {
            _ = journal.resumeOrphans(modelContext: modelContext,
                files: PluginFileOperationJournal(library: library, approvals: approvalStore))
            throw error
        }
    }

    func discard(_ review: PluginStagedReview, modelContext: ModelContext) throws {
        try recover(modelContext)
        let before = try store.savedProvenance()[review.id]
        let digest = library.installedPackage(id: review.id).map(PluginSourceCatalog.contentDigest)
        let active = before?.resolved(installedDigest: digest)
        let after: PluginSourceStore.Provenance?
        if let active, let digest, active.names(digest) {
            after = .init(sourceID: active.sourceID, digest: digest)
        } else { after = nil }
        let journal = PluginSourceOperationJournal(store: store)
        let prepared = try journal.prepare(pluginID: review.id, after: after, modelContext: modelContext)
        let operation = PluginFileOperationContext(id: prepared.id, metadataDigest: prepared.digest, metadata: journal.handler(modelContext: modelContext))
        do {
            try PluginStagedDiscard.discard(review, library: library, modelContext: modelContext, operation: operation)
        } catch {
            _ = journal.resumeOrphans(modelContext: modelContext,
                files: PluginFileOperationJournal(library: library, approvals: CapabilityApprovalStore()))
            throw error
        }
    }

    /// Remove and forget-missing publish provenance only through the same
    /// matching receipt as their library and workspace deletion.
    func removing(pluginID: String, modelContext: ModelContext,
        perform: (PluginFileOperationContext) throws -> CapabilityUninstaller.RemovalResult) throws -> CapabilityUninstaller.RemovalResult {
        try recover(modelContext)
        let journal = PluginSourceOperationJournal(store: store)
        let prepared = try journal.prepare(pluginID: pluginID, after: nil, modelContext: modelContext)
        let operation = PluginFileOperationContext(id: prepared.id, metadataDigest: prepared.digest, metadata: journal.handler(modelContext: modelContext))
        do { return try perform(operation) }
        catch {
            _ = journal.resumeOrphans(modelContext: modelContext,
                files: PluginFileOperationJournal(library: library, approvals: CapabilityApprovalStore()))
            throw error
        }
    }

    private func recover(_ context: ModelContext, approvals: CapabilityApprovalStore = CapabilityApprovalStore()) throws {
        let recovery = PluginSourceOperationRecovery(library: library, store: store, approvals: approvals)
        guard recovery.resumeSerialized(modelContext: context) == 0 else { throw PluginDefinitionChange.Failure.recoveryPending }
    }
}

import Foundation
import SwiftData
import ASTRAModels
import ASTRACore
import ASTRAPersistence

/// Immutable prepared file participant in a domain commit. It does not own
/// domain state; the matching saved receipt alone chooses replay direction.
@MainActor
struct PluginFileCommit {
    let journal: PluginFileOperationJournal
    let prepared: PluginFileOperationJournal.Prepared
    let metadata: PluginFileOperationRecovery.MetadataHandler?

    static func approval(_ record: CapabilityApprovalRecord, package: PluginPackage, library: CapabilityLibrary,
        approvals: CapabilityApprovalStore, modelContext: ModelContext) throws -> Self {
        guard record.packageID == package.id, record.packageVersion == package.version,
              record.sourceDigest == (try CapabilityApprovalDigest.digest(for: package)) else {
            throw PluginDefinitionChange.Failure.reviewedBytesChanged
        }
        guard let identity = PersistentStoreIdentity.current(for: modelContext) else { throw PluginDefinitionChange.Failure.unavailableStore }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let image = PluginFileImage(isDirectory: false, directories: [], files: ["": try encoder.encode(record)])
        let journal = PluginFileOperationJournal(library: library, approvals: approvals)
        let prepared = try journal.prepare(storeIdentity: identity, pluginIDs: [package.id], changes: [
            .init(root: .approvals, name: approvals.recordURL(for: record).lastPathComponent, replacement: image)
        ])
        return Self(journal: journal, prepared: prepared, metadata: nil)
    }

    func perform<Result>(modelContext: ModelContext, _ body: () throws -> Result) throws -> Result {
        do {
            try journal.apply(prepared, forward: true)
            return try body()
        } catch {
            if !PluginOperationProblem.preventsRollback(error), resume(modelContext: modelContext).deferred > 0 {
                throw PluginOperationProblem.commitUncertain(prepared.id)
            }
            throw error
        }
    }

    func resume(modelContext: ModelContext, export: ((Workspace, ModelContext) -> Bool)? = nil) -> PluginFileOperationRecovery.Result {
        PluginFileOperationRecovery(journal: journal).resumePending(modelContext: modelContext,
            only: prepared.id, export: export, metadata: metadata)
    }
}

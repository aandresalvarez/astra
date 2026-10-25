import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// Remove uses the same receipt as imports: no activation count, version or
/// callback result can authorize deleting a library copy or its credentials.
@MainActor
struct PluginRemovalTransaction {
    let journal: PluginFileOperationJournal
    let prepared: PluginFileOperationJournal.Prepared
    let metadata: PluginFileOperationRecovery.MetadataHandler?

    static func recover(library: CapabilityLibrary, modelContext: ModelContext, operation: PluginFileOperationContext?) throws {
        let journal = PluginFileOperationJournal(library: library, approvals: CapabilityApprovalStore())
        guard PluginFileOperationRecovery(journal: journal).resumePending(modelContext: modelContext,
            metadata: operation?.metadata).deferred == 0 else { throw PluginDefinitionChange.Failure.recoveryPending }
    }

    static func prepare(pluginID: String, missing: Bool, library: CapabilityLibrary,
        modelContext: ModelContext, operation: PluginFileOperationContext?) throws -> Self {
        guard let identity = PersistentStoreIdentity.current(for: modelContext) else { throw PluginDefinitionChange.Failure.unavailableStore }
        let journal = PluginFileOperationJournal(library: library, approvals: CapabilityApprovalStore())
        let id = operation?.id ?? UUID()
        let name = CapabilityLibrary.safeFileName(for: pluginID)
        var changes: [PluginFileOperationJournal.Change] = []
        for suffix in [".json", ""] {
            let slot = name + suffix
            if missing, let image = try PluginFileImage.capture(library.directory.appendingPathComponent(slot)) {
                // An unreadable definition may be the user's only copy. Keep
                // its literal bytes in quarantine in the same durable change.
                changes.append(.init(root: .quarantine, name: id.uuidString + suffix, replacement: image))
            }
            changes.append(.init(root: .library, name: slot, replacement: nil))
            changes.append(.init(root: .staging, name: slot, replacement: nil))
        }
        let prepared = try journal.prepare(id: id, storeIdentity: identity, pluginIDs: [pluginID], changes: changes,
            linkedMetadataDigest: operation?.metadataDigest)
        return Self(journal: journal, prepared: prepared, metadata: operation?.metadata)
    }

    func commit(workspaceIDs: [UUID], secretIDs: [UUID], modelContext: ModelContext,
        outbox: PluginSecretCleanupOutbox?, secrets: (any SkillSecretPersisting.Type)?,
        persist: (ModelContext) -> Bool, export: ((Workspace) -> Bool)?) throws {
        var proof: PluginOperationCommit.Outcome?
        var completed = false
        let saved = PluginSecretCleanupOutbox.deleteThenClean(secretIDs, modelContext: modelContext, outbox: outbox, secrets: secrets,
            save: {
                let result = PluginOperationCommit.save(id: prepared.id, kind: .remove, pluginIDs: prepared.manifest.pluginIDs,
                    workspaceIDs: workspaceIDs, manifestDigest: prepared.digest, modelContext: modelContext, persist: { context in
                        guard persist(context) else { throw CapabilityUninstaller.UninstallError.saveFailed(packageID: prepared.manifest.pluginIDs[0]) }
                    })
                proof = result
                if case .notCommitted = result { return false }
                return true // Unknown commit keeps both journals and cleanup debt.
            }, beforeSettling: {
                guard case .committed(_, saveReportedFailure: false) = proof else { return false }
                let rewrite: ((Workspace, ModelContext) -> Bool)? = export.map { callback in { workspace, _ in callback(workspace) } }
                completed = PluginFileOperationRecovery(journal: journal).resumePending(modelContext: modelContext,
                    only: prepared.id, export: rewrite, metadata: metadata).completed == 1
                return completed
            })
        guard saved else { throw CapabilityUninstaller.UninstallError.saveFailed(packageID: prepared.manifest.pluginIDs[0]) }
        if case .indeterminate(let id, _) = proof { throw PluginOperationProblem.commitUncertain(id) }
        guard completed else { throw PluginOperationProblem.savedRecoveryPending(prepared.id) }
    }

    func rollBackFiles(modelContext: ModelContext) -> Bool {
        PluginFileOperationRecovery(journal: journal).resumePending(modelContext: modelContext,
            only: prepared.id, metadata: metadata).deferred == 0
    }
}

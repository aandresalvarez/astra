import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// One account's legacy plaintext cutover. Raw values stay in the existing
/// model until an admitted private generation and its receipt are saved.
@MainActor
enum ConnectorCredentialMigration {
    enum Failure: Error, LocalizedError {
        case unsavedChanges, creatorUnavailable, invalidLegacyShape
        var errorDescription: String? {
            switch self {
            case .unsavedChanges: "Finish saving current edits before migrating account credentials."
            case .creatorUnavailable: "Restore this account's plugin definition before migrating its saved credentials."
            case .invalidLegacyShape: "Correct this account's legacy credential fields before migrating them."
            }
        }
    }

    @discardableResult
    static func migrate(
        _ account: Connector, mirroredBy workspaces: [Workspace], modelContext: ModelContext,
        resolver: (any ConnectorSettingStorageResolving.Type)? = ConnectorSettingStorageSeam.resolver,
        persist: (ModelContext) throws -> Void = { try $0.save() }, rewriteMirror: ((Workspace) -> Bool)? = nil,
        permit: PluginMutationScope.Permit? = nil
    ) throws -> Bool {
        guard account.modelContext === modelContext, !account.isDeleted else { throw ConnectorCredentialEditor.Failure.changedAccount }
        guard !modelContext.hasChanges else { throw Failure.unsavedChanges }
        // Readiness precedes implicit recovery so another call cannot finish
        // a failed operation and silently replay its original mutation.
        try requireReady(try mirrorScope(account, workspaces: workspaces, modelContext: modelContext), modelContext: modelContext)
        do {
            return try PluginMutationScope.perform(pluginID: "__account_credentials__", library: CapabilityLibrary(),
                store: PluginSourceStore(), modelContext: modelContext, permit: permit) { _ in
                    try migrateReady(account, mirroredBy: workspaces, modelContext: modelContext,
                        resolver: resolver, persist: persist, rewriteMirror: rewriteMirror)
                }
        } catch PluginSourceStoreError.pluginBusy(_) { throw PluginSourceStoreError.libraryBusy }
    }

    @discardableResult
    private static func migrateReady(
        _ account: Connector, mirroredBy workspaces: [Workspace], modelContext: ModelContext,
        resolver: (any ConnectorSettingStorageResolving.Type)? = ConnectorSettingStorageSeam.resolver,
        persist: (ModelContext) throws -> Void = { try $0.save() }, rewriteMirror: ((Workspace) -> Bool)? = nil
    ) throws -> Bool {
        guard account.modelContext === modelContext, !account.isDeleted else { throw ConnectorCredentialEditor.Failure.changedAccount }
        guard !modelContext.hasChanges else { throw Failure.unsavedChanges }
        let scope = try mirrorScope(account, workspaces: workspaces, modelContext: modelContext)
        try requireReady(scope, modelContext: modelContext)
        let declared = account.originPackageID.flatMap {
            resolver?.declaredSettingKeysStoredAsCredentials(originPackageID: $0, originComponentID: account.originComponentID)
        }
        let promoted = Set(account.configKeys.indices.compactMap { index -> String? in
            let key = ConnectorCredentialKey.canonical(account.configKeys[index])
            guard declared?.contains(where: { ConnectorCredentialKey.same($0, key) }) == true,
                  index < account.configValues.count, !account.configValues[index].isEmpty else { return nil }
            return key
        })
        let hasRaw = account.credentialValues.contains { !$0.isEmpty }
        guard hasRaw || !promoted.isEmpty else { return false }
        if account.originPackageID?.isEmpty == false, declared == nil { throw Failure.creatorUnavailable }
        guard account.credentialValues.dropFirst(account.credentialKeys.count).allSatisfy({ $0.isEmpty }),
              account.configValues.dropFirst(account.configKeys.count).allSatisfy({ $0.isEmpty }),
              !account.credentialKeys.contains(where: { ConnectorCredentialKey.canonical($0).isEmpty })
        else { throw Failure.invalidLegacyShape }
        try requireUnchanged(account, modelContext: modelContext)
        let previous = Snapshot(account)
        let keys = Set(account.credentialKeys.map(ConnectorCredentialKey.canonical)).union(promoted)
        let prepared = try ConnectorCredentialGenerationTransaction.prepare(account: account, isNew: false,
            keeping: keys, replacing: [], modelContext: modelContext, migratingSettings: promoted, settingConflicts: .reject)
        var attemptedCommit = false
        do {
            let settled = Set(prepared.settledSettingFields.map { ConnectorCredentialKey.canonical($0.key) })
            guard promoted.isSubset(of: settled) else { throw Failure.invalidLegacyShape }
            try requireReady(scope, modelContext: modelContext)
            account.credentialNamespaceID = prepared.namespaceID
            account.credentialKeys = keys.sorted()
            account.credentialValues = Array(repeating: "", count: account.credentialKeys.count)
            let retained = account.configKeys.indices.filter { !promoted.contains(ConnectorCredentialKey.canonical(account.configKeys[$0])) }
            let values = retained.map { $0 < account.configValues.count ? account.configValues[$0] : "" }
            account.configKeys = retained.map { account.configKeys[$0] }
            account.configValues = values
            account.updatedAt = Date()
            attemptedCommit = true
            switch PluginStateCommit.save(workspaceIDs: Array(scope), pluginIDs: [], kind: .configure,
                modelContext: modelContext, persist: persist, export: rewriteMirror) {
            case .completed: prepared.completed()
            case .pendingRecovery(let id): throw PluginOperationProblem.savedRecoveryPending(id)
            case .indeterminate(let id, _): throw PluginOperationProblem.commitUncertain(id)
            case .notCommitted: throw ConnectorCredentialEditor.Failure.saveFailed
            }
            return true
        } catch {
            guard !PluginOperationProblem.preventsRollback(error) else { throw error }
            if attemptedCommit { modelContext.rollback() }
            previous.restore(account)
            prepared.discard()
            throw error
        }
    }

    private static func requireUnchanged(_ account: Connector, modelContext: ModelContext) throws {
        let saved = ModelContext(modelContext.container)
        let id = account.id
        var query = FetchDescriptor<Connector>(predicate: #Predicate { $0.id == id })
        query.fetchLimit = 2
        let rows = try saved.fetch(query)
        guard rows.count == 1, let stored = rows.first,
              Snapshot(stored) == Snapshot(account) else { throw ConnectorCredentialEditor.Failure.changedAccount }
    }

    private static func mirrorScope(_ account: Connector, workspaces: [Workspace], modelContext: ModelContext) throws -> Set<UUID> {
        guard workspaces.allSatisfy({ $0.modelContext === modelContext && !$0.isDeleted })
        else { throw ConnectorCredentialEditor.Failure.changedAccount }
        // Old mirrors may contain this plaintext even after a consumer was
        // disconnected. Rewrite every known workspace, not only live bindings.
        let saved = ModelContext(modelContext.container)
        var ids = Set(try saved.fetch(FetchDescriptor<Workspace>()).map(\.id))
        ids.formUnion(workspaces.map(\.id))
        ids.formUnion(try PluginStateMirrors.affectedWorkspaces(workspace: account.workspace,
            accounts: [account], modelContext: modelContext).map(\.id))
        return ids
    }

    private static func requireReady(_ scope: Set<UUID>, modelContext: ModelContext) throws {
        let files = PluginFileOperationJournal(library: CapabilityLibrary(), approvals: CapabilityApprovalStore())
        guard try files.pendingIDs().isEmpty else { throw ConnectorCredentialEditor.Failure.otherChangePending }
        for entry in try PluginPendingOperations.capture(modelContext: modelContext) {
            let ids = entry.snapshot.workspaceIDs
            if entry.snapshot.manifestDigest != nil || ids.isEmpty || !scope.isDisjoint(with: ids) { throw entry.problem }
        }
    }

    private struct Snapshot: Equatable {
        let namespace: UUID?
        let originPackageID, originComponentID: String?
        let baseURL, serviceType: String
        let keys, values, configKeys, configValues: [String]
        let updatedAt: Date
        init(_ account: Connector) {
            namespace = account.credentialNamespaceID
            originPackageID = account.originPackageID; originComponentID = account.originComponentID
            baseURL = account.baseURL; serviceType = account.serviceType
            keys = account.credentialKeys; values = account.credentialValues
            configKeys = account.configKeys; configValues = account.configValues
            updatedAt = account.updatedAt
        }
        func restore(_ account: Connector) {
            account.credentialNamespaceID = namespace
            account.credentialKeys = keys; account.credentialValues = values
            account.configKeys = configKeys; account.configValues = configValues
            account.updatedAt = updatedAt
        }
    }
}

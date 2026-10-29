import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// Explicit account credential edits. Every change publishes an independent
/// generation with its domain receipt and complete recovery mirror scope.
@MainActor
enum ConnectorCredentialEditor {
    enum Failure: Error, LocalizedError {
        case changedAccount, invalidKey, saveFailed, unreadableChanges, otherChangePending, restartRequired, pendingEdits
        var errorDescription: String? {
            switch self {
            case .pendingEdits: "Save or discard pending edits before changing credentials."
            case .changedAccount: "This account changed. Reopen it before editing credentials."
            case .invalidKey: "Choose a credential key before saving."
            case .saveFailed: "The credential change could not be saved. Its previous value was kept."
            case .unreadableChanges: "ASTRA couldn't verify pending changes. Finish recovery in Plugins before editing credentials."
            case .otherChangePending: "Finish the pending change in Plugins before editing credentials."
            case .restartRequired: "ASTRA couldn't confirm this save. Restart ASTRA to finish recovery before editing credentials."
            }
        }
    }

    static func save(
        _ value: String, forKey key: String, on account: Connector, modelContext: ModelContext,
        allowUserInteraction: Bool = true,
        settingResolver: (any ConnectorSettingStorageResolving.Type)? = ConnectorSettingStorageSeam.resolver,
        persist: (ModelContext) throws -> Void = { try $0.save() }, rewriteMirror: ((Workspace) -> Bool)? = nil
    ) throws -> ConnectorCredentialSaveOutcome {
        try save([key: value], on: account, modelContext: modelContext, allowUserInteraction: allowUserInteraction,
            settingResolver: settingResolver, persist: persist, rewriteMirror: rewriteMirror)?.outcome ?? .saved
    }

    /// Several values in one generation, or none of them. Re-entering every
    /// value this build can't read (`unreadableKeys`) is the only edit of such
    /// an account that needn't copy one; one at a time, each save would stop
    /// at the next. Returns the first value that wasn't saved, nil when all were.
    static func save(
        _ values: [String: String], on account: Connector, modelContext: ModelContext,
        allowUserInteraction: Bool = true,
        settingResolver: (any ConnectorSettingStorageResolving.Type)? = ConnectorSettingStorageSeam.resolver,
        persist: (ModelContext) throws -> Void = { try $0.save() }, rewriteMirror: ((Workspace) -> Bool)? = nil,
        vault: SecretStore = KeychainSecretStore()
    ) throws -> (key: String, outcome: ConnectorCredentialSaveOutcome)? {
        try serializedAccount(account, modelContext: modelContext) {
            try change(values, removing: nil, account: account, modelContext: modelContext,
                allowUserInteraction: allowUserInteraction, settingResolver: settingResolver, persist: persist,
                rewriteMirror: rewriteMirror, vault: vault)
        }
    }

    /// Saved keys whose vault reads are refused, rather than missing: denied
    /// bootstrap access and an older item's ACL both produce this outcome.
    /// An explicit read per key; call from an action or task, never a view body.
    static func unreadableKeys(of account: Connector, vault: SecretStore = KeychainSecretStore()) -> [String] {
        guard !account.isStanfordOutlookMail else { return [] }
        let facts = ConnectorSecretFacts(connector: account)
        return Set(account.credentialKeys.map(ConnectorCredentialKey.canonical)).sorted().filter { key in
            !key.isEmpty && ConnectorSecretSeam.required.readCredential(key: key, facts: facts, store: vault) == .unavailable
        }
    }

    static func remove(
        _ key: String, from account: Connector, modelContext: ModelContext,
        settingResolver: (any ConnectorSettingStorageResolving.Type)? = ConnectorSettingStorageSeam.resolver,
        persist: (ModelContext) throws -> Void = { try $0.save() }, rewriteMirror: ((Workspace) -> Bool)? = nil
    ) throws {
        _ = try serializedAccount(account, modelContext: modelContext) {
            try change([:], removing: key, account: account, modelContext: modelContext,
                allowUserInteraction: false, settingResolver: settingResolver, persist: persist,
                rewriteMirror: rewriteMirror, vault: KeychainSecretStore())
        }
    }

    /// Recovery never repeats a credential write or invents a new operation.
    /// An unproved commit needs a new application context before another edit.
    static func recover(_ id: UUID, modelContext: ModelContext) throws {
        guard let saved = try PluginOperationCommit.read(id, container: modelContext.container) else { throw Failure.restartRequired }
        guard saved.manifestDigest == nil else { throw Failure.otherChangePending }
        try serialized(modelContext: modelContext) {
            _ = PluginOperationRecovery.resumePending(modelContext: modelContext, only: id)
            guard try PluginOperationCommit.read(id, container: modelContext.container)?.completedAt != nil
            else { throw PluginOperationProblem.savedRecoveryPending(id) }
        }
    }

    static func canRecoverJournal(modelContext: ModelContext) -> Bool {
        (try? ConnectorCredentialGenerationJournal(modelContext: modelContext)?.canRecoverEditing()) == true
    }

    /// Preserve the unverifiable journal before accepting any new credential
    /// edits. This action never reads/writes the vault or changes account rows.
    static func recoverJournal(on account: Connector, modelContext: ModelContext) throws {
        guard !modelContext.hasChanges else { throw Failure.pendingEdits }
        try serializedAccount(account, modelContext: modelContext) {
            guard let journal = try ConnectorCredentialGenerationJournal(modelContext: modelContext) else { return }
            let lease = try journal.acquireLease()
            try journal.recoverEditing(lease: lease)
        }
    }

    private static func serializedAccount<Result>(
        _ account: Connector, modelContext: ModelContext, _ body: () throws -> Result
    ) throws -> Result {
        guard account.modelContext === modelContext, !account.isDeleted else { throw Failure.changedAccount }
        // A replay of a failed Save must first finish its existing receipt;
        // acquiring the source lock must not silently replay that edit.
        try requireReady(try workspaceScope(of: account, modelContext: modelContext), modelContext: modelContext)
        return try serialized(modelContext: modelContext, body)
    }

    private static func serialized<Result>(modelContext: ModelContext, _ body: () throws -> Result) throws -> Result {
        do {
            return try PluginMutationScope.perform(pluginID: "__account_credentials__", library: CapabilityLibrary(),
                store: PluginSourceStore(), modelContext: modelContext) { _ in try body() }
        } catch PluginSourceStoreError.pluginBusy(_) { throw PluginSourceStoreError.libraryBusy }
    }

    private static func change(
        _ rawReplacements: [String: String], removing rawRemoved: String?, account: Connector, modelContext: ModelContext,
        allowUserInteraction: Bool, settingResolver: (any ConnectorSettingStorageResolving.Type)?,
        persist: (ModelContext) throws -> Void, rewriteMirror: ((Workspace) -> Bool)?, vault: SecretStore
    ) throws -> (key: String, outcome: ConnectorCredentialSaveOutcome)? {
        guard account.modelContext === modelContext, !account.isDeleted else { throw Failure.changedAccount }
        var replacements: [String: String] = [:]
        for (rawKey, value) in rawReplacements {
            let key = ConnectorCredentialKey.canonical(rawKey)
            guard !key.isEmpty, replacements.updateValue(value, forKey: key) == nil else { throw Failure.invalidKey }
        }
        let removed = rawRemoved.map(ConnectorCredentialKey.canonical)
        guard removed?.isEmpty != true, !replacements.isEmpty || removed != nil else { throw Failure.invalidKey }
        let scope = try workspaceScope(of: account, modelContext: modelContext)
        try requireReady(scope, modelContext: modelContext)
        guard !modelContext.hasChanges else { throw Failure.pendingEdits }
        let previous = Snapshot(account)
        let keeping = keepingKeys(of: account, settingResolver: settingResolver)
            .subtracting(removed.map { [$0] } ?? [])
        let isNew = modelContext.insertedModelsArray.contains { ($0 as? Connector) === account }
        let prepared = try ConnectorCredentialGenerationTransaction.prepare(account: account, isNew: isNew,
            keeping: keeping, replacing: Set(replacements.keys), modelContext: modelContext,
            legacyHandling: .preservePending, vault: vault)
        var attemptedCommit = false
        do {
            // Recheck scope from fresh saved rows while the producer lease is
            // held. Other workspaces using a shared account need mirrors too.
            let affected = scope.union(try workspaceScope(of: account, modelContext: modelContext))
            try requireReady(affected, modelContext: modelContext)
            prepared.apply(to: account)
            retainCredentialFields(on: account, prepared: prepared, removing: removed)
            // An explicit secret edit settles the same key's legacy plain
            // alias too. Keeping it would create a second mutable owner or
            // silently restore a removed credential during a later migration.
            let edited = Set(replacements.keys).union(removed.map { [$0] } ?? [])
            let config = account.configKeys.indices.filter { !edited.contains(ConnectorCredentialKey.canonical(account.configKeys[$0])) }
            let configValues = config.map { $0 < account.configValues.count ? account.configValues[$0] : "" }
            account.configKeys = config.map { account.configKeys[$0] }
            account.configValues = configValues
            for (key, replacement) in replacements.sorted(by: { $0.key < $1.key }) {
                prepared.noteWriteAttempt()
                let result = account.saveCredentialChecked(key: key, value: replacement, allowUserInteraction: allowUserInteraction)
                guard result.isSaved else {
                    // The context was clean on entry. Restoring values alone still
                    // leaves SwiftData dirty, which would block a corrected retry.
                    previous.restore(account); PluginSavedStateRollback.finish(in: modelContext); prepared.discard()
                    return (key, result)
                }
            }
            account.updatedAt = Date()
            attemptedCommit = true
            // Accounts can also be reached through independent shared
            // resources. An empty plugin scope covers every consumer in the
            // affected workspaces, rather than assuming only origin owns it.
            switch PluginStateCommit.save(workspaceIDs: Array(affected), pluginIDs: [], kind: .configure,
                modelContext: modelContext, persist: persist, export: rewriteMirror) {
            case .completed: prepared.completed()
            case .pendingRecovery(let id): throw PluginOperationProblem.savedRecoveryPending(id)
            case .indeterminate(let id, _): throw PluginOperationProblem.commitUncertain(id)
            case .notCommitted: throw Failure.saveFailed
            }
            return nil
        } catch {
            guard !PluginOperationProblem.preventsRollback(error) else { throw error }
            if attemptedCommit { modelContext.rollback() }
            previous.restore(account)
            PluginSavedStateRollback.finish(in: modelContext)
            prepared.discard()
            throw error
        }
    }

    /// Declared latent vault values remain owned when a different field or
    /// the OAuth authorization changes. Arbitrary plain fields are not probed.
    static func keepingKeys(of account: Connector, settingResolver: (any ConnectorSettingStorageResolving.Type)?) -> Set<String> {
        let declared = account.originPackageID.flatMap { origin in
            settingResolver?.declaredSettingKeysStoredAsCredentials(originPackageID: origin,
                originComponentID: account.originComponentID)
        } ?? []
        let declaredKeys = Set(declared.map(ConnectorCredentialKey.canonical))
        let protected = account.configKeys.filter {
            declaredKeys.contains(ConnectorCredentialKey.canonical($0)) && !account.configValue($0).isEmpty
        }
        return Set((account.credentialKeys + protected).map(ConnectorCredentialKey.canonical))
    }

    static func retainCredentialFields(on account: Connector, prepared: ConnectorCredentialGenerationTransaction, removing: String? = nil) {
        var seen = Set<String>()
        var keys: [String] = [], values: [String] = []
        for existing in account.credentialKeys {
            let canonical = ConnectorCredentialKey.canonical(existing)
            if let removing, canonical == removing { continue }
            guard seen.insert(canonical).inserted else { continue }
            if let pending = prepared.pendingLegacyFields[canonical] {
                keys += pending.map(\.key); values += pending.map(\.value)
            } else { keys.append(canonical); values.append("") }
        }
        account.credentialKeys = keys
        account.credentialValues = values
    }

    static func workspaceScope(of account: Connector, modelContext: ModelContext) throws -> Set<UUID> {
        var ids = Set(try PluginStateMirrors.affectedWorkspaces(workspace: account.workspace,
            accounts: [account], modelContext: modelContext).map(\.id))
        let fresh = ModelContext(modelContext.container)
        let id = account.id
        var query = FetchDescriptor<Connector>(predicate: #Predicate { $0.id == id })
        query.fetchLimit = 2
        let rows = try fresh.fetch(query)
        guard rows.count <= 1 else { throw Failure.changedAccount }
        if let saved = rows.first {
            ids.formUnion(try PluginStateMirrors.affectedWorkspaces(workspace: saved.workspace,
                accounts: [saved], modelContext: fresh).map(\.id))
        }
        return ids
    }

    static func requireReady(_ workspaceIDs: Set<UUID>, modelContext: ModelContext) throws {
        do {
            let files = PluginFileOperationJournal(library: CapabilityLibrary(), approvals: CapabilityApprovalStore())
            guard try files.pendingIDs().isEmpty else { throw Failure.otherChangePending }
            for entry in try PluginPendingOperations.capture(modelContext: modelContext) {
                let receipt = entry.snapshot
                guard receipt.manifestDigest != nil || receipt.workspaceIDs.isEmpty
                    || !workspaceIDs.isDisjoint(with: receipt.workspaceIDs) else { continue }
                guard receipt.manifestDigest == nil else { throw Failure.otherChangePending }
                throw entry.problem
            }
        } catch let problem as PluginOperationProblem { throw problem }
        catch let problem as Failure { throw problem }
        catch { throw Failure.unreadableChanges }
    }

    struct Snapshot {
        let namespace: UUID?
        let keys: [String]
        let values: [String]
        let configKeys: [String]
        let configValues: [String]
        let updatedAt: Date
        init(_ account: Connector) {
            namespace = account.credentialNamespaceID; keys = account.credentialKeys
            values = account.credentialValues; updatedAt = account.updatedAt
            configKeys = account.configKeys; configValues = account.configValues
        }
        func restore(_ account: Connector) {
            account.credentialNamespaceID = namespace; account.credentialKeys = keys
            account.credentialValues = values; account.updatedAt = updatedAt
            account.configKeys = configKeys; account.configValues = configValues
        }
    }
}

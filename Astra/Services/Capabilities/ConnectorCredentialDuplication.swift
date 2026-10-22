import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// An explicit transfer from the selected saved account. The source stays
/// owned; only the independent copy is a new credential generation.
@MainActor
enum ConnectorCredentialDuplication {
    static func duplicate(
        _ source: Connector, in workspace: Workspace, modelContext: ModelContext,
        settingResolver: (any ConnectorSettingStorageResolving.Type)? = ConnectorSettingStorageSeam.resolver,
        persist: (ModelContext) throws -> Void = { try $0.save() }, rewriteMirror: ((Workspace) -> Bool)? = nil
    ) throws -> Connector {
        try requireReady(source, in: workspace, modelContext: modelContext)
        SwiftDataPluginRelationshipPreparation.prepare(workspace, additionalAccounts: [source])
        let previous = WorkspaceCapabilityActivation.snapshot(workspace)
        let copy = CapabilitySharing.makeWorkspaceCopy(source, in: workspace)
        modelContext.insert(copy)
        var prepared: ConnectorCredentialGenerationTransaction?
        var attemptedCommit = false
        do {
            let declared = source.originPackageID.flatMap { origin in
                settingResolver?.declaredSettingKeysStoredAsCredentials(originPackageID: origin,
                    originComponentID: source.originComponentID)
            } ?? []
            let promoted = source.configKeys.filter { candidate in
                !source.configValue(candidate).isEmpty && declared.contains { ConnectorCredentialKey.same($0, candidate) }
            }
            let keys = Set((source.credentialKeys + promoted).map(ConnectorCredentialKey.canonical))
            let transaction = try ConnectorCredentialGenerationTransaction.prepare(account: copy, isNew: true,
                keeping: keys, replacing: [], modelContext: modelContext,
                migratingSettings: Set(promoted.map(ConnectorCredentialKey.canonical)), copying: source)
            prepared = transaction
            copy.credentialNamespaceID = transaction.namespaceID
            copy.credentialKeys = keys.sorted()
            copy.credentialValues = Array(repeating: "", count: copy.credentialKeys.count)
            let settings = transaction.retainedSettings(of: copy)
            copy.configKeys = settings.keys
            copy.configValues = settings.values
            try bindCopy(copy, replacing: source, in: workspace)
            CapabilitySharing.disableShared(source, in: workspace)
            attemptedCommit = true
            switch PluginStateCommit.save(workspace: workspace, accounts: [copy], kind: .configure,
                modelContext: modelContext, persist: persist, export: rewriteMirror) {
            case .completed: transaction.completed()
            case .pendingRecovery(let id): throw PluginOperationProblem.savedRecoveryPending(id)
            case .indeterminate(let id, _): throw PluginOperationProblem.commitUncertain(id)
            case .notCommitted: throw ConnectorCredentialEditor.Failure.saveFailed
            }
            return copy
        } catch {
            guard !PluginOperationProblem.preventsRollback(error) else { throw error }
            if attemptedCommit { modelContext.rollback() }
            if copy.modelContext === modelContext { modelContext.delete(copy) }
            WorkspaceCapabilityActivation.restore(previous, to: workspace)
            PluginSavedStateRollback.finish(in: modelContext)
            prepared?.discard()
            throw error
        }
    }

    static func requireReady(_ source: Connector, in workspace: Workspace, modelContext: ModelContext) throws {
        guard source.modelContext === modelContext, workspace.modelContext === modelContext,
              !source.isDeleted, !workspace.isDeleted else { throw ConnectorCredentialEditor.Failure.changedAccount }
        guard !modelContext.hasChanges else { throw ConnectorCredentialEditor.Failure.pendingEdits }
        let files = PluginFileOperationJournal(library: CapabilityLibrary(), approvals: CapabilityApprovalStore())
        guard try files.pendingIDs().isEmpty else { throw ConnectorCredentialEditor.Failure.otherChangePending }
        var scope = Set(try PluginStateMirrors.affectedWorkspaces(workspace: workspace,
            accounts: [source], modelContext: modelContext).map(\.id))
        let fresh = ModelContext(modelContext.container)
        let id = source.id
        var query = FetchDescriptor<Connector>(predicate: #Predicate { $0.id == id })
        query.fetchLimit = 2
        let rows = try fresh.fetch(query)
        guard rows.count == 1, let stored = rows.first else { throw ConnectorCredentialEditor.Failure.changedAccount }
        scope.formUnion(try PluginStateMirrors.affectedWorkspaces(workspace: stored.workspace,
            accounts: [stored], modelContext: fresh).map(\.id))
        for entry in try PluginPendingOperations.capture(modelContext: modelContext) {
            let ids = entry.snapshot.workspaceIDs
            if entry.snapshot.manifestDigest != nil || ids.isEmpty || !scope.isDisjoint(with: ids) { throw entry.problem }
        }
    }

    /// The local copy takes over only this workspace's selected bindings.
    /// Its creator remains authoritative for field trust and format checks.
    private static func bindCopy(_ copy: Connector, replacing source: Connector, in workspace: Workspace) throws {
        let activations = WorkspaceCapabilityActivation.activations(of: workspace)
        let hasSelectedBinding = activations.contains { activation in
            activation.bindings.contains { !$0.isDeleted && $0.account?.id == source.id }
        }
        for activation in activations {
            let selected = activation.bindings.filter { !$0.isDeleted && $0.account?.id == source.id }
                .map { ($0.componentID, $0.isDefault) }
            if !selected.isEmpty {
                WorkspaceCapabilityActivation.unbind(source, from: activation)
                for (component, isDefault) in selected {
                    WorkspaceCapabilityActivation.bind(copy, toComponent: component, of: activation, isDefault: isDefault)
                }
            } else if !hasSelectedBinding && activation.pluginID == source.originPackageID {
                guard let component = source.originComponentID, activation.knownComponentIDs.contains(component)
                else { throw ConnectorCredentialEditor.Failure.changedAccount }
                WorkspaceCapabilityActivation.bind(copy, toComponent: component, of: activation)
            }
        }
    }

}

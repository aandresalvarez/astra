import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// A verified sign-in or explicit sign-out publishes through the same durable
/// account receipt as ordinary credential edits. Accepted generations survive.
@MainActor
enum OutlookAuthorizationEditor {
    static func authorize(_ bundle: OutlookOAuthBundle, identity: GraphMeResponse, expected: PluginAccountRecord,
                          on account: Connector, modelContext: ModelContext, allowUserInteraction: Bool = true,
                          persist: (ModelContext) throws -> Void = { try $0.save() }, rewriteMirror: ((Workspace) -> Bool)? = nil) throws {
        guard identity.id == bundle.principalID, !identity.id.isEmpty else {
            throw OutlookCredentialGenerationPreparation.Failure.invalidAuthorization
        }
        try change(.authorize(bundle), identity: identity, expected: expected, on: account, modelContext: modelContext,
            allowUserInteraction: allowUserInteraction, persist: persist, rewriteMirror: rewriteMirror)
    }

    static func signOut(_ account: Connector, modelContext: ModelContext,
                        persist: (ModelContext) throws -> Void = { try $0.save() }, rewriteMirror: ((Workspace) -> Bool)? = nil) throws {
        try change(.signOut, identity: nil, expected: PluginAccountRecord(account), on: account,
            modelContext: modelContext, allowUserInteraction: false, persist: persist, rewriteMirror: rewriteMirror)
    }

    private static func change(_ change: OutlookCredentialGenerationPreparation.Change, identity: GraphMeResponse?,
                               expected: PluginAccountRecord, on account: Connector, modelContext: ModelContext,
                               allowUserInteraction: Bool, persist: (ModelContext) throws -> Void, rewriteMirror: ((Workspace) -> Bool)?) throws {
        try Task.checkCancellation()
        guard account.modelContext === modelContext, !account.isDeleted, account.isStanfordOutlookMail,
              PluginAccountRecord(account) == expected else { throw ConnectorCredentialEditor.Failure.changedAccount }
        let scope = try ConnectorCredentialEditor.workspaceScope(of: account, modelContext: modelContext)
        try ConnectorCredentialEditor.requireReady(scope, modelContext: modelContext)
        guard !modelContext.hasChanges else { throw ConnectorCredentialEditor.Failure.pendingEdits }
        let previous = ConnectorCredentialEditor.Snapshot(account)
        let prepared = try ConnectorCredentialGenerationTransaction.prepare(account: account, isNew: false,
            keeping: ConnectorCredentialEditor.keepingKeys(of: account, settingResolver: ConnectorSettingStorageSeam.resolver),
            replacing: [], modelContext: modelContext, legacyHandling: .preservePending, outlookChange: change,
            allowOutlookUserInteraction: allowUserInteraction)
        var attemptedCommit = false
        do {
            // A promptable vault write may have outlived cancellation.
            try Task.checkCancellation()
            let affected = scope.union(try ConnectorCredentialEditor.workspaceScope(of: account, modelContext: modelContext))
            try ConnectorCredentialEditor.requireReady(affected, modelContext: modelContext)
            ConnectorCredentialEditor.retainCredentialFields(on: account, prepared: prepared)
            prepared.apply(to: account)
            if let identity {
                account.setConfigValue(StanfordOutlookMail.accountIDKey, value: identity.id)
                account.setConfigValue(StanfordOutlookMail.emailKey, value: identity.mail ?? identity.userPrincipalName ?? "")
                account.setConfigValue(StanfordOutlookMail.displayNameKey, value: identity.displayName ?? "")
                account.setConfigValue(StanfordOutlookMail.tokenUpdatedAtKey, value: ISO8601DateFormatter().string(from: Date()))
            } else {
                account.setConfigValue(StanfordOutlookMail.tokenUpdatedAtKey, value: "")
            }
            account.updatedAt = Date()
            attemptedCommit = true
            switch PluginStateCommit.save(workspaceIDs: Array(affected), pluginIDs: [], kind: .configure,
                modelContext: modelContext, persist: persist, export: rewriteMirror) {
            case .completed: prepared.completed()
            case .pendingRecovery(let id): throw PluginOperationProblem.savedRecoveryPending(id)
            case .indeterminate(let id, _): throw PluginOperationProblem.commitUncertain(id)
            case .notCommitted: throw ConnectorCredentialEditor.Failure.saveFailed
            }
        } catch {
            guard !PluginOperationProblem.preventsRollback(error) else { throw error }
            if attemptedCommit { modelContext.rollback() }
            previous.restore(account)
            prepared.discard()
            throw error
        }
    }
}

import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// The migration preserves opaque legacy account credentials in unpublished
/// generations. Plaintext remains model-owned review debt for the separately
/// admitted startup credential migration; this step never promotes it.
@MainActor
final class PluginMigrationAccountCredentials {
    private let modelContext: ModelContext
    private let vault: SecretStore
    private var originals: [UUID: PluginMigrationAccountSnapshot] = [:]
    private var prepared: [UUID: ConnectorCredentialGenerationTransaction] = [:]
    /// Accounts holding a value this build can't read, with the first such key.
    /// They keep their legacy slots, untouched, until the person re-enters it.
    private(set) var awaitingReentry: [UUID: String] = [:]

    init(modelContext: ModelContext, vault: SecretStore = KeychainSecretStore()) {
        self.modelContext = modelContext
        self.vault = vault
    }

    func prepare(_ account: Connector) throws {
        if originals[account.id] == nil { originals[account.id] = PluginMigrationAccountSnapshot(account) }
        guard account.credentialNamespaceID == nil, !account.credentialKeys.isEmpty,
              prepared[account.id] == nil, awaitingReentry[account.id] == nil else { return }
        let transaction: ConnectorCredentialGenerationTransaction
        do {
            transaction = try ConnectorCredentialGenerationTransaction.prepare(account: account, isNew: false,
                keeping: Set(account.credentialKeys.map(ConnectorCredentialKey.canonical)), replacing: [],
                modelContext: modelContext, legacyHandling: .preservePending, lease: prepared.values.first?.lease,
                vault: vault)
        } catch ConnectorCredentialGenerationTransaction.Failure.readFailed(let key) {
            // A rebuilt ad-hoc ASTRA can't read what an earlier build saved.
            // Deferring this account alone lets every other one migrate; its
            // values stay where they are, nothing is written or recorded for
            // cleanup, and re-entering them publishes its generation.
            awaitingReentry[account.id] = key
            return
        }
        prepared[account.id] = transaction
        transaction.apply(to: account)
    }

    func isAwaitingReentry(_ account: Connector) -> Bool { awaitingReentry[account.id] != nil }

    func completed() { prepared.values.forEach { $0.completed() } }
    func discard() {
        // SwiftData rollback may leave changed scalar fields on an existing
        // object. Restore provenance before deleting unpublished generations.
        originals.values.forEach { $0.restore() }
        prepared.values.forEach { $0.discard() }
    }
}

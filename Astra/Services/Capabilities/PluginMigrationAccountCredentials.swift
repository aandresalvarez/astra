import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

/// The migration preserves opaque legacy account credentials in unpublished
/// generations. Plaintext remains model-owned review debt for the separately
/// admitted startup credential migration; this step never promotes it.
@MainActor
final class PluginMigrationAccountCredentials {
    private let modelContext: ModelContext
    private var prepared: [UUID: ConnectorCredentialGenerationTransaction] = [:]

    init(modelContext: ModelContext) { self.modelContext = modelContext }

    func prepare(_ account: Connector) throws {
        guard account.credentialNamespaceID == nil, !account.credentialKeys.isEmpty,
              prepared[account.id] == nil else { return }
        let transaction = try ConnectorCredentialGenerationTransaction.prepare(account: account, isNew: false,
            keeping: Set(account.credentialKeys.map(ConnectorCredentialKey.canonical)), replacing: [],
            modelContext: modelContext, legacyHandling: .preservePending, lease: prepared.values.first?.lease)
        prepared[account.id] = transaction
        account.credentialNamespaceID = transaction.namespaceID
    }

    func completed() { prepared.values.forEach { $0.completed() } }
    func discard() { prepared.values.forEach { $0.discard() } }
}

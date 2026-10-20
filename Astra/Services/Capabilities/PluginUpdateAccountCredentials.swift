import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

/// Retains one update's private account generations until its existing domain
/// commit proves publication or noncommit. Account rows remain the durable owner.
@MainActor
final class PluginUpdateAccountCredentials {
    private let modelContext: ModelContext
    private var prepared: [UUID: ConnectorCredentialGenerationTransaction] = [:]

    init(modelContext: ModelContext) { self.modelContext = modelContext }

    func prepare(_ activation: PluginActivation, package: PluginPackage) throws -> Set<UUID> {
        var changed = Set<UUID>()
        for candidate in PluginAccountCredentialCutoverPlan.candidates(for: package, activation: activation) {
            let id = candidate.account.id
            guard prepared[id] == nil else { continue }
            prepared[id] = try Self.stage(candidate, modelContext: modelContext, lease: prepared.values.first?.lease)
            changed.insert(id)
        }
        return changed
    }

    /// Add and standalone Update use exactly the same admission and source-field
    /// retirement rules, including retaining conflicting plaintext for review.
    static func stage(_ candidate: PluginAccountCredentialCutoverPlan.Candidate, modelContext: ModelContext,
                      lease: ConnectorCredentialGenerationJournal.Lease?) throws -> ConnectorCredentialGenerationTransaction {
        let account = candidate.account
        let transaction = try ConnectorCredentialGenerationTransaction.prepare(account: account, isNew: false,
            keeping: candidate.keeping, replacing: [], modelContext: modelContext, declaredFormats: candidate.formats,
            migratingSettings: candidate.migratingSettings, lease: lease)
        account.credentialNamespaceID = transaction.namespaceID
        account.credentialValues = Array(repeating: "", count: account.credentialKeys.count)
        // Retire only the exact durable source fields admitted (or matched to
        // an accepted value); a conflicting or newer value stays on its row.
        let retained = account.configKeys.indices.filter { index in
            let value = index < account.configValues.count ? account.configValues[index] : ""
            return !transaction.settledSettingFields.contains {
                ConnectorCredentialKey.same($0.key, account.configKeys[index]) && $0.value == value
            }
        }
        let values = retained.map { $0 < account.configValues.count ? account.configValues[$0] : "" }
        account.configKeys = retained.map { account.configKeys[$0] }
        account.configValues = values
        return transaction
    }

    func completed() { prepared.values.forEach { $0.completed() } }
    func discard() { prepared.values.forEach { $0.discard() } }
}

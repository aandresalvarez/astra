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
        transaction.apply(to: account)
        account.credentialValues = Array(repeating: "", count: account.credentialKeys.count)
        let settings = transaction.retainedSettings(of: account)
        account.configKeys = settings.keys
        account.configValues = settings.values
        return transaction
    }

    func completed() { prepared.values.forEach { $0.completed() } }
    func discard() { prepared.values.forEach { $0.discard() } }
}

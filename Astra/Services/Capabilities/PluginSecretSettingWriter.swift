import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

/// Journals secret writes for Add and reconciliation before their domain
/// save. Existing settings use PluginCredentialGenerationTransaction instead
/// of overwriting an active namespace.
@MainActor
enum PluginSecretSettingWriter {
    enum WriteError: Error, Equatable {
        case journalUnwritable(key: String)
    }

    /// Writes `value` for an activation the caller saves afterwards,
    /// journaling the key first. False, with nothing written and the
    /// journal taken back, when the Keychain refuses. Throws when the
    /// journal can't be written. Without an outbox (an in-memory store)
    /// there is nothing a quit could strand.
    static func writeJournaled(
        _ value: String,
        key: String,
        skillName: String,
        skillID: UUID,
        modelContext: ModelContext,
        persistence: any SkillSecretPersisting.Type
    ) throws -> Bool {
        let journaled = PluginUpdateService.StaleSecret(key: key, skillID: skillID)
        let outbox = PluginSecretCleanupOutbox(for: modelContext)
        do {
            try outbox?.journal([journaled])
        } catch {
            throw WriteError.journalUnwritable(key: key)
        }
        guard persistence.saveSecretValue(value, key: key, skillID: skillID, skillName: skillName, allowUserInteraction: false) else {
            outbox?.forget([journaled])
            return false
        }
        return true
    }

    /// Takes back what `writeJournaled` recorded, once the caller undid the
    /// writes.
    static func forgetJournaled(_ keys: [PluginUpdateService.StaleSecret], modelContext: ModelContext) {
        guard !keys.isEmpty else { return }
        PluginSecretCleanupOutbox(for: modelContext)?.forget(keys)
    }
}

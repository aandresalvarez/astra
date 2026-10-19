import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

/// The one way a plugin skill's secret setting reaches the Keychain: what
/// owns the value is durable before the value is, so a quit or a failed
/// save never leaves a credential nothing records.
///
/// Remove and Update find an activation's secrets through its
/// `secretSettingKeys`, and an Add again derives the same namespace, so a
/// value written first and recorded after could outlive every cleanup and
/// come back.
///
/// - A stored activation (the row's details editor) records the key, saves
///   and writes the workspace's mirror before every write (a recovery from
///   a mirror without the key couldn't clean the value); a write that fails
///   takes a newly recorded key back.
/// - An activation saved later in the same transaction (Add, and the setup
///   it copies) journals the key in `PluginSecretCleanupOutbox` first: that
///   transaction's save settles it (the activation records it), and launch
///   cleans it when a quit came before the save.
@MainActor
enum PluginSecretSettingWriter {
    enum WriteError: Error, Equatable {
        case journalUnwritable(key: String)
    }

    /// Writes `value` for `settingKey` of a stored `activation`.
    /// `saveMarker` saves the activation and writes its workspace's mirror
    /// durably, run before every write; it throws when it can't, and then
    /// nothing is written.
    /// Throws `PluginOperations.OperationError.secretSaveFailed` when the
    /// Keychain refuses, with the marker taken back.
    static func write(
        _ value: String,
        key: String,
        skillName: String,
        settingKey: String,
        skillID: UUID,
        on activation: PluginActivation,
        persistence: any SkillSecretPersisting.Type,
        saveMarker: () throws -> Void
    ) throws {
        let newlyRecorded = !activation.secretSettingKeys.contains(settingKey)
        WorkspaceCapabilityActivation.setSecretRecorded(true, forKey: settingKey, on: activation)
        try saveMarker()
        guard persistence.saveSecretValue(value, key: key, skillID: skillID, skillName: skillName, allowUserInteraction: true) else {
            if newlyRecorded {
                // Nothing was written: the marker goes too. One that can't be
                // saved away names a namespace cleanup clears anyway.
                WorkspaceCapabilityActivation.setSecretRecorded(false, forKey: settingKey, on: activation)
                try? saveMarker()
            }
            throw PluginOperations.OperationError.secretSaveFailed(key: key)
        }
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

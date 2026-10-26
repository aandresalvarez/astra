import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// Application boundary for explicit authored skill secrets. Queued launches
/// retain their accepted namespace; save receipts own recovery and mirror work.
@MainActor
enum SkillCredentialEditor {
    enum Failure: Error, LocalizedError {
        case changedSkill, invalidKey, pendingEdits, legacyFieldsNeedReview, secretReadFailed, secretSaveFailed, saveFailed, recoveryRequired
        var errorDescription: String? {
            switch self {
            case .changedSkill: "This skill changed. Reopen it before editing credentials."
            case .invalidKey: "Choose a secret environment key and a nonempty value."
            case .pendingEdits: "Save other edits before changing this secret."
            case .legacyFieldsNeedReview: "Review the skill's legacy secret fields before changing another secret."
            case .secretReadFailed: "ASTRA couldn't read an existing secret. Unlock Keychain and retry."
            case .secretSaveFailed: "The secret couldn't be saved. Its previous value was kept."
            case .saveFailed: "The credential change couldn't be saved. Its previous value was kept."
            case .recoveryRequired: "Finish recovery in Plugins before changing this secret."
            }
        }
    }

    static func save(_ value: String, forKey key: String, on skill: Skill, modelContext: ModelContext,
                     persist: (ModelContext) throws -> Void = { try $0.save() }, rewriteMirror: ((Workspace) -> Bool)? = nil) throws {
        guard !value.isEmpty else { throw Failure.invalidKey }
        try serializedSkill(skill, modelContext: modelContext) {
            try change([key: value], removing: nil, skill: skill, modelContext: modelContext, persist: persist,
                rewriteMirror: rewriteMirror, vault: KeychainSecretStore())
        }
    }

    /// Several values in one generation, or none of them. Re-entering every
    /// value this build can't read (`unreadableKeys`) is the only edit of such
    /// a skill that needn't copy one. It is also the one edit a plugin skill
    /// row takes, for its own keys: one the migration left as it was because
    /// an earlier build saved them, which a later launch then moves onto its
    /// activation (`PluginActivationMigration`).
    static func save(_ values: [String: String], on skill: Skill, modelContext: ModelContext,
                     persist: (ModelContext) throws -> Void = { try $0.save() }, rewriteMirror: ((Workspace) -> Bool)? = nil,
                     vault: SecretStore = KeychainSecretStore()) throws {
        guard !values.isEmpty, values.values.allSatisfy({ !$0.isEmpty }) else { throw Failure.invalidKey }
        try serializedSkill(skill, modelContext: modelContext, reentering: Set(values.keys)) {
            try change(values, removing: nil, skill: skill, modelContext: modelContext, persist: persist,
                rewriteMirror: rewriteMirror, vault: vault)
        }
    }

    static func remove(_ key: String, from skill: Skill, modelContext: ModelContext,
                       persist: (ModelContext) throws -> Void = { try $0.save() }, rewriteMirror: ((Workspace) -> Bool)? = nil) throws {
        try serializedSkill(skill, modelContext: modelContext) {
            try change([:], removing: key, skill: skill, modelContext: modelContext, persist: persist,
                rewriteMirror: rewriteMirror, vault: KeychainSecretStore())
        }
    }

    /// Saved secret keys whose values this build's Keychain access refuses
    /// (not missing ones): what an earlier ad-hoc build stored, before the
    /// person re-enters it. An explicit read per key; call it from an action
    /// or a task, never from a view body.
    static func unreadableKeys(of skill: Skill, vault: SecretStore = KeychainSecretStore()) -> [String] {
        Set(skill.environmentKeys.filter(Skill.isSecretEnvironmentKey)).sorted().filter {
            SkillSecretSeam.required.readSecretValue(key: $0, skillID: skill.secretNamespaceID, store: vault) == .unavailable
        }
    }

    static func recover(_ id: UUID, modelContext: ModelContext) throws {
        guard let receipt = try PluginOperationCommit.read(id, container: modelContext.container), receipt.manifestDigest == nil else {
            throw Failure.recoveryRequired
        }
        try serialized(modelContext: modelContext) {
            _ = PluginOperationRecovery.resumePending(modelContext: modelContext, only: id)
            guard try PluginOperationCommit.read(id, container: modelContext.container)?.completedAt != nil else {
                throw PluginOperationProblem.savedRecoveryPending(id)
            }
        }
    }

    private static func serializedSkill<Result>(
        _ skill: Skill, modelContext: ModelContext, reentering: Set<String>? = nil, _ body: () throws -> Result
    ) throws -> Result {
        guard skill.modelContext === modelContext, !skill.isDeleted,
              skill.originPackageID == nil || reentering.map({ reentersOwnKeys($0, of: skill) }) == true
        else { throw Failure.changedSkill }
        guard !modelContext.hasChanges else { throw Failure.pendingEdits }
        // Saving again must retain the existing receipt and recovery action;
        // source admission must not silently complete a previous secret edit.
        try requireReady(modelContext: modelContext)
        return try serialized(modelContext: modelContext, body)
    }

    private static func serialized<Result>(modelContext: ModelContext, _ body: () throws -> Result) throws -> Result {
        do {
            return try PluginMutationScope.perform(pluginID: "__skill_credentials__", library: CapabilityLibrary(),
                store: PluginSourceStore(), modelContext: modelContext) { _ in try body() }
        } catch PluginSourceStoreError.pluginBusy(_) { throw PluginSourceStoreError.libraryBusy }
    }

    /// A plugin skill row keeps matching its definition, so the migration
    /// still recognizes it: only keys it already has, all of them secret.
    private static func reentersOwnKeys(_ keys: Set<String>, of skill: Skill) -> Bool {
        let own = skill.environmentKeys.filter(Skill.isSecretEnvironmentKey)
        return !keys.isEmpty && keys.allSatisfy { key in
            own.contains { $0.caseInsensitiveCompare(normalized(key)) == .orderedSame }
        }
    }

    private static func normalized(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private static func change(_ rawReplacements: [String: String], removing rawRemoved: String?, skill: Skill,
                               modelContext: ModelContext, persist: (ModelContext) throws -> Void,
                               rewriteMirror: ((Workspace) -> Bool)?, vault: SecretStore) throws {
        var replacements: [String: String] = [:]
        for (rawKey, value) in rawReplacements {
            let key = normalized(rawKey)
            guard !key.isEmpty, Skill.isSecretEnvironmentKey(key), replacements.updateValue(value, forKey: key) == nil else {
                throw Failure.invalidKey
            }
        }
        let removed = rawRemoved.map(normalized)
        guard removed.map({ !$0.isEmpty && Skill.isSecretEnvironmentKey($0) }) != false,
              !replacements.isEmpty || removed != nil else { throw Failure.invalidKey }
        let edited = Set(replacements.keys).union(removed.map { [$0] } ?? [])
        func isEdited(_ existing: String) -> Bool { edited.contains { existing.caseInsensitiveCompare($0) == .orderedSame } }
        guard skill.modelContext === modelContext, !skill.isDeleted,
              skill.originPackageID == nil || (removed == nil && reentersOwnKeys(edited, of: skill))
        else { throw Failure.changedSkill }
        guard !modelContext.hasChanges else { throw Failure.pendingEdits }
        let previous = Snapshot(skill)
        let saved = ModelContext(modelContext.container)
        let id = skill.id
        let rows = try saved.fetch(FetchDescriptor<Skill>(predicate: #Predicate { $0.id == id }))
        guard rows.count == 1, rows.first.map(Snapshot.init) == previous else { throw Failure.changedSkill }
        // Include former consumers' mirrors: disconnecting a global skill does
        // not prove their prior recovery projection no longer contains it.
        let workspaceIDs = try saved.fetch(FetchDescriptor<Workspace>()).map(\.id)
        try requireReady(modelContext: modelContext)
        guard skill.environmentValues.dropFirst(skill.environmentKeys.count).allSatisfy({ $0.isEmpty }) else {
            throw Failure.legacyFieldsNeedReview
        }
        for (index, existing) in skill.environmentKeys.enumerated() where Skill.isSecretEnvironmentKey(existing) && !isEdited(existing) {
            guard skill.normalizedEnvironmentValue(at: index).isEmpty else { throw Failure.legacyFieldsNeedReview }
        }
        let prepared = try SkillCredentialGenerationTransaction.prepare(skill: skill, replacing: replacements, removing: removed,
            modelContext: modelContext, vault: vault)
        var attemptedCommit = false
        do {
            skill.credentialNamespaceID = prepared.namespaceID
            let kept = skill.environmentKeys.indices.filter { !isEdited(skill.environmentKeys[$0]) }
            let values = kept.map { skill.normalizedEnvironmentValue(at: $0) }
            skill.environmentKeys = kept.map { skill.environmentKeys[$0] }
            skill.environmentValues = values
            for key in replacements.keys.sorted() { skill.environmentKeys.append(key); skill.environmentValues.append("") }
            skill.updatedAt = Date()
            attemptedCommit = true
            switch PluginStateCommit.save(workspaceIDs: workspaceIDs, pluginIDs: [], kind: .configure,
                modelContext: modelContext, persist: persist, export: rewriteMirror) {
            case .completed: prepared.completed()
            case .pendingRecovery(let id): throw PluginOperationProblem.savedRecoveryPending(id)
            case .indeterminate(let id, _): throw PluginOperationProblem.commitUncertain(id)
            case .notCommitted: throw Failure.saveFailed
            }
        } catch {
            guard !PluginOperationProblem.preventsRollback(error) else { throw error }
            if attemptedCommit { modelContext.rollback() }
            previous.restore(skill)
            prepared.discard()
            throw error
        }
    }

    private static func requireReady(modelContext: ModelContext) throws {
        do {
            guard try PluginFileOperationJournal(library: CapabilityLibrary(), approvals: CapabilityApprovalStore()).pendingIDs().isEmpty else {
                throw Failure.recoveryRequired
            }
            // A second click must keep the original recovery action. Turning
            // a saved receipt into a generic error would hide its Finish
            // recovery button even though no new write was admitted.
            if let pending = try PluginPendingOperations.capture(modelContext: modelContext).first { throw pending.problem }
        } catch let failure as Failure { throw failure }
        catch let problem as PluginOperationProblem { throw problem }
        catch { throw Failure.recoveryRequired }
    }

    private struct Snapshot: Equatable {
        let namespace: UUID?
        let keys: [String]
        let values: [String]
        let origin: String?
        let updatedAt: Date
        init(_ skill: Skill) {
            namespace = skill.credentialNamespaceID; keys = skill.environmentKeys; values = skill.environmentValues
            origin = skill.originPackageID; updatedAt = skill.updatedAt
        }
        func restore(_ skill: Skill) {
            skill.credentialNamespaceID = namespace; skill.environmentKeys = keys; skill.environmentValues = values
            skill.updatedAt = updatedAt
        }
    }
}

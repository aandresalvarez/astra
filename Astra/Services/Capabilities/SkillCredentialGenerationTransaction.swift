import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// Stages opaque authored environment values verbatim. The live skill is not
/// touched until every read, journal intent and private write has succeeded.
@MainActor
struct SkillCredentialGenerationTransaction {
    let namespaceID: UUID
    private let journal: SkillCredentialGenerationJournal?
    private let lease: PersistentStoreLease?
    private let persistence: any SkillSecretPersisting.Type

    static func prepare(skill: Skill, replacing key: String, with replacement: String?, modelContext: ModelContext,
                        persistence: any SkillSecretPersisting.Type = SkillSecretSeam.required) throws -> Self {
        try stage(skill: skill, replacing: replacement.map { [key: $0] } ?? [:], removing: replacement == nil ? key : nil,
                  migratingLegacy: false, modelContext: modelContext, persistence: persistence, vault: KeychainSecretStore())
    }

    /// Several values at once, none of them read: what an edit of a skill
    /// whose saved values this build can't read has to replace together.
    static func prepare(skill: Skill, replacing replacements: [String: String], removing removed: String? = nil,
                        modelContext: ModelContext, persistence: any SkillSecretPersisting.Type = SkillSecretSeam.required,
                        vault: SecretStore = KeychainSecretStore()) throws -> Self {
        try stage(skill: skill, replacing: replacements, removing: removed, migratingLegacy: false,
                  modelContext: modelContext, persistence: persistence, vault: vault)
    }

    static func prepareLegacy(skill: Skill, modelContext: ModelContext,
                              persistence: any SkillSecretPersisting.Type = SkillSecretSeam.required) throws -> Self {
        try stage(skill: skill, replacing: [:], removing: nil, migratingLegacy: true,
                  modelContext: modelContext, persistence: persistence, vault: KeychainSecretStore())
    }

    private static func stage(skill: Skill, replacing replacements: [String: String], removing removed: String?,
                              migratingLegacy: Bool, modelContext: ModelContext,
                              persistence: any SkillSecretPersisting.Type, vault: SecretStore) throws -> Self {
        let journal = try SkillCredentialGenerationJournal(modelContext: modelContext)
        let lease = try journal?.acquireLease()
        var writes: [String: String] = [:]
        let edited = Array(replacements.keys) + (removed.map { [$0] } ?? [])
        for existing in Set(skill.environmentKeys) where Skill.isSecretEnvironmentKey(existing)
            && !edited.contains(where: { existing.caseInsensitiveCompare($0) == .orderedSame }) {
            switch persistence.readSecretValue(key: existing, skillID: skill.secretNamespaceID, store: vault) {
            case .value(let value): writes[existing] = value
            case .missing:
                if migratingLegacy, let index = skill.environmentKeys.firstIndex(of: existing) {
                    let value = skill.normalizedEnvironmentValue(at: index)
                    if !value.isEmpty { writes[existing] = value }
                }
            case .unavailable: throw SkillCredentialEditor.Failure.secretReadFailed
            }
        }
        for (key, replacement) in replacements { writes[key] = replacement }
        let namespace = UUID()
        if let lease { try journal?.record([namespace, skill.secretNamespaceID], lease: lease) }
        let prepared = Self(namespaceID: namespace, journal: journal, lease: lease, persistence: persistence)
        for (name, value) in writes {
            guard persistence.saveSecretValue(value, key: name, skillID: namespace, skillName: skill.name,
                allowUserInteraction: !migratingLegacy && replacements[name] != nil) else {
                prepared.discard()
                throw SkillCredentialEditor.Failure.secretSaveFailed
            }
        }
        return prepared
    }

    func completed() {
        if let lease { journal?.forget([namespaceID], lease: lease) }
    }

    /// Only a proved noncommit grants deletion of this private generation.
    func discard() {
        guard persistence.deleteAllSecretsReportingResult(skillID: namespaceID) else { return }
        if let lease { journal?.forget([namespaceID], lease: lease) }
    }
}

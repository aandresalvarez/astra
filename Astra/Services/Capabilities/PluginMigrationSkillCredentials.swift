import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// Migration writes only to unpublished activation generations. The legacy
/// row and every queued request keep their original credential namespace.
@MainActor
final class PluginMigrationSkillCredentials {
    private let prepared: PluginUpdateSkillCredentials
    private let persistence: any SkillSecretPersisting.Type
    var released: Set<UUID> { prepared.released }
    var producerLease: PluginCredentialProducerLease? { prepared.producerLease }

    init(modelContext: ModelContext, persistence: any SkillSecretPersisting.Type) {
        self.persistence = persistence
        prepared = PluginUpdateSkillCredentials(modelContext: modelContext, persistence: persistence)
    }

    func copy(from skill: Skill, to activation: PluginActivation, in workspace: Workspace,
              package: PluginPackage, componentID: String) throws {
        guard skill.environmentKeys.contains(where: Skill.isSecretEnvironmentKey) else { return }
        do { try prepared.prepare(activation, in: workspace, package: package) }
        catch PluginUpdateService.UpdateError.secretReadFailed(_, let key) {
            throw PluginActivationMigration.MigrationError.secretReadFailed(skill: skill.name, key: key)
        } catch PluginUpdateService.UpdateError.secretCopyFailed(_, let key) {
            throw PluginActivationMigration.MigrationError.secretCopyFailed(skill: skill.name, key: key)
        } catch { throw PluginActivationMigration.MigrationError.cleanupUnrecordable }
        // Relocating an already-owned login-keychain entry is separate from
        // admitting plaintext. Never promote raw fields into the source slot.
        KeychainService.migrateSkillFromLoginKeychain(skillID: skill.secretNamespaceID)
        let destination = PluginRuntimeProjection.credentialID(of: activation, componentID: componentID)
        for (index, key) in skill.environmentKeys.enumerated() where Skill.isSecretEnvironmentKey(key) {
            let value: String
            switch persistence.readSecretValue(key: key, skillID: skill.secretNamespaceID, store: KeychainSecretStore()) {
            case .value(let stored): value = stored
            case .missing: value = index < skill.environmentValues.count ? skill.environmentValues[index] : ""
            case .unavailable:
                throw PluginActivationMigration.MigrationError.secretReadFailed(skill: skill.name, key: key)
            }
            guard !value.isEmpty else { continue }
            guard persistence.saveSecretValue(value, key: key, skillID: destination, skillName: skill.name,
                allowUserInteraction: false) else {
                throw PluginActivationMigration.MigrationError.secretCopyFailed(skill: skill.name, key: key)
            }
            WorkspaceCapabilityActivation.setSecretRecorded(true,
                forKey: PluginActivation.settingKey(componentID: componentID, key: key), on: activation)
        }
    }

    func completed(in workspaces: [Workspace]) {
        prepared.completed(activations: workspaces.flatMap { WorkspaceCapabilityActivation.activations(of: $0) })
    }
    func discard() { prepared.discard() }
}

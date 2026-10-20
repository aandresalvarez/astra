import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// Stages opaque values in an unreachable generation before the domain save.
/// A quit can leave only journaled orphans, never destroy the saved generation.
/// Old generations remain owed until requests and recovery mirrors release them.
@MainActor
struct PluginCredentialGenerationTransaction {
    let generation: String
    let producerLease: PluginCredentialProducerLease?
    let namespaces: Set<UUID>
    private let outbox: PluginSecretCleanupOutbox?
    private let persistence: any SkillSecretPersisting.Type

    static func prepare(
        activation: PluginActivation, workspaceID: UUID, componentID: String, key: String,
        replacement: String?, skillName: String, modelContext: ModelContext,
        persistence: any SkillSecretPersisting.Type
    ) throws -> Self {
        try stage(activation: activation, workspaceID: workspaceID, modelContext: modelContext,
            replacing: (componentID, key, replacement), additionalComponents: [], producerLease: nil, skillName: skillName, persistence: persistence)
    }

    /// Add and reconciliation may touch several keys or rename components.
    /// Isolate their writes before changing the activation's saved contract.
    static func prepareCopy(
        activation: PluginActivation, workspaceID: UUID, modelContext: ModelContext,
        skillName: String, persistence: any SkillSecretPersisting.Type,
        additionalComponents: Set<String> = [], producerLease: PluginCredentialProducerLease? = nil
    ) throws -> Self {
        try stage(activation: activation, workspaceID: workspaceID, modelContext: modelContext,
            replacing: nil, additionalComponents: additionalComponents, producerLease: producerLease, skillName: skillName, persistence: persistence)
    }

    private static func stage(
        activation: PluginActivation, workspaceID: UUID, modelContext: ModelContext,
        replacing: (component: String, key: String, value: String?)?, additionalComponents: Set<String>,
        producerLease: PluginCredentialProducerLease?, skillName: String,
        persistence: any SkillSecretPersisting.Type
    ) throws -> Self {
        guard activation.modelContext === modelContext, activation.workspace?.id == workspaceID,
              !activation.isDeleted else { throw PluginOperations.OperationError.workspaceChanged }
        let heldLease = try PluginCredentialProducerLease.acquire(modelContext: modelContext, reusing: producerLease)
        let generation = UUID().uuidString
        let changed = replacing.map { PluginActivation.settingKey(componentID: $0.component, key: $0.key) }
        struct Write { let key: String; let component: String; let value: String; let explicit: Bool }
        var writes: [Write] = []
        for setting in Set(activation.secretSettingKeys).sorted() where setting != changed {
            guard let component = PluginActivation.componentID(ofSettingKey: setting) else {
                throw PluginOperations.OperationError.storeUnreadable
            }
            let name = String(setting.dropFirst(component.count + 1))
            let source = PluginRuntimeProjection.credentialID(of: activation, componentID: component)
            switch persistence.readSecretValue(key: name, skillID: source, store: KeychainSecretStore()) {
            case .value(let value): writes.append(Write(key: name, component: component, value: value, explicit: false))
            case .missing: break // Preserve an already-unconfigured field, not a read failure.
            case .unavailable: throw PluginOperations.OperationError.secretReadFailed(key: name)
            }
        }
        if let replacing, let value = replacing.value {
            writes.append(Write(key: replacing.key, component: replacing.component, value: value, explicit: true))
        }
        func destination(_ component: String) -> UUID {
            PluginActivation.credentialID(workspaceID: workspaceID, pluginID: activation.pluginID, componentID: component,
                runtimeSeed: activation.namespaceSeed, generation: generation)
        }
        var released = Set(PluginRuntimeProjection.secretNamespaces(of: activation, package: nil))
        if let replacing {
            released.insert(PluginRuntimeProjection.credentialID(of: activation, componentID: replacing.component))
        }
        let namespaces = Set(writes.map { destination($0.component) }).union(additionalComponents.map(destination))
        let outbox = PluginSecretCleanupOutbox(for: modelContext)
        if let outbox {
            let previous = try outbox.entries()
            try outbox.writeEntries(Array(Set(previous + released.union(namespaces).map(\.uuidString))))
        }
        let prepared = Self(generation: generation, producerLease: heldLease, namespaces: namespaces, outbox: outbox, persistence: persistence)
        for write in writes {
            guard persistence.saveSecretValue(write.value, key: write.key, skillID: destination(write.component),
                skillName: skillName, allowUserInteraction: write.explicit) else {
                prepared.discard()
                throw PluginOperations.OperationError.secretSaveFailed(key: write.key)
            }
        }
        return prepared
    }

    /// The committed activation owns the new namespaces. Old cleanup stays
    /// durable for the existing recovery pass; no all-workspace scan on edit.
    func completed() { outbox?.forgetNamespaces(namespaces) }

    /// Called only after a proved noncommit, or before domain mutation. These
    /// fresh namespaces were never published; failed deletes keep their intent.
    func discard() {
        let cleared = namespaces.filter { persistence.deleteAllSecretsReportingResult(skillID: $0) }
        outbox?.forgetNamespaces(Set(cleared))
    }
}

import Foundation
import ASTRACore
import ASTRAModels

extension WorkspaceConfigManager {
    /// Read durable key names before the portable configuration removes secret
    /// values and malformed fields. This projection never carries values.
    static func credentialEvidenceForExport(_ activation: PluginActivation, in workspace: Workspace) -> PluginCredentialRecoveryEvidence? {
        let durable = WorkspaceCapabilityActivation.credentialRecoveryEvidence(for: activation.pluginID,
            namespaceSeed: activation.namespaceSeed, credentialNamespaceSeed: activation.credentialNamespaceSeed, in: workspace)
        let keys = activation.configKeys + activation.secretSettingKeys
        let positive = activation.configKeys.filter { field in
            guard let component = PluginActivation.componentID(ofSettingKey: field) else { return false }
            return Skill.isSecretEnvironmentKey(String(field.dropFirst(component.count + 1)))
        }
        let raw = PluginCredentialRecoveryEvidence(
            unresolvedSettingKeys: keys.filter { PluginActivation.componentID(ofSettingKey: $0) == nil },
            retainedSecretSettingKeys: positive,
            namespaceSeed: activation.namespaceSeed, credentialNamespaceSeed: activation.credentialNamespaceSeed)
        var merged = raw.merging(durable)
        // Admission is local database bookkeeping, never portable proof that
        // another recovered store has inspected its current own mirror.
        merged.admittedActivationID = nil
        return merged.isEmpty ? nil : merged
    }

    /// Capture only source references that the restored domain graph cannot
    /// represent, together with the source's incomplete/ambiguous verdict.
    static func credentialEvidence(from ref: InstalledPluginRef, activation: PluginActivation,
        representedComponents: Set<String>, representedKeys: Set<String>, connectorIDs: Set<String>,
        admittingPriorMirror: Bool = false
    ) -> PluginCredentialRecoveryEvidence {
        let refs = ref.credentialReferences()
        var inline = ref.credentialRecoveryEvidence.flatMap {
            $0.appliesTo(namespaceSeed: ref.namespaceSeed ?? "", credentialNamespaceSeed: ref.credentialNamespaceSeed ?? "") ? $0 : nil
        }
        inline?.admittedActivationID = nil
        return PluginCredentialRecoveryEvidence(
            secretSettingKeysUnknown: ref.secretSettingKeys == nil || refs?.unknownSecretComponentIDs.isEmpty == false,
            unresolvedSettingKeys: (Array((ref.settings ?? [:]).keys) + (ref.secretSettingKeys ?? []))
                .filter { PluginActivation.componentID(ofSettingKey: $0) == nil }.sorted(),
            unresolvedAccounts: (ref.accounts ?? []).filter { !connectorIDs.contains($0.connectorID) }
                .map { .init(componentID: $0.componentID, connectorID: $0.connectorID) },
            inventoryAmbiguous: refs == nil ? true : nil,
            retainedComponentIDs: refs?.componentIDs.filter { !representedComponents.contains($0) },
            retainedSecretSettingKeys: refs?.secretSettingKeys.filter { !representedKeys.contains($0) },
            namespaceSeed: activation.namespaceSeed, credentialNamespaceSeed: activation.credentialNamespaceSeed,
            admittedActivationID: admittingPriorMirror ? activation.id.uuidString : nil).merging(inline)
    }
}

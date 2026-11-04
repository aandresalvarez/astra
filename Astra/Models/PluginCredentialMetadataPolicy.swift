import Foundation
import ASTRACore

/// The same value-free proof rules govern cleanup reads and own-mirror
/// recovery. Nil means ambiguous; an empty result independently proves no
/// credential namespaces. Recovery must preserve a positive result or nil,
/// rather than recomputing a weaker answer from the restored runtime graph.
public enum PluginCredentialMetadataPolicy {
    public struct References: Sendable {
        public let componentIDs: [String]
        public let secretSettingKeys: [String]
        public let unknownSecretComponentIDs: Set<String>
    }

    public static func references(
        pluginID: String, version: String?, digest: String?,
        knownComponentIDs: [String]?, credentialComponentIDs: [String]?,
        secretSettingKeys: [String]?, settingKeys: [String],
        overriddenComponentIDs: [String]?, accountComponentIDs: [String],
        recoveryEvidence: PluginCredentialRecoveryEvidence?
    ) -> References? {
        guard recoveryEvidence?.isAmbiguous != true else { return nil }
        let recorded = secretSettingKeys ?? []
        let retained = recoveryEvidence?.retainedSecretSettingKeys ?? []
        let settings = recorded + retained + settingKeys
        guard settings.allSatisfy({ PluginActivation.componentID(ofSettingKey: $0) != nil }) else { return nil }
        let known = Set(knownComponentIDs ?? [])
        var components = Set(Array(known) + (overriddenComponentIDs ?? []) + accountComponentIDs
            + (recoveryEvidence?.retainedComponentIDs ?? [])
            + settings.compactMap(PluginActivation.componentID(ofSettingKey:)))
        let matched: [String]?
        if known.isEmpty || credentialComponentIDs == [], let version, let digest {
            matched = PluginCredentialComponentInventorySeam.componentIDs(pluginID: pluginID, version: version, digest: digest)
        } else { matched = nil }
        // A supplied [] is a claim, not independent proof. Missing markers
        // and contradictory observed or retained references cannot clear it.
        if credentialComponentIDs == [] {
            guard matched == [], secretSettingKeys == [], components.isEmpty, settingKeys.isEmpty else { return nil }
        }
        components.formUnion(credentialComponentIDs ?? [])
        components.formUnion(matched ?? [])
        guard !components.isEmpty || (matched == [] && recorded.isEmpty && settingKeys.isEmpty) else { return nil }
        let unknown = components.filter {
            recoveryEvidence?.secretSettingKeysUnknown == true || secretSettingKeys == nil
                || (!known.contains($0) && recorded.isEmpty)
        }
        let positiveKeys = settings.filter { setting in
            guard let component = PluginActivation.componentID(ofSettingKey: setting) else { return false }
            let key = String(setting.dropFirst(component.count + 1))
            return recorded.contains(setting) || retained.contains(setting) || Skill.isSecretEnvironmentKey(key)
        }
        return References(componentIDs: components.sorted(), secretSettingKeys: Set(positiveKeys).sorted(),
            unknownSecretComponentIDs: Set(unknown))
    }
}

import Foundation
import ASTRACore

/// A read-only projection for launch records and portable recovery. Legacy
/// plaintext stays with its durable source row until an explicit migration.
public enum PluginLaunchConfiguration {
    public static func activation(_ activation: PluginActivation) -> (keys: [String], values: [String]) {
        self.activation(keys: activation.configKeys, values: activation.configValues, secretSettingKeys: activation.secretSettingKeys)
    }

    public static func activation(keys: [String], values: [String], secretSettingKeys: [String]) -> (keys: [String], values: [String]) {
        let recordedSecrets = Set(secretSettingKeys)
        let kept = keys.indices.filter { index in
            let setting = keys[index]
            guard let component = PluginActivation.componentID(ofSettingKey: setting) else { return false }
            let key = String(setting.dropFirst(component.count + 1))
            return !recordedSecrets.contains(setting) && !Skill.isSecretEnvironmentKey(key)
        }
        return (kept.map { keys[$0] }, kept.map { $0 < values.count ? values[$0] : "" })
    }

    public static func account(_ account: Connector) -> (keys: [String], values: [String]) {
        self.account(keys: account.configKeys, values: account.configValues, credentialKeys: account.credentialKeys,
            originPackageID: account.originPackageID, originComponentID: account.originComponentID)
    }

    public static func account(keys: [String], values: [String], credentialKeys: [String],
                               originPackageID: String?, originComponentID: String?) -> (keys: [String], values: [String]) {
        // An unregistered policy cannot prove that a plugin setting is plain.
        if originPackageID?.isEmpty == false && ConnectorSettingStorageSeam.resolver == nil { return ([], []) }
        let exportable = ConnectorSettingStorageSeam.exportableConfig(keys: keys, values: values,
            originPackageID: originPackageID, originComponentID: originComponentID)
        let credentials = Set(credentialKeys.map(ConnectorCredentialKey.canonical))
        let kept = exportable.keys.indices.filter {
            !credentials.contains(ConnectorCredentialKey.canonical(exportable.keys[$0]))
                && !Skill.isSecretEnvironmentKey(exportable.keys[$0])
        }
        return (kept.map { exportable.keys[$0] }, kept.map { $0 < exportable.values.count ? exportable.values[$0] : "" })
    }
}

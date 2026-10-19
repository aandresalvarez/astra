import Foundation
import ASTRACore

/// Which of a plugin connector's fields ASTRA keeps as plain settings.
///
/// A setting (`configHints`) is plain text on the account row and in the
/// workspace mirror, and its key and label are the plugin's choice: a plugin
/// can call a field `site` or `tenant` and ask for a token there. No name
/// proves a field harmless, so only a setting ASTRA's own bundled definition
/// declares, for the same plugin ID and connector component, and that the
/// Keychain doesn't treat as a credential (`RunSecretRedaction.isSecretKey`),
/// stays plain. Every other field of every other plugin (an imported file, a
/// plugin source, one made in ASTRA) is stored exactly as if it had been
/// declared a credential: in the Keychain, edited masked, never exported.
///
/// The one owner of that decision. Account creation, Update's account sync,
/// setup copy, the install sheet and the runtime projection read a connector
/// through `asStored(_:in:)`; the mirror export asks through
/// `ConnectorSettingStorageSeam`.
enum PluginConnectorFieldTrust {
    private static let bundledPluginIDs = Set(PluginCatalog.builtInPackages.map(\.id))

    /// Per bundled plugin ID, per connector component: the setting keys its
    /// definition declares that aren't named like a credential.
    private static let bundledPlainSettingKeys: [String: [String: Set<String>]] = {
        var keys: [String: [String: Set<String>]] = [:]
        for package in PluginCatalog.builtInPackages {
            for connector in package.connectors {
                let plain = connector.configHints.map(\.key).filter { !RunSecretRedaction.isSecretKey($0) }
                keys[package.id, default: [:]][CapabilityResourceOrigin.componentID(for: connector), default: []]
                    .formUnion(plain)
            }
        }
        return keys
    }()

    /// Whether `pluginID` is one of ASTRA's bundled plugins.
    static func isBundled(_ pluginID: String) -> Bool {
        bundledPluginIDs.contains(pluginID)
    }

    /// The settings of `connector` that stay plain in `package`.
    static func trustedPlainSettingKeys(of connector: PluginConnector, in package: PluginPackage) -> Set<String> {
        let trusted = bundledPlainSettingKeys[package.id]?[CapabilityResourceOrigin.componentID(for: connector)] ?? []
        return Set(connector.configHints.map(\.key).filter { trusted.contains($0) })
    }

    /// The settings of `connector` that `package` stores as credentials.
    static func settingsStoredAsCredentials(of connector: PluginConnector, in package: PluginPackage) -> Set<String> {
        Set(connector.configHints.map(\.key)).subtracting(trustedPlainSettingKeys(of: connector, in: package))
    }

    /// `connector` as its fields are stored: each setting it may not keep
    /// plain becomes a credential field (same key and hint), after its
    /// declared credentials. Never persisted or digested: the plugin's
    /// definition stays as its author wrote it.
    static func asStored(_ connector: PluginConnector, in package: PluginPackage) -> PluginConnector {
        let trusted = trustedPlainSettingKeys(of: connector, in: package)
        var seen = Set(connector.credentialHints.map(\.key))
        var stored = connector
        stored.configHints = connector.configHints.filter { trusted.contains($0.key) }
        stored.credentialHints += connector.configHints
            .filter { !trusted.contains($0.key) && seen.insert($0.key).inserted }
            .map { PluginConnector.CredentialHint(key: $0.key, hint: $0.hint) }
        return stored
    }
}

extension PluginConnectorFieldTrust: ConnectorSettingStorageResolving {
    /// The settings an account's creator stores as credentials, from its
    /// installed definition: the stamped component, else the one that
    /// `replaces` it. When the creator or component can't be found (its
    /// library entry is unreadable, a Remove kept the stamp), every one of
    /// `accountKeys` except those ASTRA's bundled definition of that plugin
    /// ID declares plain: an older row may still hold a credential's value.
    static func settingKeysStoredAsCredentials(
        originPackageID: String, originComponentID: String?, accountKeys: [String]
    ) -> Set<String> {
        if let declared = declaredSettingKeysStoredAsCredentials(originPackageID: originPackageID, originComponentID: originComponentID) {
            return declared
        }
        let bundled = bundledPlainSettingKeys[originPackageID] ?? [:]
        let plain = originComponentID.flatMap { bundled[$0] } ?? bundled.values.reduce(into: Set()) { $0.formUnion($1) }
        return Set(accountKeys).subtracting(plain)
    }

    static func declaredSettingKeysStoredAsCredentials(originPackageID: String, originComponentID: String?) -> Set<String>? {
        guard let package = CapabilityRuntimeResourceMatcher.packageDefinitions().first(where: { $0.id == originPackageID }),
              let stamp = originComponentID,
              let spec = package.connectors.first(where: { CapabilityResourceOrigin.componentID(for: $0) == stamp })
                ?? package.connectors.first(where: { CapabilityResourceOrigin.replacedComponentIDs(for: $0).contains(stamp) })
        else { return nil }
        return settingsStoredAsCredentials(of: spec, in: package)
    }
}

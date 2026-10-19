import Foundation
import ASTRACore
import ASTRAModels

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
/// setup copy, the install sheet, the runtime projection and every transport
/// review read a connector through `asStored(_:in:)`; the mirror export asks through
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

    /// Per bundled plugin ID, per connector component: what an account of it
    /// may carry plain in the mirror. Its plain settings, and the bundled
    /// skills' settings an account carries for them (Add stores those on
    /// the account too) that aren't named like a credential.
    private static let bundledPlainAccountKeys: [String: [String: Set<String>]] = {
        var keys = bundledPlainSettingKeys
        for package in PluginCatalog.builtInPackages {
            let skillSettings = package.skills.flatMap(\.environmentKeys)
                .filter { !RunSecretRedaction.isSecretKey($0) && !Skill.isSecretEnvironmentKey($0) }
            for connector in package.connectors {
                keys[package.id, default: [:]][CapabilityResourceOrigin.componentID(for: connector), default: []]
                    .formUnion(skillSettings)
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
        // One stored credential per canonical key (`ConnectorCredentialKey`).
        var seen = Set(connector.credentialHints.map { ConnectorCredentialKey.canonical($0.key) })
        var stored = connector
        stored.configHints = connector.configHints.filter { trusted.contains($0.key) }
        stored.credentialHints += connector.configHints
            .filter { !trusted.contains($0.key) && seen.insert(ConnectorCredentialKey.canonical($0.key)).inserted }
            .map { PluginConnector.CredentialHint(key: $0.key, hint: $0.hint) }
        return stored
    }

    /// Why `connector` can't carry credentials over its transport, judged
    /// on its fields as stored: a setting stored as a credential needs a
    /// protected transport as much as a declared one, so a definition the
    /// runtime would reject is refused at review (validation, catalog
    /// policy, install preflight) instead. `baseURL` is an override the
    /// person entered, when there is one.
    static func credentialTransportViolation(
        of connector: PluginConnector, in package: PluginPackage, baseURL: String? = nil
    ) -> String? {
        ConnectorSecurityPolicy.credentialTransportViolation(
            baseURL: baseURL ?? connector.baseURL,
            authMethod: connector.authMethod,
            credentialKeys: asStored(connector, in: package).credentialHints.map(\.key)
        )
    }
}

extension PluginConnectorFieldTrust: ConnectorSettingStorageResolving {
    /// The settings of an account the mirror withholds: every one of
    /// `accountKeys` except those ASTRA's bundled definition of its creator
    /// declares plain for its component (`bundledPlainAccountKeys`) (the stamped one, or the one that
    /// `replaces` it in the creator's installed definition). Fails closed:
    /// a key the definition no longer declares, a third-party plugin's
    /// whole account, and an account whose creator or component can't be
    /// found (its library entry is unreadable, a Remove kept the stamp) keep
    /// nothing in the mirror that ASTRA can't prove plain.
    static func settingKeysStoredAsCredentials(
        originPackageID: String, originComponentID: String?, accountKeys: [String]
    ) -> Set<String> {
        settingKeysStoredAsCredentials(
            originPackageID: originPackageID, originComponentID: originComponentID, accountKeys: accountKeys,
            definitions: CapabilityRuntimeResourceMatcher.packageDefinitions()
        )
    }

    static func settingKeysStoredAsCredentials(
        originPackageID: String, originComponentID: String?, accountKeys: [String], definitions: [PluginPackage]
    ) -> Set<String> {
        let bundled = bundledPlainAccountKeys[originPackageID] ?? [:]
        let componentID = originComponentID.map { stamp in
            definitions.first { $0.id == originPackageID }
                .flatMap { Self.component(stampedWith: stamp, in: $0) }
                .map(CapabilityResourceOrigin.componentID(for:)) ?? stamp
        }
        let plain = componentID.flatMap { bundled[$0] } ?? bundled.values.reduce(into: Set()) { $0.formUnion($1) }
        return Set(accountKeys).subtracting(plain)
    }

    /// The connector of `package` an account stamped `stamp` belongs to:
    /// that component, else the one that `replaces` it.
    private static func component(stampedWith stamp: String, in package: PluginPackage) -> PluginConnector? {
        package.connectors.first { CapabilityResourceOrigin.componentID(for: $0) == stamp }
            ?? package.connectors.first { CapabilityResourceOrigin.replacedComponentIDs(for: $0).contains(stamp) }
    }

    static func declaredSettingKeysStoredAsCredentials(originPackageID: String, originComponentID: String?) -> Set<String>? {
        guard let package = CapabilityRuntimeResourceMatcher.packageDefinitions().first(where: { $0.id == originPackageID }),
              let stamp = originComponentID,
              let spec = component(stampedWith: stamp, in: package)
        else { return nil }
        return settingsStoredAsCredentials(of: spec, in: package)
    }
}

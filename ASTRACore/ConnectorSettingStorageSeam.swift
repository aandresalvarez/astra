import Foundation
import os

// Only ASTRA's bundled plugins keep plain connector settings: every setting
// of any other plugin is stored as a credential (`PluginConnectorFieldTrust`
// in the app target owns that decision). An account created before that rule
// can still hold such a setting's value as plain text on its row, and the
// workspace mirror (`WorkspaceConfigManager`, in ASTRAPersistence) must not
// write it out. The mirror can't see plugin definitions; this seam is how it
// asks which of an account's settings its creator stores as credentials.
//
// Optional, like `ConnectorDeclaredCredentialFormatSeam`: without a resolver
// (a tool that never registers one) the export is what it was before.

public protocol ConnectorSettingStorageResolving: Sendable {
    /// The setting keys the plugin that created an account stores as
    /// credentials. When its definition can't be found, the account's own
    /// `accountKeys` that the resolver can't prove plain: the export fails
    /// closed rather than writing a creator's credential out as text.
    static func settingKeysStoredAsCredentials(
        originPackageID: String, originComponentID: String?, accountKeys: [String]
    ) -> Set<String>
}

public enum ConnectorSettingStorageSeam {
    private static let storage =
        OSAllocatedUnfairLock<(any ConnectorSettingStorageResolving.Type)?>(initialState: nil)

    /// Set once by `RuntimeSeamRegistration.registerAll()`.
    public static func register(_ resolver: any ConnectorSettingStorageResolving.Type) {
        storage.withLock { $0 = resolver }
    }

    public static var resolver: (any ConnectorSettingStorageResolving.Type)? {
        storage.withLock { $0 }
    }

    /// An account's settings as the mirror may write them: without the ones
    /// its creator stores as credentials. An account no plugin created keeps
    /// every setting the person entered; one whose creator can't be read
    /// keeps only what the resolver can prove plain.
    public static func exportableConfig(
        keys: [String],
        values: [String],
        originPackageID: String?,
        originComponentID: String?,
        resolver: (any ConnectorSettingStorageResolving.Type)? = Self.resolver
    ) -> (keys: [String], values: [String]) {
        guard !keys.isEmpty, let originPackageID, !originPackageID.isEmpty,
              let withheld = resolver?.settingKeysStoredAsCredentials(
                originPackageID: originPackageID,
                originComponentID: originComponentID,
                accountKeys: keys
              ), !withheld.isEmpty else { return (keys, values) }
        let kept = keys.indices.filter { !withheld.contains(keys[$0]) }
        return (kept.map { keys[$0] }, kept.map { $0 < values.count ? values[$0] : "" })
    }
}

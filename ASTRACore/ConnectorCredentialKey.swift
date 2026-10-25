import Foundation

/// The one spelling a connector credential key is stored and compared in.
/// `Connector.saveCredentialChecked` writes the Keychain item and the row's
/// `credentialKeys` entry under it, so a declaration's key (`token`, `Token`)
/// and the stored one (`TOKEN`) are the same key only through this:
/// readiness, the runtime allowlist, account reconciliation and field trust
/// all compare canonical keys.
public enum ConnectorCredentialKey {
    public static func canonical(_ key: String) -> String {
        key.uppercased()
    }

    /// Whether two spellings name one stored credential.
    public static func same(_ lhs: String, _ rhs: String) -> Bool {
        canonical(lhs) == canonical(rhs)
    }
}

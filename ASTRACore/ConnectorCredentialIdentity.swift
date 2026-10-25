import Foundation

/// A frozen-V20-compatible credential identity for resources created from a
/// selected file. The identity itself records that endpoint aliases are not
/// authorized; recovery cannot lose a separate in-memory import flag.
/// V21's explicit credential namespace takes precedence when present.
public enum ConnectorCredentialIdentity {
    /// Application-specific UUIDv8: A5 tag, RFC variant, and 114 random bits
    /// retained from Foundation's UUID generator. No existing IDs are changed.
    /// Format: https://www.rfc-editor.org/rfc/rfc9562.html#section-5.8
    public static func isolatedImportID() -> UUID {
        var bytes = UUID().uuid
        bytes.0 = 0xA5
        bytes.6 = (bytes.6 & 0x0F) | 0x80
        bytes.8 = (bytes.8 & 0x3F) | 0x80
        return UUID(uuid: bytes)
    }

    public static func usesIsolatedNamespace(_ id: UUID) -> Bool {
        let bytes = id.uuid
        return bytes.0 == 0xA5 && (bytes.6 & 0xF0) == 0x80 && (bytes.8 & 0xC0) == 0x80
    }
}

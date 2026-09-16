import Foundation
import os

// A capability package can declare the shape its credential must have
// (`PluginConnector.CredentialHint.format`), and `CapabilityInstaller` passes
// that declaration to `saveCredentialChecked` as `declaredFormat`. That covered
// exactly one write: the install. Every later write — replacing a rotated token
// in Configure › Connectors, a repair, a copied setup — called the same method
// with `declaredFormat: nil`, because nothing on the `Connector` row remembered
// what its package had said. A third-party format is not in
// `ConnectorCredentialFormatRegistry` by definition, so those writes fell
// through to no format at all and stored a value the package had explicitly
// declared invalid.
//
// The declaration is not copied onto the row. It belongs to the package, and a
// package can be updated: a stored copy would go stale the moment the author
// tightened the pattern, and it would need a schema migration to add. What the
// row already durably carries is *which* package and component it came from
// (`originPackageID` / `originComponentID`), which is enough to look the
// current declaration back up. This seam is that lookup.
//
// Unlike the other seams here, the accessor is **optional, not fail-fast**.
// Credential writes happen on paths that run long before `registerAll()` in
// some tests and tools, and the correct behaviour without a resolver is the
// behaviour that existed before this seam: fall back to the built-in registry.
// Trapping would convert a missing convenience into a crash on the save path.
public protocol ConnectorDeclaredCredentialFormatResolving: Sendable {
    /// The format the owning package declares for this credential, or `nil`
    /// when the package, component, or hint cannot be found — including when
    /// the connector was created by hand and has no origin at all.
    static func declaredFormat(
        originPackageID: String,
        originComponentID: String?,
        key: String
    ) -> ConnectorCredentialFormat?
}

public enum ConnectorDeclaredCredentialFormatSeam {
    private static let storage =
        OSAllocatedUnfairLock<(any ConnectorDeclaredCredentialFormatResolving.Type)?>(initialState: nil)

    /// Set once by `RuntimeSeamRegistration.registerAll()`. Safe to call
    /// concurrently — see `AgentRuntimeRegistrySeam.register(_:)`.
    public static func register(_ resolver: any ConnectorDeclaredCredentialFormatResolving.Type) {
        storage.withLock { $0 = resolver }
    }

    /// Deliberately returns `nil` rather than trapping when unregistered; see
    /// the note above.
    public static var resolver: (any ConnectorDeclaredCredentialFormatResolving.Type)? {
        storage.withLock { $0 }
    }

    /// Convenience for the one caller shape that exists: a connector asking
    /// what its own package declared.
    public static func declaredFormat(
        originPackageID: String?,
        originComponentID: String?,
        key: String
    ) -> ConnectorCredentialFormat? {
        guard let originPackageID, !originPackageID.isEmpty, let resolver else { return nil }
        return resolver.declaredFormat(
            originPackageID: originPackageID,
            originComponentID: originComponentID,
            key: key
        )
    }
}

import Foundation
import ASTRACore
import ASTRAModels

/// Looks a connector's declared credential format back up from the capability
/// package that installed it.
///
/// `CapabilityInstaller` is the only caller that passes `declaredFormat`
/// explicitly, so before this every later write — a rotated token replaced in
/// Configure › Connectors, a repair, a copied setup — evaluated the value
/// against no declared format at all. For a third-party service, which by
/// definition has no entry in `ConnectorCredentialFormatRegistry`, that meant
/// no format check whatsoever: the package could say "32 hex characters" and
/// ASTRA would still store and send whatever was pasted.
///
/// Resolves live rather than caching a copy on the row. The package owns the
/// declaration and can tighten it in an update; a copy stamped at install time
/// would answer with the old rule forever, and adding one would mean a
/// SwiftData migration to carry a value the package already holds.
enum ConnectorDeclaredCredentialFormatResolver: ConnectorDeclaredCredentialFormatResolving {
    static func declaredFormat(
        originPackageID: String,
        originComponentID: String?,
        key: String
    ) -> ConnectorCredentialFormat? {
        // `packageDefinitions` merges installed definitions with the built-ins
        // and memoises on the capability directory's fingerprint, so this costs
        // one `stat` sweep on a path that already does a full connector fetch
        // and a Keychain sweep for the reuse scan.
        guard let package = CapabilityRuntimeResourceMatcher
            .packageDefinitions()
            .first(where: { $0.id == originPackageID })
        else { return nil }

        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let candidates = matchingConnectors(in: package, componentID: originComponentID)
        for connector in candidates {
            for hint in connector.credentialHints
            where hint.key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == normalizedKey {
                if let format = hint.format { return format }
            }
        }
        return nil
    }

    /// Prefers the exact component the row was stamped with, and falls back to
    /// every connector in the package.
    ///
    /// The fallback matters because `originComponentID` encodes the connector's
    /// *name* and service type, so renaming a connector in a package update
    /// orphans the stamp. Losing the format on a rename would silently reopen
    /// the hole this closes, and the fallback cannot make the check wrong — it
    /// can only find a declaration the same package made for the same key.
    private static func matchingConnectors(
        in package: PluginPackage,
        componentID: String?
    ) -> [PluginConnector] {
        guard let componentID, !componentID.isEmpty else { return package.connectors }
        let exact = package.connectors.filter {
            CapabilityResourceOrigin.componentID(for: $0) == componentID
        }
        return exact.isEmpty ? package.connectors : exact
    }
}

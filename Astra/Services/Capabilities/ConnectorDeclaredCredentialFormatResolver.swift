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

        return declaredFormat(in: package, componentID: originComponentID, key: key)
    }

    /// The resolution itself, with the catalog lookup left out.
    ///
    /// Split from the entry point above so the matching rules can be exercised
    /// against a package a test builds — the shapes that matter here (two
    /// connectors of different services declaring one key) are shapes no shipped
    /// package has, which is exactly why the old rule looked safe.
    static func declaredFormat(
        in package: PluginPackage,
        componentID: String?,
        key: String
    ) -> ConnectorCredentialFormat? {
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let match = matchingConnectors(in: package, componentID: componentID)
        if let format = declaredFormat(in: match.exact, key: normalizedKey) {
            return format
        }
        // Only reached when the stamp names no connector the package still has.
        // A single answer from the fallback set is the rename it is there for;
        // two different answers are two connectors, and neither of them is
        // provably this row's.
        return unambiguousDeclaredFormat(in: match.fallback, key: normalizedKey)
    }

    private static func declaredFormat(
        in connectors: [PluginConnector],
        key normalizedKey: String
    ) -> ConnectorCredentialFormat? {
        for connector in connectors {
            for hint in connector.credentialHints
            where hint.key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == normalizedKey {
                if let format = hint.format { return format }
            }
        }
        return nil
    }

    /// The format the fallback set agrees on, or nothing.
    ///
    /// Taking the first match would let an unrelated sibling's declaration
    /// decide whether a rotated credential is accepted — rejecting a valid
    /// replacement, or admitting one that this connector's own package says is
    /// malformed. A disagreement means the stamp was the only thing that knew
    /// which declaration applied, and it is gone; answering `nil` puts the row
    /// back where an unstamped row already is rather than answering wrongly.
    private static func unambiguousDeclaredFormat(
        in connectors: [PluginConnector],
        key normalizedKey: String
    ) -> ConnectorCredentialFormat? {
        var declared: ConnectorCredentialFormat?
        for connector in connectors {
            for hint in connector.credentialHints
            where hint.key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == normalizedKey {
                guard let format = hint.format else { continue }
                if let declared, declared != format { return nil }
                declared = format
            }
        }
        return declared
    }

    /// Splits the package's connectors into the exact component the row was
    /// stamped with and the set to consult if that component is gone.
    ///
    /// The fallback matters because `originComponentID` encodes the connector's
    /// *name* as well as its service type, so renaming a connector in a package
    /// update orphans the stamp, and losing the format on a rename would
    /// silently reopen the hole this closes.
    ///
    /// It used to be every connector in the package, on the reasoning that the
    /// fallback "cannot make the check wrong". It can: two connectors in one
    /// package declaring the same key with different formats make the answer
    /// whichever one is listed first. The stamp still carries the service type
    /// even when the name no longer resolves, so the fallback is narrowed to the
    /// connectors that share it — a rename within a service still finds its
    /// declaration, and a Jira connector can no longer be validated against a
    /// REDCap one.
    private static func matchingConnectors(
        in package: PluginPackage,
        componentID: String?
    ) -> (exact: [PluginConnector], fallback: [PluginConnector]) {
        guard let componentID, !componentID.isEmpty else { return ([], package.connectors) }
        let exact = package.connectors.filter {
            CapabilityResourceOrigin.componentID(for: $0) == componentID
        }
        guard exact.isEmpty else { return (exact, []) }
        guard let serviceType = stampedServiceType(componentID) else {
            return ([], package.connectors)
        }
        let sameService = package.connectors.filter {
            CapabilityResourceOrigin.componentID(for: $0).hasPrefix("connector:\(serviceType):")
        }
        return ([], sameService.isEmpty ? package.connectors : sameService)
    }

    /// The service type out of a `connector:<service>:<name>` stamp.
    ///
    /// Parsed rather than stored: the stamp is the durable record, and adding a
    /// second column for a value already inside it would need a SwiftData
    /// migration to carry a substring.
    private static func stampedServiceType(_ componentID: String) -> String? {
        let parts = componentID.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0] == "connector", !parts[1].isEmpty else { return nil }
        return String(parts[1])
    }
}

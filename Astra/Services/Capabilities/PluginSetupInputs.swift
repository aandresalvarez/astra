import Foundation
import ASTRACore

/// How Add's setup inputs name one connector component.
///
/// Add takes three flat dictionaries: credential and setting values by field
/// key, and base URLs. Two connectors of one plugin can share a display name
/// and field keys while their stable component IDs differ, so a value meant
/// for one of them is stored under `key(_:component:)`, and its base URL
/// under its component ID. A bare field key, or a base URL under a connector
/// name, is shared by every connector that declares it, which is what
/// onboarding's form passes. Setup copy (`CapabilitySetupCopier`) keys
/// every value by the component it was copied from. The installer reads a
/// component's inputs only through `view(_:component:)` and
/// `baseURL(in:for:)`.
enum PluginSetupInputs {
    /// Not a character a field key or component ID contains.
    private static let separator = "\u{1F}"

    /// The input key of `field` for one connector component.
    static func key(_ field: String, component componentID: String) -> String {
        componentID + separator + field
    }

    /// `inputs` as one component reads them: the shared values, with its own
    /// over them. Another component's own values are left out.
    static func view(_ inputs: [String: String], component componentID: String, includingShared: Bool = true) -> [String: String] {
        let prefix = componentID + separator
        var view = includingShared ? inputs.filter { !$0.key.contains(separator) } : [:]
        for (key, value) in inputs where key.hasPrefix(prefix) {
            view[String(key.dropFirst(prefix.count))] = value
        }
        return view
    }

    /// The base URL `overrides` give `connector`: its component's own, else
    /// one given by its name.
    static func baseURL(in overrides: [String: String], for connector: PluginConnector) -> String? {
        overrides[connector.setupComponentID] ?? overrides[connector.name]
    }

    /// Copied setup (keyed by component) as the shared keys onboarding's
    /// form holds: a field by its key, a base URL by its connector's name.
    /// A value two components hold differently is left out, so a shared key
    /// never hands one component's value to another that had its own.
    static func flattened(
        _ copied: OnboardingCapabilityInstallationInputs,
        for connectors: [PluginConnector]
    ) -> OnboardingCapabilityInstallationInputs {
        func agreed(_ values: [(key: String, value: String)]) -> [String: String] {
            var flat: [String: String] = [:]
            var conflicting = Set<String>()
            for (key, value) in values {
                if let held = flat[key], held != value { conflicting.insert(key) } else { flat[key] = value }
            }
            return flat.filter { !conflicting.contains($0.key) }
        }
        func fields(_ values: [String: String]) -> [String: String] {
            agreed(values.map { key, value in
                (key.range(of: separator).map { String(key[$0.upperBound...]) } ?? key, value)
            })
        }
        let names = Dictionary(connectors.map { ($0.setupComponentID, $0.name) }, uniquingKeysWith: { first, _ in first })
        return OnboardingCapabilityInstallationInputs(
            credentialInputs: fields(copied.credentialInputs),
            configInputs: fields(copied.configInputs),
            baseURLOverrides: agreed(copied.baseURLOverrides.map { (names[$0.key] ?? $0.key, $0.value) })
        )
    }
}

extension PluginConnector {
    /// Its stable component ID (`CapabilityResourceOrigin`), which setup
    /// keys it by.
    var setupComponentID: String { CapabilityResourceOrigin.componentID(for: self) }
}

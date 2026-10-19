import Foundation
import ASTRACore

/// How Add's setup inputs name one connector component.
///
/// Add takes three flat dictionaries: credential and setting values by field
/// key, and base URLs. Two connectors of one plugin can share a display name
/// and field keys while their stable component IDs differ, so a value meant
/// for one of them is stored under `key(_:component:)`, and its base URL
/// under its component ID. A bare field key, or a base URL under a connector
/// name, is shared by every connector that declares it, which is what the
/// callers that predate per-component setup (setup copy, onboarding) pass.
/// The installer reads a component's inputs only through `view(_:component:)`
/// and `baseURL(in:for:)`.
enum PluginSetupInputs {
    /// Not a character a field key or component ID contains.
    private static let separator = "\u{1F}"

    /// The input key of `field` for one connector component.
    static func key(_ field: String, component componentID: String) -> String {
        componentID + separator + field
    }

    /// `inputs` as one component reads them: the shared values, with its own
    /// over them. Another component's own values are left out.
    static func view(_ inputs: [String: String], component componentID: String) -> [String: String] {
        let prefix = componentID + separator
        var view = inputs.filter { !$0.key.contains(separator) }
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

    /// Copied setup (`CapabilitySetupCopier`, shared keys) as each of
    /// `connectors`' own: every connector that declares a copied field or
    /// is named by a copied base URL gets it. Skill settings stay shared.
    static func perComponent(
        _ copied: OnboardingCapabilityInstallationInputs,
        for connectors: [PluginConnector]
    ) -> OnboardingCapabilityInstallationInputs {
        var own = OnboardingCapabilityInstallationInputs(configInputs: copied.configInputs)
        for connector in connectors {
            for hint in connector.credentialHints {
                if let value = copied.credentialInputs[hint.key] { own.credentialInputs[key(hint.key, component: connector.setupComponentID)] = value }
            }
            for hint in connector.configHints {
                if let value = copied.configInputs[hint.key] { own.configInputs[key(hint.key, component: connector.setupComponentID)] = value }
            }
            if let url = baseURL(in: copied.baseURLOverrides, for: connector) { own.baseURLOverrides[connector.setupComponentID] = url }
        }
        return own
    }
}

extension PluginConnector {
    /// Its stable component ID (`CapabilityResourceOrigin`), which setup
    /// keys it by.
    var setupComponentID: String { CapabilityResourceOrigin.componentID(for: self) }
}

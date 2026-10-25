import Foundation
import ASTRAModels

/// Projects older serialized launch records through the same public-field
/// policy as new requests. Unknown metadata and all credential references stay
/// intact; malformed records are refused by the mirror's existing error path.
enum PluginLaunchPolicyRedactor {
    static func redact(_ source: [String: Any]) throws -> [String: Any] {
        var result = source
        try projectArray("pluginActivations", in: &result, using: activation)
        try projectArray("pluginAccounts", in: &result, using: account)
        try projectArray("authoredSkills", in: &result, using: skill)
        if var overrides = try object("pluginOverrides", in: result) {
            try projectArray("skills", in: &overrides, using: skill)
            result["pluginOverrides"] = overrides
        }
        if var inventory = try object("accountInventory", in: result) {
            try projectArray("entries", in: &inventory) { source in
                var entry = source
                guard let saved = try object("account", in: entry) else { throw corrupt() }
                entry["account"] = try account(saved)
                if let parent = try object("parentSkill", in: entry) { entry["parentSkill"] = try skill(parent) }
                return entry
            }
            result["accountInventory"] = inventory
        }
        return result
    }

    private static func activation(_ source: [String: Any]) throws -> [String: Any] {
        let configuration = PluginLaunchConfiguration.activation(keys: try strings("configKeys", in: source),
            values: try strings("configValues", in: source),
            secretSettingKeys: try strings("secretSettingKeys", in: source, optional: true))
        return replacingConfiguration(source, with: configuration)
    }

    private static func account(_ source: [String: Any]) throws -> [String: Any] {
        let configuration = PluginLaunchConfiguration.account(keys: try strings("configKeys", in: source),
            values: try strings("configValues", in: source), credentialKeys: try strings("credentialKeys", in: source),
            originPackageID: try optionalString("originPackageID", in: source),
            originComponentID: try optionalString("originComponentID", in: source))
        return replacingConfiguration(source, with: configuration)
    }

    private static func skill(_ source: [String: Any]) throws -> [String: Any] {
        var result = source
        let keys = try strings("environmentKeys", in: source)
        let values = try strings("environmentValues", in: source)
        result["environmentValues"] = keys.indices.map { index in
            !Skill.isSecretEnvironmentKey(keys[index]) && index < values.count ? values[index] : ""
        }
        try projectArray("attachedConnectors", in: &result, using: account)
        return result
    }

    private static func replacingConfiguration(_ source: [String: Any], with configuration: (keys: [String], values: [String])) -> [String: Any] {
        var result = source
        result["configKeys"] = configuration.keys
        result["configValues"] = configuration.values
        return result
    }

    private static func projectArray(_ key: String, in source: inout [String: Any],
                                     using project: ([String: Any]) throws -> [String: Any]) throws {
        guard let value = source[key], !(value is NSNull) else { return }
        guard let records = value as? [[String: Any]] else { throw corrupt() }
        source[key] = try records.map(project)
    }

    private static func strings(_ key: String, in source: [String: Any], optional: Bool = false) throws -> [String] {
        if optional, source[key] == nil || source[key] is NSNull { return [] }
        guard let values = source[key] as? [String] else { throw corrupt() }
        return values
    }

    private static func object(_ key: String, in source: [String: Any]) throws -> [String: Any]? {
        guard let value = source[key], !(value is NSNull) else { return nil }
        guard let record = value as? [String: Any] else { throw corrupt() }
        return record
    }

    private static func optionalString(_ key: String, in source: [String: Any]) throws -> String? {
        guard let value = source[key], !(value is NSNull) else { return nil }
        guard let string = value as? String else { throw corrupt() }
        return string
    }

    private static func corrupt() -> CocoaError { CocoaError(.fileReadCorruptFile) }
}

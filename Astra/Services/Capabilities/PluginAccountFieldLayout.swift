import Foundation
import ASTRACore
import ASTRAModels

/// Declaration-derived account fields shared by initial Add and Add account.
/// Structure has its own owner on Connector; all skill-only settings remain on
/// the activation. Neither is duplicated in plain account configuration.
enum PluginAccountFieldLayout {
    /// Every setup field shares one input dictionary and row identity.
    /// A structure key must be distinct from all other hints, regardless of
    /// their storage or declaration order, before catalog or mutation admission.
    static func duplicateStructureKeys(in hints: [PluginConnector.ConfigHint]) -> [String] {
        Dictionary(grouping: hints, by: \.key)
            .filter { $0.value.count > 1 && $0.value.contains(where: \.isAccountStructure) }.keys.sorted()
    }

    /// Only connector declarations own account configuration. Skill settings
    /// remain on the activation, including when their defaults are nonempty.
    static func configurationKeys(hints: [PluginConnector.ConfigHint]) -> [String] {
        hints.filter { !$0.isAccountStructure }.map(\.key)
    }

    static func defaults(in package: PluginPackage) -> [String: String] {
        var values: [String: String] = [:]
        for skill in package.skills {
            for (index, key) in skill.environmentKeys.enumerated() where index < skill.environmentValues.count {
                if values[key] == nil { values[key] = skill.environmentValues[index] }
            }
        }
        return values
    }
}

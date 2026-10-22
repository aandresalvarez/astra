import Foundation
import ASTRACore
import ASTRAModels

/// Declaration-derived account fields shared by initial Add and Add account.
/// Structure has its own owner on Connector; secret skill settings remain on
/// the activation. Neither is duplicated in plain account configuration.
enum PluginAccountFieldLayout {
    /// Every setup field shares one input dictionary and row identity.
    /// A structure key must be distinct from all other hints, regardless of
    /// their storage or declaration order, before catalog or mutation admission.
    static func duplicateStructureKeys(in hints: [PluginConnector.ConfigHint]) -> [String] {
        Dictionary(grouping: hints, by: \.key)
            .filter { $0.value.count > 1 && $0.value.contains(where: \.isAccountStructure) }.keys.sorted()
    }

    static func configurationKeys(hints: [PluginConnector.ConfigHint], environmentKeys: [String]) -> [String] {
        let structure = Set(hints.filter(\.isAccountStructure).map(\.key))
        var keys = hints.filter { !$0.isAccountStructure }.map(\.key)
        for key in environmentKeys where !structure.contains(key) && !Skill.isSecretEnvironmentKey(key)
            && !keys.contains(key) {
            keys.append(key)
        }
        return keys
    }

    static func environmentKeys(in package: PluginPackage) -> [String] {
        let credentials = Set(package.connectors.flatMap {
            PluginConnectorFieldTrust.settingsStoredAsCredentials(of: $0, in: package)
        })
        return package.skills.flatMap(\.environmentKeys).filter { !credentials.contains($0) }
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

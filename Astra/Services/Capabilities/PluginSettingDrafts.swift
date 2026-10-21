import Foundation
import ASTRACore
import ASTRAModels

/// A presentation snapshot. An unreadable credential is an error, never an
/// empty editable value: saving an empty value would delete the current secret.
@MainActor
struct PluginSettingDrafts {
    var values: [String: String] = [:]
    var failures: [String: String] = [:]

    static func source(package: PluginPackage, activation: PluginActivation?) -> String {
        "\(activation?.revision ?? -1)|\(PluginDefinitionDigest.content(of: package))"
    }

    static func load(
        package: PluginPackage, activation: PluginActivation?,
        read: (String, PluginSkill, PluginActivation) throws -> String
    ) -> Self {
        guard let activation else { return Self() }
        var snapshot = Self()
        for skill in package.skills {
            let component = CapabilityResourceOrigin.componentID(for: skill)
            for key in PluginsSurfacePresentation.settingKeys(of: skill, in: activation, package: package) {
                let field = PluginActivation.settingKey(componentID: component, key: key)
                do { snapshot.values[field] = try read(key, skill, activation) }
                catch { snapshot.failures[field] = error.localizedDescription }
            }
        }
        return snapshot
    }
}

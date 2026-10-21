import Foundation
import ASTRACore
import ASTRAModels

/// A presentation snapshot. An unreadable credential is an error, never an
/// empty editable value: saving an empty value would delete the current secret.
@MainActor
struct PluginSettingDrafts {
    var values: [String: String] = [:]
    var failures: [String: String] = [:]
    private var loadedValues: [String: String] = [:]
    private var activationID: UUID?

    func belongs(to activation: PluginActivation?) -> Bool {
        activationID != nil && activationID == activation?.id
    }

    /// Keep edits across refreshes of their activation, never across owners.
    /// The fresh snapshot owns the baseline and read failures on every reload.
    func reloading(from fresh: Self) -> Self {
        guard activationID != nil, activationID == fresh.activationID else { return fresh }
        var next = fresh
        for (key, value) in values where loadedValues[key] != value && (fresh.values[key] != nil || fresh.failures[key] != nil) {
            next.values[key] = value
        }
        return next
    }

    static func source(package: PluginPackage, activation: PluginActivation?) -> String {
        "\(activation?.id.uuidString ?? "none")|\(activation?.revision ?? -1)|\(PluginDefinitionDigest.content(of: package))"
    }

    static func load(
        package: PluginPackage, activation: PluginActivation?,
        read: (String, PluginSkill, PluginActivation) throws -> String
    ) -> Self {
        guard let activation else { return Self() }
        var snapshot = Self()
        snapshot.activationID = activation.id
        for skill in package.skills {
            let component = CapabilityResourceOrigin.componentID(for: skill)
            for key in PluginsSurfacePresentation.settingKeys(of: skill, in: activation, package: package) {
                let field = PluginActivation.settingKey(componentID: component, key: key)
                do { snapshot.values[field] = try read(key, skill, activation) }
                catch { snapshot.failures[field] = error.localizedDescription }
            }
        }
        snapshot.loadedValues = snapshot.values
        return snapshot
    }
}

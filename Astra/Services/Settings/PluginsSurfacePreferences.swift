import Foundation
import ASTRACore
import ASTRAModels

/// Whether Configure → Capabilities shows the Plugins 2.0 surface instead of
/// the catalog. Unset means on in development builds and off elsewhere, so
/// the preview reaches the people building it before anyone else.
enum PluginsSurfacePreferences {
    static func isEnabled(in defaults: UserDefaults = .standard, channel: AppChannel = .current) -> Bool {
        guard defaults.object(forKey: AppStorageKeys.pluginsSurfaceEnabled) != nil else {
            return channel == .development
        }
        return defaults.bool(forKey: AppStorageKeys.pluginsSurfaceEnabled)
    }

    static func setEnabled(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: AppStorageKeys.pluginsSurfaceEnabled)
    }

    /// The plugin rows a workspace keeps expanded, so a disclosure choice
    /// survives Configure closing and the app relaunching
    /// (`docs/design-system/lean-ui-system.md`). Keyed per workspace, like
    /// `RailDisclosureStore`.
    static func expandedPluginIDs(workspaceID: UUID, in defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: expandedKey(workspaceID)) ?? [])
    }

    static func setExpandedPluginIDs(_ ids: Set<String>, workspaceID: UUID, in defaults: UserDefaults = .standard) {
        if ids.isEmpty {
            defaults.removeObject(forKey: expandedKey(workspaceID))
        } else {
            defaults.set(ids.sorted(), forKey: expandedKey(workspaceID))
        }
    }

    private static func expandedKey(_ workspaceID: UUID) -> String {
        "pluginsSurface.expanded.\(workspaceID.uuidString)"
    }
}

import Foundation
import ASTRACore
import ASTRAModels

/// What the Plugins surface remembers between sessions.
enum PluginsSurfacePreferences {
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

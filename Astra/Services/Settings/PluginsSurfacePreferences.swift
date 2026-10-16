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
}

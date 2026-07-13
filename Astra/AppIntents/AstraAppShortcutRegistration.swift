import Foundation

/// Keeps App Intents out of ad-hoc binaries that macOS cannot register.
/// `linkd` requires a validated bundle with a signing Team ID and otherwise
/// rejects the process before any shortcut can be used.
enum AstraAppShortcutRegistration {
  #if ASTRA_ENABLE_APP_INTENTS
    static let isEnabled = true
    static let binaryMarker = "astra-app-intents:enabled"
  #else
    static let isEnabled = false
    static let binaryMarker = "astra-app-intents:disabled"
  #endif
}

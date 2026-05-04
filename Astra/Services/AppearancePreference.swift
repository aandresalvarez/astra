import SwiftUI

enum AppStorageKeys {
    static let hasCompletedOnboarding = "astra.hasCompletedOnboarding"
    static let hasPresentedOnboarding = "astra.hasPresentedOnboarding"
    static let onboardingEnabledCapabilityIDs = "astra.onboardingEnabledCapabilityIDs"
    static let skipPermissions = "skipPermissions"
    static let securityGateDefaultedToReview = "astra.securityGateDefaultedToReview.v1"
}

/// User-controllable override for light/dark mode. Persisted in
/// `@AppStorage("appearancePreference")`. The scene applies
/// `preferredColorScheme(_:)` with the resolved value — `nil` means
/// "follow the system", which is the sane default.
///
/// Only one preference key drives the whole app; avoid sprinkling
/// `colorScheme` overrides in individual views or they'll fight the
/// global one.
enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "appearancePreference"
    var id: String { rawValue }

    /// Short label for menus / pickers.
    var label: String {
        switch self {
        case .system: "System"
        case .light:  "Light"
        case .dark:   "Dark"
        }
    }

    /// Icon that pairs with `label` in UI.
    var symbolName: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light:  "sun.max.fill"
        case .dark:   "moon.fill"
        }
    }

    /// The resolved `ColorScheme?` to hand to `preferredColorScheme()`.
    /// Returning `nil` opts out of the override and lets macOS's
    /// system-wide appearance decide.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light:  .light
        case .dark:   .dark
        }
    }
}

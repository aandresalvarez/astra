import SwiftUI
import ASTRACore
import ASTRAModels

enum LoggingPreferences {
    static let defaultRuntimeStreamDebugCapture = true
    static let defaultBrowserDebugCapture = true
    static let defaultLogRetentionDays = 7
    static let logRetentionDayOptions = [1, 3, 7, 14, 30, 90]

    static let registeredDefaults: [String: Any] = [
        AppStorageKeys.runtimeStreamDebugCapture: defaultRuntimeStreamDebugCapture,
        AppStorageKeys.browserDebugCapture: defaultBrowserDebugCapture,
        AppStorageKeys.logRetentionDays: defaultLogRetentionDays
    ]

    static func runtimeStreamDebugCaptureEnabled(in defaults: UserDefaults = .standard) -> Bool {
        boolPreference(
            AppStorageKeys.runtimeStreamDebugCapture,
            defaultValue: defaultRuntimeStreamDebugCapture,
            in: defaults
        )
    }

    static func browserDebugCaptureEnabled(in defaults: UserDefaults = .standard) -> Bool {
        boolPreference(
            AppStorageKeys.browserDebugCapture,
            defaultValue: defaultBrowserDebugCapture,
            in: defaults
        )
    }

    static func logRetentionDays(in defaults: UserDefaults = .standard) -> Int {
        guard defaults.object(forKey: AppStorageKeys.logRetentionDays) != nil else {
            return defaultLogRetentionDays
        }
        return min(365, max(1, defaults.integer(forKey: AppStorageKeys.logRetentionDays)))
    }

    private static func boolPreference(_ key: String, defaultValue: Bool, in defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }
}

// `TaskExecutionDefaults` and `BudgetEnforcementMode`'s core enum moved to
// `ASTRACore/TaskExecutionDefaults.swift` as part of Track A2.2. The
// UserDefaults-reading half of `BudgetEnforcementMode` stays here, since
// `ASTRACore` has no business reading user preferences.
extension BudgetEnforcementMode {
    static var configuredDefault: BudgetEnforcementMode {
        configuredDefault(in: .standard)
    }

    static func configuredDefault(in defaults: UserDefaults) -> BudgetEnforcementMode {
        let raw = defaults.string(forKey: AppStorageKeys.budgetEnforcementMode)
        return BudgetEnforcementMode(rawValue: raw ?? "") ?? TaskExecutionDefaults.budgetEnforcementMode
    }
}

/// Where the Claude Code CLI routes its API calls. Only matters for the
/// `claude_code` runtime — the Copilot CLI is unaffected.
///
/// Anthropic is the default. When set to `vertex`, the spawned `claude`
/// process gets `CLAUDE_CODE_USE_VERTEX=1` plus the configured project
/// and region (read from `claudeVertexProjectID` / `claudeVertexRegion`).
/// Authentication for Vertex piggybacks on `gcloud auth
/// application-default login`; if those credentials are missing the CLI
/// falls back to Anthropic auth and reports "Not logged in".
enum ClaudeProvider: String, CaseIterable, Identifiable, Sendable {
    case anthropic
    case vertex

    var id: String { rawValue }

    var label: String {
        switch self {
        case .anthropic: "Anthropic"
        case .vertex:    "Google Vertex AI"
        }
    }

    var symbolName: String {
        switch self {
        case .anthropic: "a.circle"
        case .vertex:    "cloud.fill"
        }
    }
}

/// User-controllable override for light/dark mode. Persisted in
/// `@AppStorage("appearancePreference")`. The scene applies
/// `preferredColorScheme(_:)` with the resolved value — `nil` means
/// "follow the system", which is the sane default.
///
/// Only one preference key drives the whole app; avoid sprinkling
/// `colorScheme` overrides in individual views or they'll fight the
/// global one.
enum AppearancePreference: String, CaseIterable, Identifiable, Sendable {
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

    /// The explicit preference that switches away from the appearance the app
    /// is rendering right now. This keeps quick toggles predictable even when
    /// the stored preference is `.system`.
    static func toggled(from colorScheme: ColorScheme) -> AppearancePreference {
        colorScheme == .dark ? .light : .dark
    }
}

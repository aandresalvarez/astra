import SwiftUI
import ASTRACore

enum AppStorageKeys {
    static let hasCompletedOnboarding = "astra.hasCompletedOnboarding"
    static let hasPresentedOnboarding = "astra.hasPresentedOnboarding"
    static let onboardingEnabledCapabilityIDs = "astra.onboardingEnabledCapabilityIDs"
    static let skipPermissions = "skipPermissions"
    static let securityGateDefaultedToReview = "astra.securityGateDefaultedToReview.v1"
    static let hasSeenNewTaskNudge = "astra.hasSeenNewTaskNudge.v1"
    static let showStarredWorkspacesOnly = "astra.sidebar.showStarredWorkspacesOnly.v1"
    static let diagnosticsScope = "astra.diagnostics.scope.v1"
    static let defaultAgentPolicyLevel = "astra.policy.defaultLevel.v1"
    static let planShelfWidth = "astra.planShelf.width.v1"
    static let browserShelfWidth = "astra.browserShelf.width.v1"
    static let markdownShelfWidth = "astra.markdownShelf.width.v1"
    static let queryShelfWidth = "astra.queryShelf.width.v1"
    static let rightRailWidth = "astra.rightRail.width.v1"
    static let markdownShelfShowHiddenPaths = "astra.markdownShelf.showHiddenPaths.v1"
    static let browserPinnedToTask = "astra.browser.pinnedToTask.v1"
    static let markdownPinnedToTask = "astra.markdown.pinnedToTask.v1"
    static let browserDebugCapture = "astra.browser.debugCapture.v1"
    static let runtimeStreamDebugCapture = "astra.runtime.streamDebugCapture.v1"
    static let logRetentionDays = "astra.logging.retentionDays.v1"
    static let browserAutoPromoteGoogleWorkspace = "astra.browser.autoPromoteGoogleWorkspace.v1"
    static let defaultTokenBudget = "defaultTokenBudget"
    static let budgetEnforcementMode = "astra.budget.enforcementMode.v1"
    static let claudeProvider = "astra.claudeProvider.v1"
    static let claudeVertexProjectID = "astra.claudeVertexProjectID.v1"
    static let claudeVertexRegion = "astra.claudeVertexRegion.v1"
    static let claudeVertexOpusModel = "astra.claudeVertexOpusModel.v1"
    static let claudeVertexSonnetModel = "astra.claudeVertexSonnetModel.v1"
    static let claudeVertexHaikuModel = "astra.claudeVertexHaikuModel.v1"
    static let claudeAvailableModels = "astra.claude.availableModels.v1"
    static let claudeModelsCheckedAt = "astra.claude.modelsCheckedAt.v1"
    static let copilotAvailableModels = "astra.copilot.availableModels.v1"
    static let copilotModelsCheckedAt = "astra.copilot.modelsCheckedAt.v1"
    static let runtimeModelCacheRevision = "astra.runtime.modelCacheRevision.v1"
    static let runtimeProviderSettingsRevision = "astra.runtime.providerSettingsRevision.v1"
    static let roleProfileRevision = "astra.roleProfile.revision.v1"

    static func runtimeAvailableModelsKey(for runtime: AgentRuntimeID) -> String {
        switch runtime {
        case .claudeCode:
            return claudeAvailableModels
        case .copilotCLI:
            return copilotAvailableModels
        default:
            return "astra.runtime.\(storageComponent(for: runtime)).availableModels.v1"
        }
    }

    static func runtimeModelsCheckedAtKey(for runtime: AgentRuntimeID) -> String {
        switch runtime {
        case .claudeCode:
            return claudeModelsCheckedAt
        case .copilotCLI:
            return copilotModelsCheckedAt
        default:
            return "astra.runtime.\(storageComponent(for: runtime)).modelsCheckedAt.v1"
        }
    }

    static func storageComponent(for runtime: AgentRuntimeID) -> String {
        runtime.rawValue
            .lowercased()
            .map { character in
                character.isLetter || character.isNumber || character == "_" || character == "-"
                    ? character
                    : "_"
            }
            .reduce(into: "") { $0.append($1) }
    }

    static func roleProfileRuntimeKey(for role: TaskRoleID) -> String {
        "astra.roleProfile.\(role.rawValue).runtime.v1"
    }

    static func roleProfileModelKey(for role: TaskRoleID) -> String {
        "astra.roleProfile.\(role.rawValue).model.v1"
    }

    static func roleProfileBudgetKey(for role: TaskRoleID) -> String {
        "astra.roleProfile.\(role.rawValue).budget.v1"
    }

    static func roleProfilePolicyKey(for role: TaskRoleID) -> String {
        "astra.roleProfile.\(role.rawValue).policy.v1"
    }
}

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

enum TaskExecutionDefaults {
    static let runtime = AgentRuntimeID.claudeCode
    static let model = AgentRuntimeAdapterRegistry.defaultModel(for: runtime)
    static let tokenBudget = 100_000
    static let budgetEnforcementMode = BudgetEnforcementMode.warning
    static let budgetPresets = [10_000, 25_000, 50_000, 100_000, 200_000, 500_000, 1_000_000, 0]
}

enum BudgetEnforcementMode: String, CaseIterable, Identifiable, Sendable {
    case hardStop = "hard_stop"
    case warning = "warning"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hardStop: "Hard Stop"
        case .warning: "Warning Only"
        }
    }

    var helpText: String {
        switch self {
        case .hardStop: "Stop the provider process when ASTRA estimates or receives usage above the task budget."
        case .warning: "Keep the task running and record a budget warning when usage goes over the task budget."
        }
    }

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
}

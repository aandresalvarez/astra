import Foundation

/// Persists the Workspace Context rail's box expand/collapse choices across
/// sessions, keyed per workspace so one workspace's layout never leaks into
/// another. Backed by `UserDefaults` directly — not `@AppStorage` — so it stays
/// off the architecture-fitness `@AppStorage` ratchet, matching the existing
/// `repositoryPanel.*` UserDefaults usage in the git view model.
enum RailDisclosureStore {
    /// One persisted disclosure toggle in the rail. Raw values are stable on-disk
    /// key suffixes — do not rename without a migration.
    enum Toggle: String, CaseIterable {
        /// The rail v2 boxes (spec 2026-10-26). Each defaults to expanded; a
        /// collapsed box still names what is inside on its one line.
        case environmentExpanded
        case contextExpanded
        case capabilitiesExpanded
    }

    /// Toggles the v1 rail persisted and the v2 rail no longer reads: the
    /// configured-setup summary, the ready/draft capability groups, and the
    /// Repository card's details/summary choice. Cleared with the workspace's
    /// other keys so they never linger.
    static let retiredToggleRawValues = [
        "configuredSetupExpanded",
        "readyCapabilitiesExpanded",
        "draftCapabilitiesExpanded",
        "repositoryShowsDetails"
    ]

    private static func defaultsKey(_ workspaceID: String, _ rawToggle: String) -> String {
        "workspaceRail.disclosure.\(workspaceID).\(rawToggle)"
    }

    /// Returns the persisted value, or `defaultValue` when the user has never
    /// touched this toggle for this workspace.
    static func bool(_ workspaceID: String, _ toggle: Toggle, default defaultValue: Bool) -> Bool {
        let key = defaultsKey(workspaceID, toggle.rawValue)
        guard UserDefaults.standard.object(forKey: key) != nil else { return defaultValue }
        return UserDefaults.standard.bool(forKey: key)
    }

    static func setBool(_ value: Bool, _ workspaceID: String, _ toggle: Toggle) {
        UserDefaults.standard.set(value, forKey: defaultsKey(workspaceID, toggle.rawValue))
    }

    /// Remove every persisted toggle for a workspace, retired ones included —
    /// useful when a workspace is deleted, and to keep tests from leaving state
    /// behind.
    static func clear(_ workspaceID: String) {
        for rawToggle in Toggle.allCases.map(\.rawValue) + retiredToggleRawValues {
            UserDefaults.standard.removeObject(forKey: defaultsKey(workspaceID, rawToggle))
        }
    }
}

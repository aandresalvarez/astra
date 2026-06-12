import Foundation

/// Persists the Workspace Context rail's section expand/collapse choices across
/// sessions, keyed per workspace so one workspace's layout never leaks into
/// another. Backed by `UserDefaults` directly — not `@AppStorage` — so it stays
/// off the architecture-fitness `@AppStorage` ratchet, matching the existing
/// `repositoryPanel.*` UserDefaults usage in the git view model.
enum RailDisclosureStore {
    /// One persisted disclosure toggle in the rail. Raw values are stable on-disk
    /// key suffixes — do not rename without a migration.
    enum Toggle: String, CaseIterable {
        case configuredSetupExpanded
        case readyCapabilitiesExpanded
        case draftCapabilitiesExpanded
        case repositoryShowsDetails
    }

    private static func defaultsKey(_ workspaceID: String, _ toggle: Toggle) -> String {
        "workspaceRail.disclosure.\(workspaceID).\(toggle.rawValue)"
    }

    /// Returns the persisted value, or `defaultValue` when the user has never
    /// touched this toggle for this workspace.
    static func bool(_ workspaceID: String, _ toggle: Toggle, default defaultValue: Bool) -> Bool {
        let key = defaultsKey(workspaceID, toggle)
        guard UserDefaults.standard.object(forKey: key) != nil else { return defaultValue }
        return UserDefaults.standard.bool(forKey: key)
    }

    static func setBool(_ value: Bool, _ workspaceID: String, _ toggle: Toggle) {
        UserDefaults.standard.set(value, forKey: defaultsKey(workspaceID, toggle))
    }

    /// Remove every persisted toggle for a workspace — useful when a workspace is
    /// deleted, and to keep tests from leaving state behind.
    static func clear(_ workspaceID: String) {
        for toggle in Toggle.allCases {
            UserDefaults.standard.removeObject(forKey: defaultsKey(workspaceID, toggle))
        }
    }
}

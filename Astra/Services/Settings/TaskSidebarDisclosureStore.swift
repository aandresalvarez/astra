import Foundation

struct TaskSidebarDisclosureState: Equatable {
    var isPinnedExpanded = true
    var isWorkspacesExpanded = true
    var isSchedulesExpanded = true
    /// Accordion model: the sidebar keeps at most one workspace drawer open
    /// (`WorkspaceSidebarAccordion`), so a single optional ID replaces the
    /// old collapsed/expanded ID sets. Nil means every drawer is closed —
    /// or nothing was ever persisted, in which case the sidebar seeds the
    /// drawer from the restored workspace selection.
    var openWorkspaceID: UUID?
}

/// Persists durable task-sidebar disclosure choices without adding another
/// `@AppStorage` owner to the large sidebar view.
enum TaskSidebarDisclosureStore {
    private enum Key: String, CaseIterable {
        case pinnedExpanded = "taskSidebar.pinnedExpanded"
        case workspacesExpanded = "taskSidebar.workspacesExpanded"
        case schedulesExpanded = "taskSidebar.schedulesExpanded"
        case openWorkspaceID = "taskSidebar.openWorkspaceID"
        // Pre-accordion multi-open state; purged on save so stale sets don't
        // linger in defaults after the model change.
        case legacyCollapsedWorkspaceIDs = "taskSidebar.collapsedWorkspaceIDs"
        case legacyExpandedWorkspaceIDs = "taskSidebar.expandedWorkspaceIDs"
    }

    static func load(defaults: UserDefaults = .standard) -> TaskSidebarDisclosureState {
        TaskSidebarDisclosureState(
            isPinnedExpanded: bool(.pinnedExpanded, default: true, defaults: defaults),
            isWorkspacesExpanded: bool(.workspacesExpanded, default: true, defaults: defaults),
            isSchedulesExpanded: bool(.schedulesExpanded, default: true, defaults: defaults),
            openWorkspaceID: (defaults.string(forKey: Key.openWorkspaceID.rawValue))
                .flatMap(UUID.init(uuidString:))
        )
    }

    static func save(_ state: TaskSidebarDisclosureState, defaults: UserDefaults = .standard) {
        defaults.set(state.isPinnedExpanded, forKey: Key.pinnedExpanded.rawValue)
        defaults.set(state.isWorkspacesExpanded, forKey: Key.workspacesExpanded.rawValue)
        defaults.set(state.isSchedulesExpanded, forKey: Key.schedulesExpanded.rawValue)
        if let openWorkspaceID = state.openWorkspaceID {
            defaults.set(openWorkspaceID.uuidString, forKey: Key.openWorkspaceID.rawValue)
        } else {
            defaults.removeObject(forKey: Key.openWorkspaceID.rawValue)
        }
        defaults.removeObject(forKey: Key.legacyCollapsedWorkspaceIDs.rawValue)
        defaults.removeObject(forKey: Key.legacyExpandedWorkspaceIDs.rawValue)
    }

    static func clear(defaults: UserDefaults = .standard) {
        for key in Key.allCases {
            defaults.removeObject(forKey: key.rawValue)
        }
    }

    private static func bool(_ key: Key, default defaultValue: Bool, defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: key.rawValue) != nil else { return defaultValue }
        return defaults.bool(forKey: key.rawValue)
    }
}

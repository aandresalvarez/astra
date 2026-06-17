import Foundation

struct TaskSidebarDisclosureState: Equatable {
    var isPinnedExpanded = true
    var isWorkspacesExpanded = true
    var isSchedulesExpanded = true
    var collapsedWorkspaceIDs: Set<UUID> = []
    var expandedWorkspaceIDs: Set<UUID> = []
}

/// Persists durable task-sidebar disclosure choices without adding another
/// `@AppStorage` owner to the large sidebar view.
enum TaskSidebarDisclosureStore {
    private enum Key: String, CaseIterable {
        case pinnedExpanded = "taskSidebar.pinnedExpanded"
        case workspacesExpanded = "taskSidebar.workspacesExpanded"
        case schedulesExpanded = "taskSidebar.schedulesExpanded"
        case collapsedWorkspaceIDs = "taskSidebar.collapsedWorkspaceIDs"
        case expandedWorkspaceIDs = "taskSidebar.expandedWorkspaceIDs"
    }

    static func load(defaults: UserDefaults = .standard) -> TaskSidebarDisclosureState {
        TaskSidebarDisclosureState(
            isPinnedExpanded: bool(.pinnedExpanded, default: true, defaults: defaults),
            isWorkspacesExpanded: bool(.workspacesExpanded, default: true, defaults: defaults),
            isSchedulesExpanded: bool(.schedulesExpanded, default: true, defaults: defaults),
            collapsedWorkspaceIDs: uuidSet(.collapsedWorkspaceIDs, defaults: defaults),
            expandedWorkspaceIDs: uuidSet(.expandedWorkspaceIDs, defaults: defaults)
        )
    }

    static func save(_ state: TaskSidebarDisclosureState, defaults: UserDefaults = .standard) {
        defaults.set(state.isPinnedExpanded, forKey: Key.pinnedExpanded.rawValue)
        defaults.set(state.isWorkspacesExpanded, forKey: Key.workspacesExpanded.rawValue)
        defaults.set(state.isSchedulesExpanded, forKey: Key.schedulesExpanded.rawValue)
        defaults.set(state.collapsedWorkspaceIDs.map(\.uuidString).sorted(), forKey: Key.collapsedWorkspaceIDs.rawValue)
        defaults.set(state.expandedWorkspaceIDs.map(\.uuidString).sorted(), forKey: Key.expandedWorkspaceIDs.rawValue)
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

    private static func uuidSet(_ key: Key, defaults: UserDefaults) -> Set<UUID> {
        let values = defaults.array(forKey: key.rawValue) as? [String] ?? []
        return Set(values.compactMap(UUID.init(uuidString:)))
    }
}

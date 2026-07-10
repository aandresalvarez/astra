import Foundation

/// The rail's liveness invariant: running work is always signalled
/// somewhere. Each visible workspace row carries its own signal (the
/// collapsed-drawer dot, or the task row's spinner when expanded), so the
/// "Workspaces" section header takes over exactly when a row can't:
///  - the whole section is collapsed, hiding every row, or
///  - a running workspace is filtered out of the visible list
///    (starred-only filter, or a search it doesn't match).
enum SidebarLivenessSignal {
    /// Running tasks whose workspace row is not currently on screen to
    /// signal them. `runningCounts` is (workspaceID, runningTaskCount)
    /// for ALL workspaces, unfiltered.
    static func headerRunningTaskCount(
        runningCounts: [(workspaceID: UUID, count: Int)],
        visibleWorkspaceIDs: Set<UUID>,
        isSectionExpanded: Bool
    ) -> Int {
        runningCounts.reduce(0) { total, entry in
            guard entry.count > 0 else { return total }
            let rowCanSignal = isSectionExpanded && visibleWorkspaceIDs.contains(entry.workspaceID)
            return rowCanSignal ? total : total + entry.count
        }
    }
}

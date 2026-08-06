import Foundation

struct SidebarWorkspaceActivityCounts: Equatable, Sendable {
    var running: Int = 0
    var waiting: Int = 0

    var isEmpty: Bool { running == 0 && waiting == 0 }
}

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

    /// The waiting count follows the same liveness rule as running work: when
    /// a workspace row is hidden, the section header becomes the truthful
    /// owner of its active-work signal.
    static func headerActivityCounts(
        activityCounts: [(workspaceID: UUID, counts: SidebarWorkspaceActivityCounts)],
        visibleWorkspaceIDs: Set<UUID>,
        isSectionExpanded: Bool
    ) -> SidebarWorkspaceActivityCounts {
        activityCounts.reduce(into: SidebarWorkspaceActivityCounts()) { total, entry in
            guard !entry.counts.isEmpty else { return }
            let rowCanSignal = isSectionExpanded && visibleWorkspaceIDs.contains(entry.workspaceID)
            guard !rowCanSignal else { return }
            total.running += entry.counts.running
            total.waiting += entry.counts.waiting
        }
    }

    /// Tasks browse mode renders one row per task instead of one per
    /// workspace, so the same rule applies at task granularity: a live task
    /// dropped from the flat list — by search, or by a collapsed section —
    /// hands its signal to the header.
    static func headerActivityCounts(
        taskActivities: [TaskActivityPresentation],
        visibleTaskIDs: Set<UUID>,
        isSectionExpanded: Bool
    ) -> SidebarWorkspaceActivityCounts {
        taskActivities.reduce(into: SidebarWorkspaceActivityCounts()) { total, activity in
            guard activity.showsPersistentSidebarGlyph else { return }
            let rowCanSignal = isSectionExpanded && visibleTaskIDs.contains(activity.taskID)
            guard !rowCanSignal else { return }
            if activity.isRunning { total.running += 1 }
            if activity.isWaiting { total.waiting += 1 }
        }
    }
}

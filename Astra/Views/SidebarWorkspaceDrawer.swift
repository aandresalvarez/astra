import Foundation
import ASTRAModels

/// What an expanded workspace row in the rail puts inside its drawer: how much
/// of a long task list it shows, and whether it is allowed to say the workspace
/// holds nothing at all.

enum SidebarWorkspaceTaskList {
    static let collapsedLimit = SidebarLeanPresentation.sectionPreviewLimit
    /// Overflow controls sit with the task titles, not the full-width row
    /// surface, so a long workspace list keeps one readable left edge.
    static let showMoreLeadingPadding = SidebarThreadRowLayout.titleLeadingOffset(
        childListPadding: SidebarLeanPresentation.childTaskListLeadingPadding,
        contentLeadingPadding: SidebarLeanPresentation.childTaskContentLeadingPadding
    )

    static func visibleTasks(_ tasks: [AgentTask], isShowingAll: Bool) -> [AgentTask] {
        isShowingAll ? tasks : Array(tasks.prefix(collapsedLimit))
    }

    static func hiddenTaskCount(totalTasks: Int, visibleTasks: Int) -> Int {
        max(0, totalTasks - visibleTasks)
    }
}

/// When an open workspace drawer may say "this workspace holds no work".
///
/// `SidebarTaskIndex` answers that question from a snapshot, and the snapshot
/// reaches a drawer row through a closure capture — something SwiftUI cannot
/// track. A row built while its workspace was empty therefore has no
/// dependency that filing the first task can invalidate, and it goes on
/// offering "Add task" for as long as the row lives. In production that lasted
/// hours: the board listed a new workspace's first two results while the rail
/// still showed the empty state.
///
/// So the workspace's own `tasks` relationship gets a vote. It is observed, so
/// reading it is also what gives the row the dependency it was missing.
enum SidebarWorkspaceDrawer {
    /// Whether the row should read `workspace.tasks` at all.
    ///
    /// Only where the answer can change what this row renders: a drawer that is
    /// open, or one the index believes is empty. Everywhere else the index
    /// already says yes and faulting the relationship would buy nothing. An
    /// open drawer always consults it — that is the subscription that keeps a
    /// drawer live, and dropping it is how the bug comes back.
    static func consultsWorkspaceTasks(isExpanded: Bool, indexHasAnyTask: Bool) -> Bool {
        isExpanded || !indexHasAnyTask
    }

    /// Whether the workspace holds any work, from both witnesses: the index is
    /// fast but can be stale here, and the relationship is authoritative but
    /// costs a fault, so it is read only where reading it can matter.
    ///
    /// `workspaceHoldsTasks` is a closure so this decides the read rather than
    /// receiving its result. It is called — not skipped as redundant — whenever
    /// the drawer is open, even where the index already says yes: that call is
    /// the observation the row subscribes to, and short-circuiting past it is
    /// exactly how the drawer went deaf in the first place.
    static func holdsWork(
        isExpanded: Bool,
        indexHasAnyTask: Bool,
        workspaceHoldsTasks: () -> Bool
    ) -> Bool {
        guard consultsWorkspaceTasks(isExpanded: isExpanded, indexHasAnyTask: indexHasAnyTask) else {
            return indexHasAnyTask
        }
        let observed = workspaceHoldsTasks()
        return indexHasAnyTask || observed
    }

    /// The empty state is a claim that there is nothing to show and nothing to
    /// find, so every source has to agree before the drawer makes it.
    static func showsEmptyState(hasDrawerTasks: Bool, holdsWork: Bool, hasApps: Bool) -> Bool {
        !hasDrawerTasks && !holdsWork && !hasApps
    }
}

/// Records what an open drawer decided, each time it decides something new.
///
/// The bug above was invisible from the logs. Every layer underneath reported
/// itself healthy — the fetch fired, the snapshot grew, the index gained the
/// workspace — and the one fact that was wrong, what the drawer actually
/// rendered, was recorded nowhere. It took a screenshot to find.
///
/// A drawer is worth a line when its contents change, which is the liveness
/// question itself: a drawer that never logs a second line while its workspace
/// gains work has gone deaf again. Logging one per body evaluation would drown
/// the rail's own performance events, which is a trap this sidebar has already
/// fallen into once.
@MainActor
enum SidebarWorkspaceDrawerLog {
    private static var lastStateByWorkspaceID: [UUID: String] = [:]

    static func record(_ workspace: Workspace, empty: Bool, tasks: Int) {
        let state = "\(empty)|\(tasks)"
        guard lastStateByWorkspaceID.updateValue(state, forKey: workspace.id) != state else { return }
        PerformanceTelemetry.log(
            "sidebar_drawer_verdict",
            fields: [
                "workspace": workspace.name,
                "workspace_id": workspace.id.uuidString,
                "shows_empty_state": PerformanceTelemetryFields.bool(empty),
                "drawer_task_count": PerformanceTelemetryFields.count(tasks)
            ]
        )
    }
}

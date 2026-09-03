import Foundation
import ASTRAModels

struct SidebarTaskIndex {
    /// The value a sidebar starts with, before its first real build. Shared
    /// rather than constructed per `@State` default: SwiftUI re-evaluates that
    /// default on every view-struct init and throws the result away, which on
    /// a busy rail meant ~100 pointless index builds — and ~100 misleading
    /// `sidebar_index_build` samples — every thirty seconds.
    static let empty = SidebarTaskIndex(tasks: [], searchText: "")

    private let searchText: String
    private let reviewTasksByWorkspaceID: [UUID: [AgentTask]]
    private let matchingReviewTasksByWorkspaceID: [UUID: [AgentTask]]
    private let anyTaskWorkspaceIDs: Set<UUID>
    // Deliberately unfiltered by search: the collapsed-drawer running signal
    // must not disappear just because a live query doesn't match the task.
    private let runningTaskCountByWorkspaceID: [UUID: Int]
    private let waitingTaskCountByWorkspaceID: [UUID: Int]

    let pinnedTasks: [AgentTask]
    let unreadTasks: [AgentTask]
    /// Cross-workspace supervision list. This is derived from the same
    /// durable request projection as workspace rows and deliberately ignores
    /// search, pinning, and drawer state so live work cannot disappear.
    let activeTasks: [AgentTask]
    /// Every task the workspace drawers would show, flattened together and
    /// search-filtered, backing the sidebar's Tasks browse mode. It admits
    /// exactly what a drawer admits — so closed threads and drafts stay filed
    /// away here too; what it adds is reach: pinned work, and work whose
    /// workspace was deleted, without opening a folder per workspace.
    let allTasks: [AgentTask]
    /// Which tasks the flat list is currently ranking in its unread tier.
    /// Feeds `heldUnreadRank(forSelected:)` on the next rebuild.
    let unreadRankedTaskIDs: Set<UUID>
    let activityCounts: SidebarWorkspaceActivityCounts

    init(
        tasks: [AgentTask],
        searchText: String,
        taskActivities: [UUID: TaskActivityPresentation] = [:],
        stickyUnreadTaskID: UUID? = nil
    ) {
        let start = DispatchTime.now().uptimeNanoseconds
        self.searchText = searchText

        var reviewGroups: [UUID: [AgentTask]] = [:]
        var matchingGroups: [UUID: [AgentTask]] = [:]
        var workspaceIDs = Set<UUID>()
        var runningCounts: [UUID: Int] = [:]
        var waitingCounts: [UUID: Int] = [:]
        var pinned: [AgentTask] = []
        var unread: [AgentTask] = []
        var active: [AgentTask] = []
        var all: [AgentTask] = []
        var allActivityCounts = SidebarWorkspaceActivityCounts()
        var reviewTaskCount = 0

        for task in tasks {
            let activity = taskActivities[task.id] ?? TaskActivityPresentation.resolve(
                taskID: task.id,
                taskStatus: task.status,
                requests: []
            )
            if activity.showsPersistentSidebarGlyph {
                active.append(task)
                if activity.isRunning { allActivityCounts.running += 1 }
                if activity.isWaiting { allActivityCounts.waiting += 1 }
            }

            let isReviewTask = Self.isSidebarReviewTask(task, activity: activity)

            // Same admission test as a workspace drawer, applied before the
            // workspace guard: a task whose workspace is gone has no drawer to
            // live in, and the flat list is the only place left that can show
            // it. Sharing the test is what keeps closed threads and
            // in-composition drafts — which the board hides everywhere else —
            // from piling up here, while its activity clause still admits a
            // closed task whose follow-up is mid-run.
            if isReviewTask,
               searchText.isEmpty || Self.taskMatchesFlatSearch(task, searchText: searchText) {
                all.append(task)
            }

            guard let workspaceID = task.workspace?.id else { continue }
            workspaceIDs.insert(workspaceID)
            // A durable running request (activity.request) means a follow-up
            // the user explicitly sent is executing right now, so it counts
            // even when the task itself is still marked done — otherwise the
            // collapsed-drawer indicator vanishes at the exact moment the
            // waiting turn (counted below) starts provider work.
            if activity.isRunning, !task.isDone || activity.request != nil {
                runningCounts[workspaceID, default: 0] += 1
            }
            // Waiting always reflects a live durable request. A follow-up sent
            // from a task the user already closed keeps `isDone` true, so the
            // done filter would hide the saved turn from the collapsed-drawer
            // count entirely.
            if activity.isWaiting {
                waitingCounts[workspaceID, default: 0] += 1
            }

            guard isReviewTask else { continue }

            reviewTaskCount += 1
            if task.isPinned {
                // Pinned tasks surface once, in the top-level Pinned
                // section, so they're excluded from the per-workspace
                // list entirely rather than rendered a second time there.
                pinned.append(task)
            } else {
                reviewGroups[workspaceID, default: []].append(task)
                if searchText.isEmpty || Self.taskMatchesSearch(task, searchText: searchText) {
                    matchingGroups[workspaceID, default: []].append(task)
                }
            }
            if Self.isUnreadTask(task) {
                unread.append(task)
            }
        }

        for workspaceID in reviewGroups.keys {
            reviewGroups[workspaceID]?.sort {
                Self.taskSortsBefore($0, $1, taskActivities: taskActivities)
            }
        }
        for workspaceID in matchingGroups.keys {
            matchingGroups[workspaceID]?.sort {
                Self.taskSortsBefore($0, $1, taskActivities: taskActivities)
            }
        }

        reviewTasksByWorkspaceID = reviewGroups
        matchingReviewTasksByWorkspaceID = matchingGroups
        anyTaskWorkspaceIDs = workspaceIDs
        runningTaskCountByWorkspaceID = runningCounts
        waitingTaskCountByWorkspaceID = waitingCounts
        pinnedTasks = pinned.sorted { $0.updatedAt > $1.updatedAt }
        unreadTasks = unread.sorted {
            ($0.unreadAt ?? $0.updatedAt) > ($1.unreadAt ?? $1.updatedAt)
        }
        activeTasks = active.sorted {
            Self.taskSortsBefore($0, $1, taskActivities: taskActivities)
        }
        allTasks = all.sorted {
            Self.flatTaskSortsBefore(
                $0,
                $1,
                taskActivities: taskActivities,
                stickyUnreadTaskID: stickyUnreadTaskID
            )
        }
        unreadRankedTaskIDs = Set(
            all.lazy
                .filter {
                    Self.ranksAsUnread(
                        $0,
                        activity: taskActivities[$0.id],
                        stickyUnreadTaskID: stickyUnreadTaskID
                    )
                }
                .map(\.id)
        )
        activityCounts = allActivityCounts
        PerformanceTelemetry.logIfNeeded(
            "sidebar_index_build",
            start: start,
            thresholdMilliseconds: PerformanceTelemetry.uiFrameThresholdMilliseconds,
            fields: [
                "task_count": PerformanceTelemetryFields.count(tasks.count),
                "workspace_count": PerformanceTelemetryFields.count(workspaceIDs.count),
                "review_task_count": PerformanceTelemetryFields.count(reviewTaskCount),
                // Tasks mode renders this list uncapped, so its size is the
                // one that predicts sidebar cost.
                "flat_task_count": PerformanceTelemetryFields.count(all.count),
                "pinned_task_count": PerformanceTelemetryFields.count(pinned.count),
                "unread_task_count": PerformanceTelemetryFields.count(unread.count),
                "search_active": PerformanceTelemetryFields.bool(!searchText.isEmpty)
            ]
        )
    }

    func reviewTasks(
        for workspace: Workspace,
        matchingSearch: Bool = false,
        workspaceMatchesSearch: Bool = false
    ) -> [AgentTask] {
        let workspaceID = workspace.id
        let allWorkspaceTasks = reviewTasksByWorkspaceID[workspaceID] ?? []

        guard matchingSearch || !searchText.isEmpty else { return allWorkspaceTasks }
        guard !workspaceMatchesSearch else { return allWorkspaceTasks }
        return matchingReviewTasksByWorkspaceID[workspaceID] ?? []
    }

    func hasAnyTask(in workspace: Workspace) -> Bool {
        anyTaskWorkspaceIDs.contains(workspace.id)
    }

    func runningTaskCount(in workspace: Workspace) -> Int {
        runningTaskCountByWorkspaceID[workspace.id] ?? 0
    }

    func waitingTaskCount(in workspace: Workspace) -> Int {
        waitingTaskCountByWorkspaceID[workspace.id] ?? 0
    }

    static func isSidebarReviewTask(
        _ task: AgentTask,
        activity: TaskActivityPresentation? = nil
    ) -> Bool {
        if activity?.showsPersistentSidebarGlyph == true { return true }
        return !task.isDone && (
            task.status == .running ||
            KanbanCategory.review.includes(task)
        )
    }

    private static func taskSortsBefore(
        _ lhs: AgentTask,
        _ rhs: AgentTask,
        taskActivities: [UUID: TaskActivityPresentation]
    ) -> Bool {
        let leftPriority = activityPriority(for: taskActivities[lhs.id])
        let rightPriority = activityPriority(for: taskActivities[rhs.id])
        if leftPriority != rightPriority { return leftPriority < rightPriority }
        return lhs.updatedAt > rhs.updatedAt
    }

    /// Flat-list order: the shared tiers first, then unread results ahead of
    /// everything already seen. Tasks mode hides the Unreads dock because the
    /// flat list repeats it — but the dock also *lifted* unread work, so
    /// without this tier a result left unread for three days would sink below
    /// every thread touched since. Workspace drawers keep `taskSortsBefore`:
    /// a drawer is already scoped, and the dock still sits above it.
    private static func flatTaskSortsBefore(
        _ lhs: AgentTask,
        _ rhs: AgentTask,
        taskActivities: [UUID: TaskActivityPresentation],
        stickyUnreadTaskID: UUID?
    ) -> Bool {
        let leftPriority = flatPriority(
            for: lhs,
            activity: taskActivities[lhs.id],
            stickyUnreadTaskID: stickyUnreadTaskID
        )
        let rightPriority = flatPriority(
            for: rhs,
            activity: taskActivities[rhs.id],
            stickyUnreadTaskID: stickyUnreadTaskID
        )
        if leftPriority != rightPriority { return leftPriority < rightPriority }
        return lhs.updatedAt > rhs.updatedAt
    }

    private static func flatPriority(
        for task: AgentTask,
        activity: TaskActivityPresentation?,
        stickyUnreadTaskID: UUID?
    ) -> Int {
        let priority = activityPriority(for: activity)
        guard priority == unrankedActivityPriority else { return priority }
        let ranksAsUnread = ranksAsUnread(
            task,
            activity: activity,
            stickyUnreadTaskID: stickyUnreadTaskID
        )
        return ranksAsUnread ? unrankedActivityPriority : unrankedActivityPriority + 1
    }

    /// Opening a task clears its unread flag, which on its own would drop the
    /// row you just clicked out of the unread tier and slide it down the list
    /// under the cursor. `stickyUnreadTaskID` holds that rank until the
    /// selection moves on.
    private static func ranksAsUnread(
        _ task: AgentTask,
        activity: TaskActivityPresentation?,
        stickyUnreadTaskID: UUID?
    ) -> Bool {
        guard activityPriority(for: activity) == unrankedActivityPriority else { return false }
        return isUnreadTask(task) || task.id == stickyUnreadTaskID
    }

    /// The task whose unread rank the next rebuild should hold: the selected
    /// one, and only if *this* index already ranked it unread. Reading it off
    /// the previous index rather than capturing it at the tap keeps the rule
    /// independent of whether the sidebar observes the selection before or
    /// after the reader marks the task read — and means selecting a task that
    /// was already read never promotes it.
    func heldUnreadRank(forSelected selectedTaskID: UUID?) -> UUID? {
        guard let selectedTaskID, unreadRankedTaskIDs.contains(selectedTaskID) else { return nil }
        return selectedTaskID
    }

    private static let unrankedActivityPriority = 2

    private static func activityPriority(for activity: TaskActivityPresentation?) -> Int {
        guard let activity else { return unrankedActivityPriority }
        if activity.isRunning { return 0 }
        if activity.isWaiting { return 1 }
        return unrankedActivityPriority
    }

    static func isUnreadTask(_ task: AgentTask) -> Bool {
        !task.isDone && task.shouldShowUnread && (
            task.status == .completed ||
            task.status == .pendingUser ||
            task.status == .failed ||
            task.status == .budgetExceeded
        )
    }

    static func taskMatchesSearch(_ task: AgentTask, searchText: String) -> Bool {
        task.title.localizedCaseInsensitiveContains(searchText) ||
            task.goal.localizedCaseInsensitiveContains(searchText)
    }

    /// The flat list also matches on workspace name. That name is the row's
    /// own second line in Tasks mode, so typing a folder has to narrow to
    /// that folder's work — inside a drawer the same query is already
    /// scoped by the workspace row above it.
    static func taskMatchesFlatSearch(_ task: AgentTask, searchText: String) -> Bool {
        taskMatchesSearch(task, searchText: searchText) ||
            task.workspace?.name.localizedCaseInsensitiveContains(searchText) == true
    }
}

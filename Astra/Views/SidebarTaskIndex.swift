import Foundation
import ASTRAModels

struct SidebarTaskIndex {
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

    init(
        tasks: [AgentTask],
        searchText: String,
        taskActivities: [UUID: TaskActivityPresentation] = [:]
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
        var reviewTaskCount = 0

        for task in tasks {
            guard let workspaceID = task.workspace?.id else { continue }
            workspaceIDs.insert(workspaceID)
            let activity = taskActivities[task.id] ?? TaskActivityPresentation.resolve(
                taskID: task.id,
                taskStatus: task.status,
                requests: []
            )
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

            guard Self.isSidebarReviewTask(task, activity: activity) else { continue }

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
        PerformanceTelemetry.logIfNeeded(
            "sidebar_index_build",
            start: start,
            thresholdMilliseconds: PerformanceTelemetry.uiFrameThresholdMilliseconds,
            fields: [
                "task_count": PerformanceTelemetryFields.count(tasks.count),
                "workspace_count": PerformanceTelemetryFields.count(workspaceIDs.count),
                "review_task_count": PerformanceTelemetryFields.count(reviewTaskCount),
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

    private static func activityPriority(for activity: TaskActivityPresentation?) -> Int {
        guard let activity else { return 2 }
        if activity.isRunning { return 0 }
        if activity.isWaiting { return 1 }
        return 2
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
}

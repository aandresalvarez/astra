import Foundation

struct SidebarTaskIndex {
    private let searchText: String
    private let reviewTasksByWorkspaceID: [UUID: [AgentTask]]
    private let matchingReviewTasksByWorkspaceID: [UUID: [AgentTask]]
    private let anyTaskWorkspaceIDs: Set<UUID>

    let pinnedTasks: [AgentTask]
    let unreadTasks: [AgentTask]

    init(tasks: [AgentTask], searchText: String) {
        self.searchText = searchText

        var reviewGroups: [UUID: [AgentTask]] = [:]
        var matchingGroups: [UUID: [AgentTask]] = [:]
        var workspaceIDs = Set<UUID>()
        var pinned: [AgentTask] = []
        var unread: [AgentTask] = []

        for task in tasks {
            guard let workspaceID = task.workspace?.id else { continue }
            workspaceIDs.insert(workspaceID)

            guard Self.isSidebarReviewTask(task) else { continue }

            reviewGroups[workspaceID, default: []].append(task)
            if task.isPinned {
                pinned.append(task)
            }
            if Self.isUnreadTask(task) {
                unread.append(task)
            }
            if searchText.isEmpty || Self.taskMatchesSearch(task, searchText: searchText) {
                matchingGroups[workspaceID, default: []].append(task)
            }
        }

        for workspaceID in reviewGroups.keys {
            reviewGroups[workspaceID]?.sort { $0.updatedAt > $1.updatedAt }
        }
        for workspaceID in matchingGroups.keys {
            matchingGroups[workspaceID]?.sort { $0.updatedAt > $1.updatedAt }
        }

        reviewTasksByWorkspaceID = reviewGroups
        matchingReviewTasksByWorkspaceID = matchingGroups
        anyTaskWorkspaceIDs = workspaceIDs
        pinnedTasks = pinned.sorted { $0.updatedAt > $1.updatedAt }
        unreadTasks = unread.sorted {
            ($0.unreadAt ?? $0.updatedAt) > ($1.unreadAt ?? $1.updatedAt)
        }
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

    static func isSidebarReviewTask(_ task: AgentTask) -> Bool {
        !task.isDone && (
            task.status == .running ||
            KanbanCategory.review.includes(task)
        )
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

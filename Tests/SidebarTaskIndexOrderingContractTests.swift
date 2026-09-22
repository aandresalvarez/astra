import Foundation
import Testing
import ASTRAModels
@testable import ASTRA

/// Pins the order of every list `SidebarTaskIndex` publishes.
///
/// These lists used to be ordered by comparator closures that recomputed each
/// task's sort key on both sides of every comparison. They are now ordered by
/// a key derived once per task. That is only a safe swap if the resulting
/// order is identical, and the existing invariance suite cannot show it: it
/// checks that permuting the *input* gives the same output, which a
/// systematically reversed sort would also satisfy.
///
/// So these assert the order itself — priority ascending, then recency
/// descending — rather than its stability.
@Suite("Sidebar index ordering contract")
struct SidebarTaskIndexOrderingContractTests {
    private func workspace() -> Workspace {
        Workspace(name: "Ordering", primaryPath: "/tmp/ordering")
    }

    private func task(
        _ title: String,
        status: TaskStatus,
        updatedAt: TimeInterval,
        unreadAt: TimeInterval? = nil,
        isPinned: Bool = false,
        isDone: Bool = false,
        in workspace: Workspace
    ) -> AgentTask {
        let task = makeTask(title: title, goal: "Goal \(title)", status: status, workspace: workspace)
        task.updatedAt = Date(timeIntervalSince1970: updatedAt)
        task.unreadAt = unreadAt.map { Date(timeIntervalSince1970: $0) }
        task.isPinned = isPinned
        task.isDone = isDone
        return task
    }

    @Test("Pinned tasks are newest first")
    func pinnedTasksAreNewestFirst() {
        let ws = workspace()
        let tasks = [
            task("oldest", status: .completed, updatedAt: 100, isPinned: true, in: ws),
            task("newest", status: .completed, updatedAt: 300, isPinned: true, in: ws),
            task("middle", status: .completed, updatedAt: 200, isPinned: true, in: ws)
        ]

        let index = SidebarTaskIndex(tasks: tasks, searchText: "")

        #expect(index.pinnedTasks.map(\.title) == ["newest", "middle", "oldest"])
    }

    @Test("Unread tasks fall back to updatedAt when unreadAt is missing")
    func unreadTasksUseUnreadAtThenUpdatedAt() {
        let ws = workspace()
        // `fallback` has no unreadAt, so its updatedAt (500) is its key and it
        // must outrank a task whose unreadAt is older. Sorting on updatedAt
        // alone, or dropping the fallback, reorders these.
        let tasks = [
            task("oldUnread", status: .completed, updatedAt: 900, unreadAt: 100, in: ws),
            task("fallback", status: .completed, updatedAt: 500, in: ws),
            task("newUnread", status: .completed, updatedAt: 100, unreadAt: 900, in: ws)
        ]

        let index = SidebarTaskIndex(tasks: tasks, searchText: "")

        // Only tasks with unreadAt set are unread at all; `fallback` is absent.
        #expect(index.unreadTasks.map(\.title) == ["newUnread", "oldUnread"])
    }

    @Test("The flat list ranks unread above read, then newest first")
    func flatListRanksUnreadThenRecency() {
        let ws = workspace()
        // `readNewest` is the most recently updated task in the list, so it can
        // only come last if priority is applied before recency.
        let tasks = [
            task("readNewest", status: .completed, updatedAt: 900, in: ws),
            task("unreadOlder", status: .completed, updatedAt: 100, unreadAt: 100, in: ws),
            task("unreadNewer", status: .completed, updatedAt: 200, unreadAt: 200, in: ws)
        ]

        let index = SidebarTaskIndex(tasks: tasks, searchText: "")

        #expect(index.allTasks.map(\.title) == ["unreadNewer", "unreadOlder", "readNewest"])
    }

    @Test("A sticky unread selection keeps its rank without reordering the rest")
    func stickyUnreadKeepsItsRank() {
        let ws = workspace()
        let sticky = task("sticky", status: .completed, updatedAt: 150, in: ws)
        let tasks = [
            task("readNewest", status: .completed, updatedAt: 900, in: ws),
            sticky,
            task("unread", status: .completed, updatedAt: 100, unreadAt: 100, in: ws)
        ]

        let index = SidebarTaskIndex(tasks: tasks, searchText: "", stickyUnreadTaskID: sticky.id)

        // `sticky` has no unreadAt, but the held rank puts it in the unread
        // tier — so it leads on recency within that tier (150 > 100), and the
        // newer read task still sorts last.
        #expect(index.allTasks.map(\.title) == ["sticky", "unread", "readNewest"])
        #expect(index.unreadRankedTaskIDs.contains(sticky.id))
    }

    @Test("Active tasks put running work first, then newest")
    func activeTasksRankRunningFirst() {
        let ws = workspace()
        let running = task("running", status: .running, updatedAt: 100, in: ws)
        let runningNewer = task("runningNewer", status: .running, updatedAt: 200, in: ws)
        let tasks = [running, runningNewer]
        let activities = Dictionary(uniqueKeysWithValues: tasks.map {
            ($0.id, TaskActivityPresentation.resolve(taskID: $0.id, taskStatus: $0.status, requests: []))
        })

        let index = SidebarTaskIndex(tasks: tasks, searchText: "", taskActivities: activities)

        #expect(index.activeTasks.map(\.title) == ["runningNewer", "running"])
    }
}

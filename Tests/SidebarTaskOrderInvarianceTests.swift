import Foundation
import Testing
import ASTRAModels
@testable import ASTRA

/// Pins the invariant that made it safe to drop `sort: \AgentTask.queuePosition`
/// from the sidebar, search, and workspace-home queries.
///
/// That sort was ordering on an unindexed column holding 0 for every row, so
/// SwiftData asked SQLite to build a temp B-tree and spill the whole result set
/// — 10+ MB of `goal` text included — to a temp file on every fetch, on the
/// main thread, inside the view transaction. Production stackshots caught 687
/// of 711 main-thread samples inside that sort while the user was typing.
///
/// Deleting it is only safe because every consumer re-sorts in Swift and none
/// of them depend on the order rows arrive in. These tests hold that line: if
/// someone later introduces a consumer that *does* care about fetch order, it
/// fails here rather than by silently reordering the sidebar in production.
@Suite("Sidebar task ordering is invariant to fetch order")
struct SidebarTaskOrderInvarianceTests {
    /// Every comparator in play falls through to `updatedAt`, so distinct
    /// timestamps make the expected output a total order. Ties would make
    /// "same output" untestable rather than untrue.
    private func makeOrderedTasks(workspace: Workspace) -> [AgentTask] {
        let specs: [(String, TaskStatus, Bool, Bool)] = [
            ("Running", .running, false, false),
            ("Pending", .pendingUser, false, false),
            ("Completed", .completed, false, false),
            ("Failed", .failed, false, false),
            ("Cancelled", .cancelled, false, false),
            ("Pinned", .completed, true, false),
            ("Closed", .completed, false, true),
            ("Queued", .queued, false, false),
            ("Draft", .draft, false, false)
        ]
        return specs.enumerated().map { index, spec in
            let task = makeTask(title: spec.0, goal: "Goal \(spec.0)", status: spec.1, workspace: workspace)
            task.isPinned = spec.2
            task.isDone = spec.3
            task.updatedAt = Date(timeIntervalSince1970: 1000 - Double(index * 10))
            if spec.1 == .completed || spec.1 == .failed {
                task.unreadAt = Date(timeIntervalSince1970: 2000 - Double(index * 10))
            }
            // The condition the deleted sort was nominally ordering by: real
            // stores hold 0 here for every row, which is exactly why the sort
            // produced nothing while costing a full external sort.
            task.queuePosition = 0
            return task
        }
    }

    /// Deterministic permutations rather than a shuffle, so a failure is
    /// reproducible instead of intermittent.
    private func permutations(of tasks: [AgentTask]) -> [[AgentTask]] {
        [
            tasks,
            tasks.reversed(),
            Array(tasks.dropFirst(3) + tasks.prefix(3)),
            tasks.enumerated().sorted { lhs, rhs in
                (lhs.offset % 2, lhs.offset) < (rhs.offset % 2, rhs.offset)
            }.map(\.element)
        ]
    }

    @Test("SidebarTaskIndex produces the same lists whatever order tasks arrive in")
    func sidebarIndexIsOrderInvariant() {
        let workspace = makeWorkspace(name: "DEID JSL")
        let tasks = makeOrderedTasks(workspace: workspace)
        let expected = SidebarTaskIndex(tasks: tasks, searchText: "")

        for permuted in permutations(of: tasks) {
            let index = SidebarTaskIndex(tasks: permuted, searchText: "")
            #expect(index.pinnedTasks.map(\.id) == expected.pinnedTasks.map(\.id))
            #expect(index.unreadTasks.map(\.id) == expected.unreadTasks.map(\.id))
            #expect(index.activeTasks.map(\.id) == expected.activeTasks.map(\.id))
            #expect(index.allTasks.map(\.id) == expected.allTasks.map(\.id))
            #expect(index.unreadRankedTaskIDs == expected.unreadRankedTaskIDs)
            #expect(
                index.reviewTasks(for: workspace).map(\.id)
                    == expected.reviewTasks(for: workspace).map(\.id)
            )
        }
    }

    @Test("Search-filtered workspace groups keep their order too")
    func sidebarIndexSearchGroupsAreOrderInvariant() {
        let workspace = makeWorkspace(name: "DEID JSL")
        let tasks = makeOrderedTasks(workspace: workspace)
        let expected = SidebarTaskIndex(tasks: tasks, searchText: "Goal")

        for permuted in permutations(of: tasks) {
            let index = SidebarTaskIndex(tasks: permuted, searchText: "Goal")
            #expect(index.allTasks.map(\.id) == expected.allTasks.map(\.id))
            #expect(
                index.reviewTasks(for: workspace, matchingSearch: true).map(\.id)
                    == expected.reviewTasks(for: workspace, matchingSearch: true).map(\.id)
            )
        }
    }

    @Test("The search overlay ranks the same results whatever order tasks arrive in")
    func searchPanelResultsAreOrderInvariant() {
        let workspace = makeWorkspace(name: "DEID JSL")
        let tasks = makeOrderedTasks(workspace: workspace)
        let expectedRecent = SearchPanelOverlayResults.recentTasks(tasks, workspaces: [workspace])
        let expectedFiltered = SearchPanelOverlayResults.filteredTasks(
            searchText: "Goal",
            tasks: tasks,
            workspaces: [workspace]
        )

        for permuted in permutations(of: tasks) {
            #expect(
                SearchPanelOverlayResults.recentTasks(permuted, workspaces: [workspace]).map(\.id)
                    == expectedRecent.map(\.id)
            )
            #expect(
                SearchPanelOverlayResults.filteredTasks(
                    searchText: "Goal",
                    tasks: permuted,
                    workspaces: [workspace]
                ).map(\.id) == expectedFiltered.map(\.id)
            )
        }
    }

    @Test("Every Kanban lane orders the same whatever order tasks arrive in")
    func kanbanLanesAreOrderInvariant() {
        let workspace = makeWorkspace(name: "DEID JSL")
        let tasks = makeOrderedTasks(workspace: workspace)

        for category in KanbanCategory.allCases {
            let expected = category.sortedTasks(from: tasks.filter { category.includes($0) })
            for permuted in permutations(of: tasks) {
                let actual = category.sortedTasks(from: permuted.filter { category.includes($0) })
                #expect(actual.map(\.id) == expected.map(\.id), "\(category.rawValue) lane reordered")
            }
        }
    }

    /// The Queued lane is the one place that still reads `queuePosition`, and
    /// with every row holding 0 — plus Swift's sort being unstable — its order
    /// was previously whatever the fetch happened to hand it. The `updatedAt`
    /// tiebreaker is what makes the lane above deterministic.
    @Test("The Queued lane falls back to updatedAt when queue positions tie")
    func queuedLaneBreaksTiesByRecency() {
        let workspace = makeWorkspace(name: "DEID JSL")
        let older = makeTask(title: "Older", status: .queued, workspace: workspace)
        older.updatedAt = Date(timeIntervalSince1970: 100)
        let newer = makeTask(title: "Newer", status: .queued, workspace: workspace)
        newer.updatedAt = Date(timeIntervalSince1970: 200)

        #expect(KanbanCategory.queued.sortedTasks(from: [older, newer]).map(\.title) == ["Newer", "Older"])
        #expect(KanbanCategory.queued.sortedTasks(from: [newer, older]).map(\.title) == ["Newer", "Older"])

        // An explicit position still wins over recency, so the field keeps
        // working the day something actually assigns one.
        older.queuePosition = 1
        newer.queuePosition = 2
        #expect(KanbanCategory.queued.sortedTasks(from: [newer, older]).map(\.title) == ["Older", "Newer"])
    }
}

import Foundation
import Testing
import ASTRAModels
@testable import ASTRA

@Suite("Sidebar browse mode")
struct SidebarBrowseModeTests {
    @Test("An unknown stored raw value falls back to the workspace list")
    func unknownRawValueFallsBackToWorkspaces() {
        #expect(SidebarBrowseMode.resolve("tasks") == .tasks)
        #expect(SidebarBrowseMode.resolve("workspaces") == .workspaces)
        #expect(SidebarBrowseMode.resolve("kanban") == .workspaces)
        #expect(SidebarBrowseMode.resolve("") == .workspaces)
    }

    @Test("The two modes alternate behind one unchanging glyph")
    func modesAlternate() {
        #expect(SidebarBrowseMode.workspaces.toggled == .tasks)
        #expect(SidebarBrowseMode.tasks.toggled == .workspaces)
        #expect(SidebarBrowseMode.workspaces.sectionTitle == "Workspaces")
        #expect(SidebarBrowseMode.tasks.sectionTitle == "Tasks")
        // One glyph in both modes: a switch that swapped its icon read as a
        // second workspace control rather than a way out of one. Only the
        // wording advertises the destination.
        #expect(SidebarBrowseModePresentation.switchGlyph == "arrow.left.arrow.right")
        #expect(SidebarBrowseModePresentation.switchHelpText(from: .workspaces) == "Show all tasks")
        #expect(SidebarBrowseModePresentation.switchHelpText(from: .tasks) == "Group by workspace")
    }

    @Test("Workspace sort and the starred filter belong to the folder list only")
    func listControlsAreWorkspaceOnly() {
        #expect(SidebarBrowseMode.workspaces.showsWorkspaceListControls)
        #expect(!SidebarBrowseMode.tasks.showsWorkspaceListControls)
    }

    @Test("Activity and Unreads dock only over the folder list")
    func crossWorkspaceDocksAreWorkspaceOnly() {
        // The flat list is already the cross-workspace surface both docks
        // exist to provide, so in Tasks mode they would repeat the rows
        // directly beneath them.
        #expect(SidebarBrowseMode.workspaces.showsCrossWorkspaceDocks)
        #expect(!SidebarBrowseMode.tasks.showsCrossWorkspaceDocks)
    }

    @Test("The flat list files closed work away and keeps the unreachable rest")
    func flatListHidesClosedWorkButKeepsWhatDrawersCannotShow() {
        let workspace = makeWorkspace(name: "DEID JSL")

        // Closed work is filed, not pending. Drawers hide it and so does this
        // list — a few hundred finished threads bury the handful that still
        // need someone.
        let closed = makeTask(title: "Closed", status: .completed, workspace: workspace)
        closed.isDone = true
        closed.updatedAt = Date(timeIntervalSince1970: 100)

        // A draft is in-composition state, not delegated work; the board hides
        // every one of them (`TaskHygiene.isHiddenFromBoard`), and a flat list
        // that showed them would be the one surface leaking them back.
        let draft = makeTask(title: "Draft", status: .draft, workspace: workspace)
        draft.updatedAt = Date(timeIntervalSince1970: 150)

        // Pinned tasks are lifted out of their workspace's list to avoid a
        // double render there; the flat list is the complete open inventory,
        // and the row's pin glyph marks it.
        let pinned = makeTask(title: "Pinned", status: .completed, workspace: workspace)
        pinned.isPinned = true
        pinned.updatedAt = Date(timeIntervalSince1970: 200)

        // No workspace at all: no drawer exists that could ever list it.
        let orphan = makeTask(title: "Orphan", status: .completed, workspace: nil)
        orphan.updatedAt = Date(timeIntervalSince1970: 300)

        let index = SidebarTaskIndex(tasks: [closed, draft, pinned, orphan], searchText: "")

        #expect(index.reviewTasks(for: workspace).isEmpty)
        #expect(Set(index.allTasks.map(\.id)) == Set([pinned.id, orphan.id]))
    }

    @Test("A closed task with a live follow-up stays in the flat list")
    func flatListKeepsClosedTasksWithLiveWork() {
        let workspace = makeWorkspace(name: "Starr Data Lake")
        // Closing a task does not retract a follow-up already sent from it:
        // the run keeps going with `isDone` still true.
        let closedButRunning = makeTask(title: "Follow-up running", status: .completed, workspace: workspace)
        closedButRunning.isDone = true
        let closedAndIdle = makeTask(title: "Closed", status: .completed, workspace: workspace)
        closedAndIdle.isDone = true

        let index = SidebarTaskIndex(
            tasks: [closedButRunning, closedAndIdle],
            searchText: "",
            taskActivities: [closedButRunning.id: activity(closedButRunning, kind: .running)]
        )

        // Tasks mode has no Activity dock any more, so dropping this row on
        // the `isDone` flag alone would leave the run with nowhere to appear.
        #expect(index.allTasks.map(\.id) == [closedButRunning.id])
    }

    @Test("The flat list puts live work first, then most recently updated")
    func flatListSortsLiveWorkFirst() {
        let workspace = makeWorkspace(name: "Starr Data Lake")
        let newestIdle = makeTask(title: "Newest idle", status: .completed, workspace: workspace)
        newestIdle.updatedAt = Date(timeIntervalSince1970: 900)
        let olderIdle = makeTask(title: "Older idle", status: .completed, workspace: workspace)
        olderIdle.updatedAt = Date(timeIntervalSince1970: 100)
        let waiting = makeTask(title: "Waiting", status: .queued, workspace: workspace)
        waiting.updatedAt = Date(timeIntervalSince1970: 200)
        let running = makeTask(title: "Running", status: .running, workspace: workspace)
        running.updatedAt = Date(timeIntervalSince1970: 300)

        let index = SidebarTaskIndex(
            tasks: [olderIdle, newestIdle, waiting, running],
            searchText: "",
            taskActivities: [
                running.id: activity(running, kind: .running),
                waiting.id: activity(waiting, kind: .waitingForWorker)
            ]
        )

        #expect(index.allTasks.map(\.id) == [running.id, waiting.id, newestIdle.id, olderIdle.id])
    }

    @Test("The flat list lifts unread results above threads already seen")
    func flatListLiftsUnreadResults() {
        let workspace = makeWorkspace(name: "PCORnet data Curation")
        // Touched today, nothing waiting on you.
        let recentlyRead = makeTask(title: "Recently read", status: .completed, workspace: workspace)
        recentlyRead.updatedAt = Date(timeIntervalSince1970: 900)
        // Finished three days ago and never opened. With the Unreads dock
        // hidden in this mode, only the sort keeps it reachable.
        let staleUnread = makeTask(title: "Stale unread", status: .completed, workspace: workspace)
        staleUnread.updatedAt = Date(timeIntervalSince1970: 100)
        staleUnread.unreadAt = Date(timeIntervalSince1970: 100)

        let index = SidebarTaskIndex(tasks: [recentlyRead, staleUnread], searchText: "")

        #expect(index.allTasks.map(\.id) == [staleUnread.id, recentlyRead.id])
        // Live work still outranks unread: the dock never reordered that.
        let running = makeTask(title: "Running", status: .running, workspace: workspace)
        running.updatedAt = Date(timeIntervalSince1970: 1)
        let withLiveWork = SidebarTaskIndex(
            tasks: [recentlyRead, staleUnread, running],
            searchText: "",
            taskActivities: [running.id: activity(running, kind: .running)]
        )
        #expect(withLiveWork.allTasks.map(\.id) == [running.id, staleUnread.id, recentlyRead.id])
    }

    @Test("Opening an unread task does not slide it down the flat list")
    func openingAnUnreadTaskHoldsItsRank() {
        let workspace = makeWorkspace(name: "PCORnet data Curation")
        let recentlyRead = makeTask(title: "Recently read", status: .completed, workspace: workspace)
        recentlyRead.updatedAt = Date(timeIntervalSince1970: 900)
        let staleUnread = makeTask(title: "Stale unread", status: .completed, workspace: workspace)
        staleUnread.updatedAt = Date(timeIntervalSince1970: 100)
        staleUnread.unreadAt = Date(timeIntervalSince1970: 100)

        let beforeOpening = SidebarTaskIndex(tasks: [recentlyRead, staleUnread], searchText: "")
        #expect(beforeOpening.allTasks.map(\.id) == [staleUnread.id, recentlyRead.id])

        // Clicking the row selects it and the reader marks it read, which on
        // its own demotes it out of the unread tier.
        let held = beforeOpening.heldUnreadRank(forSelected: staleUnread.id)
        #expect(held == staleUnread.id)
        staleUnread.markRead()

        let whileSelected = SidebarTaskIndex(
            tasks: [recentlyRead, staleUnread],
            searchText: "",
            stickyUnreadTaskID: held
        )
        #expect(whileSelected.allTasks.map(\.id) == [staleUnread.id, recentlyRead.id])
        // The hold renews itself for as long as the row stays selected.
        #expect(whileSelected.heldUnreadRank(forSelected: staleUnread.id) == staleUnread.id)

        // Selection moves on: no hold, so it takes its real place by recency.
        let afterMovingOn = SidebarTaskIndex(
            tasks: [recentlyRead, staleUnread],
            searchText: "",
            stickyUnreadTaskID: whileSelected.heldUnreadRank(forSelected: recentlyRead.id)
        )
        #expect(afterMovingOn.allTasks.map(\.id) == [recentlyRead.id, staleUnread.id])
    }

    @Test("Selecting a task that was already read never promotes it")
    func selectingAReadTaskDoesNotPromoteIt() {
        let workspace = makeWorkspace(name: "Starr Data Lake")
        let newest = makeTask(title: "Newest", status: .completed, workspace: workspace)
        newest.updatedAt = Date(timeIntervalSince1970: 900)
        let oldRead = makeTask(title: "Old and read", status: .completed, workspace: workspace)
        oldRead.updatedAt = Date(timeIntervalSince1970: 100)

        let index = SidebarTaskIndex(tasks: [newest, oldRead], searchText: "")

        // Clicking something buried must not fling it upward either — the
        // hold only ever preserves a rank the row already had.
        #expect(index.heldUnreadRank(forSelected: oldRead.id) == nil)
        #expect(index.allTasks.map(\.id) == [newest.id, oldRead.id])
    }

    @Test("A running task outranks a held unread row")
    func liveWorkStillOutranksAHeldRow() {
        let workspace = makeWorkspace(name: "DEID JSL")
        let openedUnread = makeTask(title: "Just opened", status: .completed, workspace: workspace)
        openedUnread.updatedAt = Date(timeIntervalSince1970: 100)
        let running = makeTask(title: "Running", status: .running, workspace: workspace)
        running.updatedAt = Date(timeIntervalSince1970: 1)

        let index = SidebarTaskIndex(
            tasks: [openedUnread, running],
            searchText: "",
            taskActivities: [running.id: activity(running, kind: .running)],
            stickyUnreadTaskID: openedUnread.id
        )

        #expect(index.allTasks.map(\.id) == [running.id, openedUnread.id])
        // A live row is ranked by its activity, so it is never the held one.
        #expect(!index.unreadRankedTaskIDs.contains(running.id))
    }

    @Test("Searching the flat list matches title, goal, and workspace name")
    func flatListSearchMatchesWorkspaceName() {
        let deid = makeWorkspace(name: "DEID JSL")
        let other = makeWorkspace(name: "Starr Data Lake")
        let byTitle = makeTask(title: "Benchmarks Tide 2", goal: "Unrelated", status: .completed, workspace: other)
        let byGoal = makeTask(title: "Unrelated", goal: "Run the benchmarks", status: .completed, workspace: other)
        // The workspace name is this row's own second line in Tasks mode, so
        // typing a folder has to narrow to that folder's work.
        let byWorkspace = makeTask(title: "Cutoff question", goal: "Unrelated", status: .completed, workspace: deid)
        let unmatched = makeTask(title: "Unrelated", goal: "Unrelated", status: .completed, workspace: other)

        let benchmarks = SidebarTaskIndex(
            tasks: [byTitle, byGoal, byWorkspace, unmatched],
            searchText: "benchmark"
        )
        #expect(Set(benchmarks.allTasks.map(\.id)) == Set([byTitle.id, byGoal.id]))

        let folder = SidebarTaskIndex(
            tasks: [byTitle, byGoal, byWorkspace, unmatched],
            searchText: "deid"
        )
        #expect(folder.allTasks.map(\.id) == [byWorkspace.id])
    }

    @Test("A live task off the flat list hands its signal to the section header")
    func hiddenLiveTaskSignalsFromHeader() {
        let visibleRunning = activity(id: UUID(), kind: .running)
        let filteredWaiting = activity(id: UUID(), kind: .waitingForWorker)
        let idle = activity(id: UUID(), kind: .idle)
        let all = [visibleRunning, filteredWaiting, idle]
        let visibleIDs: Set<UUID> = [visibleRunning.taskID, idle.taskID]

        // Expanded: the running row speaks for itself, the filtered-out
        // waiting task cannot, so only the latter reaches the header.
        #expect(
            SidebarLivenessSignal.headerActivityCounts(
                taskActivities: all,
                visibleTaskIDs: visibleIDs,
                isSectionExpanded: true
            ) == SidebarWorkspaceActivityCounts(running: 0, waiting: 1)
        )

        // Collapsed: no row can signal, so the header owns all live work.
        #expect(
            SidebarLivenessSignal.headerActivityCounts(
                taskActivities: all,
                visibleTaskIDs: visibleIDs,
                isSectionExpanded: false
            ) == SidebarWorkspaceActivityCounts(running: 1, waiting: 1)
        )
    }

    private func activity(_ task: AgentTask, kind: TaskActivityPresentation.Kind) -> TaskActivityPresentation {
        activity(id: task.id, kind: kind)
    }

    private func activity(id: UUID, kind: TaskActivityPresentation.Kind) -> TaskActivityPresentation {
        TaskActivityPresentation(taskID: id, kind: kind, request: nil)
    }
}

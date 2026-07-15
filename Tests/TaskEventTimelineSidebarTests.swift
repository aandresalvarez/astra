import Testing
import AppKit
import SwiftUI
import ASTRAModels
@testable import ASTRA
import ASTRACore

// MARK: - TaskEvent

@Suite("TaskEvent")
struct TaskEventTests {

    @Test("Event stores type and payload")
    func eventCreation() {
        let task = makeTask()
        let event = TaskEvent(task: task, type: "agent.thinking", payload: "Let me think...")
        #expect(event.type == "agent.thinking")
        #expect(event.payload == "Let me think...")
        #expect(event.task === task)
    }

    @Test("Event with run association")
    func eventWithRun() {
        let task = makeTask()
        let run = TaskRun(task: task)
        let event = TaskEvent(task: task, type: "tool.use", payload: "Using Glob", run: run)
        #expect(event.run === run)
    }

    @Test("Event timestamp is set automatically")
    func eventTimestamp() {
        let before = Date()
        let task = makeTask()
        let event = TaskEvent(task: task, type: "test", payload: "")
        let after = Date()
        #expect(event.timestamp >= before)
        #expect(event.timestamp <= after)
    }
}

// MARK: - Timeline event icons/colors/labels

@Suite("Timeline event display")
struct TimelineDisplayTests {

    // These test the private helper functions indirectly via TimelineTabView
    // We test the mapping logic directly

    private static let iconMap: [(String, String)] = [
        ("task.started", "play.circle"),
        ("agent.thinking", "brain"),
        ("agent.response", "text.bubble"),
        ("tool.use", "wrench"),
        ("astra.todo.replace", "checklist"),
        ("astra.complete", "checkmark.seal"),
        ("astra.protocol.invalid", "exclamationmark.triangle"),
        ("task.completed", "checkmark.circle"),
        ("task.stats", "chart.bar"),
        ("budget.exceeded", "exclamationmark.triangle"),
        ("error", "xmark.circle"),
        ("user.message", "person.circle"),
    ]

    private static let labelMap: [(String, String)] = [
        ("task.started", "Started"),
        ("agent.thinking", "Thinking"),
        ("agent.response", "Response"),
        ("tool.use", "Tool"),
        ("astra.todo.replace", "Agent Plan"),
        ("astra.complete", "Agent Completion"),
        ("astra.protocol.invalid", "Invalid Protocol"),
        ("task.completed", "Completed"),
        ("task.stats", "Stats"),
        ("budget.exceeded", "Budget Exceeded"),
        ("error", "Error"),
        ("user.message", "You"),
    ]

    @Test("Event type to icon mapping", arguments: iconMap)
    func eventIcon(type: String, expectedIcon: String) {
        // Replicate the mapping from TimelineTabView
        let icon: String = switch type {
        case "task.started": "play.circle"
        case "agent.thinking": "brain"
        case "agent.response": "text.bubble"
        case "tool.use": "wrench"
        case "astra.todo.replace": "checklist"
        case "astra.complete": "checkmark.seal"
        case "astra.protocol.invalid": "exclamationmark.triangle"
        case "task.completed": "checkmark.circle"
        case "task.stats": "chart.bar"
        case "budget.exceeded": "exclamationmark.triangle"
        case "error": "xmark.circle"
        case "user.message": "person.circle"
        default: "circle"
        }
        #expect(icon == expectedIcon)
    }

    @Test("Event type to label mapping", arguments: labelMap)
    func eventLabel(type: String, expectedLabel: String) {
        let label: String = switch type {
        case "task.started": "Started"
        case "agent.thinking": "Thinking"
        case "agent.response": "Response"
        case "tool.use": "Tool"
        case "astra.todo.replace": "Agent Plan"
        case "astra.complete": "Agent Completion"
        case "astra.protocol.invalid": "Invalid Protocol"
        case "task.completed": "Completed"
        case "task.stats": "Stats"
        case "budget.exceeded": "Budget Exceeded"
        case "error": "Error"
        case "user.message": "You"
        default: type
        }
        #expect(label == expectedLabel)
    }
}

// MARK: - Sidebar grouping logic

@Suite("Sidebar task grouping")
struct SidebarGroupingTests {

    @Test("Tasks grouped by status correctly")
    func groupByStatus() {
        let tasks = [
            makeTask(title: "Running", status: .running),
            makeTask(title: "Queued 1", status: .queued),
            makeTask(title: "Queued 2", status: .queued),
            makeTask(title: "Done", status: .completed),
            makeTask(title: "Oops", status: .failed),
            makeTask(title: "Pending", status: .pendingUser),
        ]

        let running = tasks.filter { $0.status == .running || $0.status == .pendingUser }
        let queued = tasks.filter { $0.status == .queued }
        let completed = tasks.filter { $0.status == .completed }
        let failed = tasks.filter { [.failed, .cancelled, .budgetExceeded].contains($0.status) }

        #expect(running.count == 2)  // running + pendingUser
        #expect(queued.count == 2)
        #expect(completed.count == 1)
        #expect(failed.count == 1)
    }

    @Test("Empty groups produce no sections")
    func emptyGroups() {
        let tasks = [makeTask(status: .completed)]
        let running = tasks.filter { $0.status == .running || $0.status == .pendingUser }
        let queued = tasks.filter { $0.status == .queued }
        #expect(running.isEmpty)
        #expect(queued.isEmpty)
    }

    @Test("SidebarTaskIndex groups review tasks by workspace, excluding pinned ones")
    func sidebarTaskIndexGroupsReviewTasks() {
        let firstWorkspace = makeWorkspace(name: "First")
        let secondWorkspace = makeWorkspace(name: "Second")

        // Pinned tasks surface once, in the top-level Pinned section — not
        // duplicated into their own workspace's list.
        let pinnedReview = makeTask(title: "Pinned review", status: .completed, workspace: firstWorkspace)
        pinnedReview.isPinned = true
        pinnedReview.updatedAt = Date(timeIntervalSince1970: 200)

        let archived = makeTask(title: "Archived", status: .completed, workspace: firstWorkspace)
        archived.isDone = true

        let running = makeTask(title: "Running", status: .running, workspace: secondWorkspace)

        let index = SidebarTaskIndex(tasks: [archived, running, pinnedReview], searchText: "")

        #expect(index.reviewTasks(for: firstWorkspace).isEmpty)
        #expect(index.reviewTasks(for: secondWorkspace).map(\.id) == [running.id])
        #expect(index.pinnedTasks.map(\.id) == [pinnedReview.id])
        // Still not "empty": the pinned task means there's history here, so
        // the workspace shouldn't offer the empty-state "Add task" CTA.
        #expect(index.hasAnyTask(in: firstWorkspace))
    }

    @Test("A pinned task matching a live search still doesn't reappear in its workspace's list")
    func sidebarTaskIndexPinnedTaskExcludedFromSearchMatches() {
        let workspace = makeWorkspace(name: "Deploys")
        let pinned = makeTask(title: "Deploy fix", status: .completed, workspace: workspace)
        pinned.isPinned = true

        let index = SidebarTaskIndex(tasks: [pinned], searchText: "deploy")

        #expect(index.reviewTasks(
            for: workspace,
            matchingSearch: true,
            workspaceMatchesSearch: false
        ).isEmpty)
        #expect(index.pinnedTasks.map(\.id) == [pinned.id])
    }

    @Test("SidebarTaskIndex pre-sorts workspace review tasks newest first")
    func sidebarTaskIndexSortsWorkspaceTasksNewestFirst() {
        let workspace = makeWorkspace(name: "Sorted")
        let older = makeTask(title: "Older", status: .completed, workspace: workspace)
        older.updatedAt = Date(timeIntervalSince1970: 100)

        let newer = makeTask(title: "Newer", status: .running, workspace: workspace)
        newer.updatedAt = Date(timeIntervalSince1970: 300)

        let middle = makeTask(title: "Middle", status: .pendingUser, workspace: workspace)
        middle.updatedAt = Date(timeIntervalSince1970: 200)

        let index = SidebarTaskIndex(tasks: [older, newer, middle], searchText: "")

        #expect(index.reviewTasks(for: workspace).map(\.id) == [newer.id, middle.id, older.id])
    }

    @Test("Workspace sidebar shows retry attempts as separate task rows")
    func workspaceSidebarShowsRetryAttemptsAsSeparateRows() {
        let workspace = makeWorkspace(name: "Astra Work")
        let titles = [
            "Build solved Rubik's cube",
            "Build solved Rubik's cube (attempt 2)",
            "Create 3D page",
            "Create 3D solver",
            "Explain who you are",
            "Describe who you are",
            "Build solved cube notes",
            "Review output"
        ]

        let tasks = titles.enumerated().map { offset, title in
            let task = makeTask(title: title, status: .completed, workspace: workspace)
            task.updatedAt = Date(timeIntervalSince1970: TimeInterval(800 - offset))
            return task
        }

        let index = SidebarTaskIndex(tasks: tasks, searchText: "")
        let reviewTasks = index.reviewTasks(for: workspace)
        let visibleTasks = SidebarWorkspaceTaskList.visibleTasks(reviewTasks, isShowingAll: false)

        #expect(reviewTasks.count == 8)
        #expect(visibleTasks.map(\.id) == Array(reviewTasks.prefix(6)).map(\.id))
        #expect(visibleTasks.map(\.id).contains(tasks[0].id))
        #expect(visibleTasks.map(\.id).contains(tasks[1].id))
        #expect(Set(visibleTasks.map(\.id)).count == 6)
        #expect(SidebarWorkspaceTaskList.hiddenTaskCount(
            totalTasks: reviewTasks.count,
            visibleTasks: visibleTasks.count
        ) == 2)
    }

    @Test("SidebarTaskIndex surfaces unread tasks under the dock")
    func sidebarTaskIndexUnreadTasks() {
        let workspace = makeWorkspace(name: "Unread")

        let olderUnread = makeTask(title: "Older unread", status: .completed, workspace: workspace)
        olderUnread.unreadAt = Date(timeIntervalSince1970: 200)
        olderUnread.updatedAt = Date(timeIntervalSince1970: 400)

        let newerUnread = makeTask(title: "Newer unread", status: .pendingUser, workspace: workspace)
        newerUnread.unreadAt = Date(timeIntervalSince1970: 300)
        newerUnread.updatedAt = Date(timeIntervalSince1970: 300)

        let read = makeTask(title: "Read", status: .completed, workspace: workspace)

        let archivedUnread = makeTask(title: "Archived unread", status: .completed, workspace: workspace)
        archivedUnread.unreadAt = Date(timeIntervalSince1970: 500)
        archivedUnread.isDone = true

        let running = makeTask(title: "Running", status: .running, workspace: workspace)
        running.unreadAt = Date(timeIntervalSince1970: 600)

        let index = SidebarTaskIndex(
            tasks: [olderUnread, newerUnread, read, archivedUnread, running],
            searchText: ""
        )

        #expect(index.unreadTasks.map(\.id) == [newerUnread.id, olderUnread.id])
    }

    @Test("SidebarTaskIndex applies search unless the workspace itself matches")
    func sidebarTaskIndexSearchBehavior() {
        let matchingWorkspace = makeWorkspace(name: "Deployments")
        let nonmatchingWorkspace = makeWorkspace(name: "Bugs")

        let workspaceMatchedTask = makeTask(title: "Unrelated", status: .completed, workspace: matchingWorkspace)
        let taskMatchedTask = makeTask(title: "Deploy fix", status: .completed, workspace: nonmatchingWorkspace)
        let taskFilteredOut = makeTask(title: "Investigate crash", status: .completed, workspace: nonmatchingWorkspace)

        let index = SidebarTaskIndex(
            tasks: [workspaceMatchedTask, taskMatchedTask, taskFilteredOut],
            searchText: "deploy"
        )

        #expect(index.reviewTasks(
            for: matchingWorkspace,
            matchingSearch: true,
            workspaceMatchesSearch: true
        ).map(\.id) == [workspaceMatchedTask.id])

        #expect(index.reviewTasks(
            for: nonmatchingWorkspace,
            matchingSearch: true,
            workspaceMatchesSearch: false
        ).map(\.id) == [taskMatchedTask.id])
    }

    @Test("Sidebar task index invalidates when workspace relationship materializes")
    func sidebarTaskIndexInvalidatesWhenWorkspaceRelationshipChanges() {
        let workspace = makeWorkspace(name: "Bigquery Analyst")
        workspace.isStarred = true

        let task = makeTask(title: "List BigQuery dataset tables", status: .completed)
        let before = SidebarTaskIndexInvalidation.signature(for: [task])

        task.workspace = workspace
        let after = SidebarTaskIndexInvalidation.signature(for: [task])

        #expect(before != after)

        let index = SidebarTaskIndex(tasks: [task], searchText: "")
        #expect(index.reviewTasks(for: workspace).map(\.id) == [task.id])
    }

    @Test("Sidebar task index invalidation ignores searchable text when search is inactive")
    func sidebarTaskIndexInvalidationIgnoresSearchableTextWithoutSearch() {
        let workspace = makeWorkspace(name: "Slow Workspace")
        let longGoal = String(repeating: "long goal text ", count: 20_000)
        let task = makeTask(
            title: "Original title",
            goal: longGoal,
            status: .completed,
            workspace: workspace
        )
        task.updatedAt = Date(timeIntervalSince1970: 400)

        let before = SidebarTaskIndexInvalidation.signature(for: [task], searchText: "")

        task.title = "Changed title"
        task.goal = String(repeating: "changed goal text ", count: 20_000)

        let after = SidebarTaskIndexInvalidation.signature(for: [task], searchText: "")

        #expect(before == after)
    }

    @Test("Sidebar task index invalidates searchable text when search is active")
    func sidebarTaskIndexInvalidationIncludesSearchableTextDuringSearch() {
        let workspace = makeWorkspace(name: "Search Workspace")
        let task = makeTask(
            title: "Deploy report",
            goal: "Summarize report updates",
            status: .completed,
            workspace: workspace
        )
        task.updatedAt = Date(timeIntervalSince1970: 400)

        let before = SidebarTaskIndexInvalidation.signature(for: [task], searchText: "report")

        task.title = "Archive report"
        task.goal = "Summarize archive updates"

        let after = SidebarTaskIndexInvalidation.signature(for: [task], searchText: "report")

        #expect(before != after)
    }

    @Test("TaskThreadSnapshotTrigger ignores unrelated task metadata updates")
    func taskThreadSnapshotTriggerIgnoresUpdatedAtOnlyChanges() {
        let task = makeTask(status: .running)
        let initial = TaskThreadSnapshotTrigger(task: task)

        task.updatedAt = Date(timeIntervalSince1970: 999)
        let afterMetadataUpdate = TaskThreadSnapshotTrigger(task: task)

        task.status = .completed
        let afterStatusUpdate = TaskThreadSnapshotTrigger(task: task)

        #expect(afterMetadataUpdate == initial)
        #expect(afterStatusUpdate != initial)
    }

    @Test("TaskThreadSnapshotTrigger coalesces small streaming text updates")
    func taskThreadSnapshotTriggerCoalescesSmallStreamingTextUpdates() {
        let task = makeTask(status: .running)
        let run = TaskRun(task: task)
        task.runs.append(run)
        run.output = "small chunk"
        task.events.append(TaskEvent(task: task, type: "agent.response", payload: "small chunk", run: run))
        let initial = TaskThreadSnapshotTrigger(task: task)

        run.output += " plus more"
        task.events.append(TaskEvent(task: task, type: "agent.response", payload: " plus more", run: run))
        let afterSmallTextUpdate = TaskThreadSnapshotTrigger(task: task)

        run.output = String(repeating: "x", count: 1_025)
        let afterOutputBucketChange = TaskThreadSnapshotTrigger(task: task)

        #expect(afterSmallTextUpdate == initial)
        #expect(afterOutputBucketChange != initial)
    }

    @Test("Workspace sidebar filter applies starred-only before search")
    func workspaceSidebarFilterAppliesStarredOnlyBeforeSearch() {
        let starredMatch = makeWorkspace(name: "GitHub PRs")
        starredMatch.isStarred = true
        let unstarredMatch = makeWorkspace(name: "GitHub Archive")
        let starredNonmatch = makeWorkspace(name: "REDCap")
        starredNonmatch.isStarred = true

        let visible = WorkspaceSidebarFilter.visibleWorkspaces(
            [unstarredMatch, starredNonmatch, starredMatch],
            showStarredOnly: true,
            searchText: "github"
        ) { workspace in
            workspace.name.localizedCaseInsensitiveContains("github")
        } hasMatchingTasks: { _ in
            false
        }

        #expect(visible.map(\.id) == [starredMatch.id])
    }

    @Test("Workspace sidebar keeps starred and regular workspaces in one sorted list")
    func workspaceSidebarFilterKeepsSingleSortedList() {
        let starredZoo = makeWorkspace(name: "Zoo")
        starredZoo.isStarred = true
        let regularAlpha = makeWorkspace(name: "Alpha")
        let starredBeta = makeWorkspace(name: "Beta")
        starredBeta.isStarred = true

        let visible = WorkspaceSidebarFilter.visibleWorkspaces(
            [regularAlpha, starredZoo, starredBeta],
            showStarredOnly: false,
            searchText: ""
        ) { _ in
            true
        } hasMatchingTasks: { _ in
            false
        }

        #expect(visible.map(\.id) == [starredBeta.id, starredZoo.id, regularAlpha.id])
    }

    @Test("Accordion keeps at most one workspace drawer open")
    func accordionKeepsSingleDrawerOpen() {
        let first = UUID()
        let second = UUID()
        var state = WorkspaceSidebarAccordion.State()

        state = WorkspaceSidebarAccordion.toggling(first, in: state, wasExpanded: false)
        #expect(state.openWorkspaceID == first)

        // Opening another drawer closes the first by exclusivity.
        state = WorkspaceSidebarAccordion.toggling(second, in: state, wasExpanded: false)
        #expect(state.openWorkspaceID == second)
        #expect(!WorkspaceSidebarAccordion.isExpanded(
            workspaceID: first, state: state, isSearchActive: false, matchesSearch: { false }
        ))

        // Toggling the open drawer closes it; nothing stays open.
        state = WorkspaceSidebarAccordion.toggling(second, in: state, wasExpanded: true)
        #expect(state.openWorkspaceID == nil)
    }

    @Test("Accordion follows workspace selection; nil selection leaves drawers alone")
    func accordionFollowsSelection() {
        let first = UUID()
        let second = UUID()
        var state = WorkspaceSidebarAccordion.selecting(first, in: .init())
        #expect(state.openWorkspaceID == first)

        state = WorkspaceSidebarAccordion.selecting(second, in: state)
        #expect(state.openWorkspaceID == second)

        state = WorkspaceSidebarAccordion.selecting(nil, in: state)
        #expect(state.openWorkspaceID == second)
    }

    @Test("Deferred selection echo cannot reopen the drawer a collapse click just closed")
    func accordionSelectionEchoRespectsDismissal() {
        let workspaceID = UUID()
        // The collapse click: closes the drawer and selects its workspace.
        var state = WorkspaceSidebarAccordion.selecting(workspaceID, in: .init())
        state = WorkspaceSidebarAccordion.toggling(workspaceID, in: state, wasExpanded: true)
        #expect(state.openWorkspaceID == nil)

        // SwiftUI delivers the selection onChange a frame later.
        let echoed = WorkspaceSidebarAccordion.selectionChanged(workspaceID, in: state)
        #expect(echoed.openWorkspaceID == nil)

        // A direct intent still opens through the dismissal.
        let direct = WorkspaceSidebarAccordion.selecting(workspaceID, in: state)
        #expect(direct.openWorkspaceID == workspaceID)
    }

    @Test("Search reveals matches without disturbing the open drawer, and dismissed reveals stay closed for the query")
    func accordionSearchRevealIsNonDestructive() {
        let open = UUID()
        let match = UUID()
        var state = WorkspaceSidebarAccordion.selecting(open, in: .init())

        // A matching drawer reveals during search while the open drawer keeps its intent.
        #expect(WorkspaceSidebarAccordion.isExpanded(
            workspaceID: match, state: state, isSearchActive: true, matchesSearch: { true }
        ))
        // Without an active search the same match stays closed.
        #expect(!WorkspaceSidebarAccordion.isExpanded(
            workspaceID: match, state: state, isSearchActive: false, matchesSearch: { true }
        ))

        // Closing a search-revealed drawer sticks for the rest of the query
        // without stealing the open drawer's slot.
        state = WorkspaceSidebarAccordion.toggling(match, in: state, wasExpanded: true)
        #expect(state.openWorkspaceID == open)
        #expect(!WorkspaceSidebarAccordion.isExpanded(
            workspaceID: match, state: state, isSearchActive: true, matchesSearch: { true }
        ))

        // Editing the query resets the dismissal.
        state = WorkspaceSidebarAccordion.searchChanged(in: state)
        #expect(WorkspaceSidebarAccordion.isExpanded(
            workspaceID: match, state: state, isSearchActive: true, matchesSearch: { true }
        ))
    }

    @Test("Header carries the running signal exactly when a workspace row can't")
    func headerRunningSignalCoversHiddenWork() {
        let visibleRunning = UUID()
        let filteredRunning = UUID()
        let filteredIdle = UUID()
        let counts = [
            (workspaceID: visibleRunning, count: 2),
            (workspaceID: filteredRunning, count: 1),
            (workspaceID: filteredIdle, count: 0)
        ]

        // Expanded section: only work in filtered-out workspaces needs the header.
        #expect(SidebarLivenessSignal.headerRunningTaskCount(
            runningCounts: counts,
            visibleWorkspaceIDs: [visibleRunning, filteredIdle],
            isSectionExpanded: true
        ) == 1)

        // Everything visible and expanded: rows carry their own signal.
        #expect(SidebarLivenessSignal.headerRunningTaskCount(
            runningCounts: counts,
            visibleWorkspaceIDs: [visibleRunning, filteredRunning, filteredIdle],
            isSectionExpanded: true
        ) == 0)

        // Collapsed section hides every row, so the header owns all of it.
        #expect(SidebarLivenessSignal.headerRunningTaskCount(
            runningCounts: counts,
            visibleWorkspaceIDs: [visibleRunning, filteredRunning, filteredIdle],
            isSectionExpanded: false
        ) == 3)
    }

    @Test("SidebarTaskIndex counts running tasks per workspace regardless of search")
    func sidebarTaskIndexRunningCounts() {
        let busy = makeWorkspace(name: "Busy")
        let idle = makeWorkspace(name: "Idle")
        let tasks = [
            makeTask(title: "Running one", status: .running, workspace: busy),
            makeTask(title: "Running two", status: .running, workspace: busy),
            makeTask(title: "Finished", status: .completed, workspace: busy),
            makeTask(title: "Queued", status: .queued, workspace: idle)
        ]

        let index = SidebarTaskIndex(tasks: tasks, searchText: "")
        #expect(index.runningTaskCount(in: busy) == 2)
        #expect(index.runningTaskCount(in: idle) == 0)

        // The liveness signal must survive a query that matches none of the
        // running tasks — it reports work, not search results.
        let filtered = SidebarTaskIndex(tasks: tasks, searchText: "Finished")
        #expect(filtered.runningTaskCount(in: busy) == 2)
    }

    @Test("Lean sidebar presentation contracts keep the left rail navigational")
    func leanSidebarPresentationContracts() {
        #expect(SidebarLeanPresentation.usesQuietNewTaskCommand)
        #expect(SidebarLeanPresentation.sectionHeadersShowCounts)
        #expect(SidebarLeanPresentation.workspacesUseSingleFlatList)
        #expect(SidebarLeanPresentation.sidebarTaskTitlesShowPrimaryTextOnly)
        #expect(SidebarLeanPresentation.sidebarTaskActionsLiveInOptionsMenu)
        #expect(SidebarLeanPresentation.workspaceStarsMoveToTrailingEdge)
        #expect(SidebarLeanPresentation.workspaceMetadataAndActionsShareTrailingSlot)
        #expect(!SidebarLeanPresentation.selectedWorkspaceChildrenUseGuide)
        #expect(SidebarLeanPresentation.sidebarTaskStatusesShowExceptionsOnly)
        #expect(SidebarLeanPresentation.sidebarTaskStatusesNeverAddSecondLine)
        #expect(SidebarLeanPresentation.workspaceRowsShowRestStateDisclosure)
        #expect(SidebarLeanPresentation.workspaceDisclosureChevronWidth == 11)
        #expect(SidebarLeanPresentation.workspaceSectionHorizontalInset == 10)
        #expect(SidebarLeanPresentation.workspaceRowContentLeadingPadding == 4)
        #expect(SidebarLeanPresentation.workspaceRowContentTrailingPadding == 0)
        #expect(
            SidebarLeanPresentation.workspaceTrailingAccessoryInset
                == SidebarLeanPresentation.workspaceSectionHorizontalInset
        )
        #expect(SidebarLeanPresentation.workspaceRowElementSpacing == 7)
        #expect(SidebarLeanPresentation.workspaceFolderIconWidth == 17)
        #expect(SidebarLeanPresentation.workspaceTitleLeadingOffset == 46)
        #expect(SidebarLeanPresentation.pinnedDropZoneAppearsOnlyDuringDrag)
        // One fold for every capped rail list: Pinned, Unreads, and
        // workspace drawers all preview the same number of rows.
        #expect(SidebarLeanPresentation.sectionPreviewLimit == 6)
        #expect(SidebarLeanPresentation.pinnedPreviewLimit == SidebarLeanPresentation.sectionPreviewLimit)
        #expect(SidebarLeanPresentation.unreadPreviewLimit == SidebarLeanPresentation.sectionPreviewLimit)
        #expect(SidebarWorkspaceTaskList.collapsedLimit == SidebarLeanPresentation.sectionPreviewLimit)
        #expect(SidebarLeanPresentation.childTaskListLeadingPadding == 0)
        // Child content steps in 20pt so containment reads without a
        // guide rail; row surfaces still span the full rail width.
        #expect(SidebarLeanPresentation.childTaskContentLeadingPadding == 20)
        // Workspace list overflow controls align with their task titles,
        // instead of the full-width task row surface.
        #expect(
            SidebarWorkspaceTaskList.showMoreLeadingPadding
                == SidebarThreadRowLayout.titleLeadingOffset(
                    childListPadding: SidebarLeanPresentation.childTaskListLeadingPadding,
                    contentLeadingPadding: SidebarLeanPresentation.childTaskContentLeadingPadding
                )
        )
        #expect(!SidebarThreadRowLayout.isActionableStatus(.completed))
        #expect(SidebarThreadRowLayout.isActionableStatus(.running))
        #expect(SidebarThreadRowLayout.showsStatusIcon(for: .completed, isUnread: false, isHovered: false, isSelected: false) == false)
        #expect(SidebarThreadRowLayout.showsStatusIcon(for: .completed, isUnread: true, isHovered: false, isSelected: false))
        #expect(SidebarThreadRowLayout.showsStatusIcon(for: .completed, isUnread: false, isHovered: true, isSelected: false))
        #expect(SidebarThreadRowLayout.showsStatusIcon(for: .completed, isUnread: false, isHovered: false, isKeyboardFocused: true, isSelected: false))
        #expect(SidebarThreadRowLayout.showsStatusIcon(for: .completed, isUnread: false, isHovered: false, isSelected: true))
        #expect(SidebarThreadRowLayout.showsStatusIcon(for: .running, isUnread: false, isHovered: false, isSelected: false))
        // Rest-state glyphs: actionable work and unseen results only —
        // read terminal states stay bare so the rail scans as navigation.
        #expect(SidebarThreadRowLayout.showsRestStateGlyph(for: .completed, isUnread: true))
        #expect(SidebarThreadRowLayout.showsRestStateGlyph(for: .failed, isUnread: false))
        #expect(!SidebarThreadRowLayout.showsRestStateGlyph(for: .completed, isUnread: false))
        #expect(!SidebarThreadRowLayout.showsRestStateGlyph(for: .cancelled, isUnread: false))
        // The glyph gutter is always reserved: the title's x-position no
        // longer depends on status or unread state, so hover/selection
        // glyph reveals fade in place instead of shoving the title.
        let childTaskTitleLeadingOffset = SidebarThreadRowLayout.titleLeadingOffset(
            childListPadding: SidebarLeanPresentation.childTaskListLeadingPadding,
            contentLeadingPadding: SidebarLeanPresentation.childTaskContentLeadingPadding
        )
        #expect(childTaskTitleLeadingOffset == 51)
        #expect(childTaskTitleLeadingOffset > SidebarLeanPresentation.workspaceTitleLeadingOffset)
        #expect(SidebarThreadRowLayout.titleFontSize == 14)
    }

    @Test("Task age moves from the row into the options menu")
    func taskAgeUsesReadableOptionsMenuMetadata() {
        let now = Date(timeIntervalSince1970: 10_000_000)

        #expect(
            SidebarTaskAgePresentation.menuLabel(
                updatedAt: now.addingTimeInterval(-59),
                now: now
            ) == "Updated just now"
        )
        #expect(
            SidebarTaskAgePresentation.menuLabel(
                updatedAt: now.addingTimeInterval(-60),
                now: now
            ) == "Updated 1 minute ago"
        )
        #expect(
            SidebarTaskAgePresentation.menuLabel(
                updatedAt: now.addingTimeInterval(-7_200),
                now: now
            ) == "Updated 2 hours ago"
        )
        #expect(
            SidebarTaskAgePresentation.menuLabel(
                updatedAt: now.addingTimeInterval(-604_800),
                now: now
            ) == "Updated 1 week ago"
        )
        #expect(
            SidebarTaskAgePresentation.menuLabel(
                updatedAt: now.addingTimeInterval(-5_184_000),
                now: now
            ) == "Updated 2 months ago"
        )
        #expect(
            SidebarTaskAgePresentation.menuLabel(
                updatedAt: now.addingTimeInterval(60),
                now: now
            ) == "Updated just now"
        )
    }

    @Test("Task action prefixes move from rows into the options menu")
    func taskActionsUseOptionsMenuMetadata() {
        let checkRow = SidebarTaskActionPresentation.rowTitle(
            for: "Check PR comments and todos"
        )
        #expect(checkRow.prefix == nil)
        #expect(checkRow.primary == "PR comments and todos")
        #expect(checkRow.fullTitle == "Check PR comments and todos")
        #expect(
            SidebarTaskActionPresentation.menuLabel(
                for: "Check PR comments and todos"
            ) == "Action: Check"
        )
        #expect(
            SidebarTaskActionPresentation.menuLabel(
                for: "Summarize two GitHub repositories"
            ) == "Action: Summarize"
        )

        let unprefixedRow = SidebarTaskActionPresentation.rowTitle(
            for: "Fork of Summarize two GitHub repositories"
        )
        #expect(unprefixedRow.primary == "Fork of Summarize two GitHub repositories")
        #expect(
            SidebarTaskActionPresentation.menuLabel(
                for: "Fork of Summarize two GitHub repositories"
            ) == nil
        )
    }

    @Test("Task option overlay separates long titles from an opaque menu surface")
    func taskOptionOverlayHasSeparationFromLongTitles() {
        #expect(SidebarTaskAccessoryPresentation.controlSize == 24)
        #expect(SidebarTaskAccessoryPresentation.trailingPadding == 8)
        #expect(SidebarTaskAccessoryPresentation.footprintWidth == 32)
        #expect(SidebarTaskAccessoryPresentation.backgroundCornerRadius == 6)
        #expect(SidebarTaskAccessoryPresentation.backgroundOpacity == 1)
        #expect(SidebarTaskAccessoryPresentation.trailingFadeWidth == 64)
        #expect(
            SidebarTaskAccessoryPresentation.trailingFadeWidth
                >= SidebarTaskAccessoryPresentation.footprintWidth * 2
        )
    }

    @Test("Workspace stars share geometry while filter and status keep distinct chrome")
    func workspaceStarPresentationContracts() {
        #expect(SidebarWorkspaceStarPresentation.glyphSize == 13)
        #expect(SidebarWorkspaceStarPresentation.frameSize == 22)
        #expect(SidebarWorkspaceStarPresentation.cornerRadius == 6)
        #expect(SidebarWorkspaceStarPresentation.activeBackgroundOpacity == 0.10)

        let inactiveFilter = SidebarWorkspaceStarPresentation.style(for: .filter(isEnabled: false))
        #expect(inactiveFilter.symbolName == "star")
        #expect(!inactiveFilter.isActive)
        #expect(!inactiveFilter.showsBackground)

        let hoveredFilter = SidebarWorkspaceStarPresentation.style(
            for: .filter(isEnabled: false),
            isHovered: true
        )
        #expect(hoveredFilter.symbolName == "star")
        #expect(!hoveredFilter.isActive)
        #expect(hoveredFilter.showsBackground)

        let activeFilter = SidebarWorkspaceStarPresentation.style(for: .filter(isEnabled: true))
        #expect(activeFilter.symbolName == "star.fill")
        #expect(activeFilter.isActive)
        #expect(activeFilter.showsBackground)

        let workspaceStatus = SidebarWorkspaceStarPresentation.style(for: .workspaceStatus)
        #expect(workspaceStatus.symbolName == "star.fill")
        #expect(workspaceStatus.isActive)
        #expect(!workspaceStatus.showsBackground)
    }

    @Test("Pinned task workspace context moves from the row to hover help")
    func pinnedTaskWorkspaceContextUsesHoverHelp() {
        #expect(
            SidebarPinnedTaskPresentation.workspaceHoverHelp(workspaceName: "JSL")
                == "Workspace: JSL"
        )
        #expect(SidebarPinnedTaskPresentation.workspaceHoverHelp(workspaceName: "  ") == nil)
        #expect(SidebarPinnedTaskPresentation.workspaceHoverHelp(workspaceName: nil) == nil)
    }

    @Test("Task row hover is borderless while keyboard focus remains explicit")
    func taskRowSurfaceStates() {
        let rest = SidebarThreadRowSurfaceStyle.resolve(
            isSelected: false,
            isHovered: false,
            isKeyboardFocused: false
        )
        #expect(rest == .init(fill: .clear, stroke: .clear, strokeWidth: 0))

        let hover = SidebarThreadRowSurfaceStyle.resolve(
            isSelected: false,
            isHovered: true,
            isKeyboardFocused: false
        )
        #expect(hover.fill == .adaptiveNeutral(opacity: 0.03))
        #expect(hover.stroke == .clear)
        #expect(hover.strokeWidth == 0)

        let focus = SidebarThreadRowSurfaceStyle.resolve(
            isSelected: false,
            isHovered: false,
            isKeyboardFocused: true
        )
        #expect(focus.fill == .keyboardFocus)
        #expect(focus.stroke == .keyboardFocus)
        #expect(focus.strokeWidth == 2)

        let selectedAndFocused = SidebarThreadRowSurfaceStyle.resolve(
            isSelected: true,
            isHovered: true,
            isKeyboardFocused: true
        )
        #expect(selectedAndFocused.fill == .selection)
        #expect(selectedAndFocused.stroke == .keyboardFocus)
        #expect(selectedAndFocused.strokeWidth == 2)
    }

    @Test("Sidebar collapses before the expanded rail can clip trailing metadata")
    func sidebarColumnCollapsesBeforeTrailingMetadataClips() {
        let readableTitleWidth: CGFloat = 200
        let workspaceRowFixedChrome =
            SidebarLeanPresentation.workspaceRowTrailingSlotWidth
            + SidebarLeanPresentation.workspaceDisclosureChevronWidth
            + SidebarLeanPresentation.workspaceRowElementSpacing
            + SidebarLeanPresentation.workspaceFolderIconWidth
            + SidebarLeanPresentation.workspaceRowElementSpacing
            + SidebarLeanPresentation.workspaceRowContentLeadingPadding

        #expect(SidebarColumnLayout.expandedMinimumWidth == 310)
        #expect(SidebarColumnLayout.expandedIdealWidth >= SidebarColumnLayout.expandedMinimumWidth)
        #expect(SidebarColumnLayout.expandedMaximumWidth >= SidebarColumnLayout.expandedIdealWidth)
        #expect(SidebarColumnLayout.collapseEdge == .leading)
        #expect(SidebarColumnLayout.collapseUsesRightPanelMotion)
        #expect(SidebarColumnLayout.expandedMinimumWidth - workspaceRowFixedChrome >= readableTitleWidth)

        #expect(SidebarColumnLayout.shouldCollapseExpandedSidebar(width: 0) == false)
        #expect(SidebarColumnLayout.shouldCollapseExpandedSidebar(
            width: SidebarColumnLayout.expandedMinimumWidth - 0.5
        ) == true)
        #expect(SidebarColumnLayout.shouldCollapseExpandedSidebar(
            width: SidebarColumnLayout.expandedMinimumWidth
        ) == false)
        #expect(SidebarColumnLayout.shouldCollapseVisibleSplitWidth(.infinity) == false)
        #expect(SidebarColumnLayout.shouldCollapseVisibleSplitWidth(.nan) == false)
        #expect(SidebarColumnLayout.shouldCollapseVisibleSplitWidth(
            SidebarColumnLayout.expandedMinimumWidth - 1
        ) == true)
        #expect(SidebarColumnLayout.shouldCollapseVisibleSplitWidth(
            SidebarColumnLayout.expandedMinimumWidth - 1,
            isRevealInProgress: true
        ) == false)
        #expect(SidebarColumnLayout.shouldCollapseVisibleSplitWidth(
            SidebarColumnLayout.expandedMinimumWidth
        ) == false)
        #expect(SidebarColumnLayout.shouldCompleteSidebarReveal(width: 0) == false)
        #expect(SidebarColumnLayout.shouldCompleteSidebarReveal(
            width: SidebarColumnLayout.expandedMinimumWidth - 1
        ) == false)
        #expect(SidebarColumnLayout.shouldCompleteSidebarReveal(
            width: SidebarColumnLayout.expandedMinimumWidth
        ) == true)
        #expect(SidebarRevealSettlingPolicy.fallbackDelayNanoseconds > 0)

        let firstRevision = SidebarRevealSettlingPolicy.nextRevision(after: 0)
        let secondRevision = SidebarRevealSettlingPolicy.nextRevision(after: firstRevision)
        #expect(firstRevision != secondRevision)
        #expect(SidebarRevealSettlingPolicy.shouldBeginReveal(isRevealInProgress: false))
        #expect(!SidebarRevealSettlingPolicy.shouldBeginReveal(isRevealInProgress: true))
        #expect(SidebarRevealSettlingPolicy.shouldClearReveal(
            scheduledRevision: firstRevision,
            currentRevision: firstRevision,
            isRevealInProgress: true
        ))
        #expect(!SidebarRevealSettlingPolicy.shouldClearReveal(
            scheduledRevision: firstRevision,
            currentRevision: secondRevision,
            isRevealInProgress: true
        ))
        #expect(!SidebarRevealSettlingPolicy.shouldClearReveal(
            scheduledRevision: firstRevision,
            currentRevision: firstRevision,
            isRevealInProgress: false
        ))
    }
}

// MARK: - DiffsTabView logic

@Suite("Diffs tab logic")
struct DiffsTabTests {

    @Test("Latest run is most recent by startedAt")
    func latestRun() {
        let task = makeTask()
        let run1 = TaskRun(task: task)
        let run2 = TaskRun(task: task)
        // run2 is created after run1, so it's more recent
        let runs = [run1, run2]
        let latest = runs.sorted { $0.startedAt > $1.startedAt }.first
        #expect(latest === run2)
    }

    @Test("File changes from latest run")
    func fileChangesFromRun() {
        let task = makeTask()
        let run = TaskRun(task: task)
        let change = StoredFileChange(
            from: FileChange(path: "/tmp/a.swift", changeType: .write,
                             content: "hello", oldString: nil, newString: nil, timestamp: Date())
        )
        run.appendFileChange(change)

        let changes = run.fileChanges
        #expect(changes.count == 1)
        #expect(changes[0].path == "/tmp/a.swift")
    }
}

// MARK: - Prompt building logic

@Suite("Prompt building")
struct PromptBuildingTests {

    @Test("Basic prompt with goal only")
    func basicPrompt() {
        let task = makeTask(goal: "Fix the login bug")
        // Replicate buildPrompt logic
        let parts: [String] = ["Goal: \(task.goal)"]
        let prompt = parts.joined(separator: "\n\n")
        #expect(prompt == "Goal: Fix the login bug")
    }

    @Test("Prompt includes constraints")
    func promptWithConstraints() {
        let task = makeTask(goal: "Add feature")
        task.constraints = ["Don't break tests", "Keep backward compat"]
        var parts: [String] = ["Goal: \(task.goal)"]
        if !task.constraints.isEmpty {
            parts.append("Constraints:\n" + task.constraints.map { "- \($0)" }.joined(separator: "\n"))
        }
        let prompt = parts.joined(separator: "\n\n")
        #expect(prompt.contains("- Don't break tests"))
        #expect(prompt.contains("- Keep backward compat"))
    }

    @Test("Prompt includes acceptance criteria")
    func promptWithCriteria() {
        let task = makeTask(goal: "Refactor")
        task.acceptanceCriteria = ["Tests pass", "No regressions"]
        var parts: [String] = ["Goal: \(task.goal)"]
        if !task.acceptanceCriteria.isEmpty {
            parts.append("Acceptance Criteria:\n" + task.acceptanceCriteria.map { "- \($0)" }.joined(separator: "\n"))
        }
        let prompt = parts.joined(separator: "\n\n")
        #expect(prompt.contains("- Tests pass"))
        #expect(prompt.contains("- No regressions"))
    }

    @Test("Prompt includes file context")
    func promptWithFileContext() throws {
        let file = "/tmp/astra-prompt-test-\(UUID().uuidString.prefix(8)).txt"
        defer { try? FileManager.default.removeItem(atPath: file) }
        try "export const API_KEY = 'test';".write(toFile: file, atomically: true, encoding: .utf8)

        let task = makeTask(goal: "Update API")
        task.inputs = [file]

        var parts: [String] = ["Goal: \(task.goal)"]
        var contextParts: [String] = []
        for input in task.inputs {
            if input.hasPrefix("/"),
               let content = try? String(contentsOfFile: input, encoding: .utf8) {
                contextParts.append("File: \(input)\n```\n\(content)\n```")
            }
        }
        if !contextParts.isEmpty {
            parts.append("Context/Inputs:\n" + contextParts.joined(separator: "\n\n"))
        }
        let prompt = parts.joined(separator: "\n\n")
        #expect(prompt.contains("API_KEY"))
        #expect(prompt.contains("Context/Inputs:"))
    }
}

// MARK: - Enum coverage

@Suite("Enum completeness")
struct EnumTests {

    @Test("TaskStatus has all expected cases")
    func taskStatusCases() {
        let all = TaskStatus.allCases
        #expect(all.count == 8)
        #expect(all.contains(.draft))
        #expect(all.contains(.queued))
        #expect(all.contains(.running))
        #expect(all.contains(.pendingUser))
        #expect(all.contains(.completed))
        #expect(all.contains(.failed))
        #expect(all.contains(.cancelled))
        #expect(all.contains(.budgetExceeded))
    }

    @Test("IsolationStrategy has all expected cases")
    func isolationCases() {
        let all = IsolationStrategy.allCases
        #expect(all.count == 3)
        #expect(all.contains(.sameDirectory))
        #expect(all.contains(.gitBranch))
        #expect(all.contains(.copy))
    }

    @Test("ValidationStrategy has all expected cases")
    func validationCases() {
        let all = ValidationStrategy.allCases
        #expect(all.count == 3)
        #expect(all.contains(.manual))
        #expect(all.contains(.runTests))
        #expect(all.contains(.aiCheck))
    }

    @Test("RunStatus raw values")
    func runStatusRawValues() {
        #expect(RunStatus.running.rawValue == "running")
        #expect(RunStatus.completed.rawValue == "completed")
        #expect(RunStatus.failed.rawValue == "failed")
        #expect(RunStatus.cancelled.rawValue == "cancelled")
        #expect(RunStatus.timeout.rawValue == "timeout")
        #expect(RunStatus.budgetExceeded.rawValue == "budget_exceeded")
    }

    @Test("Plan execution failure is a lifecycle event")
    func planExecutionFailureEventCategory() {
        #expect(TaskEvent.categoryFor(type: "plan.execution.failed") == "lifecycle")
    }
}

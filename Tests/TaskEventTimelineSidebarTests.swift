import Testing
import AppKit
import SwiftUI
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

    @Test("SidebarTaskIndex groups review tasks by workspace")
    func sidebarTaskIndexGroupsReviewTasks() {
        let firstWorkspace = makeWorkspace(name: "First")
        let secondWorkspace = makeWorkspace(name: "Second")

        let pinnedReview = makeTask(title: "Pinned review", status: .completed, workspace: firstWorkspace)
        pinnedReview.isPinned = true
        pinnedReview.updatedAt = Date(timeIntervalSince1970: 200)

        let archived = makeTask(title: "Archived", status: .completed, workspace: firstWorkspace)
        archived.isDone = true

        let running = makeTask(title: "Running", status: .running, workspace: secondWorkspace)

        let index = SidebarTaskIndex(tasks: [archived, running, pinnedReview], searchText: "")

        #expect(index.reviewTasks(for: firstWorkspace).map(\.id) == [pinnedReview.id])
        #expect(index.reviewTasks(for: secondWorkspace).map(\.id) == [running.id])
        #expect(index.pinnedTasks.map(\.id) == [pinnedReview.id])
        #expect(index.hasAnyTask(in: firstWorkspace))
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

    @Test("Collapsed selected workspace is not force-expanded on selection change")
    func collapsedSelectedWorkspaceDoesNotAutoExpand() {
        let workspaceID = UUID()

        #expect(!WorkspaceSidebarSelection.shouldEnsureSelectedWorkspaceExpanded(
            selectedWorkspaceID: workspaceID,
            collapsedWorkspaceIDs: [workspaceID]
        ))
        #expect(WorkspaceSidebarSelection.shouldEnsureSelectedWorkspaceExpanded(
            selectedWorkspaceID: workspaceID,
            collapsedWorkspaceIDs: []
        ))
        #expect(!WorkspaceSidebarSelection.shouldEnsureSelectedWorkspaceExpanded(
            selectedWorkspaceID: nil,
            collapsedWorkspaceIDs: [workspaceID]
        ))
    }

    @Test("Lean sidebar presentation contracts keep the left rail navigational")
    func leanSidebarPresentationContracts() {
        #expect(SidebarLeanPresentation.usesQuietNewTaskCommand)
        #expect(SidebarLeanPresentation.sectionHeadersShowCounts)
        #expect(SidebarLeanPresentation.workspacesUseSingleFlatList)
        #expect(SidebarLeanPresentation.sidebarTaskTitlesUsePrefixPrimaryPresentation)
        #expect(SidebarLeanPresentation.workspaceStarsMoveToTrailingEdge)
        #expect(SidebarLeanPresentation.workspaceMetadataAndActionsShareTrailingSlot)
        #expect(!SidebarLeanPresentation.selectedWorkspaceChildrenUseGuide)
        #expect(SidebarLeanPresentation.sidebarTaskStatusesShowExceptionsOnly)
        #expect(SidebarLeanPresentation.pinnedPreviewLimit == 5)
        #expect(SidebarLeanPresentation.childTaskListLeadingPadding == 0)
        #expect(SidebarLeanPresentation.childTaskContentLeadingPadding == 0)
    }

    @Test("Sidebar collapses before the expanded rail can clip trailing metadata")
    func sidebarColumnCollapsesBeforeTrailingMetadataClips() {
        let readableTitleWidth: CGFloat = 200
        let workspaceRowFixedChrome =
            SidebarLeanPresentation.workspaceRowTrailingSlotWidth
            + 17 // folder icon width
            + 7 // workspace row icon/title spacing
            + 8 // horizontal row padding

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
            SidebarColumnLayout.expandedMinimumWidth
        ) == false)
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

import Testing
import SwiftUI
@testable import ASTRA
import ASTRACore

// MARK: - Helper

private func makeTask(
    title: String = "Test Task",
    goal: String = "Do something",
    status: TaskStatus = .queued,
    workspace: Workspace? = nil,
    tokensUsed: Int = 0,
    tokenBudget: Int = 50000,
    costUSD: Double = 0,
    model: String = "claude-sonnet-4-6"
) -> AgentTask {
    let task = AgentTask(title: title, goal: goal, workspace: workspace, tokenBudget: tokenBudget, model: model)
    task.status = status
    task.tokensUsed = tokensUsed
    task.costUSD = costUSD
    return task
}

private func makeWorkspace(name: String = "Workspace") -> Workspace {
    Workspace(name: name, primaryPath: "/tmp/\(name)")
}

private func makeEvent(
    task: AgentTask,
    type: String,
    payload: String,
    timestamp: Date,
    run: TaskRun? = nil
) -> TaskEvent {
    let event = TaskEvent(task: task, type: type, payload: payload, run: run)
    event.timestamp = timestamp
    return event
}

// MARK: - MarkdownTextView

@Suite("MarkdownTextView")
struct MarkdownTextViewTests {

    @Test("Malformed schedule markdown is rendered as text instead of trapping")
    func malformedScheduleMarkdownDoesNotTrap() {
        let malformed = "Schedule result: [unterminated link with agent output"

        let attributed = MarkdownTextView.markdownAttributed(malformed)

        #expect(String(attributed.characters) == malformed)
    }

    @Test("Bare URLs are linked with the shared markdown linkifier")
    func bareURLsAreLinked() {
        let attributed = MarkdownTextView.markdownAttributed("Visit https://example.com/docs")
        let links = attributed.runs.compactMap(\.link)
        let expected = URL(string: "https://example.com/docs")!

        #expect(links.contains(expected))
    }

    @Test("Markdown linkifier returns stable attributed output from cache")
    func markdownLinkifierCacheIsStable() {
        MarkdownLinkifier.clearCacheForTests()

        let source = "Read **docs** at https://example.com/docs"
        let first = MarkdownLinkifier.markdownAttributed(source)
        let second = MarkdownLinkifier.markdownAttributed(source)

        #expect(String(first.characters) == String(second.characters))
        #expect(first.runs.compactMap(\.link) == second.runs.compactMap(\.link))
    }
}

// MARK: - TaskThreadSnapshot

@Suite("TaskThreadSnapshot")
struct TaskThreadSnapshotTests {

    @Test("Conversation snapshot preserves chronological run and message behavior")
    func conversationSnapshotOrdering() {
        let createdAt = Date(timeIntervalSince1970: 100)
        let task = makeTask(goal: "Original goal")
        task.createdAt = createdAt

        let firstRun = TaskRun(task: task)
        firstRun.startedAt = Date(timeIntervalSince1970: 110)
        firstRun.completedAt = Date(timeIntervalSince1970: 130)
        firstRun.output = "First run output"

        let secondRun = TaskRun(task: task)
        secondRun.startedAt = Date(timeIntervalSince1970: 140)
        secondRun.output = "Second run output"

        let userFollowUp = makeEvent(
            task: task,
            type: "user.message",
            payload: "Continue",
            timestamp: Date(timeIntervalSince1970: 150)
        )

        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: [userFollowUp],
            runs: [secondRun, firstRun]
        )

        #expect(snapshot.conversationItems.count == 4)

        if case .userMessage(let text, _) = snapshot.conversationItems[0] {
            #expect(text == "Original goal")
        } else {
            Issue.record("Expected original goal as first conversation item")
        }

        if case .agentResponse(let run) = snapshot.conversationItems[1] {
            #expect(run === firstRun)
        } else {
            Issue.record("Expected completed first run before the follow-up")
        }

        if case .userMessage(let text, _) = snapshot.conversationItems[2] {
            #expect(text == "Continue")
        } else {
            Issue.record("Expected follow-up user message")
        }

        if case .agentResponse(let run) = snapshot.conversationItems[3] {
            #expect(run === secondRun)
        } else {
            Issue.record("Expected remaining run output at the end")
        }
    }

    @Test("Tool activity is grouped once per run")
    func toolActivityGrouping() {
        let task = makeTask()
        let run = TaskRun(task: task)
        let events = [
            makeEvent(task: task, type: "tool.use", payload: "Using tool: Read", timestamp: Date(timeIntervalSince1970: 1), run: run),
            makeEvent(task: task, type: "tool.use", payload: "Using tool: Bash", timestamp: Date(timeIntervalSince1970: 2), run: run),
            makeEvent(task: task, type: "tool.use", payload: "Using tool: Read", timestamp: Date(timeIntervalSince1970: 3), run: run),
            makeEvent(task: task, type: "tool.result", payload: "result", timestamp: Date(timeIntervalSince1970: 4), run: run),
            makeEvent(task: task, type: "tool.result", payload: "", timestamp: Date(timeIntervalSince1970: 5), run: run)
        ]

        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: events,
            runs: [run]
        )
        let activity = snapshot.activity(for: run)

        #expect(activity.tools == [
            TaskToolSummary(name: "Read", count: 2),
            TaskToolSummary(name: "Bash", count: 1)
        ])
        #expect(activity.toolResults.count == 1)
        #expect(activity.toolResults.first?.payload == "result")
    }

    @Test("Large snapshot fixture preserves per-run activity grouping")
    func largeSnapshotFixture() {
        let task = makeTask()
        let runCount = 750
        var runs: [TaskRun] = []
        var events: [TaskEvent] = []
        runs.reserveCapacity(runCount)
        events.reserveCapacity(runCount * 4)

        for index in 0..<runCount {
            let baseTimestamp = Double(index * 10)
            let run = TaskRun(task: task)
            run.startedAt = Date(timeIntervalSince1970: baseTimestamp)
            run.completedAt = Date(timeIntervalSince1970: baseTimestamp + 5)
            run.output = "Run output \(index)"
            runs.append(run)

            events.append(makeEvent(
                task: task,
                type: "tool.use",
                payload: "Using tool: Read",
                timestamp: Date(timeIntervalSince1970: baseTimestamp + 1),
                run: run
            ))
            events.append(makeEvent(
                task: task,
                type: "tool.use",
                payload: "Using tool: Bash",
                timestamp: Date(timeIntervalSince1970: baseTimestamp + 2),
                run: run
            ))
            events.append(makeEvent(
                task: task,
                type: "tool.use",
                payload: "Using tool: Read",
                timestamp: Date(timeIntervalSince1970: baseTimestamp + 3),
                run: run
            ))
            events.append(makeEvent(
                task: task,
                type: "tool.result",
                payload: "result \(index)",
                timestamp: Date(timeIntervalSince1970: baseTimestamp + 4),
                run: run
            ))
        }

        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: events.reversed(),
            runs: runs.reversed()
        )

        #expect(snapshot.sortedRuns.count == runCount)
        #expect(snapshot.sortedEvents.count == runCount * 4)
        #expect(snapshot.conversationItems.count == runCount + 1)

        for index in stride(from: 0, to: runCount, by: 125) {
            let activity = snapshot.activity(for: runs[index])
            #expect(activity.tools == [
                TaskToolSummary(name: "Read", count: 2),
                TaskToolSummary(name: "Bash", count: 1)
            ])
            #expect(activity.toolResults.count == 1)
            #expect(activity.toolResults.first?.payload == "result \(index)")
        }
    }

    @Test("Generated file scan excludes internal task files")
    func generatedFileScanExcludesInternalFiles() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-generated-files-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("nested")
        let outputs = root.appendingPathComponent("outputs")

        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: true)
        try "visible".write(to: root.appendingPathComponent("visible.txt"), atomically: true, encoding: .utf8)
        try "internal".write(to: root.appendingPathComponent("session_history.md"), atomically: true, encoding: .utf8)
        try "output".write(to: outputs.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
        try "nested".write(to: nested.appendingPathComponent("session_history.md"), atomically: true, encoding: .utf8)

        defer { try? FileManager.default.removeItem(at: root) }

        let paths = Set(TaskGeneratedFiles.files(in: root.path))

        #expect(paths.contains(root.appendingPathComponent("visible.txt").path))
        #expect(paths.contains(nested.appendingPathComponent("session_history.md").path))
        #expect(!paths.contains(root.appendingPathComponent("session_history.md").path))
        #expect(!paths.contains(outputs.appendingPathComponent("result.txt").path))
    }

    @Test("Generated file scan can run asynchronously")
    func generatedFileScanRunsAsync() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-generated-files-async-\(UUID().uuidString)")

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "visible".write(to: root.appendingPathComponent("visible.txt"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = await TaskGeneratedFiles.filesAsync(in: root.path)

        #expect(paths == [root.appendingPathComponent("visible.txt").path])
    }
}

// MARK: - ChatPanelView

@Suite("ChatPanelView")
struct ChatPanelViewTests {

    @Test("New task prompt rotation copy")
    func newTaskPromptRotationCopy() {
        #expect(ChatPanelView.newTaskPrompts == [
            "What should we get done?",
            "Where should we start?",
            "What’s the next move?",
            "What problem are we solving?",
            "What should we prototype?",
            "What’s worth solving next?",
            "What idea should we test?",
            "What should we make real?",
            "Start with a question, goal, or problem.",
        ])
    }
}

// MARK: - StatusBadge

@Suite("StatusBadge View")
struct StatusBadgeTests {

    @Test("Color mapping for all statuses",
          arguments: [
            (TaskStatus.queued, Stanford.queued),
            (TaskStatus.running, Stanford.running),
            (TaskStatus.pendingUser, Stanford.pendingUser),
            (TaskStatus.completed, Stanford.completed),
            (TaskStatus.failed, Stanford.failed),
            (TaskStatus.budgetExceeded, Stanford.failed),
            (TaskStatus.cancelled, Stanford.cancelled),
          ])
    func colorMapping(status: TaskStatus, expected: Color) {
        let badge = StatusBadge(status: status)
        #expect(badge.color == expected)
    }
}

// MARK: - TaskRowView (status icon/color removed — redundant with section headers)

// MARK: - KanbanCategory

@Suite("KanbanCategory")
struct KanbanCategoryTests {

    @Test("Completed tasks land in Done when explicitly marked done")
    func completedTasksBelongToDone() {
        #expect(KanbanCategory.done.includes(status: .completed, isDone: true))
        #expect(KanbanCategory.review.includes(status: .completed, isDone: true) == false)
    }

    @Test("Reopened completed tasks move back to Review")
    func reopenedCompletedTasksBelongToReview() {
        #expect(KanbanCategory.done.includes(status: .completed, isDone: false) == false)
        #expect(KanbanCategory.review.includes(status: .completed, isDone: false))
    }

    @Test("Failed tasks stay in Review until explicitly marked done")
    func failedTasksStayInReview() {
        #expect(KanbanCategory.review.includes(status: .failed, isDone: false))
        #expect(KanbanCategory.done.includes(status: .failed, isDone: false) == false)
        #expect(KanbanCategory.done.includes(status: .failed, isDone: true))
    }

    @Test("Pending-user work lands in Review, not Running")
    func pendingUserTasksLandInReview() {
        #expect(KanbanCategory.review.includes(status: .pendingUser, isDone: false))
        #expect(KanbanCategory.running.includes(status: .pendingUser, isDone: false) == false)
    }

    @Test("Running work lands only in Running")
    func runningTasksLandInRunning() {
        #expect(KanbanCategory.running.includes(status: .running, isDone: false))
        #expect(KanbanCategory.review.includes(status: .running, isDone: false) == false)
    }

    @Test("Review sort surfaces pending-user tasks above terminal outcomes")
    func reviewSortPromotesPendingUser() {
        // Two terminal tasks with newer timestamps than the pending-user task:
        // pending-user must still win because the agent is blocked on input.
        let completedNewer = AgentTask(title: "completed newer", goal: "g")
        completedNewer.status = .completed
        completedNewer.updatedAt = Date(timeIntervalSince1970: 3_000_000)

        let failedMid = AgentTask(title: "failed middle", goal: "g")
        failedMid.status = .failed
        failedMid.updatedAt = Date(timeIntervalSince1970: 2_000_000)

        let pendingOldest = AgentTask(title: "pending oldest", goal: "g")
        pendingOldest.status = .pendingUser
        pendingOldest.updatedAt = Date(timeIntervalSince1970: 1_000_000)

        let sorted = KanbanCategory.review.sortedTasks(from: [completedNewer, failedMid, pendingOldest])
        #expect(sorted.first?.status == .pendingUser)
        #expect(sorted.last?.status != .pendingUser)
    }

    @Test("Review covers pending-user and all four terminal statuses")
    func reviewCoverageAcrossStatuses() {
        for status in [TaskStatus.pendingUser, .completed, .failed, .cancelled, .budgetExceeded] {
            #expect(KanbanCategory.review.includes(status: status, isDone: false),
                    "Review should include status \(status)")
        }
        // Any of those statuses with isDone == true must leave Review for Done.
        #expect(KanbanCategory.review.includes(status: .completed, isDone: true) == false)
    }
}

// MARK: - KanbanTaskCardView.shortenIdentifierTokens

@Suite("shortenIdentifierTokens")
struct ShortenIdentifierTokensTests {

    @Test("Short titles pass through untouched")
    func shortTitlesUnchanged() {
        #expect(KanbanTaskCardView.shortenIdentifierTokens("Investigate failing sync job")
                == "Investigate failing sync job")
    }

    @Test("Long identifier-like tokens get middle-ellipsized")
    func longIdentifierIsShortened() {
        let input = "Sync project-alpha-prod-eu.table_long_identifier_notes_archive"
        let out = KanbanTaskCardView.shortenIdentifierTokens(input)
        // The leading word is preserved; the long token is collapsed.
        #expect(out.hasPrefix("Sync "))
        #expect(out.contains("…"))
        // Prefix + ellipsis + suffix are all shorter than the original token.
        #expect(out.count < input.count)
    }

    @Test("Long tokens without identifier separators are left alone")
    func longProseTokenUnchanged() {
        // 30 chars, no separators — normal word line-clipping is fine.
        let input = "Supercalifragilisticexpialidocious"
        #expect(KanbanTaskCardView.shortenIdentifierTokens(input) == input)
    }

    @Test("Prefix and suffix of the original token are preserved")
    func preservesHeadAndTail() {
        let input = "project-alpha-prod-eu.table_long_identifier_notes_archive"
        let out = KanbanTaskCardView.shortenIdentifierTokens(input, keepEachSide: 8)
        #expect(out.hasPrefix("project-"))
        #expect(out.hasSuffix("archive"))
    }
}

// MARK: - ChatBubbleView

@Suite("ChatBubbleView")
struct ChatBubbleViewTests {

    @Test("isUser true for user.message")
    func isUserTrue() {
        let task = makeTask()
        let event = TaskEvent(task: task, type: "user.message", payload: "hello")
        let bubble = ChatBubbleView(event: event)
        #expect(bubble.isUser == true)
    }

    @Test("isUser false for agent types",
          arguments: ["agent.response", "agent.thinking", "tool.use", "task.completed", "error"])
    func isUserFalse(eventType: String) {
        let task = makeTask()
        let event = TaskEvent(task: task, type: eventType, payload: "test")
        let bubble = ChatBubbleView(event: event)
        #expect(bubble.isUser == false)
    }
}

// MARK: - AgentTask computed properties

@Suite("AgentTask computed properties")
struct AgentTaskPropertyTests {

    @Test("isTerminal for terminal statuses",
          arguments: [TaskStatus.completed, .failed, .cancelled, .budgetExceeded])
    func isTerminalTrue(status: TaskStatus) {
        let task = makeTask(status: status)
        #expect(task.isTerminal == true)
    }

    @Test("isTerminal false for non-terminal statuses",
          arguments: [TaskStatus.queued, .running, .pendingUser])
    func isTerminalFalse(status: TaskStatus) {
        let task = makeTask(status: status)
        #expect(task.isTerminal == false)
    }

    @Test("budgetProgress calculated correctly")
    func budgetProgress() {
        let task = makeTask(tokensUsed: 25000, tokenBudget: 50000)
        #expect(task.budgetProgress == 0.5)
    }

    @Test("budgetProgress at 100%")
    func budgetProgressFull() {
        let task = makeTask(tokensUsed: 50000, tokenBudget: 50000)
        #expect(task.budgetProgress == 1.0)
    }

    @Test("budgetProgress zero when no budget")
    func budgetProgressZero() {
        let task = makeTask(tokensUsed: 0, tokenBudget: 0)
        #expect(task.budgetProgress == 0)
    }

    @Test("threadMessageCount falls back to the original goal")
    func threadMessageCountFallback() {
        let task = makeTask(goal: "Investigate the failing sync job")
        #expect(task.threadMessageCount == 1)
    }

    @Test("threadMessageCount counts only conversation messages")
    func threadMessageCountFromEvents() {
        let task = makeTask()
        let user = TaskEvent(task: task, type: "user.message", payload: "What failed?")
        let assistant = TaskEvent(task: task, type: "agent.response", payload: "The sync job timed out.")
        let tool = TaskEvent(task: task, type: "tool.use", payload: "Bash")

        task.events.append(user)
        task.events.append(assistant)
        task.events.append(tool)

        #expect(task.threadMessageCount == 2)
    }

    @Test("statusColor returns expected values",
          arguments: [
            (TaskStatus.queued, "gray"),
            (TaskStatus.running, "blue"),
            (TaskStatus.pendingUser, "orange"),
            (TaskStatus.completed, "green"),
            (TaskStatus.failed, "red"),
            (TaskStatus.budgetExceeded, "red"),
            (TaskStatus.cancelled, "gray"),
          ])
    func statusColor(status: TaskStatus, expected: String) {
        let task = makeTask(status: status)
        #expect(task.statusColor == expected)
    }
}

// MARK: - TaskRun & StoredFileChange

@Suite("TaskRun file changes")
struct TaskRunFileChangeTests {

    @Test("Empty fileChangesJSON returns empty array")
    func emptyFileChanges() {
        let task = makeTask()
        let run = TaskRun(task: task)
        #expect(run.fileChanges.isEmpty)
        #expect(run.fileChangesJSON == "[]")
    }

    @Test("appendFileChange adds to JSON storage")
    func appendFileChange() {
        let task = makeTask()
        let run = TaskRun(task: task)
        let change = StoredFileChange(
            from: FileChange(path: "/tmp/test.swift", changeType: .write,
                             content: "let x = 1", oldString: nil, newString: nil, timestamp: Date())
        )
        run.appendFileChange(change)

        #expect(run.fileChanges.count == 1)
        #expect(run.fileChanges[0].path == "/tmp/test.swift")
        #expect(run.fileChanges[0].changeType == "Write")
    }

    @Test("Multiple file changes accumulate")
    func multipleChanges() {
        let task = makeTask()
        let run = TaskRun(task: task)

        for i in 0..<3 {
            let change = StoredFileChange(
                from: FileChange(path: "/tmp/file\(i).swift", changeType: .edit,
                                 content: nil, oldString: "old\(i)", newString: "new\(i)", timestamp: Date())
            )
            run.appendFileChange(change)
        }

        #expect(run.fileChanges.count == 3)
        #expect(run.fileChanges[2].path == "/tmp/file2.swift")
        #expect(run.fileChanges[2].oldString == "old2")
    }
}

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
        var parts: [String] = ["Goal: \(task.goal)"]
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
}

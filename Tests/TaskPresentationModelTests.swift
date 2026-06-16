import Testing
import AppKit
import SwiftUI
@testable import ASTRA
import ASTRACore

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

    @Test("Approve Plan inline action is gated by pending plan state")
    func approvePlanInlineActionIsGatedByPendingPlanState() {
        #expect(ChatPanelView.shouldShowApprovePlanInlineAction(
            in: "When the draft looks right, click Approve Plan.",
            hasPendingPlan: true
        ))
        #expect(!ChatPanelView.shouldShowApprovePlanInlineAction(
            in: "When the draft looks right, click Approve Plan.",
            hasPendingPlan: false
        ))
        #expect(!ChatPanelView.shouldShowApprovePlanInlineAction(
            in: "When the draft looks right, create the task.",
            hasPendingPlan: true
        ))
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

    @Test("Completed tasks land in Closed when explicitly closed")
    func completedTasksBelongToClosed() {
        #expect(KanbanCategory.done.includes(status: .completed, isDone: true))
        #expect(KanbanCategory.review.includes(status: .completed, isDone: true) == false)
    }

    @Test("Reopened completed tasks move back to Review")
    func reopenedCompletedTasksBelongToReview() {
        #expect(KanbanCategory.done.includes(status: .completed, isDone: false) == false)
        #expect(KanbanCategory.review.includes(status: .completed, isDone: false))
    }

    @Test("Failed tasks stay in Review until explicitly closed")
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
        // Any of those statuses with isDone == true must leave Review for Closed.
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

    @Test("Unread starts clear and is set only for agent-result statuses")
    func unreadStateFollowsResultStatuses() {
        let task = makeTask(status: .running)
        let unreadDate = Date(timeIntervalSince1970: 1_000)

        #expect(task.shouldShowUnread == false)

        task.markUnreadForCurrentStatus(at: unreadDate)
        #expect(task.shouldShowUnread == false)

        task.status = .completed
        task.markUnreadForCurrentStatus(at: unreadDate)
        #expect(task.shouldShowUnread == true)
        #expect(task.unreadAt == unreadDate)

        task.markRead()
        #expect(task.shouldShowUnread == false)
    }

    @Test("Pending user and failed outcomes can be unread")
    func reviewOutcomesCanBeUnread() {
        for status in [TaskStatus.pendingUser, .failed, .budgetExceeded] {
            let task = makeTask(status: status)
            task.markUnreadForCurrentStatus(at: Date(timeIntervalSince1970: 2_000))
            #expect(task.shouldShowUnread == true)
        }
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

    @Test("Kanban card message label uses goal fallback instead of event relationship")
    func kanbanCardMessageLabelUsesGoalFallback() {
        #expect(KanbanBoardPresentation.cardThreadMessageCount(goal: "Investigate crash") == 1)
        #expect(KanbanBoardPresentation.cardThreadMessageCount(goal: " \n\t ") == 0)
        #expect(KanbanTaskCardView.threadMessageLabel(for: 1) == "1 message")
        #expect(KanbanTaskCardView.threadMessageLabel(for: 2) == "2 messages")
    }

    @Test("hasProviderSession requires a trimmed non-empty session id")
    func hasProviderSessionRequiresTrimmedNonEmptySessionID() {
        let task = makeTask()

        #expect(task.hasProviderSession == false)

        task.sessionId = ""
        #expect(task.hasProviderSession == false)

        task.sessionId = " \n\t "
        #expect(task.hasProviderSession == false)

        task.sessionId = " session-123 "
        #expect(task.hasProviderSession == true)
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

    @Test("verificationPresentation surfaces passed verification command and artifact state")
    func verificationPresentationPassed() {
        let verification = TaskContextState.Verification(
            status: "passed",
            strategy: ValidationStrategy.runTests.rawValue,
            command: "swift test --filter TaskContextStateTests",
            summary: "Tests passed.",
            evidence: [],
            updatedAt: nil,
            completionVerified: true,
            artifactStatus: "1 current, 1 stale"
        )

        let presentation = TaskPresentationState.verificationPresentation(for: verification)

        #expect(presentation.title == "Verification passed")
        #expect(presentation.summary == "Verified")
        #expect(presentation.tone == .verified)
        #expect(presentation.detail?.contains("swift test --filter TaskContextStateTests") == true)
        #expect(presentation.detail?.contains("Artifacts: 1 current, 1 stale") == true)
    }

    @Test("verificationPresentation distinguishes manual completion from failed verification")
    func verificationPresentationManualAndFailed() {
        let manual = TaskContextState.Verification(
            status: "manual_completion",
            strategy: ValidationStrategy.manual.rawValue,
            command: nil,
            summary: "Manual completion recorded.",
            evidence: [],
            updatedAt: nil,
            completionVerified: false,
            artifactStatus: "none recorded"
        )
        let failed = TaskContextState.Verification(
            status: "failed",
            strategy: ValidationStrategy.runTests.rawValue,
            command: "swift test",
            summary: "Tests failed.",
            evidence: [],
            updatedAt: nil,
            completionVerified: false,
            artifactStatus: "none recorded"
        )

        let manualPresentation = TaskPresentationState.verificationPresentation(for: manual)
        let failedPresentation = TaskPresentationState.verificationPresentation(for: failed)

        #expect(manualPresentation.summary == "Not automatically verified")
        #expect(manualPresentation.tone == .attention)
        #expect(manualPresentation.detail?.contains("Artifacts: none recorded") != true)
        #expect(failedPresentation.summary == "Verification failed")
        #expect(failedPresentation.tone == .failed)
        #expect(failedPresentation.systemImage == "exclamationmark.triangle.fill")
        #expect(failedPresentation.detail?.contains("Artifacts: none recorded") != true)
    }

    @Test("verificationPresentation surfaces deliverable review quality")
    func verificationPresentationDeliverableReviewNeeded() {
        let verification = TaskContextState.Verification(
            status: "review_needed",
            strategy: "deliverable_verification",
            command: nil,
            summary: "Deliverable artifact exists, but ASTRA needs human review.",
            evidence: [],
            updatedAt: nil,
            completionVerified: false,
            artifactStatus: "1 current",
            deliverableLevel: "needs_human_review",
            deliverableSummary: "Deterministic probes were incomplete."
        )

        let presentation = TaskPresentationState.verificationPresentation(for: verification)

        #expect(presentation.title == "Needs review")
        #expect(presentation.summary == "Needs review")
        #expect(presentation.tone == .attention)
        #expect(presentation.detail?.contains("Deliverable quality: needs_human_review") == true)
    }

    @Test("verification loader reads finished task state asynchronously")
    @MainActor
    func verificationLoaderReadsFinishedTaskState() async throws {
        let root = NSTemporaryDirectory() + "verification-loader-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)

        let workspace = makeWorkspace(name: "Verification Loader")
        workspace.primaryPath = root
        let task = makeTask(
            goal: "Verify the cached presentation path",
            status: .completed,
            workspace: workspace
        )
        let run = TaskRun(task: task)
        run.status = .completed
        run.output = "Completed without automated verification."
        run.completedAt = Date()
        task.runs = [run]

        TaskContextStateManager.refresh(task: task)
        let folder = TaskWorkspaceAccess(task: task).taskFolder

        let presentation = try #require(await TaskVerificationPresentationLoader.presentation(
            isFinished: true,
            taskFolder: folder
        ))
        let hiddenPresentation = await TaskVerificationPresentationLoader.presentation(
            isFinished: false,
            taskFolder: folder
        )

        #expect(presentation.title == "Not automatically verified")
        #expect(presentation.summary == "Not automatically verified")
        #expect(hiddenPresentation == nil)
    }

    @Test("verification loader uses injected reader away from the main actor")
    @MainActor
    func verificationLoaderUsesInjectedReaderAwayFromMainActor() async throws {
        let probe = VerificationReaderProbe(verification: TaskContextState.Verification(
            status: "passed",
            strategy: "run_tests",
            command: "swift test",
            summary: "Verified by injected reader",
            evidence: [],
            updatedAt: nil,
            completionVerified: true,
            artifactStatus: "none recorded"
        ))
        let reader = TaskVerificationStateReader { taskFolder in
            probe.record(taskFolder: taskFolder, calledOnMainThread: Thread.isMainThread)
        }

        let presentation = try #require(await TaskVerificationPresentationLoader.presentation(
            isFinished: true,
            taskFolder: "/tmp/injected-verification-reader",
            stateReader: reader
        ))

        #expect(presentation.title == "Verification passed")
        #expect(probe.recordedTaskFolders == ["/tmp/injected-verification-reader"])
        #expect(probe.calledOnMainThread == [false])
    }

    @Test("verification loader skips IO reader for unfinished or empty requests")
    func verificationLoaderSkipsIOReaderForUnfinishedOrEmptyRequests() async {
        let probe = VerificationReaderProbe(verification: nil)
        let reader = TaskVerificationStateReader { taskFolder in
            probe.record(taskFolder: taskFolder, calledOnMainThread: Thread.isMainThread)
        }

        let unfinished = await TaskVerificationPresentationLoader.presentation(
            isFinished: false,
            taskFolder: "/tmp/unfinished",
            stateReader: reader
        )
        let emptyFolder = await TaskVerificationPresentationLoader.presentation(
            isFinished: true,
            taskFolder: "",
            stateReader: reader
        )

        #expect(unfinished == nil)
        #expect(emptyFolder == nil)
        #expect(probe.recordedTaskFolders.isEmpty)
        #expect(probe.calledOnMainThread.isEmpty)
    }
}

// MARK: - TaskRun & StoredFileChange

private final class VerificationReaderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let verification: TaskContextState.Verification?
    private var taskFolders: [String] = []
    private var mainThreadCalls: [Bool] = []

    init(verification: TaskContextState.Verification?) {
        self.verification = verification
    }

    var recordedTaskFolders: [String] {
        lock.withLock { taskFolders }
    }

    var calledOnMainThread: [Bool] {
        lock.withLock { mainThreadCalls }
    }

    func record(taskFolder: String, calledOnMainThread: Bool) -> TaskContextState.Verification? {
        lock.withLock {
            taskFolders.append(taskFolder)
            mainThreadCalls.append(calledOnMainThread)
        }
        return verification
    }
}

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

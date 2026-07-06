import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA
import ASTRACore

/// Covers the board-invariant hygiene logic: title sanitisation, the low-signal
/// conversation classifier, the draft prune/hide predicates, and the idempotent
/// session-import filter. All pure logic — no model context required.
@Suite("Task hygiene")
@MainActor
struct TaskHygieneTests {

    // MARK: - Title sanitiser

    @Test("Collapses a self-doubled multi-word title")
    func collapsesDoubledTitle() {
        #expect(TaskTitleSanitizer.collapseDoubled("New greetingNew greeting") == "New greeting")
        #expect(TaskTitleSanitizer.collapseDoubled("Fix login CSSFix login CSS") == "Fix login CSS")
    }

    @Test("Leaves genuine reduplications and odd-length strings alone")
    func leavesNonDoubledAlone() {
        #expect(TaskTitleSanitizer.collapseDoubled("abcabc") == "abcabc")       // no space
        #expect(TaskTitleSanitizer.collapseDoubled("ParserParser") == "ParserParser") // single-token, no space
        #expect(TaskTitleSanitizer.collapseDoubled("hello") == "hello")        // odd length
        #expect(TaskTitleSanitizer.collapseDoubled("Review the parser") == "Review the parser")
    }

    @Test("sanitizeGeneratedTitle trims, strips quotes, and collapses")
    func sanitizeGeneratedTitle() {
        #expect(TaskTitleSanitizer.sanitizeGeneratedTitle("  \"New plan\"  ") == "New plan")
        #expect(TaskTitleSanitizer.sanitizeGeneratedTitle("Build dashboardBuild dashboard") == "Build dashboard")
    }

    // MARK: - Low-signal classifier

    @Test("Greetings and identity probes are low-signal")
    func greetingsAreLowSignal() {
        for phrase in ["hi", "Hello!", "hey there", "how are you", "who are you?",
                       "who a re you ?", "what can you do", "what is your name",
                       "new conversation", "good morning", ""] {
            #expect(
                TaskConversationSignal.isLowSignalConversation(goal: phrase, userMessages: [phrase]),
                "expected low-signal: \(phrase)"
            )
        }
    }

    @Test("Real task descriptions are not low-signal")
    func realTasksAreSubstantive() {
        for phrase in ["Review the auth module for race conditions",
                       "Check open GitHub PRs",
                       "Fix login page CSS",
                       "do i have open PRs in github?",
                       "can you read what is in this folder?",
                       "how do I run the tests",
                       // Must NOT prefix-match the "how are you" probe phrase.
                       "how are you going to fix the CI pipeline?",
                       // Slash commands are intentional even when short.
                       "/tool", "/recap"] {
            #expect(
                !TaskConversationSignal.isLowSignalConversation(goal: phrase, userMessages: [phrase]),
                "expected substantive: \(phrase)"
            )
        }
    }

    @Test("Two or more user turns is always substantive")
    func multiTurnIsSubstantive() {
        #expect(
            !TaskConversationSignal.isLowSignalConversation(
                goal: "hi",
                userMessages: ["hi", "actually, can you refactor the JSON parser"]
            )
        )
    }

    // MARK: - Draft predicates

    @Test("Every draft is hidden from the board, regardless of content")
    func everyDraftIsHidden() {
        for goal in ["hi", "Review the auth module for race conditions"] {
            let draft = AgentTask(title: goal, goal: goal)
            draft.status = .draft
            #expect(TaskHygiene.isHiddenFromBoard(draft), "draft should be hidden: \(goal)")
        }
    }

    @Test("Delegated (non-draft) work is always shown on the board")
    func delegatedWorkIsShown() {
        for status in [TaskStatus.queued, .running, .pendingUser, .completed, .failed, .cancelled] {
            let task = AgentTask(title: "Check open PRs", goal: "Check open GitHub PRs")
            task.status = status
            #expect(!TaskHygiene.isHiddenFromBoard(task), "status \(status.rawValue) should be visible")
        }
    }

    @Test("Stale, unpinned, never-run drafts are prunable; fresh/pinned/non-draft are not")
    func abandonedDraftPruning() {
        let draft = AgentTask(title: "x", goal: "Some abandoned draft")
        draft.status = .draft
        let created = draft.updatedAt

        // Fresh: not prunable (could be actively composed).
        #expect(!TaskHygiene.isPrunableAbandonedDraft(draft, olderThan: 24 * 3600, now: created))
        // Stale: prunable.
        let later = created.addingTimeInterval(48 * 3600)
        #expect(TaskHygiene.isPrunableAbandonedDraft(draft, olderThan: 24 * 3600, now: later))

        // Pinned draft: never pruned, even when stale.
        let pinned = AgentTask(title: "x", goal: "Pinned draft")
        pinned.status = .draft
        pinned.isPinned = true
        #expect(!TaskHygiene.isPrunableAbandonedDraft(pinned, olderThan: 0, now: pinned.updatedAt.addingTimeInterval(99 * 3600)))

        // Non-draft (delegated) work is never pruned by this pass.
        let queued = AgentTask(title: "x", goal: "Queued work")
        queued.status = .queued
        #expect(!TaskHygiene.isPrunableAbandonedDraft(queued, olderThan: 0, now: queued.updatedAt.addingTimeInterval(99 * 3600)))
    }

    @Test("Drafts carrying real intent are never pruned, even when stale")
    func contentDraftsAreProtectedFromPruning() {
        let stale = { (t: AgentTask) in t.updatedAt.addingTimeInterval(99 * 3600) }

        // Stored conversation (e.g. an "Address PR comments" intent draft).
        let withConversation = AgentTask(title: "Address PR #5 comments", goal: "Fix the review comments")
        withConversation.status = .draft
        withConversation.draftMessages = "[{\"role\":\"user\",\"content\":\"Fix the review comments\"}]"
        #expect(!TaskHygiene.isPrunableAbandonedDraft(withConversation, olderThan: 0, now: stale(withConversation)))

        // Attached inputs.
        let withInputs = AgentTask(title: "Process files", goal: "Process attached files")
        withInputs.status = .draft
        withInputs.inputs = ["/tmp/data.csv"]
        #expect(!TaskHygiene.isPrunableAbandonedDraft(withInputs, olderThan: 0, now: stale(withInputs)))

        // Recorded acceptance criteria (an approved-but-unrun plan).
        let withPlan = AgentTask(title: "Build feature", goal: "Build the feature")
        withPlan.status = .draft
        withPlan.acceptanceCriteria = ["Produces a report"]
        #expect(!TaskHygiene.isPrunableAbandonedDraft(withPlan, olderThan: 0, now: stale(withPlan)))

        // Programmatic intent: a template-chain main task held as .draft until
        // its before-task completes (WorkspaceCommandService) — no conversation.
        let templated = AgentTask(title: "Template main", goal: "Run the template")
        templated.status = .draft
        templated.templateID = UUID()
        #expect(!TaskHygiene.isPrunableAbandonedDraft(templated, olderThan: 0, now: stale(templated)))

        let chained = AgentTask(title: "Chained phase", goal: "Second phase")
        chained.status = .draft
        chained.chainedFromID = UUID()
        #expect(!TaskHygiene.isPrunableAbandonedDraft(chained, olderThan: 0, now: stale(chained)))
    }

    @Test("Drafts whose only content is conversation history are never pruned")
    func eventBackedDraftsAreProtectedFromPruning() throws {
        // A queued task moved back to draft for editing (TaskMainView) keeps its
        // turn in a TaskEvent, not in draftMessages. Requires a real context so
        // the event ↔ task inverse relationship is established.
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)

        let task = AgentTask(title: "Moved back to draft", goal: "Edit me")
        task.status = .draft
        context.insert(task)
        context.insert(TaskEvent(
            task: task,
            eventType: TaskEventTypes.Conversation.userMessage,
            payload: "check my open prs in github"
        ))
        try context.save()

        #expect(TaskHygiene.hasRecoverableContent(task))
        let stale = task.updatedAt.addingTimeInterval(99 * 3600)
        #expect(!TaskHygiene.isPrunableAbandonedDraft(task, olderThan: 0, now: stale))
    }

    // MARK: - Idempotent session import

    private func session(_ id: String, goal: String, userMessages: [String]? = nil) -> SessionScanner.DiscoveredSession {
        SessionScanner.DiscoveredSession(
            sessionId: id,
            goal: goal,
            userMessages: userMessages ?? [goal],
            totalTokens: 1000,
            startedAt: Date(timeIntervalSince1970: 0),
            lastActivity: Date(timeIntervalSince1970: 60),
            model: "claude-sonnet-4-6"
        )
    }

    @Test("Already-imported sessions are skipped (idempotency)")
    func skipsAlreadyImported() {
        let sessions = [session("a", goal: "Refactor the parser"), session("b", goal: "Add tests")]
        let result = SessionScanner.sessionsToImport(sessions, existingSessionIds: ["a"])
        #expect(result.map(\.sessionId) == ["b"])
    }

    @Test("Trivial greeting sessions are not imported")
    func skipsTrivialSessions() {
        let sessions = [session("a", goal: "who are you"), session("b", goal: "Investigate the flaky test")]
        let result = SessionScanner.sessionsToImport(sessions, existingSessionIds: [])
        #expect(result.map(\.sessionId) == ["b"])
    }
}

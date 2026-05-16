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
    tokenBudget: Int = TaskExecutionDefaults.tokenBudget,
    costUSD: Double = 0,
    model: String = TaskExecutionDefaults.model
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

private actor QueryStubRunner: StandardInputBinaryRunner {
    var results: [RunResult]
    private(set) var lastArgs: [String] = []
    private(set) var lastStandardInput = ""
    private(set) var allArgs: [[String]] = []
    private(set) var allStandardInputs: [String] = []

    init(result: RunResult) {
        self.results = [result]
    }

    init(results: [RunResult]) {
        self.results = results
    }

    func run(
        path: String,
        args: [String],
        timeout: TimeInterval,
        environment: [String: String]?
    ) async -> RunResult {
        lastArgs = args
        lastStandardInput = ""
        allArgs.append(args)
        allStandardInputs.append("")
        return nextResult()
    }

    func run(
        path: String,
        args: [String],
        timeout: TimeInterval,
        environment: [String: String]?,
        standardInput: String
    ) async -> RunResult {
        lastArgs = args
        lastStandardInput = standardInput
        allArgs.append(args)
        allStandardInputs.append(standardInput)
        return nextResult()
    }

    private func nextResult() -> RunResult {
        guard !results.isEmpty else {
            return RunResult(outcome: .exited(code: 0), stdout: "", stderr: "")
        }
        return results.removeFirst()
    }
}

private final class QueryBriefRecordingGenerator: QueryBriefGenerating {
    var result: Result<QueryBrief, Error>
    private(set) var lastRequest: QueryBriefRequest?

    init(result: Result<QueryBrief, Error>) {
        self.result = result
    }

    func generateBrief(_ request: QueryBriefRequest) async throws -> QueryBrief {
        lastRequest = request
        return try result.get()
    }
}

private final class QueryRepairRecordingGenerator: QueryRepairGenerating {
    var results: [Result<QueryRepairSuggestion, Error>]
    private(set) var requests: [QueryRepairRequest] = []

    init(results: [Result<QueryRepairSuggestion, Error>]) {
        self.results = results
    }

    func repair(_ request: QueryRepairRequest) async throws -> QueryRepairSuggestion {
        requests.append(request)
        guard !results.isEmpty else {
            return QueryRepairSuggestion(sql: request.failedSQL, summary: "No repair", assumptions: [])
        }
        return try results.removeFirst().get()
    }
}

private final class QueryResultExplanationRecordingGenerator: QueryResultExplanationGenerating {
    var result: Result<QueryResultExplanation, Error>
    private(set) var lastRequest: QueryResultExplanationRequest?

    init(result: Result<QueryResultExplanation, Error>) {
        self.result = result
    }

    func explainResult(_ request: QueryResultExplanationRequest) async throws -> QueryResultExplanation {
        lastRequest = request
        return try result.get()
    }
}

// MARK: - Content Selection

@Suite("Content selection")
struct ContentSelectionResolverTests {

    @Test("Effective workspace follows the selected task over stale workspace state")
    func effectiveWorkspaceFollowsSelectedTask() {
        let staleWorkspace = makeWorkspace(name: "JSL")
        let taskWorkspace = makeWorkspace(name: "REDCap")
        let task = makeTask(title: "Get current process ID", workspace: taskWorkspace)

        let resolved = ContentSelectionResolver.effectiveWorkspace(
            selectedTask: task,
            selectedWorkspace: staleWorkspace
        )

        #expect(resolved?.id == taskWorkspace.id)
    }

    @Test("Effective workspace falls back to selected workspace when no task is selected")
    func effectiveWorkspaceFallsBackToSelectedWorkspace() {
        let workspace = makeWorkspace(name: "JSL")

        let resolved = ContentSelectionResolver.effectiveWorkspace(
            selectedTask: nil,
            selectedWorkspace: workspace
        )

        #expect(resolved?.id == workspace.id)
    }

    @Test("Workspace restoration preserves a live current selection")
    func workspaceRestorationPreservesLiveCurrentSelection() {
        let first = makeWorkspace(name: "First")
        let current = makeWorkspace(name: "Current")

        let restored = ContentWorkspaceSelectionResolver.restoredWorkspace(
            workspaces: [first, current],
            currentSelection: current,
            lastSelectedWorkspaceID: first.id.uuidString,
            lastSelectedWorkspacePath: first.primaryPath
        )

        #expect(restored?.id == current.id)
    }

    @Test("Workspace restoration falls back by ID then path then first workspace")
    func workspaceRestorationFallsBackByIDPathThenFirst() {
        let first = makeWorkspace(name: "First")
        let byPath = makeWorkspace(name: "By Path")
        let byID = makeWorkspace(name: "By ID")

        let restoredByID = ContentWorkspaceSelectionResolver.restoredWorkspace(
            workspaces: [first, byPath, byID],
            currentSelection: nil,
            lastSelectedWorkspaceID: byID.id.uuidString,
            lastSelectedWorkspacePath: byPath.primaryPath
        )
        let restoredByPath = ContentWorkspaceSelectionResolver.restoredWorkspace(
            workspaces: [first, byPath],
            currentSelection: byID,
            lastSelectedWorkspaceID: byID.id.uuidString,
            lastSelectedWorkspacePath: byPath.primaryPath
        )
        let restoredFirst = ContentWorkspaceSelectionResolver.restoredWorkspace(
            workspaces: [first, byPath],
            currentSelection: nil,
            lastSelectedWorkspaceID: UUID().uuidString,
            lastSelectedWorkspacePath: "/missing"
        )

        #expect(restoredByID?.id == byID.id)
        #expect(restoredByPath?.id == byPath.id)
        #expect(restoredFirst?.id == first.id)
    }
}

// MARK: - Content Detail Presentation

@Suite("ContentDetailPresentation")
struct ContentDetailPresentationTests {

    @Test("Zero-task workspaces open directly into the new-task composer")
    func zeroTaskWorkspaceShowsComposer() {
        let workspace = makeWorkspace(name: "GitHub PRs")

        let presentation = ContentDetailPresentation.resolve(
            selectedTask: nil,
            effectiveWorkspace: workspace,
            isComposingTask: false
        )

        #expect(presentation == .newTaskComposer)
    }

    @Test("Workspaces with tasks show the workspace home")
    func workspaceWithTasksShowsHome() {
        let workspace = makeWorkspace(name: "GitHub PRs")
        let task = makeTask(workspace: workspace)
        workspace.tasks.append(task)

        let presentation = ContentDetailPresentation.resolve(
            selectedTask: nil,
            effectiveWorkspace: workspace,
            isComposingTask: false
        )

        #expect(presentation == .workspaceHome)
    }

    @Test("Selected tasks take precedence over empty workspace composer")
    func selectedTaskTakesPrecedence() {
        let workspace = makeWorkspace(name: "GitHub PRs")
        let task = makeTask(status: .queued, workspace: workspace)

        let presentation = ContentDetailPresentation.resolve(
            selectedTask: task,
            effectiveWorkspace: workspace,
            isComposingTask: false
        )

        #expect(presentation == .existingTask)
    }
}

// MARK: - New Workspace

@Suite("NewWorkspaceDraft")
struct NewWorkspaceDraftTests {

    @Test("Blank workspace names cannot be created")
    func blankNameCannotCreate() {
        let draft = NewWorkspaceDraft(name: "   ", instructions: "Context")

        #expect(!draft.canCreate)
    }

    @Test("Placeholder workspace names fall back to folder name")
    func placeholderWorkspaceNameFallsBackToFolderName() {
        let workspace = Workspace(name: "Untitled", primaryPath: "/tmp/omop-cohort-gen")

        #expect(workspace.name == "Omop Cohort Gen")
    }

    @Test("Keyboard-smash workspace names fall back to folder name")
    func keyboardSmashWorkspaceNameFallsBackToFolderName() {
        let workspace = Workspace(name: "Asdfadsf", primaryPath: "/tmp/jira-support-tickets")

        #expect(workspace.name == "Jira Support Tickets")
    }

    @Test("Workspace draft trims name and optional instructions")
    func trimsNameAndInstructions() {
        let draft = NewWorkspaceDraft(
            name: "  GitHub PRs  ",
            instructions: "\nUse alvaro as my GitHub username.  \n"
        )

        #expect(draft.canCreate)
        #expect(draft.trimmedName == "GitHub PRs")
        #expect(draft.trimmedInstructions == "Use alvaro as my GitHub username.")
    }

    @Test("Selected workspace capabilities contribute setup requirements")
    func selectedCapabilitiesRequireConfiguration() {
        var draft = NewWorkspaceDraft(name: "Research Ops")
        draft.selectedCapabilityIDs = ["jira-workflow", "github-workflow"]

        #expect(draft.capabilitySetupIssues(githubCLIReady: false) == [
            "Jira: Jira base URL",
            "Jira: Jira email",
            "Jira: Jira API token",
            "GitHub: Authenticated gh CLI"
        ])

        draft.capabilityConfiguration.jiraBaseURL = "https://example.atlassian.net"
        draft.capabilityConfiguration.jiraEmail = "user@example.com"
        draft.capabilityConfiguration.jiraAPIToken = "token"

        #expect(draft.capabilitySetupIssues(githubCLIReady: true).isEmpty)
        #expect(draft.canCreate)
    }
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

    @Test("Long bare URLs render as compact links")
    func longBareURLsRenderAsCompactLinks() {
        let rawURL = "https://docs.google.com/document/d/abcdefghijklmnopqrstuvwxyz0123456789/edit?usp=sharing"
        let attributed = MarkdownTextView.markdownAttributed("Open \(rawURL)")
        let rendered = String(attributed.characters)
        let expected = URL(string: rawURL)!

        #expect(rendered.contains("docs.google.com"))
        #expect(rendered.contains("..."))
        #expect(!rendered.contains(rawURL))
        #expect(attributed.runs.compactMap(\.link).contains(expected))
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

    @Test("Parser recognizes GitHub tables without outer pipes")
    func parserRecognizesGitHubTablesWithoutOuterPipes() {
        let source = """
        Name | Score | Status
        --- | ---: | :---
        Ada | 10 | **ready**
        Grace | 8 | waiting
        """

        let blocks = MarkdownTextView.parse(source)

        #expect(blocks.count == 1)
        #expect(blocks.first?.kind == .table)
        #expect(blocks.first?.content.contains("Name | Score | Status") == true)
        #expect(blocks.first?.content.contains("Ada | 10 | **ready**") == true)
    }

    @Test("Parser handles empty table cells without formatter crash")
    func parserHandlesEmptyTableCellsWithoutFormatterCrash() {
        let source = """
        Name | Score | Status
        --- | ---: | :---
        Ada | 10 |
        Grace | | waiting
        """

        let blocks = MarkdownTextView.parse(source)

        #expect(blocks.count == 1)
        #expect(blocks.first?.kind == .table)
        #expect(blocks.first?.content.contains("Ada | 10 |") == true)
        #expect(blocks.first?.content.contains("Grace |  | waiting") == true)
    }

    @Test("Parser formats tables for selectable Markdown preview")
    func parserFormatsTablesForSelectableMarkdownPreview() {
        let source = """
        Name | Score | Status
        --- | ---: | :---
        Ada | 10 | ready
        Grace | 8 | waiting
        """

        let rendered = MarkdownTextView.monospacedTableText(source)

        #expect(rendered.contains("Name"))
        #expect(rendered.contains("Score"))
        #expect(rendered.contains("-----"))
        #expect(rendered.contains("Ada"))
        #expect(!rendered.contains("--- | ---: | :---"))
    }

    @Test("Parser recognizes additional heading forms")
    func parserRecognizesAdditionalHeadingForms() {
        let source = """
        Report Title
        ============

        #### Deep Section ####

        #Compact Heading
        """

        let blocks = MarkdownTextView.parse(source)
        let headings = blocks.compactMap { block -> (Int, String)? in
            guard case .heading(let level) = block.kind else { return nil }
            return (level, block.content)
        }

        #expect(headings.map(\.0) == [1, 4, 1])
        #expect(headings.map(\.1) == ["Report Title", "Deep Section", "Compact Heading"])
    }

    @Test("Parser normalizes soft-wrapped prose paragraphs")
    func parserNormalizesSoftWrappedProseParagraphs() {
        let source = """
        I can use the browser.The page is blank
        and has no text to summarize.
        """

        let blocks = MarkdownTextView.parse(source)

        #expect(blocks.count == 1)
        #expect(blocks.first?.kind == .text)
        #expect(blocks.first?.content == "I can use the browser. The page is blank and has no text to summarize.")
    }

    @Test("Parser preserves fenced code block line breaks")
    func parserPreservesFencedCodeBlockLineBreaks() {
        let source = """
        ```json
        {"ok": true}
        {"done": false}
        ```
        """

        let blocks = MarkdownTextView.parse(source)

        #expect(blocks.count == 1)
        #expect(blocks.first?.kind == .codeBlock(language: "json"))
        #expect(blocks.first?.content == "{\"ok\": true}\n{\"done\": false}")
    }

    @Test("Parser preserves ordered list markers")
    func parserPreservesOrderedListMarkers() {
        let blocks = MarkdownTextView.parse("""
        1. First step
        2. Second step
        """)

        let listItems = blocks.compactMap { block -> (String, String)? in
            guard case .listItem(_, let marker) = block.kind else { return nil }
            return (marker, block.content)
        }

        #expect(listItems.map(\.0) == ["1.", "2."])
        #expect(listItems.map(\.1) == ["First step", "Second step"])
    }

    @Test("Parser preserves blockquote paragraph breaks")
    func parserPreservesBlockquoteParagraphBreaks() {
        let blocks = MarkdownTextView.parse("""
        > First quoted paragraph.
        >
        > Second quoted paragraph.
        """)

        #expect(blocks.count == 1)
        #expect(blocks.first?.kind == .blockquote)
        #expect(blocks.first?.content == "First quoted paragraph.\n\nSecond quoted paragraph.")
    }

    @Test("Streaming text normalizes soft wraps")
    func streamingTextNormalizesSoftWraps() {
        let normalized = MarkdownTextView.normalizedStreamingText("""
        First sentence.Second sentence
        continues here.
        """)

        #expect(normalized == "First sentence. Second sentence continues here.")
    }
}

// MARK: - ShelfMarkdownSession

@Suite("ShelfMarkdownSession")
struct ShelfMarkdownSessionTests {

    @MainActor
    @Test("Opening multiple Markdown files keeps them as selectable tabs")
    func openingMultipleMarkdownFilesKeepsSelectableTabs() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-markdown-tabs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let summary = root.appendingPathComponent("summary.md")
        let story = root.appendingPathComponent("warriors_story.md")
        try "# Summary".write(to: summary, atomically: true, encoding: .utf8)
        try "# The Last Quarter".write(to: story, atomically: true, encoding: .utf8)

        let session = ShelfMarkdownSession()
        session.load(summary)
        session.load(story)

        #expect(session.documents.map(\.fileURL) == [summary, story])
        #expect(session.fileURL == story)
        #expect(session.title == "warriors_story.md")
        #expect(session.content.contains("The Last Quarter"))

        session.selectDocument(summary.path)

        #expect(session.fileURL == summary)
        #expect(session.title == "summary.md")
        #expect(session.content.contains("Summary"))

        session.load(story)

        #expect(session.documents.count == 2)
        #expect(session.fileURL == story)
    }

    @MainActor
    @Test("Closing selected Markdown tab selects a neighboring file")
    func closingSelectedMarkdownTabSelectsNeighbor() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-markdown-close-tabs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = root.appendingPathComponent("first.md")
        let second = root.appendingPathComponent("second.md")
        try "First".write(to: first, atomically: true, encoding: .utf8)
        try "Second".write(to: second, atomically: true, encoding: .utf8)

        let session = ShelfMarkdownSession()
        session.load(first)
        session.load(second)
        session.closeSelectedDocument()

        #expect(session.documents.map(\.fileURL) == [first])
        #expect(session.fileURL == first)

        session.closeSelectedDocument()

        #expect(session.documents.isEmpty)
        #expect(session.fileURL == nil)
        #expect(session.title == "Text")
    }

    @MainActor
    @Test("Copying selected Markdown tab writes content to pasteboard")
    func copyingSelectedMarkdownTabWritesContentToPasteboard() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-markdown-copy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("story.md")
        try "# Story\n\nFull text".write(to: file, atomically: true, encoding: .utf8)

        let session = ShelfMarkdownSession()
        session.load(file)
        session.copyContentToPasteboard()

        #expect(NSPasteboard.general.string(forType: .string) == "# Story\n\nFull text")
    }

    @MainActor
    @Test("Saving selected text file persists edits and clears dirty state")
    func savingSelectedTextFilePersistsEditsAndClearsDirtyState() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-text-save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("notes.txt")
        try "first draft".write(to: file, atomically: true, encoding: .utf8)

        let session = ShelfMarkdownSession()
        session.load(file)

        #expect(session.selectedDocumentKind == .text)
        #expect(session.isSelectedDocumentDirty == false)

        session.updateSelectedContent("final draft\n")

        #expect(session.content == "final draft\n")
        #expect(session.isSelectedDocumentDirty == true)

        session.saveSelectedDocument()

        #expect(try String(contentsOf: file, encoding: .utf8) == "final draft\n")
        #expect(session.isSelectedDocumentDirty == false)
        #expect(session.errorMessage == nil)
    }

    @MainActor
    @Test("Text shelf infers Markdown and plain text document kinds")
    func textShelfInfersMarkdownAndPlainTextKinds() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-text-kinds-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let quarto = root.appendingPathComponent("report.qmd")
        let json = root.appendingPathComponent("data.json")
        try "# Report".write(to: quarto, atomically: true, encoding: .utf8)
        try #"{"ok":true}"#.write(to: json, atomically: true, encoding: .utf8)

        let session = ShelfMarkdownSession()
        session.load(quarto)
        session.load(json)

        #expect(session.documents.map(\.kind) == [.markdown, .text])
        #expect(session.selectedDocumentKind == .text)
        #expect(session.documents.map(\.title) == ["report.qmd", "data.json"])
    }

    @MainActor
    @Test("Reloading selected text file discards dirty edits and rereads disk")
    func reloadingSelectedTextFileDiscardsDirtyEditsAndRereadsDisk() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-text-reload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("notes.txt")
        try "original".write(to: file, atomically: true, encoding: .utf8)

        let session = ShelfMarkdownSession()
        session.load(file)
        session.updateSelectedContent("unsaved")
        try "changed on disk".write(to: file, atomically: true, encoding: .utf8)

        #expect(session.isSelectedDocumentDirty == true)

        session.reload()

        #expect(session.content == "changed on disk")
        #expect(session.isSelectedDocumentDirty == false)
        #expect(session.saveErrorMessage == nil)
    }

    @MainActor
    @Test("Failed save preserves dirty text and reports save error")
    func failedSavePreservesDirtyTextAndReportsSaveError() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-text-save-failure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let file = root.appendingPathComponent("notes.txt")
        try "original".write(to: file, atomically: true, encoding: .utf8)

        let session = ShelfMarkdownSession()
        session.load(file)
        session.updateSelectedContent("unsaved edit")
        try FileManager.default.removeItem(at: root)

        session.saveSelectedDocument()

        #expect(session.content == "unsaved edit")
        #expect(session.isSelectedDocumentDirty == true)
        #expect(session.errorMessage == nil)
        #expect(session.saveErrorMessage?.contains("Could not save notes.txt") == true)

        session.updateSelectedContent("unsaved edit with follow-up")

        #expect(session.saveErrorMessage == nil)
        #expect(session.isSelectedDocumentDirty == true)
    }

    @MainActor
    @Test("Unreadable selected file disables saving")
    func unreadableSelectedFileDisablesSaving() {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-missing-text-\(UUID().uuidString).txt")

        let session = ShelfMarkdownSession()
        session.load(file)

        #expect(session.hasFile == true)
        #expect(session.content == "")
        #expect(session.errorMessage?.contains("Could not read") == true)
        #expect(session.canSaveSelectedDocument == false)
        #expect(session.isSelectedDocumentDirty == false)
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
            #expect(run.id == firstRun.id)
        } else {
            Issue.record("Expected completed first run before the follow-up")
        }

        if case .userMessage(let text, _) = snapshot.conversationItems[2] {
            #expect(text == "Continue")
        } else {
            Issue.record("Expected follow-up user message")
        }

        if case .agentResponse(let run) = snapshot.conversationItems[3] {
            #expect(run.id == secondRun.id)
        } else {
            Issue.record("Expected remaining run output at the end")
        }
    }

    @Test("Plan conversation events appear inline")
    func planConversationEventsAppearInline() {
        let task = makeTask(goal: "Original goal")
        task.createdAt = Date(timeIntervalSince1970: 100)
        let planUser = makeEvent(
            task: task,
            type: TaskPlanConversationEventTypes.userMessage,
            payload: "Plan this first",
            timestamp: Date(timeIntervalSince1970: 110)
        )
        let planAssistant = makeEvent(
            task: task,
            type: TaskPlanConversationEventTypes.assistantMessage,
            payload: "Here is the plan",
            timestamp: Date(timeIntervalSince1970: 120)
        )

        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: [planAssistant, planUser],
            runs: []
        )

        #expect(snapshot.conversationItems.count == 3)
        if case .planUserMessage(let text, _) = snapshot.conversationItems[1] {
            #expect(text == "Plan this first")
        } else {
            Issue.record("Expected plan user message")
        }
        if case .planAssistantMessage(let text, _) = snapshot.conversationItems[2] {
            #expect(text == "Here is the plan")
        } else {
            Issue.record("Expected plan assistant message")
        }
    }

    @Test("System lifecycle events appear as timeline notices")
    func systemLifecycleEventsAppearAsTimelineNotices() {
        let task = makeTask(goal: "Original goal")
        task.createdAt = Date(timeIntervalSince1970: 100)
        let approved = makeEvent(
            task: task,
            type: TaskPlanEventTypes.approved,
            payload: "{}",
            timestamp: Date(timeIntervalSince1970: 110)
        )
        let restarted = makeEvent(
            task: task,
            type: "task.started",
            payload: "Moved back to draft for editing.",
            timestamp: Date(timeIntervalSince1970: 120)
        )

        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: [restarted, approved],
            runs: []
        )

        #expect(snapshot.conversationItems.count == 3)
        if case .systemInfo(let text, _) = snapshot.conversationItems[1] {
            #expect(text == "Plan approved.")
        } else {
            Issue.record("Expected plan approval as a system notice")
        }
        if case .systemInfo(let text, _) = snapshot.conversationItems[2] {
            #expect(text == "Moved back to draft for editing.")
        } else {
            Issue.record("Expected retry/start event as a system notice")
        }
    }

    @Test("Task run snapshot precomputes VPN warning markers")
    func taskRunSnapshotPrecomputesVPNWarningMarkers() {
        let task = makeTask()
        let run = TaskRun(task: task)
        run.output = #"API Error: 403 {"message":"Request is prohibited by organization's policy.","details":[{"reason":"SECURITY_POLICY_VIOLATED","metadata":{"vpcServiceControlsUniqueIdentifier":"abc123"}}]}"#

        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: [],
            runs: [run]
        )

        #expect(snapshot.latestRun?.hasVPNWarning == true)
    }

    @Test("Task run snapshot hides persisted ASTRA protocol marker fragments")
    func taskRunSnapshotHidesProtocolMarkerFragments() {
        let task = makeTask()
        let run = TaskRun(task: task)
        run.output = """
        ● I'll build a clean page.
           tepID":"step-1","status":"running"}
        ✓ Create .astra/tasks/3BAB3C9D/index.html (+124)
        ● ASTRA_EVENT {"v":1,"type":"complete","summary":"Verified both files created successfully
           with index.html and styles.css in black and white design. All placeholder content is clearly
           marked for customization.","verifiedBy":"File system verification"}
        Final response.
        """

        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: [],
            runs: [run]
        )

        let output = snapshot.latestRun?.output ?? ""
        #expect(!output.contains("ASTRA_EVENT"))
        #expect(!output.contains("tepID"))
        #expect(!output.contains("verifiedBy"))
        #expect(!output.contains("marked for customization"))
        #expect(output.contains("I'll build a clean page."))
        #expect(output.contains("Create .astra/tasks/3BAB3C9D/index.html"))
        #expect(output.contains("Final response."))
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

    @Test("Tool activity presentation parses tool details")
    func toolActivityPresentationParsesDetails() {
        let task = makeTask()
        let run = TaskRun(task: task)
        let events = [
            makeEvent(
                task: task,
                type: "tool.use",
                payload: "Using tool: Bash: astra-browser google-docs-read-document",
                timestamp: Date(timeIntervalSince1970: 1),
                run: run
            ),
            makeEvent(
                task: task,
                type: "tool.use",
                payload: "Using tool: Read: /tmp/notes.md",
                timestamp: Date(timeIntervalSince1970: 2),
                run: run
            ),
            makeEvent(
                task: task,
                type: "tool.use",
                payload: "Running validation tests...",
                timestamp: Date(timeIntervalSince1970: 3),
                run: run
            ),
            makeEvent(
                task: task,
                type: "tool.use",
                payload: "Using Glob",
                timestamp: Date(timeIntervalSince1970: 4),
                run: run
            )
        ]

        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: events,
            runs: [run]
        )
        let activity = snapshot.activity(for: run)

        #expect(activity.toolCalls.map(\.toolName) == ["Bash", "Read", "Validation tests", "Glob"])
        #expect(activity.toolCalls[0].detail == "astra-browser google-docs-read-document")
        #expect(activity.toolCalls[0].detailKind == .command)
        #expect(activity.toolCalls[1].detailKind == .path)
        #expect(activity.tools == [
            TaskToolSummary(name: "Bash", count: 1),
            TaskToolSummary(name: "Read", count: 1),
            TaskToolSummary(name: "Validation tests", count: 1),
            TaskToolSummary(name: "Glob", count: 1)
        ])
    }

    @Test("Permission summary presentation formats compact facts")
    func permissionSummaryPresentationFormatsFacts() {
        let payload = """
        {
          "status": "failed",
          "stopReason": "google_docs_safe_edit_unavailable",
          "toolUseCount": 1,
          "deniedCount": 0,
          "fileChangeCount": 0,
          "toolsUsed": ["Bash"],
          "commandsRun": ["astra-browser google-docs-read-document"],
          "externalDomains": ["docs.google.com"],
          "environmentKeyNames": ["GCP_PROJECT", "GCP_REGION"],
          "usedBroadProviderPermissions": true,
          "exceededInitialPermissionLevel": false
        }
        """

        let facts = PolicySummaryPresentation.permissionSummaryFacts(from: payload)

        #expect(facts.contains(RunFactPresentation(title: "Status", value: "failed")))
        #expect(facts.contains(RunFactPresentation(title: "Stop reason", value: "google_docs_safe_edit_unavailable")))
        #expect(facts.contains(RunFactPresentation(title: "Tools used", value: "1")))
        #expect(facts.contains(RunFactPresentation(title: "Broad provider mode", value: "Yes")))
        #expect(facts.contains(RunFactPresentation(title: "Commands", value: "astra-browser google-docs-read-document", isMonospaced: true)))
        #expect(facts.contains(RunFactPresentation(title: "Env keys", value: "GCP_PROJECT, GCP_REGION", isMonospaced: true)))
    }

    @Test("Run activity presentation suppresses duplicated actionable notices")
    func runActivityPresentationSuppressesActionableNotices() {
        let task = makeTask(status: .failed)
        let run = TaskRun(task: task)
        run.status = .failed
        let events = [
            makeEvent(
                task: task,
                type: "error",
                payload: "Copilot exited with code 1.\n\nProvider error:\nraw stack output",
                timestamp: Date(timeIntervalSince1970: 1),
                run: run
            )
        ]
        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: events,
            runs: [run]
        )
        let visibleRun = snapshot.latestRun!
        let activity = snapshot.activity(for: visibleRun)
        let notice = activity.notices.first!

        let presentation = RunActivityPresentation(
            run: visibleRun,
            activity: activity,
            notices: activity.notices,
            suppressedNoticeIDs: [notice.id]
        )

        #expect(presentation.issues.isEmpty)
        #expect(presentation.technicalOutputs.count == 1)
        #expect(presentation.technicalOutputs.first?.title == "Run stopped details")
        #expect(presentation.technicalOutputs.first?.rawPayload.contains("raw stack output") == true)
    }

    @Test("Run activity presentation keeps actionable notices when not rendered separately")
    func runActivityPresentationKeepsActionableIssuesWithoutSuppression() {
        let task = makeTask(status: .failed)
        let run = TaskRun(task: task)
        run.status = .failed
        let events = [
            makeEvent(
                task: task,
                type: "budget.exceeded",
                payload: "Browser action budget was exceeded.",
                timestamp: Date(timeIntervalSince1970: 1),
                run: run
            )
        ]
        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: events,
            runs: [run]
        )
        let visibleRun = snapshot.latestRun!
        let activity = snapshot.activity(for: visibleRun)

        let presentation = RunActivityPresentation(
            run: visibleRun,
            activity: activity,
            notices: activity.notices
        )

        #expect(presentation.issues.count == 1)
        #expect(presentation.issues.first?.title == "Budget exceeded")
        #expect(presentation.technicalOutputs.isEmpty)
    }

    @Test("Long tool results are summarized while preserving raw output")
    func longToolResultsAreSummarizedWithRawOutput() {
        let payload = String(repeating: "x", count: 6_000)
        let summary = PayloadFormatter.summary(for: payload)

        #expect(summary.summary.count <= 243)
        #expect(summary.summary.hasSuffix("..."))
        #expect(summary.rawPayload.count == 6_000)
    }

    @Test("Budget warning is visible in run activity")
    func budgetWarningCreatesRunNotice() {
        let task = makeTask()
        let run = TaskRun(task: task)
        let events = [
            makeEvent(
                task: task,
                type: "budget.warning",
                payload: "Budget exceeded in warning mode (147124/10000).",
                timestamp: Date(timeIntervalSince1970: 1),
                run: run
            )
        ]

        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: events,
            runs: [run]
        )
        let activity = snapshot.activity(for: run)

        #expect(activity.notices.count == 1)
        #expect(activity.notices.first?.type == "budget.warning")
        #expect(activity.notices.first?.payload.contains("147124/10000") == true)
        #expect(snapshot.conversationItems.contains {
            if case .agentResponse(let visibleRun) = $0 {
                return visibleRun.id == run.id
            }
            return false
        })
    }

    @Test("Provider error event is visible in run activity")
    func providerErrorCreatesRunNotice() {
        let task = makeTask(status: .failed)
        let run = TaskRun(task: task)
        run.status = .failed
        run.output = ""
        let events = [
            makeEvent(
                task: task,
                type: "error",
                payload: "Copilot exited with code 1. GitHub Copilot failed before ASTRA received a visible assistant response.",
                timestamp: Date(timeIntervalSince1970: 1),
                run: run
            )
        ]

        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: events,
            runs: [run]
        )
        let activity = snapshot.activity(for: run)

        #expect(activity.notices.count == 1)
        #expect(activity.notices.first?.type == "error")
        #expect(activity.notices.first?.payload.contains("Copilot exited") == true)
        #expect(snapshot.conversationItems.contains {
            if case .agentResponse(let visibleRun) = $0 {
                return visibleRun.id == run.id
            }
            return false
        })
    }

    @Test("Permission approval request is visible in run activity")
    func permissionApprovalCreatesRunNotice() {
        let task = makeTask(status: .pendingUser)
        let run = TaskRun(task: task)
        run.status = .failed
        run.stopReason = "permission_approval_required"
        let events = [
            makeEvent(
                task: task,
                type: "permission.approval.requested",
                payload: "Approve to continue with Write access.",
                timestamp: Date(timeIntervalSince1970: 1),
                run: run
            )
        ]

        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: events,
            runs: [run]
        )
        let activity = snapshot.activity(for: run)

        #expect(activity.notices.count == 1)
        #expect(activity.notices.first?.type == "permission.approval.requested")
        #expect(activity.notices.first?.payload.contains("Approve to continue") == true)
        #expect(snapshot.conversationItems.contains {
            if case .agentResponse(let visibleRun) = $0 {
                return visibleRun.id == run.id
            }
            return false
        })
    }

    @Test("Conversation includes running run with tool activity before output")
    func toolActivityCreatesLiveConversationItemBeforeOutput() {
        let createdAt = Date(timeIntervalSince1970: 100)
        let task = makeTask(goal: "Original goal", status: .running)
        task.createdAt = createdAt

        let run = TaskRun(task: task)
        run.startedAt = Date(timeIntervalSince1970: 110)
        run.status = .running
        run.output = ""

        let toolUse = makeEvent(
            task: task,
            type: "tool.use",
            payload: "Using tool: Bash",
            timestamp: Date(timeIntervalSince1970: 115),
            run: run
        )

        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: [toolUse],
            runs: [run]
        )

        #expect(snapshot.conversationItems.count == 2)
        guard case .agentResponse(let responseRun) = snapshot.conversationItems[1] else {
            Issue.record("Expected live agent response for tool-only running run")
            return
        }
        #expect(responseRun.id == run.id)
        #expect(snapshot.activity(for: responseRun).tools == [TaskToolSummary(name: "Bash", count: 1)])
    }

    @Test("Latest agent plan derives from newest ARP todo.replace event")
    func latestAgentPlanDerivesFromProtocolEvents() {
        let task = makeTask()
        let run = TaskRun(task: task)
        let firstPayload = AstraRunProtocolParsedEvent.valid(.todoReplace(items: [
            AstraRunProtocolEvent.TodoItem(text: "Old step", status: .pending)
        ])).normalizedPayload
        let secondPayload = AstraRunProtocolParsedEvent.valid(.todoReplace(items: [
            AstraRunProtocolEvent.TodoItem(text: "Inspect", status: .done),
            AstraRunProtocolEvent.TodoItem(text: "Test", status: .pending)
        ])).normalizedPayload

        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: [
                makeEvent(task: task, type: "astra.todo.replace", payload: firstPayload, timestamp: Date(timeIntervalSince1970: 1), run: run),
                makeEvent(task: task, type: "astra.todo.replace", payload: secondPayload, timestamp: Date(timeIntervalSince1970: 2), run: run)
            ],
            runs: [run]
        )

        #expect(snapshot.latestAgentPlanItems.map(\.text) == ["Inspect", "Test"])
        #expect(snapshot.latestAgentPlanItems.map(\.isDone) == [true, false])
        #expect(snapshot.protocolState(for: run).todoItems.map(\.text) == ["Inspect", "Test"])
    }

    @Test("Conversation includes run with ARP completion even when output is empty")
    func protocolCompletionCreatesConversationItem() {
        let createdAt = Date(timeIntervalSince1970: 100)
        let task = makeTask(goal: "Original goal")
        task.createdAt = createdAt
        let run = TaskRun(task: task)
        run.startedAt = Date(timeIntervalSince1970: 110)
        run.completedAt = Date(timeIntervalSince1970: 120)
        run.output = ""

        let payload = AstraRunProtocolParsedEvent.valid(.complete(
            summary: "Implementation complete.",
            verifiedBy: "swift test"
        )).normalizedPayload
        let event = makeEvent(
            task: task,
            type: "astra.complete",
            payload: payload,
            timestamp: Date(timeIntervalSince1970: 115),
            run: run
        )

        let snapshot = TaskThreadSnapshot(
            goal: task.goal,
            createdAt: task.createdAt,
            events: [event],
            runs: [run]
        )

        #expect(snapshot.conversationItems.count == 2)
        guard case .agentResponse(let responseRun) = snapshot.conversationItems[1] else {
            Issue.record("Expected agent response for protocol-only completion")
            return
        }
        #expect(responseRun.id == run.id)
        #expect(snapshot.protocolState(for: run).completionSummary == "Implementation complete.")
        #expect(snapshot.protocolState(for: run).verifiedBy == "swift test")
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

    @Test("Async snapshot builder preserves conversation and activity")
    func asyncSnapshotBuilder() async {
        let task = makeTask(goal: "Original goal")
        let run = TaskRun(task: task)
        run.startedAt = Date(timeIntervalSince1970: 10)
        run.completedAt = Date(timeIntervalSince1970: 20)
        run.output = "Done"

        let events = [
            makeEvent(
                task: task,
                type: "tool.use",
                payload: "Using tool: Read",
                timestamp: Date(timeIntervalSince1970: 11),
                run: run
            ),
            makeEvent(
                task: task,
                type: "tool.result",
                payload: "read result",
                timestamp: Date(timeIntervalSince1970: 12),
                run: run
            )
        ]

        let snapshot = await TaskThreadSnapshot.buildAsync(
            input: TaskThreadSnapshotInput(
                goal: task.goal,
                createdAt: task.createdAt,
                events: events,
                runs: [run]
            ),
            fields: [:]
        )

        #expect(snapshot.conversationItems.count == 2)
        guard case .agentResponse(let responseRun) = snapshot.conversationItems[1] else {
            Issue.record("Expected async snapshot to include the run response")
            return
        }
        #expect(responseRun.id == run.id)
        #expect(snapshot.activity(for: responseRun).tools == [
            TaskToolSummary(name: "Read", count: 1)
        ])
        #expect(snapshot.activity(for: responseRun).toolResults.first?.payload == "read result")
    }

    @Test("Task snapshot input windows long histories for app rendering")
    func taskSnapshotInputWindowsLongHistories() {
        let task = makeTask()
        task.createdAt = Date(timeIntervalSince1970: 0)

        for runIndex in 0..<100 {
            let run = TaskRun(task: task)
            run.startedAt = Date(timeIntervalSince1970: Double(runIndex * 100))
            run.completedAt = Date(timeIntervalSince1970: Double(runIndex * 100 + 90))
            run.output = "run \(runIndex)"
            task.runs.append(run)

            for resultIndex in 0..<20 {
                task.events.append(makeEvent(
                    task: task,
                    type: "tool.result",
                    payload: "result \(runIndex)-\(resultIndex)",
                    timestamp: Date(timeIntervalSince1970: Double(runIndex * 100 + resultIndex)),
                    run: run
                ))
            }
        }

        let input = TaskThreadSnapshotInput(task: task)
        let snapshot = TaskThreadSnapshot(input: input)

        #expect(input.totalRunCount == 100)
        #expect(input.omittedRunCount > 0)
        #expect(input.runs.count < 100)
        #expect(input.totalEventCount == 2_000)
        #expect(input.omittedEventCount > 0)
        #expect(snapshot.latestRun?.output == "run 99")
        #expect(!snapshot.sortedRuns.contains { $0.output == "run 0" })

        let latestActivity = snapshot.latestRun.map { snapshot.activity(for: $0) } ?? .empty
        #expect(latestActivity.toolResults.count <= 12)
        #expect(latestActivity.toolResults.last?.payload == "result 99-19")
    }

    @Test("Generated file scan excludes internal task files")
    func generatedFileScanExcludesInternalFiles() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-generated-files-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("nested")
        let outputs = root.appendingPathComponent("outputs")
        let runtimeBin = root.appendingPathComponent(".runtime-bin")

        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runtimeBin, withIntermediateDirectories: true)
        try "visible".write(to: root.appendingPathComponent("visible.txt"), atomically: true, encoding: .utf8)
        try "internal".write(to: root.appendingPathComponent("session_history.md"), atomically: true, encoding: .utf8)
        try "output".write(to: outputs.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
        try "shim".write(to: runtimeBin.appendingPathComponent("astra-browser"), atomically: true, encoding: .utf8)
        try "nested".write(to: nested.appendingPathComponent("session_history.md"), atomically: true, encoding: .utf8)

        defer { try? FileManager.default.removeItem(at: root) }

        let paths = Set(TaskGeneratedFiles.files(in: root.path))

        #expect(paths.contains(root.appendingPathComponent("visible.txt").path))
        #expect(paths.contains(nested.appendingPathComponent("session_history.md").path))
        #expect(!paths.contains(root.appendingPathComponent("session_history.md").path))
        #expect(!paths.contains(outputs.appendingPathComponent("result.txt").path))
        #expect(!paths.contains(runtimeBin.appendingPathComponent("astra-browser").path))
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

    @Test("Task file index scans task folder with shelf destinations")
    func taskFileIndexScansTaskFolderWithShelfDestinations() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-task-file-index-\(UUID().uuidString)")

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".runtime-bin"), withIntermediateDirectories: true)
        try "# Summary".write(to: root.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        try "<h1>Preview</h1>".write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "select 1".write(to: root.appendingPathComponent("query.sql"), atomically: true, encoding: .utf8)
        try "shim".write(to: root.appendingPathComponent(".runtime-bin/astra-browser"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let files = TaskFileIndex.scanTaskFolder(root.path)
        let destinations = Dictionary(uniqueKeysWithValues: files.map { ($0.name, $0.destination) })

        #expect(destinations["summary.md"] == .text)
        #expect(destinations["index.html"] == .browser)
        #expect(destinations["query.sql"] == .query)
        #expect(!files.contains { $0.path.hasSuffix(".runtime-bin/astra-browser") })
    }

    @Test("Task file index merges visible files without duplicates")
    func taskFileIndexMergesVisibleFilesWithoutDuplicates() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-task-file-merge-\(UUID().uuidString)")
        let report = root.appendingPathComponent("report.md")
        let data = root.appendingPathComponent("data.json")

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "# Report".write(to: report, atomically: true, encoding: .utf8)
        try "{}".write(to: data, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let merged = TaskFileIndex.mergedItems(
            latestRun: nil,
            taskFolderFiles: [TaskFileIndex.fileItem(path: report.path, isDirectory: false, source: "output")],
            inputs: [report.path, data.path],
            outputPathFiles: [TaskFileIndex.fileItem(path: data.path, isDirectory: false, source: "referenced")]
        )

        #expect(merged.map(\.path) == [report.path, data.path])
        #expect(merged.map(\.source) == ["output", "input"])
    }

    @Test("Generated file preview prefers task index HTML")
    func generatedFilePreviewPrefersTaskIndexHTML() {
        let root = URL(fileURLWithPath: "/tmp/astra-generated-files-preview")
        let paths = [
            root.appendingPathComponent("nested/page.html").path,
            root.appendingPathComponent("preview.htm").path,
            root.appendingPathComponent("index.html").path,
            root.appendingPathComponent("notes.txt").path
        ]

        #expect(TaskGeneratedFiles.preferredHTMLFile(in: paths, taskFolder: root.path) == root.appendingPathComponent("index.html").path)
    }

    @Test("Generated file preview ignores non HTML files")
    func generatedFilePreviewIgnoresNonHTMLFiles() {
        let paths = [
            "/tmp/result.md",
            "/tmp/styles.css",
            "/tmp/script.js"
        ]

        #expect(TaskGeneratedFiles.preferredHTMLFile(in: paths) == nil)
    }

    @Test("Generated HTML preview does not replace a user navigated page")
    func generatedHTMLPreviewDoesNotReplaceUserNavigatedPage() {
        let root = URL(fileURLWithPath: "/tmp/astra-generated-preview-autoload")
        let index = root.appendingPathComponent("index.html").path
        let about = root.appendingPathComponent("about.html").path

        #expect(TaskGeneratedFiles.shouldAutoLoadHTMLPreview(currentBrowserURL: "", targetPath: index))
        #expect(TaskGeneratedFiles.shouldAutoLoadHTMLPreview(currentBrowserURL: "about:blank", targetPath: index))
        #expect(TaskGeneratedFiles.shouldAutoLoadHTMLPreview(currentBrowserURL: URL(fileURLWithPath: index).absoluteString, targetPath: index))
        #expect(!TaskGeneratedFiles.shouldAutoLoadHTMLPreview(currentBrowserURL: URL(fileURLWithPath: about).absoluteString, targetPath: index))
        #expect(!TaskGeneratedFiles.shouldAutoLoadHTMLPreview(currentBrowserURL: "https://example.com/current-page", targetPath: index))
    }

    @Test("Generated file preview prefers task README Markdown")
    func generatedFilePreviewPrefersTaskReadmeMarkdown() {
        let root = URL(fileURLWithPath: "/tmp/astra-generated-files-markdown-preview")
        let paths = [
            root.appendingPathComponent("nested/report.md").path,
            root.appendingPathComponent("docs/starr_common.qmd").path,
            root.appendingPathComponent("summary.markdown").path,
            root.appendingPathComponent("README.md").path,
            root.appendingPathComponent("index.html").path
        ]

        #expect(TaskGeneratedFiles.preferredMarkdownFile(in: paths, taskFolder: root.path) == root.appendingPathComponent("README.md").path)
    }

    @Test("Generated file preview ignores non Markdown files")
    func generatedFilePreviewIgnoresNonMarkdownFiles() {
        let paths = [
            "/tmp/index.html",
            "/tmp/styles.css",
            "/tmp/result.txt"
        ]

        #expect(TaskGeneratedFiles.preferredMarkdownFile(in: paths) == nil)
    }

    @Test("Generated file shelf destination routes web and text artifacts")
    func generatedFileShelfDestinationRoutesPreviewableArtifacts() {
        #expect(TaskGeneratedFiles.shelfDestination(for: "/tmp/index.html") == .browser)
        #expect(TaskGeneratedFiles.shelfDestination(for: "/tmp/preview.htm") == .browser)
        #expect(TaskGeneratedFiles.shelfDestination(for: "/tmp/README.md") == .text)
        #expect(TaskGeneratedFiles.shelfDestination(for: "/tmp/report.markdown") == .text)
        #expect(TaskGeneratedFiles.shelfDestination(for: "/tmp/docs/starr_common.qmd") == .text)
        #expect(TaskGeneratedFiles.shelfDestination(for: "/tmp/query.sql") == .query)
        #expect(TaskGeneratedFiles.shelfDestination(for: "/tmp/script.py") == .text)
        #expect(TaskGeneratedFiles.shelfDestination(for: "/tmp/data.json") == .text)
        #expect(TaskGeneratedFiles.shelfDestination(for: "/tmp/session.log") == .text)
        #expect(TaskGeneratedFiles.shelfDestination(for: "/tmp/image.png") == nil)
    }

    @Test("Generated file text shelf recognition covers common source and config files")
    func generatedFileTextShelfRecognitionCoversCommonSourceAndConfigFiles() {
        let textPaths = [
            "/tmp/Sources/App.swift",
            "/tmp/scripts/run.sh",
            "/tmp/styles/site.css",
            "/tmp/data/results.jsonl",
            "/tmp/config/settings.yaml",
            "/tmp/config/.env.local",
            "/tmp/project/.gitignore",
            "/tmp/project/Dockerfile",
            "/tmp/project/Makefile",
            "/tmp/project/LICENSE",
            "/tmp/project/README"
        ]

        for path in textPaths {
            #expect(TaskGeneratedFiles.isTextShelfFile(path), "Expected \(path) to be recognized as text")
            #expect(TaskGeneratedFiles.shelfDestination(for: path) == .text, "Expected \(path) to route to the Text Shelf")
        }
    }

    @Test("Generated file shelf keeps HTML in browser even though it is text")
    func generatedFileShelfKeepsHTMLInBrowserEvenThoughItIsText() {
        #expect(TaskGeneratedFiles.isTextShelfFile("/tmp/index.html") == true)
        #expect(TaskGeneratedFiles.isTextShelfFile("/tmp/preview.htm") == true)
        #expect(TaskGeneratedFiles.shelfDestination(for: "/tmp/index.html") == .browser)
        #expect(TaskGeneratedFiles.shelfDestination(for: "/tmp/preview.htm") == .browser)
    }

    @Test("Generated file text shelf rejects unknown binary and arbitrary extensionless files")
    func generatedFileTextShelfRejectsUnknownBinaryAndArbitraryExtensionlessFiles() {
        #expect(TaskGeneratedFiles.isTextShelfFile("/tmp/image.png") == false)
        #expect(TaskGeneratedFiles.isTextShelfFile("/tmp/archive.zip") == false)
        #expect(TaskGeneratedFiles.isTextShelfFile("/tmp/random-output") == false)
        #expect(TaskGeneratedFiles.shelfDestination(for: "/tmp/image.png") == nil)
        #expect(TaskGeneratedFiles.shelfDestination(for: "/tmp/archive.zip") == nil)
        #expect(TaskGeneratedFiles.shelfDestination(for: "/tmp/random-output") == nil)
    }

    @Test("Generated file preview finds attached SQL inputs")
    func generatedFilePreviewFindsAttachedSQLInputs() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-attached-sql-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("nested")

        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "select 1".write(to: root.appendingPathComponent("query.sql"), atomically: true, encoding: .utf8)
        try "select 2".write(to: nested.appendingPathComponent("report.sql"), atomically: true, encoding: .utf8)
        try "not sql".write(to: nested.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TaskGeneratedFiles.sqlFiles(inInputs: [
            root.appendingPathComponent("query.sql").path,
            root.path,
            root.appendingPathComponent("notes.txt").path
        ])

        #expect(paths.contains(root.appendingPathComponent("query.sql").path))
        #expect(paths.contains(nested.appendingPathComponent("report.sql").path))
        #expect(!paths.contains(nested.appendingPathComponent("notes.txt").path))
    }

    @Test("SQL classifier separates reads from mutations and scripts")
    func sqlClassifierSeparatesReadsFromMutationsAndScripts() {
        #expect(SQLClassifier.classify("-- comment\nselect * from users") == .read)
        #expect(SQLClassifier.classify("with x as (select 1) select * from x") == .read)
        #expect(SQLClassifier.classify("update users set active = false") == .dml)
        #expect(SQLClassifier.classify("create table backup as select * from users") == .ddl)
        #expect(SQLClassifier.classify("select 1; select 2") == .script)
    }

    @Test("AI Brief parser reads prefixed JSON")
    func queryBriefParserReadsPrefixedJSON() throws {
        let output = """
        planning text
        ASTRA_QUERY_BRIEF {"version":1,"goal":"Compare visits","grain":"one row per dataset and visit source","tables":["demo.clinical.visit_occurrence"],"columns":["visit_source_value"],"filters":["visit_source_value LIKE '%History%'"],"joins":[],"assumptions":["History means source value contains History"],"risk":"low","estimatedCost":"12 KB","checks":[{"status":"passed","label":"All referenced columns are listed"}],"notes":["Dry run has not executed"]}
        """

        let brief = try #require(QueryBriefParser.parse(from: output))

        #expect(brief.goal == "Compare visits")
        #expect(brief.grain == "one row per dataset and visit source")
        #expect(brief.risk == .low)
        #expect(brief.checks.first?.status == .passed)
    }

    @Test("Query repair parser reads prefixed JSON")
    func queryRepairParserReadsPrefixedJSON() throws {
        let output = """
        ASTRA_QUERY_REPAIR {"sql":"SELECT 1 AS value","summary":"Replaced the missing column with a constant for validation.","assumptions":["The user only needs a smoke test."]}
        """

        let repair = try #require(QueryRepairParser.parse(from: output))

        #expect(repair.sql == "SELECT 1 AS value")
        #expect(repair.summary.contains("missing column"))
        #expect(repair.assumptions == ["The user only needs a smoke test."])
    }

    @Test("AI result explanation parser reads prefixed JSON")
    func queryResultExplanationParserReadsPrefixedJSON() throws {
        let output = """
        ASTRA_RESULT_EXPLANATION {"version":1,"headline":"stet53 has the dominant History source count.","summary":"The returned preview compares History-like visit sources across two datasets.","keyFindings":["stet53 History has 392224 rows while stet54 History has 1065 rows."],"anomalies":["stet54 is much lower than stet53 for the plain History source."],"caveats":["This only explains the returned preview rows."],"followUps":["Check the upstream source period for stet54."],"checks":[{"status":"warning","label":"Preview rows may be limited by the shelf row limit."}]}
        """

        let explanation = try #require(QueryResultExplanationParser.parse(from: output))

        #expect(explanation.headline.contains("stet53"))
        #expect(explanation.keyFindings.first?.contains("392224") == true)
        #expect(explanation.checks.first?.status == .warning)
    }

    @Test("SQL syntax tokenizer preserves strings comments and quoted identifiers")
    func sqlSyntaxTokenizerPreservesStringsCommentsAndQuotedIdentifiers() {
        let sql = "-- comment\nSELECT 'from' AS source FROM `demo.dataset.table` WHERE value = 42"
        let tokens = SQLSyntaxTokenizer.tokens(in: sql)

        #expect(tokens.contains { $0.kind == .lineComment && $0.text == "-- comment" })
        #expect(tokens.contains { $0.kind == .stringLiteral && $0.text == "'from'" })
        #expect(tokens.contains { $0.kind == .quotedIdentifier && $0.text == "`demo.dataset.table`" })
        #expect(tokens.contains { $0.kind == .number && $0.text == "42" })
    }

    @Test("SQL formatter uppercases keywords and breaks common clauses")
    func sqlFormatterUppercasesKeywordsAndBreaksCommonClauses() {
        let input = """
        -- keep this comment
        select 'from' as source, count(*) as n from `demo.dataset.table` where visit_source_value like '%History%' group by 1 order by n desc
        """

        let formatted = SQLFormatter.format(input)

        #expect(formatted.contains("-- keep this comment"))
        #expect(formatted.contains("SELECT 'from' AS source,"))
        #expect(formatted.contains("\n    COUNT(*) AS n"))
        #expect(formatted.contains("\nFROM `demo.dataset.table`"))
        #expect(formatted.contains("\nWHERE visit_source_value LIKE '%History%'"))
        #expect(formatted.contains("\nGROUP BY 1"))
        #expect(formatted.contains("\nORDER BY n DESC"))
    }

    @MainActor
    @Test("Query session stores generated AI Brief")
    func querySessionStoresGeneratedAIBrief() async throws {
        let session = ShelfQuerySession()
        let connection = DatabaseConnection(
            id: "bigquery-cli",
            displayName: "BigQuery",
            adapterID: "bigquery-cli",
            dialect: .bigQueryStandard,
            defaultNamespace: "clinical",
            projectID: "demo"
        )
        let expectedBrief = QueryBrief(
            goal: "Preview a constant value",
            grain: "one row",
            tables: [],
            columns: ["value"],
            risk: .low,
            checks: [
                QueryBriefTrustCheck(status: .passed, label: "Read-only SQL")
            ]
        )
        let generator = QueryBriefRecordingGenerator(result: .success(expectedBrief))

        session.loadSQL("SELECT 1 AS value", title: "constant.sql")
        await session.generateBrief(
            connection: connection,
            taskContext: QueryBriefTaskContext(
                taskTitle: "Check BigQuery",
                taskGoal: "Run a simple query",
                workspaceName: "Analytics"
            ),
            generator: generator
        )

        #expect(session.aiBrief?.goal == "Preview a constant value")
        #expect(session.aiBriefErrorMessage == nil)
        #expect(generator.lastRequest?.sql == "SELECT 1 AS value")
        #expect(generator.lastRequest?.classification == .read)
        #expect(generator.lastRequest?.taskContext?.taskTitle == "Check BigQuery")
    }

    @MainActor
    @Test("Query session clears stale AI Brief when SQL changes")
    func querySessionClearsStaleAIBriefWhenSQLChanges() async {
        let session = ShelfQuerySession()
        let generator = QueryBriefRecordingGenerator(result: .success(QueryBrief(goal: "Initial brief")))

        session.loadSQL("SELECT 1", title: "constant.sql")
        await session.generateBrief(
            connection: .editOnly,
            taskContext: nil,
            generator: generator
        )
        session.updateSelectedSQL("SELECT 2")

        #expect(session.aiBrief == nil)
        #expect(session.aiBriefErrorMessage == nil)
    }

    @MainActor
    @Test("Query session stores generated AI result explanation")
    func querySessionStoresGeneratedAIResultExplanation() async throws {
        let runner = QueryStubRunner(result: RunResult(
            outcome: .exited(code: 0),
            stdout: #"[{"dataset":"stet53","row_count":392224},{"dataset":"stet54","row_count":1065}]"#,
            stderr: "Total bytes processed: 42"
        ))
        let adapter = BigQueryCLIAdapter(runner: runner, bqPath: "/bin/echo")
        let session = ShelfQuerySession(queryService: DatabaseQueryService(adapters: [
            "bigquery-cli": adapter
        ]))
        let connection = DatabaseConnection(
            id: "bigquery-cli",
            displayName: "BigQuery",
            adapterID: "bigquery-cli",
            dialect: .bigQueryStandard,
            defaultNamespace: "clinical",
            projectID: "demo"
        )
        let expectedExplanation = QueryResultExplanation(
            headline: "stet53 has many more History rows than stet54.",
            summary: "The preview compares row counts by dataset.",
            keyFindings: ["stet53 has 392224 rows compared with 1065 for stet54."],
            caveats: ["This reflects only the returned preview."]
        )
        let generator = QueryResultExplanationRecordingGenerator(result: .success(expectedExplanation))

        session.loadSQL("SELECT dataset, row_count FROM comparison", title: "comparison.sql")
        await session.run(connection: connection)
        await session.explainResult(
            connection: connection,
            taskContext: QueryBriefTaskContext(
                taskTitle: "Compare History visits",
                taskGoal: "Understand dataset differences",
                workspaceName: "Analytics"
            ),
            generator: generator
        )

        #expect(session.resultExplanation?.headline.contains("stet53") == true)
        #expect(session.resultExplanationErrorMessage == nil)
        #expect(generator.lastRequest?.sql == "SELECT dataset, row_count FROM comparison")
        #expect(generator.lastRequest?.executionResult.rowCount == 2)
        #expect(generator.lastRequest?.taskContext?.taskTitle == "Compare History visits")
    }

    @MainActor
    @Test("Query result explanation requires an executed result")
    func queryResultExplanationRequiresExecutedResult() async {
        let session = ShelfQuerySession()
        let generator = QueryResultExplanationRecordingGenerator(result: .success(QueryResultExplanation(headline: "Unused")))

        session.loadSQL("SELECT 1", title: "constant.sql")
        await session.explainResult(
            connection: .editOnly,
            taskContext: nil,
            generator: generator
        )

        #expect(session.resultExplanation == nil)
        #expect(session.resultExplanationErrorMessage == QueryResultExplanationError.noResult.localizedDescription)
        #expect(generator.lastRequest == nil)
    }

    @MainActor
    @Test("Query session clears stale AI result explanation when SQL changes")
    func querySessionClearsStaleAIResultExplanationWhenSQLChanges() async {
        let runner = QueryStubRunner(result: RunResult(
            outcome: .exited(code: 0),
            stdout: #"[{"value":1}]"#,
            stderr: ""
        ))
        let adapter = BigQueryCLIAdapter(runner: runner, bqPath: "/bin/echo")
        let session = ShelfQuerySession(queryService: DatabaseQueryService(adapters: [
            "bigquery-cli": adapter
        ]))
        let connection = DatabaseConnection(
            id: "bigquery-cli",
            displayName: "BigQuery",
            adapterID: "bigquery-cli",
            dialect: .bigQueryStandard,
            defaultNamespace: nil,
            projectID: "demo"
        )
        let generator = QueryResultExplanationRecordingGenerator(result: .success(QueryResultExplanation(headline: "Initial explanation")))

        session.loadSQL("SELECT 1 AS value", title: "constant.sql")
        await session.run(connection: connection)
        await session.explainResult(connection: connection, taskContext: nil, generator: generator)
        session.updateSelectedSQL("SELECT 2 AS value")

        #expect(session.resultExplanation == nil)
        #expect(session.resultExplanationErrorMessage == nil)
    }

    @MainActor
    @Test("Self-healing validation passes without repair when dry run succeeds")
    func selfHealingValidationPassesWithoutRepairWhenDryRunSucceeds() async {
        let runner = QueryStubRunner(result: RunResult(
            outcome: .exited(code: 0),
            stdout: "",
            stderr: "Query successfully validated. This query will process 1 bytes when run."
        ))
        let adapter = BigQueryCLIAdapter(runner: runner, bqPath: "/bin/echo")
        let session = ShelfQuerySession(queryService: DatabaseQueryService(adapters: [
            "bigquery-cli": adapter
        ]))
        let connection = DatabaseConnection(
            id: "bigquery-cli",
            displayName: "BigQuery",
            adapterID: "bigquery-cli",
            dialect: .bigQueryStandard,
            defaultNamespace: nil,
            projectID: "demo"
        )
        let repairGenerator = QueryRepairRecordingGenerator(results: [])

        session.loadSQL("SELECT 1 AS value", title: "constant.sql")
        await session.validateAndRepair(
            connection: connection,
            taskContext: nil,
            repairGenerator: repairGenerator
        )

        #expect(session.sql == "SELECT 1 AS value")
        #expect(session.dryRunResult?.bytesProcessed == 1)
        #expect(session.validationSteps.contains { $0.status == .passed })
        #expect(session.selfHealingOriginalSQL == nil)
        #expect(repairGenerator.requests.isEmpty)
        #expect(await runner.allStandardInputs == ["SELECT 1 AS value"])
    }

    @MainActor
    @Test("Self-healing validation applies AI repair and retries dry run")
    func selfHealingValidationAppliesAIRepairAndRetriesDryRun() async {
        let runner = QueryStubRunner(results: [
            RunResult(outcome: .exited(code: 1), stdout: "", stderr: "Unrecognized name: bad_column"),
            RunResult(
                outcome: .exited(code: 0),
                stdout: "",
                stderr: "Query successfully validated. This query will process 2 bytes when run."
            )
        ])
        let adapter = BigQueryCLIAdapter(runner: runner, bqPath: "/bin/echo")
        let session = ShelfQuerySession(queryService: DatabaseQueryService(adapters: [
            "bigquery-cli": adapter
        ]))
        let connection = DatabaseConnection(
            id: "bigquery-cli",
            displayName: "BigQuery",
            adapterID: "bigquery-cli",
            dialect: .bigQueryStandard,
            defaultNamespace: nil,
            projectID: "demo"
        )
        let repairGenerator = QueryRepairRecordingGenerator(results: [
            .success(QueryRepairSuggestion(
                sql: "SELECT 1 AS value",
                summary: "Replaced the missing column with a constant.",
                assumptions: ["The intended smoke test can use a constant value."]
            ))
        ])

        session.loadSQL("SELECT bad_column", title: "broken.sql")
        await session.validateAndRepair(
            connection: connection,
            taskContext: QueryBriefTaskContext(taskTitle: "Smoke test", taskGoal: "Validate SQL", workspaceName: "Analytics"),
            repairGenerator: repairGenerator
        )

        #expect(session.sql == "SELECT 1 AS value")
        #expect(session.selfHealingOriginalSQL == "SELECT bad_column")
        #expect(session.dryRunResult?.bytesProcessed == 2)
        #expect(repairGenerator.requests.first?.dryRunError.contains("Unrecognized name") == true)
        #expect(session.validationSteps.map(\.status).contains(.failed))
        #expect(session.validationSteps.map(\.status).contains(.repaired))
        #expect(session.validationSteps.map(\.status).contains(.passed))
        #expect(await runner.allStandardInputs == ["SELECT bad_column", "SELECT 1 AS value"])

        session.restoreSelfHealingOriginalSQL()

        #expect(session.sql == "SELECT bad_column")
        #expect(session.selfHealingOriginalSQL == nil)
    }

    @MainActor
    @Test("Self-healing validation blocks mutation SQL before dry run")
    func selfHealingValidationBlocksMutationSQLBeforeDryRun() async {
        let runner = QueryStubRunner(result: RunResult(outcome: .exited(code: 0), stdout: "", stderr: ""))
        let adapter = BigQueryCLIAdapter(runner: runner, bqPath: "/bin/echo")
        let session = ShelfQuerySession(queryService: DatabaseQueryService(adapters: [
            "bigquery-cli": adapter
        ]))
        let connection = DatabaseConnection(
            id: "bigquery-cli",
            displayName: "BigQuery",
            adapterID: "bigquery-cli",
            dialect: .bigQueryStandard,
            defaultNamespace: nil,
            projectID: "demo"
        )
        let repairGenerator = QueryRepairRecordingGenerator(results: [])

        session.loadSQL("DELETE FROM demo.dataset.table WHERE id = 1", title: "delete.sql")
        await session.validateAndRepair(
            connection: connection,
            taskContext: nil,
            repairGenerator: repairGenerator
        )

        #expect(session.validationErrorMessage?.contains("read-only") == true)
        #expect(session.validationSteps.first?.status == .blocked)
        #expect(repairGenerator.requests.isEmpty)
        #expect((await runner.allArgs).isEmpty)
    }

    @Test("BigQuery dry run parses bytes processed")
    func bigQueryDryRunParsesBytesProcessed() async throws {
        let runner = QueryStubRunner(result: RunResult(
            outcome: .exited(code: 0),
            stdout: "",
            stderr: "Query successfully validated. This query will process 12,345 bytes when run."
        ))
        let adapter = BigQueryCLIAdapter(runner: runner, bqPath: "/bin/echo")
        let result = try await adapter.dryRun(QueryRequest(
            sql: "-- leading comment\nselect 1",
            connection: DatabaseConnection(
                id: "bigquery-cli",
                displayName: "BigQuery",
                adapterID: "bigquery-cli",
                dialect: .bigQueryStandard,
                defaultNamespace: nil,
                projectID: "demo"
            ),
            rowLimit: 100
        ))

        #expect(result.bytesProcessed == 12345)
        #expect(result.message.contains("12,345 bytes"))
        #expect(await runner.lastStandardInput == "-- leading comment\nselect 1")
        #expect(!((await runner.lastArgs).contains { $0.contains("leading comment") }))
    }

    @Test("BigQuery run parses JSON preview rows")
    func bigQueryRunParsesJSONPreviewRows() async throws {
        let runner = QueryStubRunner(result: RunResult(
            outcome: .exited(code: 0),
            stdout: #"[{"name":"Ada","total":3}]"#,
            stderr: #"totalBytesProcessed: "42""#
        ))
        let adapter = BigQueryCLIAdapter(runner: runner, bqPath: "/bin/echo")
        let result = try await adapter.run(QueryRequest(
            sql: "select 'Ada' as name, 3 as total",
            connection: DatabaseConnection(
                id: "bigquery-cli",
                displayName: "BigQuery",
                adapterID: "bigquery-cli",
                dialect: .bigQueryStandard,
                defaultNamespace: nil,
                projectID: nil
            ),
            rowLimit: 100
        ))

        #expect(Set(result.columns.map(\.name)) == ["name", "total"])
        #expect(Set(result.rows.first ?? []) == ["Ada", "3"])
        #expect(result.bytesProcessed == 42)
    }

    @Test("BigQuery schema lists tables and columns")
    func bigQuerySchemaListsTablesAndColumns() async throws {
        let runner = QueryStubRunner(results: [
            RunResult(
                outcome: .exited(code: 0),
                stdout: #"[{"tableReference":{"projectId":"demo","datasetId":"clinical","tableId":"person"},"type":"TABLE"}]"#,
                stderr: ""
            ),
            RunResult(
                outcome: .exited(code: 0),
                stdout: #"{"schema":{"fields":[{"name":"person_id","type":"INT64","mode":"REQUIRED"},{"name":"birth_datetime","type":"TIMESTAMP","mode":"NULLABLE"}]}}"#,
                stderr: ""
            )
        ])
        let adapter = BigQueryCLIAdapter(runner: runner, bqPath: "/bin/echo")
        let connection = DatabaseConnection(
            id: "bigquery-cli",
            displayName: "BigQuery",
            adapterID: "bigquery-cli",
            dialect: .bigQueryStandard,
            defaultNamespace: "clinical",
            projectID: "demo"
        )

        let catalog = try await adapter.schema(SchemaRequest(connection: connection, datasetID: nil))
        let table = try #require(catalog.datasets.first?.tables.first)
        let detailed = try await adapter.tableSchema(SchemaTableRequest(
            connection: connection,
            projectID: table.projectID,
            datasetID: table.datasetID,
            tableID: table.tableID
        ))

        #expect(table.fullName == "demo:clinical.person")
        #expect(table.projectID == "demo")
        #expect(detailed.columns.map(\.name) == ["person_id", "birth_datetime"])
        #expect(await runner.allArgs == [
            ["--project_id=demo", "ls", "--format=json", "demo:clinical"],
            ["--project_id=demo", "show", "--format=json", "demo:clinical.person"]
        ])
    }

    @Test("BigQuery schema uses datasets referenced by SQL first")
    func bigQuerySchemaUsesDatasetsReferencedBySQLFirst() async throws {
        let runner = QueryStubRunner(results: [
            RunResult(outcome: .exited(code: 0), stdout: #"[]"#, stderr: ""),
            RunResult(outcome: .exited(code: 0), stdout: #"[]"#, stderr: "")
        ])
        let adapter = BigQueryCLIAdapter(runner: runner, bqPath: "/bin/echo")
        let connection = DatabaseConnection(
            id: "bigquery-cli",
            displayName: "BigQuery",
            adapterID: "bigquery-cli",
            dialect: .bigQueryStandard,
            defaultNamespace: nil,
            projectID: "som-rit-phi-starr-dev"
        )

        _ = try await adapter.schema(SchemaRequest(
            connection: connection,
            datasetID: nil,
            sqlContext: """
            SELECT * FROM `som-rit-phi-starr-dev.stet54_destination.visit_occurrence`
            UNION ALL
            SELECT * FROM `som-rit-phi-starr-dev.stet53_destination.visit_occurrence`
            """
        ))

        #expect(await runner.allArgs == [
            ["--project_id=som-rit-phi-starr-dev", "ls", "--format=json", "som-rit-phi-starr-dev:stet54_destination"],
            ["--project_id=som-rit-phi-starr-dev", "ls", "--format=json", "som-rit-phi-starr-dev:stet53_destination"]
        ])
    }

    @Test("BigQuery schema parser tolerates warning text around JSON")
    func bigQuerySchemaParserToleratesWarningTextAroundJSON() async throws {
        let runner = QueryStubRunner(result: RunResult(
            outcome: .exited(code: 0),
            stdout: """
            Waiting on bq auth refresh...
            [{"tableReference":{"projectId":"demo","datasetId":"clinical","tableId":"visit_occurrence"},"type":"TABLE"}]
            trailing diagnostic
            """,
            stderr: ""
        ))
        let adapter = BigQueryCLIAdapter(runner: runner, bqPath: "/bin/echo")
        let catalog = try await adapter.schema(SchemaRequest(
            connection: DatabaseConnection(
                id: "bigquery-cli",
                displayName: "BigQuery",
                adapterID: "bigquery-cli",
                dialect: .bigQueryStandard,
                defaultNamespace: "clinical",
                projectID: "demo"
            ),
            datasetID: nil
        ))

        #expect(catalog.datasets.first?.tables.first?.tableID == "visit_occurrence")
    }

    @Test("BigQuery recovery creates copy backup for mutations")
    func bigQueryRecoveryCreatesCopyBackupForMutations() async throws {
        let runner = QueryStubRunner(result: RunResult(
            outcome: .exited(code: 0),
            stdout: "",
            stderr: ""
        ))
        let adapter = BigQueryCLIAdapter(runner: runner, bqPath: "/bin/echo")
        let plan = try await adapter.prepareRecovery(QueryRequest(
            sql: "UPDATE `demo.clinical.person` SET active = false WHERE person_id = 1",
            connection: DatabaseConnection(
                id: "bigquery-cli",
                displayName: "BigQuery",
                adapterID: "bigquery-cli",
                dialect: .bigQueryStandard,
                defaultNamespace: nil,
                projectID: "demo"
            ),
            rowLimit: 100
        ), classification: .dml)

        #expect(plan.isPrepared)
        #expect(plan.sourceTableID == "demo.clinical.person")
        #expect(plan.backupTableID?.contains("demo.clinical.person__astra_backup_") == true)
        #expect(plan.restoreSQL.contains("CREATE OR REPLACE TABLE `demo.clinical.person`"))
        #expect((await runner.lastArgs).prefix(3) == ["--project_id=demo", "cp", "demo:clinical.person"])
    }

    @MainActor
    @Test("Query session blocks mutation after recovery until safety gate is approved")
    func querySessionBlocksMutationAfterRecoveryUntilSafetyGateApproved() async {
        let runner = QueryStubRunner(results: [
            RunResult(outcome: .exited(code: 0), stdout: "", stderr: "")
        ])
        let adapter = BigQueryCLIAdapter(runner: runner, bqPath: "/bin/echo")
        let session = ShelfQuerySession(queryService: DatabaseQueryService(adapters: [
            "bigquery-cli": adapter
        ]))
        let connection = DatabaseConnection(
            id: "bigquery-cli",
            displayName: "BigQuery",
            adapterID: "bigquery-cli",
            dialect: .bigQueryStandard,
            defaultNamespace: "clinical",
            projectID: "demo"
        )

        session.loadSQL("DELETE FROM `demo.clinical.person` WHERE person_id = 1", title: "delete.sql")
        await session.prepareRecovery(connection: connection)
        await session.run(connection: connection)

        #expect(session.recoveryPlan?.isPrepared == true)
        #expect(session.safetyGateReview?.isApproved == false)
        #expect(session.errorMessage == "Mutation and script execution is blocked until the safe execution gate is approved.")
        #expect(session.history.first?.status == .blocked)
        #expect((await runner.allArgs).count == 1)
        #expect((await runner.allArgs).first?.contains("cp") == true)
        #expect(await runner.allStandardInputs == [""])
    }

    @MainActor
    @Test("Query session runs mutation after recovery and safety gate approval")
    func querySessionRunsMutationAfterRecoveryAndSafetyGateApproval() async {
        let runner = QueryStubRunner(results: [
            RunResult(outcome: .exited(code: 0), stdout: "", stderr: ""),
            RunResult(outcome: .exited(code: 0), stdout: #"[]"#, stderr: "")
        ])
        let adapter = BigQueryCLIAdapter(runner: runner, bqPath: "/bin/echo")
        let session = ShelfQuerySession(queryService: DatabaseQueryService(adapters: [
            "bigquery-cli": adapter
        ]))
        let connection = DatabaseConnection(
            id: "bigquery-cli",
            displayName: "BigQuery",
            adapterID: "bigquery-cli",
            dialect: .bigQueryStandard,
            defaultNamespace: "clinical",
            projectID: "demo"
        )

        session.loadSQL("DELETE FROM `demo.clinical.person` WHERE person_id = 1", title: "delete.sql")
        await session.prepareRecovery(connection: connection)
        session.approveSafetyGate(connection: connection)
        await session.run(connection: connection)

        #expect(session.recoveryPlan?.isPrepared == true)
        #expect(session.hasApprovedSafetyGate(connection: connection))
        #expect(session.errorMessage == nil)
        #expect(session.executionResult?.rowCount == 0)
        #expect(session.history.first?.status == .succeeded)
        #expect(await runner.allStandardInputs.last == "DELETE FROM `demo.clinical.person` WHERE person_id = 1")
    }

    @MainActor
    @Test("Safety gate approval is cleared when SQL changes")
    func safetyGateApprovalIsClearedWhenSQLChanges() async {
        let runner = QueryStubRunner(result: RunResult(outcome: .exited(code: 0), stdout: "", stderr: ""))
        let adapter = BigQueryCLIAdapter(runner: runner, bqPath: "/bin/echo")
        let session = ShelfQuerySession(queryService: DatabaseQueryService(adapters: [
            "bigquery-cli": adapter
        ]))
        let connection = DatabaseConnection(
            id: "bigquery-cli",
            displayName: "BigQuery",
            adapterID: "bigquery-cli",
            dialect: .bigQueryStandard,
            defaultNamespace: "clinical",
            projectID: "demo"
        )

        session.loadSQL("DELETE FROM `demo.clinical.person` WHERE person_id = 1", title: "delete.sql")
        await session.prepareRecovery(connection: connection)
        session.approveSafetyGate(connection: connection)
        session.updateSelectedSQL("DELETE FROM `demo.clinical.person` WHERE person_id = 2")

        #expect(session.recoveryPlan == nil)
        #expect(session.safetyGateReview == nil)
        #expect(!session.hasApprovedSafetyGate(connection: connection))
    }

    @MainActor
    @Test("Safety gate approval cannot reuse recovery from another connection")
    func safetyGateApprovalCannotReuseRecoveryFromAnotherConnection() async {
        let runner = QueryStubRunner(result: RunResult(outcome: .exited(code: 0), stdout: "", stderr: ""))
        let adapter = BigQueryCLIAdapter(runner: runner, bqPath: "/bin/echo")
        let session = ShelfQuerySession(queryService: DatabaseQueryService(adapters: [
            "bigquery-cli": adapter
        ]))
        let originalConnection = DatabaseConnection(
            id: "bigquery-dev",
            displayName: "BigQuery Dev",
            adapterID: "bigquery-cli",
            dialect: .bigQueryStandard,
            defaultNamespace: "clinical",
            projectID: "demo"
        )
        let otherConnection = DatabaseConnection(
            id: "bigquery-prod",
            displayName: "BigQuery Prod",
            adapterID: "bigquery-cli",
            dialect: .bigQueryStandard,
            defaultNamespace: "clinical",
            projectID: "demo"
        )

        session.loadSQL("DELETE FROM `demo.clinical.person` WHERE person_id = 1", title: "delete.sql")
        await session.prepareRecovery(connection: originalConnection)
        session.approveSafetyGate(connection: otherConnection)
        await session.run(connection: otherConnection)

        #expect(session.recoveryPlan?.isPrepared == true)
        #expect(!session.hasCurrentPreparedRecovery(connection: otherConnection))
        #expect(!session.hasApprovedSafetyGate(connection: otherConnection))
        #expect(session.errorMessage == "Mutation and script execution is blocked until a prepared recovery plan exists.")
        #expect((await runner.allArgs).count == 1)
        #expect((await runner.allArgs).first?.contains("cp") == true)
    }

    @MainActor
    @Test("Read-only query runs without safety gate approval")
    func readOnlyQueryRunsWithoutSafetyGateApproval() async {
        let runner = QueryStubRunner(result: RunResult(
            outcome: .exited(code: 0),
            stdout: #"[{"value":1}]"#,
            stderr: ""
        ))
        let adapter = BigQueryCLIAdapter(runner: runner, bqPath: "/bin/echo")
        let session = ShelfQuerySession(queryService: DatabaseQueryService(adapters: [
            "bigquery-cli": adapter
        ]))
        let connection = DatabaseConnection(
            id: "bigquery-cli",
            displayName: "BigQuery",
            adapterID: "bigquery-cli",
            dialect: .bigQueryStandard,
            defaultNamespace: nil,
            projectID: "demo"
        )

        session.loadSQL("SELECT 1 AS value", title: "read.sql")
        await session.run(connection: connection)

        #expect(session.safetyGateReview == nil)
        #expect(session.errorMessage == nil)
        #expect(session.executionResult?.rowCount == 1)
        #expect(await runner.allStandardInputs == ["SELECT 1 AS value"])
    }

    @MainActor
    @Test("Query session persists task scoped history")
    func querySessionPersistsTaskScopedHistory() async {
        let taskID = UUID()
        let storageKey = "astra.queryShelf.history.\(taskID.uuidString)"
        UserDefaults.standard.removeObject(forKey: storageKey)
        defer { UserDefaults.standard.removeObject(forKey: storageKey) }

        let runner = QueryStubRunner(result: RunResult(
            outcome: .exited(code: 0),
            stdout: "",
            stderr: "Query successfully validated. This query will process 1 bytes when run."
        ))
        let adapter = BigQueryCLIAdapter(runner: runner, bqPath: "/bin/echo")
        let session = ShelfQuerySession(queryService: DatabaseQueryService(adapters: [
            "bigquery-cli": adapter
        ]))
        let connection = DatabaseConnection(
            id: "bigquery-cli",
            displayName: "BigQuery",
            adapterID: "bigquery-cli",
            dialect: .bigQueryStandard,
            defaultNamespace: nil,
            projectID: "demo"
        )

        session.bindToTask(taskID)
        session.loadSQL("select 1", title: "query.sql")
        await session.dryRun(connection: connection)

        let restored = ShelfQuerySession()
        restored.bindToTask(taskID)

        #expect(restored.history.first?.status == .dryRunSucceeded)
        #expect(restored.history.first?.sql == "select 1")
    }

    @MainActor
    @Test("Query session keeps schema browser when column loading fails")
    func querySessionKeepsSchemaBrowserWhenColumnLoadingFails() async {
        let runner = QueryStubRunner(results: [
            RunResult(
                outcome: .exited(code: 0),
                stdout: #"[{"tableReference":{"projectId":"demo","datasetId":"clinical","tableId":"visit_occurrence"},"type":"TABLE"}]"#,
                stderr: ""
            ),
            RunResult(
                outcome: .exited(code: 0),
                stdout: "not json",
                stderr: ""
            )
        ])
        let adapter = BigQueryCLIAdapter(runner: runner, bqPath: "/bin/echo")
        let session = ShelfQuerySession(queryService: DatabaseQueryService(adapters: [
            "bigquery-cli": adapter
        ]))
        let connection = DatabaseConnection(
            id: "bigquery-cli",
            displayName: "BigQuery",
            adapterID: "bigquery-cli",
            dialect: .bigQueryStandard,
            defaultNamespace: "clinical",
            projectID: "demo"
        )

        await session.loadSchema(connection: connection)
        let table = session.schemaCatalog?.datasets.first?.tables.first
        if let table {
            await session.loadTableSchema(table, connection: connection)
        }

        #expect(session.schemaCatalog?.datasets.first?.tables.first?.tableID == "visit_occurrence")
        #expect(session.schemaErrorMessage == nil)
        #expect(session.tableSchemaErrorTableID == "demo:clinical.visit_occurrence")
        #expect(session.tableSchemaErrorMessage?.contains("without a JSON payload") == true)
    }

    @MainActor
    @Test("Query session loads columns using table project instead of connection project")
    func querySessionLoadsColumnsUsingTableProjectInsteadOfConnectionProject() async {
        let runner = QueryStubRunner(results: [
            RunResult(
                outcome: .exited(code: 0),
                stdout: #"[{"tableReference":{"projectId":"som-rit-phi-starr-dev","datasetId":"stet54_destination","tableId":"care_site"},"type":"TABLE"}]"#,
                stderr: ""
            ),
            RunResult(
                outcome: .exited(code: 0),
                stdout: #"{"schema":{"fields":[{"name":"care_site_id","type":"INT64"}]}}"#,
                stderr: ""
            )
        ])
        let adapter = BigQueryCLIAdapter(runner: runner, bqPath: "/bin/echo")
        let session = ShelfQuerySession(queryService: DatabaseQueryService(adapters: [
            "bigquery-cli": adapter
        ]))
        let connection = DatabaseConnection(
            id: "bigquery-cli",
            displayName: "BigQuery",
            adapterID: "bigquery-cli",
            dialect: .bigQueryStandard,
            defaultNamespace: nil,
            projectID: "upo-nero-phi-su-deid-pa"
        )

        session.loadSQL("SELECT * FROM `som-rit-phi-starr-dev.stet54_destination.care_site`", title: "query.sql")
        await session.loadSchema(connection: connection)
        let table = session.schemaCatalog?.datasets.first?.tables.first
        if let table {
            await session.loadTableSchema(table, connection: connection)
        }

        #expect(session.tableSchemaErrorMessage == nil)
        #expect(session.schemaCatalog?.datasets.first?.tables.first?.columns.map(\.name) == ["care_site_id"])
        #expect(await runner.allArgs == [
            [
                "--project_id=upo-nero-phi-su-deid-pa",
                "ls",
                "--format=json",
                "som-rit-phi-starr-dev:stet54_destination"
            ],
            [
                "--project_id=upo-nero-phi-su-deid-pa",
                "show",
                "--format=json",
                "som-rit-phi-starr-dev:stet54_destination.care_site"
            ]
        ])
    }

    @MainActor
    @Test("Query session blocks mutations before execution")
    func querySessionBlocksMutationsBeforeExecution() async {
        let session = ShelfQuerySession()
        session.loadSQL("delete from users where active = false", title: "Dangerous.sql")
        await session.run(connection: DatabaseConnection(
            id: "bigquery-cli",
            displayName: "BigQuery",
            adapterID: "bigquery-cli",
            dialect: .bigQueryStandard,
            defaultNamespace: nil,
            projectID: nil
        ))

        #expect(session.errorMessage == "Mutation and script execution is blocked until a prepared recovery plan exists.")
        #expect(session.history.first?.status == .blocked)
    }

    @MainActor
    @Test("Query session discovers BigQuery from skill-attached tools")
    func querySessionDiscoversBigQueryFromSkillAttachedTools() {
        let workspace = makeWorkspace(name: "BigQuery")
        let skill = Skill(name: "GCloud Agent")
        skill.workspace = workspace
        let tool = LocalTool(name: "bq - BigQuery CLI", command: "bq", arguments: "")
        tool.workspace = workspace
        tool.skill = skill
        skill.localTools = [tool]
        workspace.skills = [skill]

        let connections = ShelfQuerySession().availableConnections(for: workspace)

        #expect(connections.contains { $0.adapterID == "bigquery-cli" })
    }

    @MainActor
    @Test("Query session discovers BigQuery from enabled global tools")
    func querySessionDiscoversBigQueryFromEnabledGlobalTools() {
        let workspace = makeWorkspace(name: "BigQuery")
        let tool = LocalTool(name: "bq - BigQuery CLI", command: "bq", arguments: "")
        tool.isGlobal = true
        workspace.enabledGlobalToolIDs = [tool.id.uuidString]

        let connections = ShelfQuerySession().availableConnections(
            for: workspace,
            globalTools: [tool]
        )

        #expect(connections.contains { $0.adapterID == "bigquery-cli" })
    }

    @MainActor
    @Test("Query session auto-selects runnable connection when available")
    func querySessionAutoSelectsRunnableConnectionWhenAvailable() {
        let session = ShelfQuerySession()
        let connection = DatabaseConnection(
            id: "bigquery-cli",
            displayName: "BigQuery CLI",
            adapterID: "bigquery-cli",
            dialect: .bigQueryStandard,
            defaultNamespace: nil,
            projectID: nil
        )

        session.selectConnectionIfNeeded(from: [.editOnly, connection])

        #expect(session.selectedConnectionID == "bigquery-cli")
        #expect(session.selectedDialect == .bigQueryStandard)
    }

    @Test("Generated file preview finds attached Markdown inputs")
    func generatedFilePreviewFindsAttachedMarkdownInputs() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-attached-markdown-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("nested")

        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "# Attached".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "nested".write(to: nested.appendingPathComponent("notes.markdown"), atomically: true, encoding: .utf8)
        try "quarto".write(to: nested.appendingPathComponent("starr_common.qmd"), atomically: true, encoding: .utf8)
        try "html".write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TaskGeneratedFiles.markdownFiles(inInputs: [
            root.appendingPathComponent("README.md").path,
            root.path,
            root.appendingPathComponent("index.html").path
        ])

        #expect(paths.contains(root.appendingPathComponent("README.md").path))
        #expect(paths.contains(nested.appendingPathComponent("notes.markdown").path))
        #expect(paths.contains(nested.appendingPathComponent("starr_common.qmd").path))
        #expect(!paths.contains(root.appendingPathComponent("index.html").path))
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

import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Task file turns")
struct TaskFileTurnsTests {
    private static let workspace = "/ws"
    private static let folder = "/ws/.astra/tasks/T1"
    private static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test("Turns count the goal as 1, list newest first, and skip turns that changed nothing")
    func numbersAndOrdersTurns() {
        let input = makeInput(
            requests: [request("Second ask", at: 100), request("Third ask", at: 200)],
            runs: [
                run(at: 10, changes: [change("plan.md", .discovered, at: 11)]),
                run(at: 110, changes: []),
                run(at: 210, changes: [change("plan.md", .modified, at: 211)])
            ]
        )

        let turns = TaskFileTurns.build(input, fileExists: { _ in true })

        #expect(turns.map(\.number) == [3, 1])
        #expect(turns.map(\.request) == ["Third ask", "Write the plan"])
        #expect(turns.first?.entries.map(\.change) == [.edited])
    }

    @Test("A run belongs to the message that launched it; an unlinked retry to the latest earlier request")
    func assignsRunsToTheirRequests() {
        let linkedRunID = UUID()
        let input = makeInput(
            // The message is stamped after its run started; the link still wins.
            requests: [request("Follow-up", at: 105, runID: linkedRunID)],
            runs: [
                run(id: linkedRunID, at: 100, changes: [change("a.md", .discovered, at: 101)]),
                run(at: 120, changes: [change("b.md", .discovered, at: 121)])
            ]
        )

        let turns = TaskFileTurns.build(input, fileExists: { _ in true })

        #expect(turns.map(\.number) == [2])
        #expect(turns.first?.entries.map(\.displayPath) == ["a.md", "b.md"])
    }

    @Test("A tool write is new the first time the task sees a path and an edit after that")
    func classifiesChangesAcrossTurns() {
        let input = makeInput(
            requests: [request("Revise", at: 100)],
            runs: [
                run(at: 10, changes: [change("report.md", .write, at: 11), change("notes.md", .write, at: 12)]),
                run(at: 110, changes: [
                    change("report.md", .write, at: 111),
                    change("fresh.md", .write, at: 112),
                    change("notes.md", .removed, at: 113),
                    change("scratch.md", .discovered, at: 114),
                    change("scratch.md", .removed, at: 115)
                ])
            ]
        )

        let turns = TaskFileTurns.build(input, fileExists: { _ in true })
        let latest = turns.first

        #expect(latest?.entries.map(\.displayPath) == ["fresh.md", "report.md", "notes.md"])
        #expect(latest?.entries.map(\.change) == [.new, .edited, .removed])
        #expect(latest?.entries.last?.exists == false)
        #expect(turns.last?.entries.map(\.change) == [.new, .new])
    }

    @Test("Bookkeeping and other tasks' files stay out; workspace files show relative to the workspace")
    func keepsOnlyFilesAUserWouldBrowse() {
        let input = makeInput(runs: [run(at: 10, changes: [
            change("outputs/turn_001.md", .write, at: 11),
            change("current_state.json", .write, at: 11),
            TaskFileTurnsInput.Change(path: "/ws/.astra/tasks/OTHER/x.md", kind: .write, timestamp: at(11)),
            TaskFileTurnsInput.Change(path: "/ws/src/App.swift", kind: .edit, timestamp: at(12)),
            change("answer.md", .write, at: 13)
        ])])

        let entries = TaskFileTurns.build(input, fileExists: { _ in true }).first?.entries

        #expect(entries?.map(\.displayPath) == ["answer.md", "src/App.swift"])
        #expect(entries?.map(\.path) == [Self.folder + "/answer.md", "/ws/src/App.swift"])
    }

    @Test("A path a provider recorded relative to the workspace opens from the task folder")
    func resolvesWorkspaceRelativePaths() {
        let input = makeInput(runs: [run(at: 10, changes: [
            TaskFileTurnsInput.Change(path: ".astra/tasks/T1/index.html", kind: .write, timestamp: at(11)),
            change("index.html", .edit, at: 12)
        ])])

        let entries = TaskFileTurns.build(input, fileExists: { _ in true }).first?.entries

        #expect(entries?.map(\.path) == [Self.folder + "/index.html"])
        #expect(entries?.map(\.change) == [.new])
    }

    @Test("Files only the artifact index saw go to the run they appeared in, as new files only")
    func recoversOlderTurnsFromTheArtifactIndex() {
        let input = makeInput(
            requests: [request("Build it", at: 100)],
            runs: [
                run(at: 10, endsAt: 20, changes: [change("tool.md", .write, at: 11)]),
                run(at: 110, endsAt: 120, changes: [])
            ],
            indexedFiles: [
                indexed("tool.md", at: 11),
                indexed("shell-output.csv", at: 123),
                indexed("shell-output.csv", at: 300),
                indexed("unmatched.md", at: 500)
            ]
        )

        let turns = TaskFileTurns.build(input, fileExists: { _ in true })

        #expect(turns.map(\.number) == [2, 1])
        #expect(turns.first?.entries.map(\.displayPath) == ["shell-output.csv"])
        #expect(turns.first?.listsNewFilesOnly == true)
        #expect(turns.last?.listsNewFilesOnly == false)
    }

    @Test("A file an older turn created keeps that turn when a later run edits it")
    func laterEditDoesNotEraseAnIndexedCreation() {
        let input = makeInput(
            requests: [request("Tweak it", at: 100)],
            runs: [
                run(at: 10, endsAt: 20, changes: []),
                run(at: 110, endsAt: 120, changes: [change("report.md", .modified, at: 115)])
            ],
            indexedFiles: [indexed("report.md", at: 21)]
        )

        let turns = TaskFileTurns.build(input, fileExists: { _ in true })

        #expect(turns.map(\.number) == [2, 1])
        #expect(turns.map { $0.entries.map(\.change) } == [[.edited], [.new]])
    }

    @Test("A tool path outside the task folder and the workspace is not listed")
    func pathsOutsideTheBrowsableRootsAreLeftOut() {
        let input = makeInput(runs: [run(at: 10, changes: [
            TaskFileTurnsInput.Change(path: "/tmp/scratch.md", kind: .write, timestamp: at(11)),
            TaskFileTurnsInput.Change(path: "/other-workspace/notes.md", kind: .write, timestamp: at(11)),
            change("answer.md", .write, at: 12)
        ])])

        let entries = TaskFileTurns.build(input, fileExists: { _ in true }).first?.entries

        #expect(entries?.map(\.displayPath) == ["answer.md"])
    }

    @Test("A fork's copied runs name the source task's folder; their files open from the fork's")
    func forkedHistoryMapsOntoTheForksFolder() {
        var input = makeInput(runs: [run(at: 10, changes: [
            TaskFileTurnsInput.Change(path: "/ws/.astra/tasks/PARENT/plan.md", kind: .write, timestamp: at(11))
        ])])
        input.inheritedTaskFolders = ["/ws/.astra/tasks/PARENT"]

        let entries = TaskFileTurns.build(input, fileExists: { _ in true }).first?.entries

        #expect(entries?.map(\.path) == [Self.folder + "/plan.md"])
        #expect(entries?.map(\.displayPath) == ["plan.md"])
    }

    @Test("Files under the workspace's additional folders are listed under that folder's name")
    func additionalWorkspaceRootsAreBrowsable() {
        var input = makeInput(runs: [run(at: 10, changes: [
            TaskFileTurnsInput.Change(path: "/repos/api/Sources/App.swift", kind: .edit, timestamp: at(11))
        ])])
        input.additionalRoots = ["/repos/api"]

        let entries = TaskFileTurns.build(input, fileExists: { _ in true }).first?.entries

        #expect(entries?.map(\.path) == ["/repos/api/Sources/App.swift"])
        #expect(entries?.map(\.displayPath) == ["api/Sources/App.swift"])
    }

    @Test("A plan-created task's ask is its goal, so it counts once, as turn 1")
    func goalEchoedByAPlanMessageIsOneTurn() {
        let input = makeInput(
            requests: [
                TaskFileTurnsInput.Request(text: " Write the plan\n", requestedAt: at(1), runID: nil, isPlanMessage: true),
                request("Next", at: 100)
            ],
            runs: [
                run(at: 10, changes: [change("plan.md", .discovered, at: 11)]),
                run(at: 110, changes: [change("next.md", .discovered, at: 111)])
            ]
        )

        let turns = TaskFileTurns.build(input, fileExists: { _ in true })

        #expect(turns.map(\.number) == [2, 1])
        #expect(turns.map(\.request) == ["Next", " Write the plan\n"])
    }

    @Test("A relative path resolves where the task runs, then in the workspace folder")
    func relativePathsResolveAgainstTheExecutionDirectory() {
        var input = makeInput(runs: [run(at: 10, changes: [
            TaskFileTurnsInput.Change(path: "Sources/App.swift", kind: .edit, timestamp: at(11)),
            TaskFileTurnsInput.Change(path: ".astra/tasks/T1/plan.md", kind: .write, timestamp: at(12))
        ])])
        input.executionPath = "/repos/api"

        let entries = TaskFileTurns.build(input, fileExists: { _ in true }).first?.entries

        #expect(entries?.map(\.path) == [Self.folder + "/plan.md", "/repos/api/Sources/App.swift"])
        #expect(entries?.map(\.displayPath) == ["plan.md", "api/Sources/App.swift"])
    }

    @Test("A running turn shows before it has changed anything")
    func runningTurnIsListed() {
        let input = makeInput(
            requests: [request("Keep going", at: 100)],
            runs: [run(at: 110, isRunning: true, changes: [])]
        )

        let turns = TaskFileTurns.build(input, fileExists: { _ in true })

        #expect(turns.map(\.number) == [2])
        #expect(turns.first?.isRunning == true)
    }

    @Test("A file a later turn removed cannot be opened from the turn that made it")
    func marksFilesNoLongerOnDisk() {
        let input = makeInput(runs: [run(at: 10, changes: [change("gone.md", .discovered, at: 11)])])

        let entry = TaskFileTurns.build(input, fileExists: { _ in false }).first?.entries.first

        #expect(entry?.change == .new)
        #expect(entry?.exists == false)
    }

    // MARK: - Fixtures

    private func makeInput(
        requests: [TaskFileTurnsInput.Request] = [],
        runs: [TaskFileTurnsInput.Run],
        indexedFiles: [TaskFileTurnsInput.IndexedFile] = []
    ) -> TaskFileTurnsInput {
        TaskFileTurnsInput(
            goal: "Write the plan",
            createdAt: Self.start,
            requests: requests,
            runs: runs,
            indexedFiles: indexedFiles,
            taskFolder: Self.folder,
            workspacePath: Self.workspace
        )
    }

    private func at(_ seconds: TimeInterval) -> Date { Self.start.addingTimeInterval(seconds) }

    private func request(_ text: String, at seconds: TimeInterval, runID: UUID? = nil) -> TaskFileTurnsInput.Request {
        TaskFileTurnsInput.Request(text: text, requestedAt: at(seconds), runID: runID)
    }

    private func run(
        id: UUID = UUID(),
        at seconds: TimeInterval,
        endsAt end: TimeInterval? = nil,
        isRunning: Bool = false,
        changes: [TaskFileTurnsInput.Change]
    ) -> TaskFileTurnsInput.Run {
        TaskFileTurnsInput.Run(
            id: id,
            startedAt: at(seconds),
            completedAt: isRunning ? nil : at(end ?? seconds + 5),
            isRunning: isRunning,
            changes: changes
        )
    }

    private func change(_ name: String, _ kind: StoredFileChangeKind, at seconds: TimeInterval) -> TaskFileTurnsInput.Change {
        TaskFileTurnsInput.Change(path: Self.folder + "/" + name, kind: kind, timestamp: at(seconds))
    }

    private func indexed(_ name: String, at seconds: TimeInterval) -> TaskFileTurnsInput.IndexedFile {
        TaskFileTurnsInput.IndexedFile(path: Self.folder + "/" + name, indexedAt: at(seconds))
    }
}

@Suite("Task file turns presentation")
struct ShelfFileTurnsPresentationTests {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter
    }()

    @Test("The subtitle leads with the turn number, then when, then counts by kind")
    func subtitleCarriesNumberTimeAndCounts() {
        let turn = makeTurn(entries: [entry("a.md", .new), entry("b.md", .edited), entry("c.md", .edited)])
        #expect(ShelfFileTurnsPresentation.subtitle(for: turn, formatter: Self.formatter) == "Turn 4 · Jan 1, 12:00 AM · 1 new, 2 edited")

        let running = makeTurn(isRunning: true, entries: [entry("gone.md", .removed)])
        #expect(ShelfFileTurnsPresentation.subtitle(for: running, formatter: Self.formatter) == "Turn 4 · Running · 1 removed")
    }

    @Test("The title is the first line the user wrote")
    func titleIsTheFirstLine() {
        #expect(ShelfFileTurnsPresentation.title(for: makeTurn(request: "\n  Fix the README\nand more")) == "Fix the README")
        #expect(ShelfFileTurnsPresentation.title(for: makeTurn(request: "Attached files:\n- /tmp/a.png")) == "Attached files")
    }

    @Test("Hidden files stay out unless Show hidden paths is on, as in Folders")
    func hiddenFilesFollowThePreference() {
        let turns = [
            makeTurn(number: 2, entries: [entry(".env", .new)]),
            makeTurn(number: 1, entries: [entry("config/.secrets/key.md", .edited), entry("plan.md", .new)])
        ]

        let hidden = ShelfFileTurnsPresentation.visibleTurns(turns, matching: "", showsHiddenPaths: false)
        #expect(hidden.map(\.number) == [1])
        #expect(hidden.first?.entries.map(\.displayPath) == ["plan.md"])

        let shown = ShelfFileTurnsPresentation.visibleTurns(turns, matching: "", showsHiddenPaths: true)
        #expect(shown.map { $0.entries.count } == [1, 2])
    }

    @Test("Search keeps matching files, or every file of a request whose text matches")
    func searchFiltersByPathOrRequest() {
        let turns = [
            makeTurn(number: 2, request: "Refresh the report", entries: [entry("report.csv", .edited), entry("notes.md", .new)]),
            makeTurn(number: 1, request: "Start", entries: [entry("reports/q3.md", .new), entry("plan.md", .new)])
        ]

        let byPath = ShelfFileTurnsPresentation.visibleTurns(turns, matching: "q3")
        #expect(byPath.map(\.number) == [1])
        #expect(byPath.first?.entries.map(\.displayPath) == ["reports/q3.md"])

        let byRequest = ShelfFileTurnsPresentation.visibleTurns(turns, matching: "refresh")
        #expect(byRequest.first?.entries.count == 2)
    }

    @Test("An open turn shows its first hundred files until the user asks for all of them")
    func openTurnShowsAPreviewOfItsFiles() {
        let turn = makeTurn(entries: (0..<150).map { entry("out/\($0).csv", .new) })

        #expect(ShelfFileTurnsPresentation.shownEntries(of: turn, showsAll: false).count == 100)
        #expect(ShelfFileTurnsPresentation.shownEntries(of: turn, showsAll: true).count == 150)
        #expect(ShelfFileTurnsPresentation.showAllTitle(for: turn) == "Show all 150 files")
    }

    private func makeTurn(
        number: Int = 4,
        request: String = "Ask",
        isRunning: Bool = false,
        entries: [TaskFileTurn.Entry] = []
    ) -> TaskFileTurn {
        TaskFileTurn(
            number: number,
            request: request,
            requestedAt: Date(timeIntervalSince1970: 0),
            isRunning: isRunning,
            entries: entries,
            listsNewFilesOnly: false
        )
    }

    private func entry(_ path: String, _ change: TaskFileTurn.Change) -> TaskFileTurn.Entry {
        TaskFileTurn.Entry(path: "/t/" + path, displayPath: path, change: change, changedAt: Date(), exists: true)
    }
}

@Suite("Task file turns store read")
@MainActor
struct TaskFileTurnsStoreTests {
    @Test("The store reads every run, message link, and indexed file into turns")
    func storeReadsTheWholeHistory() async throws {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Turns", primaryPath: "/ws")
        let task = AgentTask(title: "Report", goal: "Write the report", workspace: workspace)
        let folder = TaskWorkspaceAccess(task: task).taskFolder
        let first = TaskRun(task: task)
        first.appendHostFileChanges([StoredFileChange(path: folder + "/report.csv", changeType: "discovered")])
        first.status = .completed
        first.completedAt = first.startedAt
        let second = TaskRun(task: task)
        second.startedAt = first.startedAt.addingTimeInterval(60)
        second.appendHostFileChanges([StoredFileChange(path: folder + "/report.csv", changeType: "modified")])
        second.status = .completed
        second.completedAt = second.startedAt
        let message = TaskEvent(task: task, eventType: TaskEventTypes.Conversation.userMessage, payload: "Add a row", run: second)
        message.timestamp = second.startedAt
        context.insert(workspace)
        context.insert(task)
        context.insert(first)
        context.insert(second)
        context.insert(message)
        try context.save()

        let turns = try await TaskThreadHistoryStore(container: container).fileTurns(
            taskID: task.id,
            taskFolder: folder,
            workspacePath: "/ws"
        )

        #expect(turns.map(\.number) == [2, 1])
        #expect(turns.map(\.request) == ["Add a row", "Write the report"])
        #expect(turns.map { $0.entries.map(\.change) } == [[.edited], [.new]])
    }

    @Test("A streaming run's unsaved changes are read from the main context, without saving it")
    func unsavedRunChangesAreOverlaid() async throws {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        // Autosave would save between the awaits below and hide whether the
        // read saved anything.
        context.autosaveEnabled = false
        let workspace = Workspace(name: "Turns", primaryPath: "/ws")
        let task = AgentTask(title: "Report", goal: "Write the report", workspace: workspace)
        let folder = TaskWorkspaceAccess(task: task).taskFolder
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        try context.save()
        run.appendFileChange(StoredFileChange(path: folder + "/draft.md", changeType: "Write", content: "x"))
        #expect(context.hasChanges)

        let store = TaskThreadHistoryStore(container: container)
        let saved = try await store.fileTurns(taskID: task.id, taskFolder: folder, workspacePath: "/ws")
        let overlaid = try await store.fileTurns(
            taskID: task.id,
            taskFolder: folder,
            workspacePath: "/ws",
            pendingRuns: [TaskFileTurnsReader.PendingRun(run)]
        )

        #expect(saved.flatMap(\.entries).isEmpty)
        #expect(overlaid.first?.entries.map(\.displayPath) == ["draft.md"])
        #expect(context.hasChanges)
    }
}

import Testing
import ASTRACore
@testable import ASTRA

@Suite("New task worktree dock")
struct NewTaskWorktreeDockPresentationTests {
    private let astra = GitRepositoryInfo(name: "astra", path: "/tmp/astra-dock/astra")
    private let docs = GitRepositoryInfo(name: "docs", path: "/tmp/astra-dock/docs")
    private let site = GitRepositoryInfo(name: "site", path: "/tmp/astra-dock/site")

    private func selection(
        enabled: Bool = false,
        repositories: [GitRepositoryInfo]? = nil,
        selected: String? = nil,
        loading: Bool = false
    ) -> NewTaskWorktreeSelection {
        var selection = NewTaskWorktreeSelection()
        selection.repositories = repositories ?? [astra, docs]
        selection.isEnabled = enabled
        selection.repositoryPath = selected
        selection.isLoading = loading
        return selection
    }

    private func dock(
        _ selection: NewTaskWorktreeSelection,
        allowsChoice: Bool = true,
        pinnedPath: String? = nil,
        isPreparing: Bool = false,
        problem: String? = nil
    ) -> NewTaskWorktreeDockPresentation? {
        NewTaskWorktreeDockPresentation.build(.init(
            selection: selection,
            allowsChoice: allowsChoice,
            pinnedPath: pinnedPath,
            isPreparing: isPreparing,
            problem: problem
        ))
    }

    @Test("No strip appears without repositories, a pinned draft, or a problem")
    func hiddenWithoutContent() {
        #expect(dock(selection(repositories: [])) == nil)
        #expect(dock(selection(), allowsChoice: false) == nil)
        #expect(dock(selection(), allowsChoice: false, problem: "  \n ") == nil)
    }

    @Test("Associated repositories show an unchecked trailing checkbox and name the current checkouts")
    func uncheckedStripNamesRepositories() throws {
        let unchecked = try #require(dock(selection()))
        #expect(unchecked.tone == .neutral)
        #expect(unchecked.title == "Current checkouts")
        #expect(unchecked.meta == "astra, docs")
        #expect(unchecked.showsToggle)
        #expect(!unchecked.showsRepositoryMenu)
        #expect(!unchecked.controlsDisabled)
        #expect(unchecked.problem == nil)

        let single = try #require(dock(selection(repositories: [astra])))
        #expect(single.title == "Current checkout")
        #expect(single.meta == "astra")
    }

    @Test("Repository summaries stay compact")
    func repositorySummaryStaysCompact() {
        #expect(NewTaskWorktreeDockPresentation.repositorySummary([]) == nil)
        #expect(NewTaskWorktreeDockPresentation.repositorySummary([astra, docs, site]) == "astra, docs +1")
    }

    @Test("Checking the box reveals the repository menu and reports whether the task can start")
    func checkedStates() throws {
        let ready = try #require(dock(selection(enabled: true, selected: docs.path)))
        #expect(ready.tone == .success)
        #expect(ready.title == "New worktree")
        #expect(ready.glyph == .symbol("arrow.triangle.branch"))
        #expect(ready.showsToggle && ready.showsRepositoryMenu)
        #expect(ready.help.contains("docs"))

        let loading = try #require(dock(selection(enabled: true, repositories: [], loading: true)))
        #expect(loading.glyph == .progress)
        #expect(loading.meta == "checking repositories…")
        #expect(loading.showsToggle && !loading.showsRepositoryMenu)

        let unchosen = try #require(dock(selection(enabled: true, selected: "/tmp/astra-dock/removed")))
        #expect(unchosen.tone == .attention)
        #expect(unchosen.meta == "choose a repository")
        #expect(unchosen.showsRepositoryMenu)

        let missing = try #require(dock(selection(enabled: true, repositories: [])))
        #expect(missing.tone == .attention)
        #expect(missing.meta == "no Git repositories found")
        #expect(missing.showsToggle && !missing.showsRepositoryMenu)
    }

    @Test("Setup progress appears only while a worktree is actually being created")
    func preparingStates() throws {
        let creating = try #require(dock(selection(enabled: true, selected: astra.path), isPreparing: true))
        #expect(creating.tone == .running)
        #expect(creating.glyph == .progress)
        #expect(creating.title == "Creating worktree")
        #expect(creating.meta == "astra")
        #expect(creating.controlsDisabled)

        // Every submission briefly prepares; a plain run must not flash worktree progress.
        let plainRun = try #require(dock(selection(), isPreparing: true))
        #expect(plainRun.title == "Current checkouts")
        #expect(plainRun.glyph != .progress)
        #expect(plainRun.controlsDisabled)
    }

    @Test("Drafts show their pinned worktree without choice controls")
    func pinnedDraftHidesChoice() throws {
        let path = "/tmp/astra-dock/Worktrees/astra/astra-task"
        let pinned = try #require(dock(
            selection(enabled: true, selected: astra.path),
            allowsChoice: false,
            pinnedPath: path
        ))
        #expect(pinned.title == "Task worktree")
        #expect(pinned.meta == WorkspacePathPresentation.abbreviatePath(path))
        #expect(pinned.help.contains(path))
        #expect(!pinned.showsToggle)
        #expect(!pinned.showsRepositoryMenu)
    }

    @Test("Task-creation problems use the failure tone and keep the choice available for retry")
    func problemsKeepChoiceForRetry() throws {
        let message = TaskWorktreeCreationError.noCommit("/tmp/astra-dock/astra").localizedDescription
        let failed = try #require(dock(selection(enabled: true, selected: astra.path), problem: message))
        #expect(failed.tone == .failed)
        #expect(failed.title == "Task not started")
        #expect(failed.problem == message)
        #expect(failed.help == message)
        #expect(failed.showsToggle && failed.showsRepositoryMenu)

        let noRepositories = try #require(dock(selection(repositories: []), problem: " Save failed \n"))
        #expect(noRepositories.problem == "Save failed")
        #expect(!noRepositories.showsToggle)

        let pinnedDraft = try #require(dock(
            selection(),
            allowsChoice: false,
            pinnedPath: "/tmp/astra-dock/Worktrees/astra/astra-task",
            problem: "Save failed"
        ))
        #expect(pinnedDraft.tone == .failed)
        #expect(!pinnedDraft.showsToggle)
    }
}

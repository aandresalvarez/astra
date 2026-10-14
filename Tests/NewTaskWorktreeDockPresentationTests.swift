import Foundation
import Testing
import ASTRACore
import ASTRAModels
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
        pinnedBase: String? = nil,
        isPreparing: Bool = false,
        problem: String? = nil
    ) -> NewTaskWorktreeDockPresentation? {
        NewTaskWorktreeDockPresentation.build(.init(
            selection: selection,
            allowsChoice: allowsChoice,
            pinnedPath: pinnedPath,
            pinnedBase: pinnedBase,
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
        #expect(unchosen.meta == "repository unavailable")
        #expect(unchosen.help.contains("removed"))
        #expect(unchosen.showsRepositoryMenu)
        #expect(!selection(enabled: true, selected: "/tmp/astra-dock/removed").canSubmit)

        var unset = selection(enabled: true)
        unset.repositoryPath = nil
        let choose = try #require(dock(unset))
        #expect(choose.meta == "choose a repository")

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

        let withBase = try #require(dock(selection(), allowsChoice: false, pinnedPath: path, pinnedBase: "origin/main"))
        #expect(withBase.meta == "\(WorkspacePathPresentation.abbreviatePath(path)) · from origin/main")
        #expect(withBase.help.contains("started from origin/main"))
        #expect(withBase.help.contains("Start over or delete the draft"))
    }

    @Test("The strip and its menu name the base the worktree starts from")
    func baseCopy() throws {
        var ready = selection(enabled: true, selected: astra.path)
        let unresolved = try #require(dock(ready))
        #expect(unresolved.meta == "from default branch")
        #expect(unresolved.help.contains("fetches astra's default branch"))

        ready.defaultBaseLabel = "main"
        let main = try #require(dock(ready))
        #expect(main.meta == "from main")
        #expect(main.help.contains("from main"))

        ready.base = .currentBranch
        ready.currentBaseLabel = "feature/x"
        let current = try #require(dock(ready))
        #expect(current.meta == "from feature/x")
        #expect(current.help.contains("uncommitted changes stay in the original checkout"))
        let creating = try #require(dock(ready, isPreparing: true))
        #expect(creating.meta == "astra · from feature/x")

        #expect(NewTaskWorktreeDockPresentation.baseOptionTitle(.defaultBranch, label: "main") == "Default branch (main)")
        #expect(NewTaskWorktreeDockPresentation.baseOptionTitle(.currentBranch, label: " ") == "Current branch")
        #expect(NewTaskWorktreeDockPresentation.startsFrom(.currentBranch, label: nil) == "from current branch")
        #expect(NewTaskWorktreeDockPresentation.chipTitle(repository: "astra", baseLabel: "main") == "astra · main")
        #expect(NewTaskWorktreeDockPresentation.chipTitle(repository: "astra", baseLabel: nil) == "astra")
        #expect(NewTaskWorktreeDockPresentation.chipTitle(repository: nil, baseLabel: "main") == "Choose repository")
        #expect(NewTaskWorktreeDockPresentation.toggleHelp.contains("default branch"))
    }

    @Test("The Repository card previews a new worktree only while the next task will get one")
    @MainActor
    func repositoryCardPreview() throws {
        let workspaceID = UUID()
        let entry = NewTaskWorktreeIntentStore.Entry(
            owner: UUID(), workspaceID: workspaceID, isEnabled: true, base: .defaultBranch, baseLabel: "main"
        )
        let preview = try #require(WorkspaceGitNewWorktreePreview(entry: entry, contextTask: nil))
        #expect(preview.summary == "New worktree · from main")
        #expect(preview.branchValue == "New · from main")
        #expect(preview.branchHelp.contains("astra/"))
        #expect(WorkspaceGitNewWorktreePreview.checkoutValue == "New worktree")
        #expect(WorkspaceGitNewWorktreePreview.changesCaption == "Base checkout · not copied")
        // The scope label sits beside the repository path; longer than the
        // card's own "Workspace default" it truncates at rail width.
        #expect(WorkspaceGitNewWorktreePreview.scopeLabel == "Worktree source")
        #expect(WorkspaceGitNewWorktreePreview.scopeLabel.count <= "Workspace default".count)
        #expect(WorkspaceGitNewWorktreePreview(base: .currentBranch, baseLabel: " ").branchValue == "New · from current branch")

        var unchecked = entry
        unchecked.isEnabled = false
        #expect(WorkspaceGitNewWorktreePreview(entry: unchecked, contextTask: nil) == nil)
        #expect(WorkspaceGitNewWorktreePreview(entry: nil, contextTask: nil) == nil)

        // A draft that already has its worktree shows that worktree instead.
        let draft = AgentTask(title: "Draft", goal: "Explore")
        draft.executionRootPath = "/tmp/astra-dock/Worktrees/astra/draft"
        let payload = try TaskEvent.encodePayload(TaskWorktreePayload(
            repositoryPath: astra.path, worktreePath: "/tmp/astra-dock/Worktrees/astra/draft", branch: "astra/draft"
        )).get()
        draft.events = [TaskEvent(task: draft, eventType: TaskEventTypes.Task.worktreePrepared, payload: payload)]
        #expect(WorkspaceGitNewWorktreePreview(entry: entry, contextTask: draft) == nil)
        #expect(WorkspaceGitNewWorktreePreview(entry: entry, contextTask: AgentTask(title: "Plain", goal: "Explore")) != nil)
    }

    @Test("Only the composer on screen owns the shared worktree choice")
    @MainActor
    func intentStoreOwnership() {
        let store = NewTaskWorktreeIntentStore()
        let workspaceID = UUID()
        let first = UUID()
        let second = UUID()
        let draftID = UUID()
        store.claim(owner: first, workspaceID: workspaceID, draftID: nil)
        store.update(owner: first) { $0.isEnabled = true }
        #expect(store.entry(workspaceID: workspaceID, selectedTaskID: nil)?.isEnabled == true)
        #expect(store.entry(workspaceID: UUID(), selectedTaskID: nil) == nil)
        #expect(store.entry(workspaceID: workspaceID, selectedTaskID: UUID()) == nil)

        // A replacement composer that claims first keeps its entry when the
        // old one leaves the screen.
        store.claim(owner: second, workspaceID: workspaceID, draftID: draftID)
        store.update(owner: first) { $0.isEnabled = true }
        store.release(owner: first)
        #expect(store.entry(workspaceID: workspaceID, selectedTaskID: draftID)?.owner == second)
        #expect(store.entry(workspaceID: workspaceID, selectedTaskID: draftID)?.isEnabled == false)
        store.release(owner: second)
        #expect(store.entry == nil)
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

    @Test("A gone checkout stays selected and blocks only Current branch until the repository is chosen again")
    func unavailableCheckoutBlocksCurrentBranch() throws {
        let gone = "/tmp/astra-dock/Worktrees/astra/astra-side"
        var blocked = selection(enabled: true)
        blocked.updateRepositories([astra, docs], selectedPath: astra.path, checkoutPath: gone, checkoutAvailable: false)
        blocked.base = .currentBranch
        #expect(blocked.repositoryPath == astra.path)
        #expect(blocked.checkoutPath == gone)
        #expect(blocked.isBlockedByCheckout)
        #expect(!blocked.canSubmit)
        #expect(blocked.submitError == .checkoutUnavailable(gone))
        #expect(blocked.request?.checkoutPath == gone)
        let strip = try #require(dock(blocked))
        #expect(strip.tone == .attention)
        #expect(strip.meta == "checkout unavailable")
        #expect(strip.help.contains("astra/astra-side"))
        #expect(strip.help.contains("Choose astra again"))
        #expect(strip.showsToggle && strip.showsRepositoryMenu)

        // Default branch never reads the checkout.
        var fromDefault = blocked
        fromDefault.base = .defaultBranch
        #expect(fromDefault.canSubmit)
        #expect(try #require(dock(fromDefault)).tone == .success)
        var unchecked = blocked
        unchecked.isEnabled = false
        #expect(unchecked.canSubmit)

        #expect(blocked.isNewChoice(astra))
        #expect(blocked.isNewChoice(docs))
        blocked.choose(astra)
        #expect(blocked.checkoutPath == astra.path)
        #expect(!blocked.isCheckoutUnavailable)
        #expect(blocked.canSubmit)
        #expect(blocked.submitError == .repositoryUnavailable)
        #expect(try #require(dock(blocked)).tone == .success)
        #expect(!blocked.isNewChoice(astra))

        // A checkout stays only with the repository it was recorded for.
        var fallback = NewTaskWorktreeSelection()
        fallback.updateRepositories(
            [astra, docs], selectedPath: "/tmp/astra-dock/removed", checkoutPath: gone, checkoutAvailable: false
        )
        #expect(fallback.repositoryPath == astra.path)
        #expect(fallback.checkoutPath == astra.path)
        #expect(!fallback.isCheckoutUnavailable)
    }
}

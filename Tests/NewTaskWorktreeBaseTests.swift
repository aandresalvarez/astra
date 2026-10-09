import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("New task worktree bases, names, and cleanup", .serialized)
struct NewTaskWorktreeBaseTests {
    private typealias Fixture = NewTaskWorktreeFixture

    private func workspace(_ repository: URL, in context: ModelContext) -> Workspace {
        let workspace = Workspace(name: repository.lastPathComponent, primaryPath: repository.path)
        context.insert(workspace)
        return workspace
    }

    private func prepare(
        _ task: AgentTask,
        _ repository: URL,
        base: TaskWorktreeBaseChoice = .defaultBranch,
        inheritingFrom draft: AgentTask? = nil,
        context: ModelContext,
        fixture: Fixture
    ) async throws {
        try await TaskWorktreeService.prepare(
            task: task,
            request: TaskWorktreeRequest(repositoryPath: repository.path, checkoutPath: repository.path, base: base),
            inheritingFrom: draft,
            modelContext: context, resourceQueue: fixture.resourceQueue,
            worktreesRoot: fixture.worktrees.path, ownership: fixture.ownership
        )
    }

    // MARK: - Base

    @Test("The default base is the freshly fetched remote main, not the checked-out feature branch")
    func defaultBaseFetchesRemoteMain() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let remote = try fixture.bareRemote("App.git")
        try fixture.git(["remote", "add", "origin", remote.path], at: repository)
        try fixture.push(["-u", "origin", "main"], at: repository)
        // A teammate lands work on main after this checkout last fetched.
        let teammate = try fixture.clone(remote, as: "Teammate")
        let remoteTip = try fixture.commit("Sources/landed.txt", contents: "landed", message: "Land", at: teammate)
        try fixture.push(["origin", "main"], at: teammate)
        // The checkout itself is on an unmerged feature branch.
        try fixture.git(["switch", "-c", "feature/local"], at: repository)
        let featureTip = try fixture.commit("Sources/feature.txt", contents: "wip", message: "WIP", at: repository)
        let store = try Fixture.container()
        let task = AgentTask(title: "Fix login", goal: "Fix login", workspace: workspace(repository, in: store.mainContext))

        try await prepare(task, repository, context: store.mainContext, fixture: fixture)

        let worktree = URL(fileURLWithPath: try #require(task.executionRootPath))
        #expect(try fixture.git(["rev-parse", "HEAD"], at: worktree) == remoteTip)
        #expect(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("Sources/landed.txt").path))
        #expect(!FileManager.default.fileExists(atPath: worktree.appendingPathComponent("Sources/feature.txt").path))
        #expect(try fixture.git(["branch", "--show-current"], at: repository) == "feature/local")
        #expect(try fixture.git(["rev-parse", "HEAD"], at: repository) == featureTip)
        let binding = try #require(TaskWorktreeService.activeWorktreeBinding(for: task))
        #expect(binding.baseRef == "origin/main")
        #expect(binding.baseCommit == remoteTip)
        #expect(binding.baseSource == .defaultBranch)
        #expect(binding.baseFetched == true)
        let label = await TaskWorktreeService.baseLabel(
            for: TaskWorktreeRequest(repositoryPath: repository.path), git: GitService.shared
        )
        #expect(label == "main")
    }

    @Test("When the remote can't be reached the default base is the local main, never the current branch")
    func defaultBaseFallsBackToLocalMain() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let mainTip = try fixture.git(["rev-parse", "HEAD"], at: repository)
        try fixture.git(["remote", "add", "origin", fixture.root.appendingPathComponent("missing.git").path], at: repository)
        try fixture.git(["switch", "-c", "feature"], at: repository)
        try fixture.commit("Sources/feature.txt", contents: "wip", message: "WIP", at: repository)
        let store = try Fixture.container()
        let task = AgentTask(title: "Update", goal: "Update", workspace: workspace(repository, in: store.mainContext))

        try await prepare(task, repository, context: store.mainContext, fixture: fixture)

        let worktree = URL(fileURLWithPath: try #require(task.executionRootPath))
        #expect(try fixture.git(["rev-parse", "HEAD"], at: worktree) == mainTip)
        let binding = try #require(TaskWorktreeService.activeWorktreeBinding(for: task))
        #expect(binding.baseRef == "main")
        #expect(binding.baseFetched == false)
    }

    @Test("Current branch starts from the selected checkout's HEAD, including its unmerged commits")
    func currentBranchBase() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        try fixture.git(["switch", "-c", "feature/x"], at: repository)
        let featureTip = try fixture.commit("Sources/feature.txt", contents: "wip", message: "WIP", at: repository)
        let store = try Fixture.container()
        let task = AgentTask(title: "Continue", goal: "Continue", workspace: workspace(repository, in: store.mainContext))

        try await prepare(task, repository, base: .currentBranch, context: store.mainContext, fixture: fixture)

        let worktree = URL(fileURLWithPath: try #require(task.executionRootPath))
        #expect(try fixture.git(["rev-parse", "HEAD"], at: worktree) == featureTip)
        let binding = try #require(TaskWorktreeService.activeWorktreeBinding(for: task))
        #expect(binding.baseRef == "feature/x")
        #expect(binding.baseSource == .currentBranch)
        #expect(binding.baseFetched == false)
        let label = await TaskWorktreeService.baseLabel(
            for: TaskWorktreeRequest(repositoryPath: repository.path, base: .currentBranch), git: GitService.shared
        )
        #expect(label == "feature/x")
    }

    @Test("A repository without main or master fails closed and points to Current branch")
    func missingDefaultBranchFailsClosed() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("Trunk", branch: "trunk")
        let store = try Fixture.container()
        let task = AgentTask(title: "Update", goal: "Update", workspace: workspace(repository, in: store.mainContext))

        await #expect(throws: TaskWorktreeCreationError.self) {
            try await prepare(task, repository, context: store.mainContext, fixture: fixture)
        }
        #expect(task.executionRootPath == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.worktrees.path))
        #expect(TaskWorktreeCreationError.baseUnavailable(repository.path).localizedDescription.contains("Current branch"))
        let label = await TaskWorktreeService.baseLabel(
            for: TaskWorktreeRequest(repositoryPath: repository.path), git: GitService.shared
        )
        #expect(label == nil)

        try await prepare(task, repository, base: .currentBranch, context: store.mainContext, fixture: fixture)
        #expect(TaskWorktreeService.activeWorktreeBinding(for: task)?.baseRef == "trunk")
    }

    @Test("After the remote renames its default branch, the base follows the remote's HEAD, not stale origin/HEAD")
    func defaultBaseFollowsRemoteHead() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let remote = try fixture.bareRemote("App.git")
        let seed = try fixture.repository("Seed")
        try fixture.git(["remote", "add", "origin", remote.path], at: seed)
        try fixture.push(["origin", "main"], at: seed)
        let repository = try fixture.clone(remote, as: "App")
        // The remote renames main to develop after this clone.
        try fixture.push(["origin", "main:develop"], at: seed)
        try fixture.git(["--git-dir", remote.path, "symbolic-ref", "HEAD", "refs/heads/develop"], at: fixture.root)
        try fixture.push(["origin", ":main"], at: seed)
        let teammate = try fixture.clone(remote, as: "Teammate")
        let remoteTip = try fixture.commit("Sources/landed.txt", contents: "landed", message: "Land", at: teammate)
        try fixture.push(["origin", "develop"], at: teammate)
        #expect(try fixture.git(["symbolic-ref", "refs/remotes/origin/HEAD"], at: repository) == "refs/remotes/origin/main")
        let store = try Fixture.container()
        let task = AgentTask(title: "Fix login", goal: "Fix login", workspace: workspace(repository, in: store.mainContext))

        try await prepare(task, repository, context: store.mainContext, fixture: fixture)

        let binding = try #require(TaskWorktreeService.activeWorktreeBinding(for: task))
        #expect(binding.baseRef == "origin/develop")
        #expect(binding.baseCommit == remoteTip)
        #expect(binding.baseFetched == true)
        let worktree = URL(fileURLWithPath: try #require(task.executionRootPath))
        #expect(try fixture.git(["rev-parse", "HEAD"], at: worktree) == remoteTip)
    }

    @Test("A remote added by hand, without origin/HEAD, main, or master, still yields its default branch")
    func defaultBaseWithoutRemoteHeadRef() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let remote = try fixture.bareRemote("App.git")
        let repository = try fixture.repository("App", branch: "develop")
        try fixture.git(["remote", "add", "origin", remote.path], at: repository)
        try fixture.push(["origin", "develop"], at: repository)
        try fixture.git(["--git-dir", remote.path, "symbolic-ref", "HEAD", "refs/heads/develop"], at: fixture.root)
        let teammate = try fixture.clone(remote, as: "Teammate")
        let remoteTip = try fixture.commit("Sources/landed.txt", contents: "landed", message: "Land", at: teammate)
        try fixture.push(["origin", "develop"], at: teammate)
        let store = try Fixture.container()
        let task = AgentTask(title: "Fix login", goal: "Fix login", workspace: workspace(repository, in: store.mainContext))

        try await prepare(task, repository, context: store.mainContext, fixture: fixture)

        let binding = try #require(TaskWorktreeService.activeWorktreeBinding(for: task))
        #expect(binding.baseRef == "origin/develop")
        #expect(binding.baseCommit == remoteTip)
        #expect(binding.baseFetched == true)
    }

    @Test("Only a safe branch named by the remote's HEAD symref is accepted")
    func remoteHeadParsing() {
        let sha = String(repeating: "a", count: 40)
        #expect(GitService.remoteHead(fromLsRemote: "ref: refs/heads/develop\tHEAD\n\(sha)\tHEAD\n") == .branch("develop"))
        #expect(GitService.remoteHead(fromLsRemote: "ref: refs/heads/release/2.0\tHEAD\n") == .branch("release/2.0"))
        #expect(GitService.remoteHead(fromLsRemote: "") == .unnamed)
        #expect(GitService.remoteHead(fromLsRemote: "\(sha)\tHEAD\n") == .unnamed)
        #expect(GitService.remoteHead(fromLsRemote: "ref: refs/heads/--upload-pack=x\tHEAD\n") == .unnamed)
        #expect(GitService.remoteHead(fromLsRemote: "ref: refs/heads/a..b\tHEAD\n") == .unnamed)
        #expect(GitService.remoteHead(fromLsRemote: "ref: refs/heads/main\trefs/heads/other\n") == .unnamed)
    }

    @Test("Current branch reads HEAD from the selected linked worktree; the worktree is added from the repository")
    func currentBranchUsesSelectedCheckout() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let linked = fixture.root.appendingPathComponent("App-side", isDirectory: true)
        try fixture.git(["worktree", "add", "--quiet", "-b", "side", linked.path], at: repository)
        let sideTip = try fixture.commit("Sources/side.txt", contents: "side", message: "Side work", at: linked)
        let store = try Fixture.container()
        let task = AgentTask(title: "Continue", goal: "Continue", workspace: workspace(repository, in: store.mainContext))

        try await TaskWorktreeService.prepare(
            task: task,
            request: TaskWorktreeRequest(repositoryPath: repository.path, checkoutPath: linked.path, base: .currentBranch),
            modelContext: store.mainContext, resourceQueue: fixture.resourceQueue,
            worktreesRoot: fixture.worktrees.path, ownership: fixture.ownership
        )

        let binding = try #require(TaskWorktreeService.activeWorktreeBinding(for: task))
        #expect(binding.baseRef == "side")
        #expect(binding.baseCommit == sideTip)
        #expect(binding.repositoryPath == repository.path)
        let worktree = URL(fileURLWithPath: try #require(task.executionRootPath))
        #expect(try fixture.git(["rev-parse", "HEAD"], at: worktree) == sideTip)
        #expect(try fixture.git(["branch", "--show-current"], at: repository) == "main")
    }

    // MARK: - Names

    @Test("Branch names keep whole words of the title and end with the task folder's short ID")
    func branchNamesAreShortAndReadable() throws {
        let id = try #require(UUID(uuidString: "25E8279E-1111-2222-3333-444455556666"))
        #expect(TaskWorktreeService.branchName(
            title: "fix the login button alignment on the settings page", taskID: id
        ) == "astra/fix-login-button-alignment-25e8279e")
        #expect(TaskWorktreeService.branchName(title: "Update", taskID: id, attempt: 3) == "astra/update-25e8279e-3")
        #expect(TaskWorktreeService.slug(for: "Añadir función de búsqueda") == "anadir-funcion-de-busqueda")
        #expect(TaskWorktreeService.slug(for: "Ünïcödé façade") == "unicode-facade")
        #expect(TaskWorktreeService.slug(for: "the and of") == "the-and-of")
        #expect(TaskWorktreeService.slug(for: "") == "task")
        #expect(TaskWorktreeService.slug(for: String(repeating: "x", count: 50)) == String(repeating: "x", count: 32))
        for title in ["修复登录按钮", "Привет мир", "fix: a/b..c @{now}"] {
            let slug = TaskWorktreeService.slug(for: title)
            #expect(slug.count <= TaskWorktreeService.slugLimit)
            #expect(slug.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
        }
    }

    @Test("A taken branch name gets a numbered suffix instead of reusing another branch")
    func collidingNamesGetSuffix() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let task = AgentTask(title: "Update docs", goal: "Update", workspace: workspace(repository, in: store.mainContext))
        try fixture.git(["branch", TaskWorktreeService.branchName(for: task)], at: repository)

        try await prepare(task, repository, context: store.mainContext, fixture: fixture)

        let expected = TaskWorktreeService.branchName(for: task, attempt: 2)
        #expect(TaskWorktreeService.activeWorktreeBinding(for: task)?.branch == expected)
        let worktree = URL(fileURLWithPath: try #require(task.executionRootPath))
        #expect(try fixture.git(["branch", "--show-current"], at: worktree) == expected)
    }

    // MARK: - Lazy creation and handoff

    @Test("A draft's planning worktree is created once and carried to the task started from it")
    func planningWorktreeCarriesOver() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let context = store.mainContext
        let workspace = workspace(repository, in: context)
        let draft = AgentTask(title: "Plan login", goal: "Plan login", workspace: workspace)

        try await prepare(draft, repository, context: context, fixture: fixture)
        let path = try #require(draft.executionRootPath)
        try await prepare(draft, repository, context: context, fixture: fixture)
        #expect(draft.executionRootPath == path)

        let task = AgentTask(title: "Approved plan", goal: "Plan login", workspace: workspace)
        try await prepare(task, repository, inheritingFrom: draft, context: context, fixture: fixture)
        #expect(task.executionRootPath == path)
        #expect(TaskWorktreeService.activeWorktreeBinding(for: task)?.worktreePath == path)
        #expect(await GitService.shared.listWorktrees(at: repository.path).count == 2)
    }

    @Test("A failed start durably adopts its worktree into an unbound draft", arguments: [false, true])
    func failedStartAdoptsWorktreeIntoDraft(invalidOriginalBinding: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let context = store.mainContext
        let workspace = workspace(repository, in: context)
        let draft = AgentTask(title: "Chat", goal: "Explore", workspace: workspace)
        context.insert(draft)
        if invalidOriginalBinding {
            draft.executionRootPath = fixture.root.appendingPathComponent("missing").path
            context.insert(TaskEvent(task: draft, eventType: TaskEventTypes.Task.worktreePrepared, payload: "{"))
        }
        // An unselected draft without a worktree is not a checkout source.
        #expect(NewTaskWorktreeComposerFlow.checkoutSource(draft: draft, isSelectedDraft: false) == nil)
        #expect(NewTaskWorktreeComposerFlow.checkoutSource(draft: draft, isSelectedDraft: true) === draft)
        let task = AgentTask(title: "Run", goal: "Explore", workspace: workspace)
        try await prepare(task, repository, context: context, fixture: fixture)
        let path = try #require(task.executionRootPath)
        TaskStateMachine.enqueueFromChatSubmission(task, modelContext: context)

        let recovered = try TaskWorktreeService.recoverFailedSubmission(task: task, existingDraft: draft, modelContext: context)

        #expect(recovered === draft)
        #expect(draft.executionRootPath == path)
        #expect(TaskWorktreeService.activeWorktreeBinding(for: draft)?.worktreePath == path)
        let recoveredContext = ModelContext(store)
        let persistedDraft = try #require(try recoveredContext.fetch(FetchDescriptor<AgentTask>()).first)
        #expect(try recoveredContext.fetchCount(FetchDescriptor<AgentTask>()) == 1)
        #expect(persistedDraft.id == draft.id)
        #expect(persistedDraft.executionRootPath == path)
        #expect(TaskWorktreeService.activeWorktreeBinding(for: persistedDraft)?.worktreePath == path)
        #expect(NewTaskWorktreeComposerFlow.checkoutSource(draft: draft, isSelectedDraft: false) === draft)
        let retry = AgentTask(title: "Retry", goal: "Explore", workspace: workspace)
        try await prepare(retry, repository, inheritingFrom: draft, context: context, fixture: fixture)
        #expect(retry.executionRootPath == path)
        #expect(await GitService.shared.listWorktrees(at: repository.path).count == 2)
    }

    @Test("Failed recovery saves are surfaced and never remove the prepared checkout", arguments: [false, true])
    func recoverySaveFailureKeepsWorktree(adoptingDraft: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let context = store.mainContext
        let workspace = workspace(repository, in: context)
        let draft = adoptingDraft ? AgentTask(title: "Chat", goal: "Explore", workspace: workspace) : nil
        if let draft { context.insert(draft) }
        let task = AgentTask(title: "Run", goal: "Explore", workspace: workspace)
        try await prepare(task, repository, context: context, fixture: fixture)
        let path = try #require(task.executionRootPath)
        TaskStateMachine.enqueueFromChatSubmission(task, modelContext: context)
        var attemptedSave = false
        do {
            _ = try TaskWorktreeService.recoverFailedSubmission(
                task: task, existingDraft: draft, modelContext: context,
                persist: { savedWorkspace, _, taskID in
                    attemptedSave = true
                    #expect(savedWorkspace === workspace)
                    #expect(taskID == (draft?.id ?? task.id))
                    throw CocoaError(.fileWriteNoPermission)
                }
            )
            Issue.record("A failed recovery save must not report a recovered draft")
        } catch let error as TaskWorktreeCreationError {
            guard case .recoveryPersistenceFailed = error else {
                Issue.record(error)
                return
            }
            #expect(error.localizedDescription.contains("could not save the recovered draft"))
        }
        #expect(attemptedSave)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(await GitService.shared.listWorktrees(at: repository.path).count == 2)
        // A failed adoption leaves nothing pending: the task is still there
        // with its worktree, and the draft took nothing over. Without a
        // draft, the task's own return to draft stays pending by design.
        #expect(context.hasChanges == !adoptingDraft)
        #expect(!task.isDeleted)
        #expect(task.executionRootPath == path)
        #expect(draft?.executionRootPath == nil)
        #expect(draft.map { TaskWorktreeBinding.eventForInheritance(from: $0) == nil } ?? true)
        let recoveredContext = ModelContext(store)
        let durableTask = try #require(try recoveredContext.fetch(FetchDescriptor<AgentTask>()).first { $0.id == task.id })
        #expect(durableTask.executionRootPath == path)
        #expect(TaskWorktreeService.activeWorktreeBinding(for: durableTask)?.worktreePath == path)
    }

    @Test("The composer's choice is recorded on the draft once enabled and restored on reopen")
    func requestRoundTrip() throws {
        let store = try Fixture.container()
        let context = store.mainContext
        let workspace = Workspace(name: "App", primaryPath: "/repos/app")
        context.insert(workspace)
        let draft = AgentTask(title: "Draft", goal: "Explore", workspace: workspace)
        context.insert(draft)
        var selection = NewTaskWorktreeSelection()

        NewTaskWorktreeComposerFlow.recordChoice(selection, on: draft, modelContext: context)
        #expect(TaskWorktreeService.latestRequest(for: draft) == nil)
        selection.isEnabled = true
        NewTaskWorktreeComposerFlow.recordChoice(selection, on: draft, modelContext: context)
        NewTaskWorktreeComposerFlow.recordChoice(selection, on: draft, modelContext: context)
        selection.base = .currentBranch
        NewTaskWorktreeComposerFlow.recordChoice(selection, on: draft, modelContext: context)

        let requests = draft.events.filter { $0.hasType(TaskEventTypes.Task.worktreeRequested) }
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.typedCategory == .system })
        #expect(TaskWorktreeService.latestRequest(for: draft) == TaskWorktreeRequestPayload(enabled: true, base: .currentBranch))
        var reopened = NewTaskWorktreeSelection()
        NewTaskWorktreeComposerFlow.restoreChoice(&reopened, from: draft)
        #expect(reopened.isEnabled)
        #expect(reopened.base == .currentBranch)
    }

    @Test("Saved draft controls persist without another chat message", arguments: ["enable", "base", "disable"])
    func changedControlsSurviveNavigation(change: String) throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = try Fixture.container()
        let context = store.mainContext
        let workspace = Workspace(name: "Draft", primaryPath: fixture.storage.path)
        context.insert(workspace)
        let draft = AgentTask(title: "Draft", goal: "Explore", workspace: workspace)
        context.insert(draft)
        var selection = NewTaskWorktreeSelection()
        if change != "enable" {
            selection.isEnabled = true
            NewTaskWorktreeComposerFlow.recordChoice(selection, on: draft, modelContext: context)
        }
        try context.save()

        switch change {
        case "base": selection.base = .currentBranch
        case "disable": selection.isEnabled = false
        default: selection.isEnabled = true
        }
        try NewTaskWorktreeComposerFlow.persistChoice(selection, on: draft, modelContext: context)
        try NewTaskWorktreeComposerFlow.persistChoice(selection, on: draft, modelContext: context)

        let reopened = try #require(ModelContext(store).fetch(FetchDescriptor<AgentTask>()).first)
        var restored = NewTaskWorktreeSelection()
        NewTaskWorktreeComposerFlow.restoreChoice(&restored, from: reopened)
        #expect(restored.requestPayload == selection.requestPayload)
        #expect(reopened.events.filter { $0.hasType(TaskEventTypes.Task.worktreeRequested) }.count == (change == "enable" ? 1 : 2))
        let exported = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: context))
        let importedStore = try Fixture.container()
        let imported = WorkspaceConfigManager.importWorkspace(from: exported, modelContext: importedStore.mainContext)
        #expect(TaskWorktreeService.latestRequest(for: try #require(imported.tasks.first)) == selection.requestPayload)
    }

    @Test("A failed control save surfaces an error and retains the previous durable choice")
    func choiceSaveFailureKeepsPreviousRequest() throws {
        struct StoreUnavailable: Error {}
        let store = try Fixture.container()
        let context = store.mainContext
        let workspace = Workspace(name: "Draft", primaryPath: "/repos/app")
        context.insert(workspace)
        let draft = AgentTask(title: "Draft", goal: "Explore", workspace: workspace)
        context.insert(draft)
        var selection = NewTaskWorktreeSelection()
        selection.isEnabled = true
        NewTaskWorktreeComposerFlow.recordChoice(selection, on: draft, modelContext: context)
        try context.save()
        let previous = selection.requestPayload
        selection.isEnabled = false

        #expect(throws: TaskWorktreeCreationError.self) {
            try NewTaskWorktreeComposerFlow.persistChoice(
                selection, on: draft, modelContext: context, persist: { _, _ in throw StoreUnavailable() }
            )
        }
        #expect(TaskWorktreeService.latestRequest(for: draft) == previous)
        let reopened = try #require(ModelContext(store).fetch(FetchDescriptor<AgentTask>()).first)
        #expect(TaskWorktreeService.latestRequest(for: reopened) == previous)

        try NewTaskWorktreeComposerFlow.persistChoice(selection, on: draft, modelContext: context, persist: { _, context in
            try context.save()
        })
        #expect(TaskWorktreeService.latestRequest(for: draft) == selection.requestPayload)
    }

    // MARK: - Cleanup

    @Test("Discarding an untouched draft removes its worktree and branch")
    func discardRemovesUnusedWorktree() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let context = store.mainContext
        let draft = AgentTask(title: "Explore", goal: "Explore", workspace: workspace(repository, in: context))
        try await prepare(draft, repository, context: context, fixture: fixture)
        let path = try #require(draft.executionRootPath)
        let discard = try #require(TaskWorktreeService.discardSnapshots(for: draft, ownership: fixture.ownership).first)
        context.delete(draft)
        try context.save()

        #expect(await TaskWorktreeService.discardUnusedWorktree(discard, modelContext: context, resourceQueue: fixture.resourceQueue))

        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(try fixture.git(["branch", "--list", discard.branch], at: repository).isEmpty)
        #expect(await GitService.shared.listWorktrees(at: repository.path).count == 1)
    }

    @Test("Worktrees with changes, commits, or another owner are kept")
    func discardKeepsUsedWorktrees() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let context = store.mainContext
        let workspace = workspace(repository, in: context)

        func discarded(_ title: String, after use: (URL) throws -> Void) async throws -> (Bool, URL) {
            let draft = AgentTask(title: title, goal: title, workspace: workspace)
            try await prepare(draft, repository, context: context, fixture: fixture)
            let worktree = URL(fileURLWithPath: try #require(draft.executionRootPath))
            let discard = try #require(TaskWorktreeService.discardSnapshots(for: draft, ownership: fixture.ownership).first)
            try use(worktree)
            context.delete(draft)
            try context.save()
            return (await TaskWorktreeService.discardUnusedWorktree(discard, modelContext: context, resourceQueue: fixture.resourceQueue), worktree)
        }

        let (dirtyRemoved, dirty) = try await discarded("Dirty") { worktree in
            try "edited".write(to: worktree.appendingPathComponent("Sources/file.txt"), atomically: true, encoding: .utf8)
        }
        #expect(!dirtyRemoved)
        #expect(FileManager.default.fileExists(atPath: dirty.path))

        let (committedRemoved, committed) = try await discarded("Committed") { worktree in
            _ = try fixture.commit("Sources/new.txt", contents: "new", message: "Work", at: worktree)
        }
        #expect(!committedRemoved)
        #expect(FileManager.default.fileExists(atPath: committed.path))

        let (referencedRemoved, referenced) = try await discarded("Referenced") { worktree in
            workspace.activeWorkingPath = worktree.path
        }
        #expect(!referencedRemoved)
        #expect(FileManager.default.fileExists(atPath: referenced.path))
        #expect(await GitService.shared.listWorktrees(at: repository.path).count == 4)

        // Worktrees prepared before the base commit was recorded are never discarded.
        let legacy = AgentTask(title: "Legacy", goal: "Legacy", workspace: workspace)
        legacy.executionRootPath = "/tmp/legacy-worktree"
        let payload = try TaskEvent.encodePayload(TaskWorktreePayload(
            repositoryPath: repository.path, worktreePath: "/tmp/legacy-worktree", branch: "astra/legacy"
        )).get()
        legacy.events = [TaskEvent(task: legacy, eventType: TaskEventTypes.Task.worktreePrepared, payload: payload)]
        #expect(TaskWorktreeService.discardSnapshots(for: legacy, ownership: fixture.ownership).isEmpty)
    }

    @Test("Ignored files are work too: a worktree holding only ignored files is kept")
    func discardKeepsIgnoredFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        try fixture.commit(".gitignore", contents: "*.env\n", message: "Ignore env files", at: repository)
        let store = try Fixture.container()
        let context = store.mainContext
        let draft = AgentTask(title: "Explore", goal: "Explore", workspace: workspace(repository, in: context))
        try await prepare(draft, repository, context: context, fixture: fixture)
        let worktree = URL(fileURLWithPath: try #require(draft.executionRootPath))
        #expect(!(await GitService.shared.hasIgnoredFiles(at: worktree.path)))
        let secret = worktree.appendingPathComponent("local.env")
        try "TOKEN=local".write(to: secret, atomically: true, encoding: .utf8)
        #expect(await GitService.shared.getStatusFiles(at: worktree.path).isEmpty)
        let discard = try #require(TaskWorktreeService.discardSnapshots(for: draft, ownership: fixture.ownership).first)
        context.delete(draft)
        try context.save()

        #expect(!(await TaskWorktreeService.discardUnusedWorktree(discard, modelContext: context, resourceQueue: fixture.resourceQueue)))
        #expect(FileManager.default.fileExists(atPath: secret.path))
        #expect(try fixture.git(["branch", "--list", discard.branch], at: repository).isEmpty == false)
    }

    @Test("When references can't be read, before or after the Git checks, the worktree is kept")
    func referenceFailureKeepsWorktree() async throws {
        @MainActor final class Calls { var count = 0 }
        struct StoreUnavailable: Error {}
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let context = store.mainContext
        let draft = AgentTask(title: "Explore", goal: "Explore", workspace: workspace(repository, in: context))
        try await prepare(draft, repository, context: context, fixture: fixture)
        let path = try #require(draft.executionRootPath)
        let discard = try #require(TaskWorktreeService.discardSnapshots(for: draft, ownership: fixture.ownership).first)
        context.delete(draft)
        try context.save()

        #expect(!(await TaskWorktreeService.discardUnusedWorktree(
            discard, modelContext: context, resourceQueue: fixture.resourceQueue, checkoutPins: { _ in throw StoreUnavailable() }
        )))
        #expect(FileManager.default.fileExists(atPath: path))
        let calls = Calls()
        #expect(!(await TaskWorktreeService.discardUnusedWorktree(
            discard, modelContext: context, resourceQueue: fixture.resourceQueue, checkoutPins: { _ in
                calls.count += 1
                if calls.count > 1 { throw StoreUnavailable() }
                return []
            }
        )))
        #expect(calls.count == 2)
        #expect(FileManager.default.fileExists(atPath: path))

        #expect(await TaskWorktreeService.discardUnusedWorktree(discard, modelContext: context, resourceQueue: fixture.resourceQueue))
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("Cleanup starts only after the deletion is saved; a failed save keeps the worktree")
    func cleanupWaitsForDurableDeletion() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let context = store.mainContext
        let workspace = workspace(repository, in: context)
        let draft = AgentTask(title: "Explore", goal: "Explore", workspace: workspace)
        try await prepare(draft, repository, context: context, fixture: fixture)
        let path = try #require(draft.executionRootPath)
        let discards = TaskWorktreeService.discardSnapshots(for: draft, ownership: fixture.ownership)
        #expect(discards.count == 1)

        // Unrelated unsaved work is checkpointed before the deletion, so
        // rolling the failed deletion back does not discard it.
        let unrelated = AgentTask(title: "Unrelated", goal: "Keep me", workspace: workspace)
        context.insert(unrelated)
        unrelated.title = "Unrelated, edited"
        let unsaved = TaskWorktreeService.saveDeletionThenDiscard(
            discards, workspace: workspace, modelContext: context, resourceQueue: fixture.resourceQueue, cleanupStore: fixture.cleanupStore,
            delete: { context.delete(draft) },
            persist: { _, _ in false }
        )
        #expect(!unsaved.persisted)
        #expect(unsaved.cleanup == nil)
        #expect(!draft.isDeleted)
        #expect(!unrelated.isDeleted)
        #expect(unrelated.title == "Unrelated, edited")
        #expect(!context.hasChanges)
        try await Task.sleep(for: .milliseconds(50))
        #expect(FileManager.default.fileExists(atPath: path))

        let saved = TaskWorktreeService.saveDeletionThenDiscard(
            discards, workspace: workspace, modelContext: context, resourceQueue: fixture.resourceQueue, cleanupStore: fixture.cleanupStore,
            delete: { context.delete(draft) },
            persist: { _, context in
                (try? context.save()) != nil
            }
        )
        let cleanup = try #require(saved.cleanup)
        #expect(saved.persisted)
        #expect(await cleanup.value)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("Start Over also saves the deletion of a plain draft without a worktree")
    func discardingPlainDraftPersistsDeletion() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = try Fixture.container()
        let context = ModelContext(store)
        let workspace = Workspace(name: "Plain", primaryPath: fixture.storage.path)
        context.insert(workspace)
        let draft = AgentTask(title: "Draft", goal: "Explore", workspace: workspace)
        context.insert(draft)
        try context.save()

        context.delete(draft)
        NewTaskWorktreeComposerFlow.discardWorktrees([], workspace: workspace, modelContext: context, resourceQueue: fixture.resourceQueue)

        let reloaded = ModelContext(store)
        #expect(try reloaded.fetchCount(FetchDescriptor<AgentTask>()) == 0)
    }

    @Test("Deleting a draft that never ran gives back its untouched worktree")
    func deletingDraftDiscardsItsWorktree() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let context = ModelContext(store)
        let draft = AgentTask(title: "Explore", goal: "Explore", workspace: workspace(repository, in: context))
        try await prepare(draft, repository, context: context, fixture: fixture)
        let path = try #require(draft.executionRootPath)
        let coordinator = TaskLifecycleCoordinator(
            modelContext: context, taskQueue: TaskQueue(poolSize: 0), worktreeCleanupStore: fixture.cleanupStore
        )

        _ = coordinator.deleteTask(draft)

        for _ in 0..<100 where FileManager.default.fileExists(atPath: path) {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(await GitService.shared.listWorktrees(at: repository.path).count == 1)
    }

    // MARK: - Shared code location

    @Test("One writer stores where the next task runs: the draft's pin or the workspace default")
    func codeLocationPinHasOneOwner() {
        let workspace = Workspace(name: "App", primaryPath: "/repos/app")
        #expect(TaskCodeLocationPin.set("/repos/other", workspace: workspace, task: nil))
        #expect(workspace.activeWorkingPath == "/repos/other")
        #expect(!TaskCodeLocationPin.set("/repos/other", workspace: workspace, task: nil))
        #expect(TaskCodeLocationPin.set("/repos/app", workspace: workspace, task: nil))
        #expect(workspace.activeWorkingPath == nil)

        let draft = AgentTask(title: "Draft", goal: "Explore", workspace: workspace)
        #expect(TaskCodeLocationPin.set(" /repos/other ", workspace: workspace, task: draft))
        #expect(draft.executionRootPath == "/repos/other")
        #expect(workspace.activeWorkingPath == nil)
        #expect(TaskCodeLocationPin.set("/repos/app", workspace: workspace, task: draft))
        #expect(draft.executionRootPath == "/repos/app")
    }

    @Test("An explicit primary-repository draft stays there after the workspace default moves")
    func explicitPrimaryRepositorySurvivesWorkspaceDefaultChange() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let primary = try fixture.repository("Primary")
        let other = try fixture.repository("Other")
        let store = try Fixture.container()
        let context = store.mainContext
        let workspace = Workspace(name: "App", primaryPath: primary.path, additionalPaths: [other.path])
        context.insert(workspace)
        let draft = AgentTask(title: "Stay on primary", goal: "Stay", workspace: workspace)
        context.insert(draft)
        #expect(TaskCodeLocationPin.set(primary.path, workspace: workspace, task: draft))
        var selection = NewTaskWorktreeSelection()
        selection.isEnabled = true
        selection.repositoryPath = primary.path
        NewTaskWorktreeComposerFlow.recordChoice(selection, on: draft, modelContext: context)

        workspace.activeWorkingPath = other.path
        NewTaskWorktreeComposerFlow.followWorkspaceDefault(draft)
        #expect(draft.executionRootPath == primary.path)
        var restored = NewTaskWorktreeSelection()
        NewTaskWorktreeComposerFlow.restoreChoice(&restored, from: draft)
        restored.repositories = [GitRepositoryInfo(name: "Primary", path: primary.path)]
        #expect(restored.repositoryPath == primary.path)
        #expect(restored.request?.repositoryPath == primary.path)

        let task = AgentTask(title: "Run", goal: "Run", workspace: workspace)
        context.insert(task)
        try await TaskWorktreeService.prepare(
            task: task,
            request: restored.request,
            modelContext: context, resourceQueue: fixture.resourceQueue,
            worktreesRoot: fixture.worktrees.path, ownership: fixture.ownership
        )
        let binding = try #require(TaskWorktreeService.activeWorktreeBinding(for: task))
        #expect(binding.repositoryPath == primary.path)
        #expect(binding.worktreePath != other.path)
    }

    @Test("A Current branch draft keeps its linked checkout across reopening and starts from that commit")
    func currentBranchDraftKeepsLinkedCheckout() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let linked = fixture.root.appendingPathComponent("App-side", isDirectory: true)
        try fixture.git(["worktree", "add", "--quiet", "-b", "side", linked.path], at: repository)
        let sideTip = try fixture.commit("Side.txt", contents: "side", message: "Side", at: linked)
        #expect(try fixture.git(["rev-parse", "HEAD"], at: repository) != sideTip)
        let store = try Fixture.container()
        let context = store.mainContext
        let workspace = Workspace(name: "App", primaryPath: repository.path)
        context.insert(workspace)
        let draft = AgentTask(title: "Draft", goal: "Explore", workspace: workspace)
        context.insert(draft)
        #expect(draft.executionRootPath == nil)

        // The strip showed the linked checkout; the draft's first save keeps it.
        var selection = NewTaskWorktreeSelection()
        selection.isEnabled = true
        selection.base = .currentBranch
        selection.updateRepositories(
            [GitRepositoryInfo(name: "App", path: repository.path)],
            selectedPath: repository.path,
            checkoutPath: linked.path
        )
        NewTaskWorktreeComposerFlow.recordChoice(selection, on: draft, modelContext: context)
        NewTaskWorktreeComposerFlow.followWorkspaceDefault(draft)
        try context.save()

        let reopened = try #require(ModelContext(store).fetch(FetchDescriptor<AgentTask>()).first)
        #expect(reopened.executionRootPath == linked.path)
        #expect(TaskWorktreeService.latestRequest(for: reopened)?.checkoutPath == linked.path)
        var restored = NewTaskWorktreeSelection()
        NewTaskWorktreeComposerFlow.restoreChoice(&restored, from: reopened)
        #expect(restored.checkoutPath == linked.path)
        let repositories = await GitService.shared.scanForGitRepositories(
            primaryPath: repository.path, additionalPaths: []
        )
        let match = await NewTaskWorktreeDockView.scanSelection(
            codePath: reopened.executionRootPath, primaryPath: repository.path, repositories: repositories,
            recorded: NewTaskWorktreeDockView.recordedChoice(for: reopened), git: GitService.shared
        )
        #expect(match == .checkout(repository: repository.path, path: linked.path, available: true))
        NewTaskWorktreeDockView.applyScan(match, repositories: repositories, to: &restored)
        #expect(restored.checkoutPath == linked.path)
        #expect(!restored.isCheckoutUnavailable)

        let task = AgentTask(title: "Run", goal: "Run", workspace: workspace)
        context.insert(task)
        try await TaskWorktreeService.prepare(
            task: task,
            request: restored.request,
            modelContext: context, resourceQueue: fixture.resourceQueue,
            worktreesRoot: fixture.worktrees.path, ownership: fixture.ownership
        )
        let binding = try #require(TaskWorktreeService.activeWorktreeBinding(for: task))
        #expect(binding.baseCommit == sideTip)
        #expect(binding.baseRef == "side")
    }

    @Test("Requests recorded before the checkout field still restore their choice")
    func legacyRequestWithoutCheckoutRestores() throws {
        let store = try Fixture.container()
        let context = store.mainContext
        let workspace = Workspace(name: "App", primaryPath: "/repos/app")
        context.insert(workspace)
        let draft = AgentTask(title: "Draft", goal: "Explore", workspace: workspace)
        context.insert(draft)
        context.insert(TaskEvent(
            task: draft,
            eventType: TaskEventTypes.Task.worktreeRequested,
            payload: #"{"base":"current_branch","enabled":true,"repositoryPath":"/repos/app"}"#
        ))

        let request = try #require(TaskWorktreeService.latestRequest(for: draft))
        #expect(request == TaskWorktreeRequestPayload(enabled: true, base: .currentBranch, repositoryPath: "/repos/app"))
        #expect(request.checkoutPath == nil)
        var restored = NewTaskWorktreeSelection()
        NewTaskWorktreeComposerFlow.restoreChoice(&restored, from: draft)
        #expect(restored.isEnabled)
        #expect(restored.repositoryPath == "/repos/app")
        #expect(restored.checkoutPath == nil)
    }

    @Test("An unborn repository checkout still starts from the chosen base")
    func unbornCheckoutDoesNotRejectAValidBase() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let remote = try fixture.bareRemote("App.git")
        try fixture.git(["remote", "add", "origin", remote.path], at: repository)
        try fixture.push(["-u", "origin", "main"], at: repository)
        let mainTip = try fixture.git(["rev-parse", "HEAD"], at: repository)
        let linked = fixture.root.appendingPathComponent("App-side", isDirectory: true)
        try fixture.git(["worktree", "add", "--quiet", "-b", "side", linked.path], at: repository)
        try fixture.git(["checkout", "--orphan", "unborn"], at: repository)
        #expect(await GitService.shared.getCommitSHA("HEAD", at: repository.path) == nil)

        let defaultBase = try await TaskWorktreeService.resolveBase(
            for: TaskWorktreeRequest(repositoryPath: repository.path),
            git: GitService.shared
        )
        #expect(defaultBase.commit == mainTip)
        #expect(defaultBase.ref == "origin/main")

        let linkedBase = try await TaskWorktreeService.resolveBase(
            for: TaskWorktreeRequest(
                repositoryPath: repository.path, checkoutPath: linked.path, base: .currentBranch
            ),
            git: GitService.shared
        )
        #expect(linkedBase.commit == mainTip)
        #expect(linkedBase.ref == "side")

        await #expect(throws: TaskWorktreeCreationError.self) {
            try await TaskWorktreeService.resolveBase(
                for: TaskWorktreeRequest(repositoryPath: repository.path, base: .currentBranch),
                git: GitService.shared
            )
        }
    }

    @Test("The strip picks the repository that holds the shared code location, then the draft's recorded choice")
    func stripFollowsSharedCodeLocation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let first = try fixture.repository("First")
        let second = try fixture.repository("Second")
        let linked = fixture.root.appendingPathComponent("Second-side", isDirectory: true)
        try fixture.git(["worktree", "add", "--quiet", "-b", "side", linked.path], at: second)
        let repositories = await GitService.shared.scanForGitRepositories(
            primaryPath: fixture.storage.path, additionalPaths: [first.path, second.path]
        )
        func scan(
            _ codePath: String?,
            primary: String? = nil,
            recorded: NewTaskWorktreeDockView.RecordedChoice? = nil
        ) async -> NewTaskWorktreeDockView.ScanSelection {
            await NewTaskWorktreeDockView.scanSelection(
                codePath: codePath, primaryPath: primary ?? fixture.storage.path,
                repositories: repositories, recorded: recorded, git: GitService.shared
            )
        }

        let exact = await scan(second.path)
        #expect(exact == .checkout(repository: second.path, path: second.path, available: true))
        let worktree = await scan(linked.path)
        #expect(worktree == .checkout(repository: second.path, path: linked.path, available: true))
        let primary = await scan(nil, primary: second.path)
        #expect(primary == .checkout(repository: second.path, path: second.path, available: true))
        let fallback = await scan(nil)
        #expect(fallback == .checkout(repository: first.path, path: first.path, available: true))

        // A recorded choice beats the fallback; a live checkout beats both.
        let recorded = NewTaskWorktreeDockView.RecordedChoice(repository: second.path, checkout: linked.path)
        let kept = await scan(fixture.storage.path, recorded: recorded)
        #expect(kept == .checkout(repository: second.path, path: linked.path, available: true))
        let live = await scan(first.path, recorded: recorded)
        #expect(live == .checkout(repository: first.path, path: first.path, available: true))
        let legacy = await scan(nil, recorded: .init(repository: second.path, checkout: nil))
        #expect(legacy == .checkout(repository: second.path, path: second.path, available: true))
        // A recorded checkout that is not the recorded repository's is unavailable.
        let foreign = await scan(nil, recorded: .init(repository: first.path, checkout: linked.path))
        #expect(foreign == .checkout(repository: first.path, path: linked.path, available: false))
    }

    @Test("The Repository card's scan keeps a workspace default on one of the repository's worktrees")
    func repositoryScanKeepsWorktreeDefault() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let linked = fixture.root.appendingPathComponent("App-side", isDirectory: true)
        try fixture.git(["worktree", "add", "--quiet", "-b", "side", linked.path], at: repository)
        let workspace = Workspace(name: "App", primaryPath: fixture.storage.path, additionalPaths: [repository.path])
        workspace.activeWorkingPath = linked.path

        let panel = WorkspaceGitViewModel()
        panel.setWorkspaceForTesting(workspace)
        await panel.scanRepositories()

        #expect(panel.rootRepoPath == repository.path)
        #expect(panel.workingPath == linked.path)
        #expect(workspace.activeWorkingPath == linked.path)
    }

    @Test("A bound worktree that is gone or replaced disables repository actions instead of using another checkout",
          arguments: ["missing", "folder", "repository"])
    func missingBoundWorktreeDisablesRepositoryActions(state: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let workspace = workspace(repository, in: store.mainContext)
        let draft = AgentTask(title: "Draft", goal: "Explore", workspace: workspace)
        try await prepare(draft, repository, context: store.mainContext, fixture: fixture)
        let path = try #require(draft.executionRootPath)

        let panel = WorkspaceGitViewModel()
        panel.setWorkspaceForTesting(workspace, selectedTask: draft)
        panel.selectedRepository = GitRepositoryInfo(name: "App", path: repository.path)
        // The live worktree is usable.
        #expect(panel.unavailableWorktreeBinding == nil)
        #expect(panel.workingPath == path)

        try FileManager.default.removeItem(atPath: path)
        switch state {
        case "folder":
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        case "repository":
            _ = try fixture.repository(String(path.dropFirst(fixture.root.path.count + 1)))
        default: break
        }
        #expect(panel.unavailableWorktreeBinding?.worktreePath == path)
        #expect(panel.workingPath == nil)
        #expect(!panel.canOpenCommitSheet)
        #expect(!panel.canChangeActiveCodePath)
        #expect(panel.activeSelectionScopeLabel == "Worktree unavailable")
        #expect(panel.createPullRequestCommentTask(modelContext: store.mainContext) == nil)
    }

    @Test("A binding survives a branch switch inside its worktree but not a same-repository replacement")
    func bindingRejectsSameRepositoryReplacement() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let workspace = workspace(repository, in: store.mainContext)
        let draft = AgentTask(title: "Draft", goal: "Explore", workspace: workspace)
        try await prepare(draft, repository, context: store.mainContext, fixture: fixture)
        let path = try #require(draft.executionRootPath)
        let payload = try #require(TaskWorktreeBinding.payload(for: draft))
        #expect(payload.identity != nil)

        try fixture.git(["checkout", "--quiet", "-b", "agent-branch"], at: URL(fileURLWithPath: path))
        #expect(TaskWorktreeBinding.payload(for: draft)?.worktreePath == path)

        try fixture.git(["worktree", "remove", "--force", path], at: repository)
        try fixture.git(["worktree", "add", "--quiet", "-b", "someone-else", path], at: repository)
        guard case .invalid = TaskWorktreeBinding.state(of: draft) else {
            Issue.record("A worktree recreated at the same path must not pass as the task's")
            return
        }
        let panel = WorkspaceGitViewModel()
        panel.setWorkspaceForTesting(workspace, selectedTask: draft)
        panel.selectedRepository = GitRepositoryInfo(name: "App", path: repository.path)
        #expect(panel.unavailableWorktreeBinding?.worktreePath == path)
        #expect(panel.workingPath == nil)
    }

    @Test("A draft with its own worktree keeps it; the card explains how to choose another checkout")
    func draftWorktreeLocksCodeLocation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let workspace = workspace(repository, in: store.mainContext)
        let plain = AgentTask(title: "Plain", goal: "Explore", workspace: workspace)
        let draft = AgentTask(title: "Draft", goal: "Explore", workspace: workspace)
        try await prepare(draft, repository, context: store.mainContext, fixture: fixture)
        let panel = WorkspaceGitViewModel()

        panel.setWorkspaceForTesting(workspace, selectedTask: plain)
        #expect(panel.canChangeActiveCodePath)
        panel.setWorkspaceForTesting(workspace, selectedTask: draft)
        #expect(!panel.canChangeActiveCodePath)
        #expect(panel.activeCodePathChangeBlockedMessage.contains("own worktree"))
    }

    @Test("Addressing PR comments from a task's worktree keeps that task's binding")
    func pullRequestCommentDraftKeepsWorktreeBinding() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let sources = repository.appendingPathComponent("Sources").path
        let store = try Fixture.container()
        let workspace = Workspace(name: "App", primaryPath: repository.path, additionalPaths: [sources])
        store.mainContext.insert(workspace)
        let task = AgentTask(title: "Task", goal: "Update files", workspace: workspace)
        try await prepare(task, repository, context: store.mainContext, fixture: fixture)
        let path = try #require(task.executionRootPath)
        let pr = GitHubPullRequestRef(number: 7, url: "https://github.com/coral/astra/pull/7", title: "Worktree")
        let comment = GitHubPullRequestComment(
            id: "c7", author: "reviewer", body: "Fix the file.", path: "Sources/file.txt", line: 1,
            url: "https://github.com/coral/astra/pull/7#discussion_r7", createdAt: "2026-10-08T00:00:00Z",
            isReviewThread: true
        )
        let panel = WorkspaceGitViewModel()
        panel.setWorkspaceForTesting(workspace, selectedTask: task)
        panel.selectedRepository = GitRepositoryInfo(name: "App", path: repository.path)
        panel.openPullRequest = pr
        panel.pullRequestComments = GitHubPullRequestCommentSummary(
            pullRequest: pr, comments: [comment], unresolvedThreadCount: 1, issueCommentCount: 0, fetchedAt: Date()
        )
        #expect(panel.workingPath == path)

        let draft = try #require(panel.createPullRequestCommentTask(modelContext: store.mainContext))
        #expect(draft.executionRootPath == path)
        #expect(TaskWorktreeBinding.payload(for: draft)?.worktreePath == path)
        let writable = TaskWorkspaceAccess(task: draft).runtimeWritablePaths
        #expect(writable.contains(path + "/Sources"))
        #expect(!writable.contains(sources))
        #expect(!writable.contains(repository.path))
    }

    @Test("Current branch fails when the selected checkout disappears")
    func missingSelectedCheckoutDoesNotUseRepositoryHead() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let missing = fixture.root.appendingPathComponent("gone").path
        let request = TaskWorktreeRequest(
            repositoryPath: repository.path, checkoutPath: missing, base: .currentBranch
        )
        do {
            _ = try await TaskWorktreeService.resolveBase(for: request, git: GitService.shared)
            Issue.record("A missing checkout must not fall back to the repository HEAD")
        } catch let error as TaskWorktreeCreationError {
            guard case .checkoutUnavailable(let path) = error else {
                Issue.record(error)
                return
            }
            #expect(path.hasSuffix("gone"))
        }
        #expect(await TaskWorktreeService.baseLabel(for: request, git: GitService.shared) == nil)

        // A folder that appeared at the recorded path, even another
        // checkout with a commit the repository also holds, is not the
        // recorded checkout.
        let replacement = try fixture.repository("App-replacement")
        let replaced = TaskWorktreeRequest(
            repositoryPath: repository.path, checkoutPath: replacement.path, base: .currentBranch
        )
        await #expect(throws: TaskWorktreeCreationError.checkoutUnavailable(replacement.path)) {
            try await TaskWorktreeService.resolveBase(for: replaced, git: GitService.shared)
        }
        #expect(await TaskWorktreeService.baseLabel(for: replaced, git: GitService.shared) == nil)
    }

    @Test("A composer draft's recorded location follows Repository-card edits of the workspace default")
    func composerDraftFollowsWorkspaceDefault() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let first = try fixture.repository("First")
        let second = try fixture.repository("Second")
        let store = try Fixture.container()
        let context = store.mainContext
        let workspace = Workspace(name: "Both", primaryPath: first.path, additionalPaths: [second.path])
        context.insert(workspace)
        let draft = AgentTask(title: "Draft", goal: "Explore", workspace: workspace)
        context.insert(draft)
        var selection = NewTaskWorktreeSelection()
        selection.isEnabled = true
        selection.base = .currentBranch
        selection.repositoryPath = first.path
        selection.checkoutPath = first.path
        try NewTaskWorktreeComposerFlow.persistChoice(selection, on: draft, modelContext: context)
        TaskCodeLocationPin.set(first.path, workspace: workspace, task: draft)
        // The strip's own pick of the primary matches the default: no change.
        #expect(try !NewTaskWorktreeComposerFlow.followWorkspaceLocation(selection, on: draft, modelContext: context))

        workspace.activeWorkingPath = second.path
        #expect(try NewTaskWorktreeComposerFlow.followWorkspaceLocation(selection, on: draft, modelContext: context))
        let request = try #require(TaskWorktreeService.latestRequest(for: draft))
        #expect(request.enabled)
        #expect(request.base == .currentBranch)
        #expect(request.repositoryPath == nil)
        #expect(request.checkoutPath == nil)
        #expect(draft.executionRootPath == second.path)
        #expect(try !NewTaskWorktreeComposerFlow.followWorkspaceLocation(selection, on: draft, modelContext: context))
    }

    @Test("A recorded repository that disappears stays selected and cannot submit")
    func missingRecordedRepositoryIsNotReplaced() async {
        let app = GitRepositoryInfo(name: "App", path: "/repos/app")
        let other = GitRepositoryInfo(name: "Other", path: "/repos/other")
        let missing = GitRepositoryInfo(name: "Missing", path: "/repos/missing")
        let recorded = NewTaskWorktreeDockView.RecordedChoice(repository: missing.path, checkout: nil)
        var selection = NewTaskWorktreeSelection()
        selection.isEnabled = true
        let gone = await NewTaskWorktreeDockView.scanSelection(
            codePath: missing.path, primaryPath: app.path, repositories: [app, other],
            recorded: recorded, git: GitService.shared
        )
        #expect(gone == .missingRepository(missing.path, checkout: nil))
        NewTaskWorktreeDockView.applyScan(gone, repositories: [app, other], to: &selection)
        #expect(selection.repositoryPath == missing.path)
        #expect(selection.checkoutPath == nil)
        #expect(selection.request == nil)
        #expect(!selection.canSubmit)

        let back = await NewTaskWorktreeDockView.scanSelection(
            codePath: missing.path, primaryPath: app.path, repositories: [app, other, missing],
            recorded: recorded, git: GitService.shared
        )
        #expect(back == .checkout(repository: missing.path, path: missing.path, available: true))
        NewTaskWorktreeDockView.applyScan(back, repositories: [app, other, missing], to: &selection)
        #expect(selection.repositoryPath == missing.path)
        #expect(selection.canSubmit)

        // A recorded Current-branch checkout survives the repository being
        // gone, so editing the choice meanwhile saves it unchanged.
        let side = "/repos/missing-side"
        var withCheckout = NewTaskWorktreeSelection()
        withCheckout.isEnabled = true
        withCheckout.base = .currentBranch
        let goneWithCheckout = await NewTaskWorktreeDockView.scanSelection(
            codePath: nil, primaryPath: app.path, repositories: [app, other],
            recorded: .init(repository: missing.path, checkout: side), git: GitService.shared
        )
        #expect(goneWithCheckout == .missingRepository(missing.path, checkout: side))
        NewTaskWorktreeDockView.applyScan(goneWithCheckout, repositories: [app, other], to: &withCheckout)
        withCheckout.base = .defaultBranch
        #expect(withCheckout.requestPayload.repositoryPath == missing.path)
        #expect(withCheckout.requestPayload.checkoutPath == side)
        #expect(!withCheckout.canSubmit)
    }

    @Test(
        "A Current branch draft whose recorded checkout is gone keeps it selected instead of another checkout",
        arguments: [false, true]
    )
    func vanishedRecordedCheckoutStaysSelected(pruned: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let other = try fixture.repository("Other")
        let app = try fixture.repository("App")
        let linked = fixture.root.appendingPathComponent("App-side", isDirectory: true)
        try fixture.git(["worktree", "add", "--quiet", "-b", "side", linked.path], at: app)
        let store = try Fixture.container()
        let context = store.mainContext
        // The workspace default is Other, so a fallback would pick it.
        let workspace = Workspace(name: "Work", primaryPath: other.path, additionalPaths: [app.path])
        context.insert(workspace)
        let draft = AgentTask(title: "Draft", goal: "Explore", workspace: workspace)
        context.insert(draft)
        let repositories = await GitService.shared.scanForGitRepositories(
            primaryPath: other.path, additionalPaths: [app.path]
        )
        let appInfo = try #require(repositories.first { $0.path == app.path })

        var selection = NewTaskWorktreeSelection()
        selection.isEnabled = true
        selection.base = .currentBranch
        selection.updateRepositories(repositories, selectedPath: app.path, checkoutPath: linked.path)
        NewTaskWorktreeComposerFlow.recordChoice(selection, on: draft, modelContext: context)
        NewTaskWorktreeComposerFlow.followWorkspaceDefault(draft)
        try context.save()
        if pruned {
            try fixture.git(["worktree", "remove", "--force", linked.path], at: app)
        } else {
            try FileManager.default.removeItem(at: linked)
        }

        let reopenedContext = ModelContext(store)
        let reopened = try #require(reopenedContext.fetch(FetchDescriptor<AgentTask>()).first)
        var restored = NewTaskWorktreeSelection()
        NewTaskWorktreeComposerFlow.restoreChoice(&restored, from: reopened)
        #expect(restored.checkoutPath == linked.path)
        #expect(restored.isCheckoutUnavailable)
        let scan = await NewTaskWorktreeDockView.scanSelection(
            codePath: reopened.executionRootPath, primaryPath: other.path, repositories: repositories,
            recorded: NewTaskWorktreeDockView.recordedChoice(for: reopened), git: GitService.shared
        )
        #expect(scan == .checkout(repository: app.path, path: linked.path, available: false))
        NewTaskWorktreeDockView.applyScan(scan, repositories: repositories, to: &restored)
        #expect(restored.repositoryPath == app.path)
        #expect(restored.checkoutPath == linked.path)
        #expect(!restored.canSubmit)
        #expect(restored.submitError == .checkoutUnavailable(linked.path))
        // Saving the draft again leaves its recorded choice as it was.
        #expect(!NewTaskWorktreeComposerFlow.recordChoice(restored, on: reopened, modelContext: reopenedContext))

        let blocked = AgentTask(title: "Blocked", goal: "Run", workspace: workspace)
        context.insert(blocked)
        await #expect(throws: TaskWorktreeCreationError.checkoutUnavailable(linked.path)) {
            try await TaskWorktreeService.prepare(
                task: blocked, request: restored.request, modelContext: context, resourceQueue: fixture.resourceQueue,
                worktreesRoot: fixture.worktrees.path, ownership: fixture.ownership
            )
        }
        #expect(TaskWorktreeService.activeWorktreeBinding(for: blocked) == nil)

        // Default branch does not read the checkout, so it starts in App.
        restored.base = .defaultBranch
        #expect(restored.canSubmit)
        let task = AgentTask(title: "Run", goal: "Run", workspace: workspace)
        context.insert(task)
        try await TaskWorktreeService.prepare(
            task: task, request: restored.request, modelContext: context, resourceQueue: fixture.resourceQueue,
            worktreesRoot: fixture.worktrees.path, ownership: fixture.ownership
        )
        #expect(try #require(TaskWorktreeService.activeWorktreeBinding(for: task)).repositoryPath == app.path)

        // Choosing App again replaces the gone checkout with App's own folder.
        restored.base = .currentBranch
        #expect(restored.isNewChoice(appInfo))
        restored.choose(appInfo)
        #expect(restored.checkoutPath == app.path)
        #expect(restored.canSubmit)
        #expect(!restored.isNewChoice(appInfo))
    }
}

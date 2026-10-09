import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("New task worktree creation journal and submodules", .serialized)
struct NewTaskWorktreeCreationJournalTests {
    private typealias Fixture = NewTaskWorktreeFixture

    private func commitAll(_ message: String, at repository: URL, fixture: Fixture) throws {
        try fixture.git([
            "-c", "user.name=ASTRA Tests", "-c", "user.email=astra-tests@example.invalid",
            "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
            "commit", "--quiet", "-m", message
        ], at: repository)
    }

    /// Git blocks local-path submodule clones by default; fixtures allow them.
    private func addSubmodule(_ source: URL, at path: String, in repository: URL, fixture: Fixture) throws {
        try fixture.git(["-c", "protocol.file.allow=always", "submodule", "add", "--quiet", source.path, path], at: repository)
        try commitAll("Add \(path)", at: repository, fixture: fixture)
    }

    /// `App` with an initialized `libs/a`, whose own `deps/nested` is
    /// initialized too, and a registered `libs/b` the repository never
    /// initialized.
    private func repositoryWithSubmodules(_ fixture: Fixture) throws -> URL {
        let nested = try fixture.repository("Nested")
        let libA = try fixture.repository("LibA")
        try addSubmodule(nested, at: "deps/nested", in: libA, fixture: fixture)
        let libB = try fixture.repository("LibB")
        let app = try fixture.repository("App")
        try addSubmodule(libA, at: "libs/a", in: app, fixture: fixture)
        try addSubmodule(libB, at: "libs/b", in: app, fixture: fixture)
        try fixture.git(["-c", "protocol.file.allow=always", "submodule", "update", "--init", "--recursive"], at: app)
        try fixture.git(["submodule", "deinit", "--quiet", "libs/b"], at: app)
        return app
    }

    /// ASTRA's submodule commands, with the local-path clones fixtures need.
    private func localSubmoduleSetup(_ fixture: Fixture, commands: [[String]] = GitService.taskWorktreeSubmoduleCommands,
                                     thenFail: Bool = false) -> TaskWorktreeSubmoduleSetup {
        { _, path in
            for arguments in commands {
                try fixture.git(["-c", "protocol.file.allow=always"] + arguments, at: URL(fileURLWithPath: path))
            }
            if thenFail { throw CocoaError(.fileReadNoPermission) }
        }
    }

    private func draft(in repository: URL, context: ModelContext) -> AgentTask {
        let workspace = Workspace(name: "App", primaryPath: repository.path)
        context.insert(workspace)
        return AgentTask(title: "Update libraries", goal: "Update the libraries", workspace: workspace)
    }

    private func jsonFiles(in directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
    }

    /// An intent for a worktree ASTRA would create for a new task.
    private func intent(_ name: String, in repository: URL, fixture: Fixture) throws -> TaskWorktreeDiscard {
        let branch = "astra/\(name)-0badc0de"
        return TaskWorktreeDiscard(
            taskID: UUID(), repositoryPath: repository.path,
            worktreePath: GitService.worktreeLocation(
                repoPath: repository.path, branch: branch, worktreesRoot: fixture.worktrees.path
            ),
            branch: branch, baseCommit: try fixture.git(["rev-parse", "HEAD"], at: repository)
        )
    }

    /// Runs `git worktree add` the way creation does for `intent`.
    @discardableResult
    private func addWorktree(for intent: TaskWorktreeDiscard, fixture: Fixture) async throws -> String {
        let created = try await GitService.shared.addWorktree(
            repoPath: intent.repositoryPath, branch: intent.branch, createBranch: true, base: intent.baseCommit,
            worktreesRoot: fixture.worktrees.path
        )
        #expect(created == intent.worktreePath)
        return created
    }

    /// Nothing from a failed or abandoned creation remains: no checkout, no
    /// branch, no journal entry, and no ownership record.
    private func expectNothingLeft(in repository: URL, fixture: Fixture) async throws {
        #expect(await GitService.shared.listWorktrees(at: repository.path).count == 1)
        #expect(try fixture.git(["branch", "--list", "astra/*"], at: repository).isEmpty)
        #expect(try fixture.ownership.creationJournal.pendingURLs().isEmpty)
        #expect(try jsonFiles(in: fixture.ownership.directory).isEmpty)
    }

    // MARK: - Submodules

    @Test("A new worktree populates the submodules the repository initialized, recursively")
    func worktreeMirrorsInitializedSubmodules() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let app = try repositoryWithSubmodules(fixture)
        let store = try Fixture.container()
        let task = draft(in: app, context: store.mainContext)

        try await TaskWorktreeService.prepare(
            task: task, request: TaskWorktreeRequest(repositoryPath: app.path, base: .currentBranch),
            modelContext: store.mainContext, resourceQueue: fixture.resourceQueue, worktreesRoot: fixture.worktrees.path, ownership: fixture.ownership,
            setUpSubmodules: localSubmoduleSetup(fixture)
        )

        let worktree = URL(fileURLWithPath: try #require(task.executionRootPath))
        #expect(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("libs/a/Sources/file.txt").path))
        #expect(FileManager.default.fileExists(
            atPath: worktree.appendingPathComponent("libs/a/deps/nested/Sources/file.txt").path
        ))
        #expect(try FileManager.default.contentsOfDirectory(atPath: worktree.appendingPathComponent("libs/b").path).isEmpty)
        #expect(try fixture.git(["status", "--porcelain", "--ignore-submodules=none"], at: worktree).isEmpty)
        #expect(await GitService.shared.submoduleCheckoutState(at: worktree.path) == .unchanged)
        #expect(try fixture.ownership.creationJournal.pendingURLs().isEmpty)
    }

    @Test("A worktree whose submodules can't be set up blocks the task and leaves nothing behind")
    func submoduleFailureAbandonsCreation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let app = try repositoryWithSubmodules(fixture)
        // The worktree's clone of libs/a has nowhere to come from.
        try fixture.git(["config", "submodule.libs/a.url", fixture.root.appendingPathComponent("Missing").path], at: app)
        let store = try Fixture.container()
        let task = draft(in: app, context: store.mainContext)

        do {
            try await TaskWorktreeService.prepare(
                task: task, request: TaskWorktreeRequest(repositoryPath: app.path, base: .currentBranch),
                modelContext: store.mainContext, resourceQueue: fixture.resourceQueue, worktreesRoot: fixture.worktrees.path, ownership: fixture.ownership
            )
            Issue.record("Expected submodule setup to fail")
        } catch TaskWorktreeCreationError.submodulesUnavailable(let path, _) {
            #expect(path == app.path)
        }

        #expect(task.executionRootPath == nil)
        #expect(task.events.isEmpty)
        try await expectNothingLeft(in: app, fixture: fixture)
    }

    @Test("A partly set-up worktree is removed, populated submodules included, when setup fails")
    func partialSubmoduleSetupIsRemoved() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let app = try repositoryWithSubmodules(fixture)
        let store = try Fixture.container()
        let task = draft(in: app, context: store.mainContext)

        await #expect(throws: TaskWorktreeCreationError.self) {
            try await TaskWorktreeService.prepare(
                task: task, request: TaskWorktreeRequest(repositoryPath: app.path, base: .currentBranch),
                modelContext: store.mainContext, resourceQueue: fixture.resourceQueue, worktreesRoot: fixture.worktrees.path, ownership: fixture.ownership,
                setUpSubmodules: localSubmoduleSetup(
                    fixture, commands: Array(GitService.taskWorktreeSubmoduleCommands.prefix(1)), thenFail: true
                )
            )
        }

        #expect(task.executionRootPath == nil)
        try await expectNothingLeft(in: app, fixture: fixture)
    }

    enum SubmoduleWork: String, CaseIterable, Sendable {
        case none
        /// A commit only the nested submodule's reflog holds, invisible to the
        /// worktree's own status once the submodule is back on its commit.
        case unpushedCommit
        /// A deinitialized submodule keeps its repository in the worktree's
        /// Git folder, where a forced removal would delete it.
        case deinitialized
    }

    @Test("Worktree cleanliness is true, false, or unknown, and an unknown status is never clean")
    func worktreeCleanlinessFailsClosed() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        #expect(await GitService.shared.worktreeIsClean(at: repository.path) == true)
        try "edit".write(to: repository.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        #expect(await GitService.shared.worktreeIsClean(at: repository.path) == false)
        // Where `git status` fails, the status list reads as clean; the
        // cleanliness check reports it as unknown instead.
        let notARepository = fixture.root.appendingPathComponent("not-a-repository", isDirectory: true)
        try FileManager.default.createDirectory(at: notARepository, withIntermediateDirectories: true)
        #expect(await GitService.shared.getStatusFiles(at: notARepository.path).isEmpty)
        #expect(await GitService.shared.worktreeIsClean(at: notARepository.path) == nil)
    }

    @Test("Discarding removes submodules only while they hold no local work", arguments: SubmoduleWork.allCases)
    func discardRespectsSubmoduleWork(work: SubmoduleWork) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let app = try repositoryWithSubmodules(fixture)
        let store = try Fixture.container()
        let context = store.mainContext
        let task = draft(in: app, context: context)
        try await TaskWorktreeService.prepare(
            task: task, request: TaskWorktreeRequest(repositoryPath: app.path, base: .currentBranch),
            modelContext: context, resourceQueue: fixture.resourceQueue, worktreesRoot: fixture.worktrees.path, ownership: fixture.ownership,
            setUpSubmodules: localSubmoduleSetup(fixture)
        )
        let discard = try #require(TaskWorktreeService.discardSnapshots(for: task, ownership: fixture.ownership).first)
        let worktree = URL(fileURLWithPath: discard.worktreePath)
        switch work {
        case .none:
            break
        case .unpushedCommit:
            let nested = worktree.appendingPathComponent("libs/a/deps/nested")
            let recorded = try fixture.git(["rev-parse", "HEAD"], at: nested)
            try fixture.git([
                "-c", "user.name=ASTRA Tests", "-c", "user.email=astra-tests@example.invalid",
                "-c", "commit.gpgsign=false", "commit", "--quiet", "--allow-empty", "-m", "Local work"
            ], at: nested)
            try fixture.git(["checkout", "--quiet", "--detach", recorded], at: nested)
        case .deinitialized:
            try fixture.git(["submodule", "deinit", "--quiet", "libs/a"], at: worktree)
        }
        #expect(try fixture.git(["status", "--porcelain"], at: worktree).isEmpty)
        context.delete(task)
        try context.save()

        let outcome = await TaskWorktreeService.discardOutcome(discard, modelContext: context, resourceQueue: fixture.resourceQueue)

        let removed = work == .none
        #expect(outcome == (removed ? .removed : .kept("submodule_changes")))
        #expect(FileManager.default.fileExists(atPath: discard.worktreePath) == !removed)
        #expect(try fixture.git(["branch", "--list", discard.branch], at: app).isEmpty == removed)
    }

    // MARK: - Creation journal

    @Test("A creation interrupted after Git ran is removed on next launch")
    func interruptedCreationIsRemoved() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let journal = fixture.ownership.creationJournal
        let intent = try intent("interrupted", in: repository, fixture: fixture)
        // What a crash between `git worktree add` and saving the task leaves.
        try journal.record(intent)
        try journal.ownership.record(.init(intent))
        try await addWorktree(for: intent, fixture: fixture)
        let store = try Fixture.container()

        #expect(await TaskWorktreeCleanupService.resumeInterruptedCreations(
            modelContext: store.mainContext, resourceQueue: fixture.resourceQueue, journal: journal
        ) == 1)

        #expect(!FileManager.default.fileExists(atPath: intent.worktreePath))
        try await expectNothingLeft(in: repository, fixture: fixture)
        #expect(await TaskWorktreeCleanupService.resumeInterruptedCreations(
            modelContext: store.mainContext, resourceQueue: fixture.resourceQueue, journal: journal
        ) == 0)
    }

    @Test("A journal entry without its ownership record never touches Git")
    func unownedJournalEntryLeavesGitAlone() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let journal = fixture.ownership.creationJournal
        let intent = try intent("unowned", in: repository, fixture: fixture)
        // Ownership is recorded only once Git created the worktree, so a
        // checkout at this path without it isn't one this creation made.
        try journal.record(intent)
        try await addWorktree(for: intent, fixture: fixture)
        let store = try Fixture.container()

        #expect(await TaskWorktreeCleanupService.resumeInterruptedCreations(
            modelContext: store.mainContext, resourceQueue: fixture.resourceQueue, journal: journal
        ) == 0)

        #expect(try journal.pendingURLs().isEmpty)
        #expect(FileManager.default.fileExists(atPath: intent.worktreePath))
        #expect(try !fixture.git(["branch", "--list", intent.branch], at: repository).isEmpty)
    }

    @Test("A creation whose task binding was saved keeps its worktree and settles the journal")
    func savedBindingSettlesJournal() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let task = draft(in: repository, context: store.mainContext)
        try await TaskWorktreeService.prepare(
            task: task, request: TaskWorktreeRequest(repositoryPath: repository.path, base: .currentBranch),
            modelContext: store.mainContext, resourceQueue: fixture.resourceQueue, worktreesRoot: fixture.worktrees.path, ownership: fixture.ownership
        )
        let journal = fixture.ownership.creationJournal
        #expect(try journal.pendingURLs().isEmpty)
        // The intent outlived a save that bound the worktree.
        let intent = try #require(TaskWorktreeService.discardSnapshots(for: task, ownership: fixture.ownership).first)
        try journal.record(intent)

        #expect(await TaskWorktreeCleanupService.resumeInterruptedCreations(
            modelContext: ModelContext(store), resourceQueue: fixture.resourceQueue, journal: journal
        ) == 0)

        #expect(try journal.pendingURLs().isEmpty)
        #expect(FileManager.default.fileExists(atPath: intent.worktreePath))
        #expect(try !fixture.git(["branch", "--list", intent.branch], at: repository).isEmpty)
        #expect(fixture.ownership.owns(intent))
    }

    @Test("Recovery leaves an in-flight creation alone; abandoning it clears the journal")
    func inFlightCreationIsSkipped() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let journal = fixture.ownership.creationJournal
        let intent = try intent("in-flight", in: repository, fixture: fixture)
        let store = try Fixture.container()
        try TaskWorktreeCleanupService.beginCreation(intent, journal: journal)
        #expect(throws: (any Error).self) { try TaskWorktreeCleanupService.beginCreation(intent, journal: journal) }

        #expect(await TaskWorktreeCleanupService.resumeInterruptedCreations(
            modelContext: store.mainContext, resourceQueue: fixture.resourceQueue, journal: journal
        ) == 0)
        #expect(try journal.pendingURLs().count == 1)
        // Nothing is owned until Git has created the worktree.
        #expect(!journal.ownership.owns(intent))

        await TaskWorktreeCleanupService.abandonCreation(
            intent, journal: journal, modelContext: store.mainContext, resourceQueue: fixture.resourceQueue, git: GitService.shared
        )
        try await expectNothingLeft(in: repository, fixture: fixture)
    }

    @Test("A creation that loses its branch and folder to another process never removes them")
    func failedCreationLeavesCompetingWorktree() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let journal = fixture.ownership.creationJournal
        var intent = try intent("raced", in: repository, fixture: fixture)
        intent.identity = "raced-identity"
        let store = try Fixture.container()
        try TaskWorktreeCleanupService.beginCreation(intent, journal: journal)
        // Another process takes the branch and folder before ASTRA's
        // `git worktree add` runs, so that command fails and is abandoned.
        // The competitor's worktree doesn't carry this intent's lock reason.
        try await addWorktree(for: intent, fixture: fixture)

        await TaskWorktreeCleanupService.abandonCreation(
            intent, journal: journal, modelContext: store.mainContext, resourceQueue: fixture.resourceQueue, git: GitService.shared
        )

        #expect(FileManager.default.fileExists(atPath: intent.worktreePath))
        #expect(try !fixture.git(["branch", "--list", intent.branch], at: repository).isEmpty)
        #expect(try journal.pendingURLs().isEmpty)
        #expect(!journal.ownership.owns(intent))
    }

    @Test("A creation that stopped after Git ran but before recording ownership is still removed")
    func lockedCreationIsAdopted() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let journal = fixture.ownership.creationJournal
        var intent = try intent("locked", in: repository, fixture: fixture)
        intent.identity = "locked-identity"
        // What a quit right after `git worktree add --lock` leaves: the
        // journal entry and Git's own lock reason, but no ownership record.
        try journal.record(intent)
        let created = try await GitService.shared.addLockedTaskWorktree(
            repoPath: repository.path, branch: intent.branch, base: intent.baseCommit,
            worktreesRoot: fixture.worktrees.path, lockReason: TaskWorktreeBinding.lockReason(forIdentity: "locked-identity")
        )
        #expect(created == intent.worktreePath)
        #expect(!fixture.ownership.owns(intent))
        let store = try Fixture.container()

        #expect(await TaskWorktreeCleanupService.resumeInterruptedCreations(
            modelContext: store.mainContext, resourceQueue: fixture.resourceQueue, journal: journal
        ) == 1)
        #expect(!FileManager.default.fileExists(atPath: intent.worktreePath))
        try await expectNothingLeft(in: repository, fixture: fixture)
    }

    @Test("A branch tip is a commit, positively absent, or unavailable")
    func branchTipIsTriState() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let head = try fixture.git(["rev-parse", "HEAD"], at: repository)
        #expect(await GitService.shared.localBranchTip("main", at: repository.path) == .commit(head))
        try fixture.git(["branch", "main-extra"], at: repository)
        // `for-each-ref` matches by prefix; only the exact branch counts.
        #expect(await GitService.shared.localBranchTip("mai", at: repository.path) == .absent)
        #expect(await GitService.shared.localBranchTip("gone", at: repository.path) == .absent)
        let notARepository = fixture.root.appendingPathComponent("not-a-repository", isDirectory: true)
        try FileManager.default.createDirectory(at: notARepository, withIntermediateDirectories: true)
        #expect(await GitService.shared.getCommitSHA("refs/heads/main", at: notARepository.path) == nil)
        #expect(await GitService.shared.localBranchTip("main", at: notARepository.path) == .unavailable)
    }

    @Test("A name an unsettled creation journaled is not reused")
    func journaledNameIsSkipped() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let task = draft(in: repository, context: store.mainContext)
        let journal = fixture.ownership.creationJournal
        let first = TaskWorktreeService.branchName(for: task)
        let pending = TaskWorktreeDiscard(
            taskID: task.id, repositoryPath: repository.path,
            worktreePath: GitService.worktreeLocation(
                repoPath: repository.path, branch: first, worktreesRoot: fixture.worktrees.path
            ),
            branch: first, baseCommit: "0000000000000000000000000000000000000000"
        )
        try journal.record(pending)

        try await TaskWorktreeService.prepare(
            task: task, request: TaskWorktreeRequest(repositoryPath: repository.path, base: .currentBranch),
            modelContext: store.mainContext, resourceQueue: fixture.resourceQueue, worktreesRoot: fixture.worktrees.path, ownership: fixture.ownership
        )

        let binding = try #require(TaskWorktreeService.activeWorktreeBinding(for: task))
        #expect(binding.branch == TaskWorktreeService.branchName(for: task, attempt: 2))
        #expect(try journal.pendingURLs().map(\.lastPathComponent) == [journal.recordURL(for: pending).lastPathComponent])
    }
}

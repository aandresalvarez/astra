import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Durable draft worktree cleanup", .serialized)
struct NewTaskWorktreeCleanupTests {
    private typealias Fixture = NewTaskWorktreeFixture

    private func prepare(
        repository: URL, context: ModelContext, fixture: Fixture
    ) async throws -> (draft: AgentTask, discard: TaskWorktreeDiscard) {
        let workspace = Workspace(name: "App", primaryPath: repository.path)
        context.insert(workspace)
        let draft = AgentTask(title: "Explore", goal: "Explore the implementation", workspace: workspace)
        try await TaskWorktreeService.prepare(
            task: draft, request: TaskWorktreeRequest(repositoryPath: repository.path, base: .currentBranch),
            modelContext: context, resourceQueue: fixture.resourceQueue, worktreesRoot: fixture.worktrees.path, ownership: fixture.ownership
        )
        return (draft, try #require(TaskWorktreeService.discardSnapshots(for: draft, ownership: fixture.ownership).first))
    }

    private func persistentContainer(at url: URL) throws -> ModelContainer {
        try ModelContainer(for: ASTRASchema.current, configurations: [ModelConfiguration(url: url)])
    }

    private func leaveInterruptedCleanup(
        repository: URL, fixture: Fixture, storeURL: URL
    ) async throws -> TaskWorktreeDiscard {
        let store = try persistentContainer(at: storeURL)
        let (draft, discard) = try await prepare(repository: repository, context: store.mainContext, fixture: fixture)
        try fixture.cleanupStore.record(discard)
        store.mainContext.delete(draft)
        try store.mainContext.save()
        return discard
    }

    @Test("Outbox enumeration preserves record identity across equivalent filesystem URL spellings")
    func enumeratedRecordsRoundTrip() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let outbox = fixture.cleanupStore
        let discard = TaskWorktreeDiscard(
            taskID: UUID(), repositoryPath: fixture.root.path, worktreePath: fixture.worktrees.path,
            branch: "astra/test", baseCommit: "base"
        )
        try outbox.record(discard)
        let listed = try #require(outbox.pendingURLs().first)
        #expect(try outbox.read(listed) == discard)
        #expect(try fixture.cleanupStore.read(listed) == discard)
        try fixture.cleanupStore.remove(discard)
        #expect(try outbox.pendingURLs().isEmpty)
    }

    @Test("A cleanup intent survives reopening the persistent store and is consumed once")
    func cleanupSurvivesRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let storeURL = fixture.root.appendingPathComponent("cleanup.sqlite")
        let discard = try await leaveInterruptedCleanup(repository: repository, fixture: fixture, storeURL: storeURL)
        #expect(try fixture.cleanupStore.read(fixture.cleanupStore.recordURL(for: discard)) == discard)

        let reopened = try persistentContainer(at: storeURL)
        #expect(try reopened.mainContext.fetchCount(FetchDescriptor<AgentTask>()) == 0)
        #expect(await TaskWorktreeCleanupService.resumePending(modelContext: reopened.mainContext, resourceQueue: fixture.resourceQueue, store: fixture.cleanupStore) == 1)
        #expect(!FileManager.default.fileExists(atPath: discard.worktreePath))
        #expect(try fixture.git(["branch", "--list", discard.branch], at: repository).isEmpty)
        #expect(try fixture.cleanupStore.pendingURLs().isEmpty)
        #expect(await TaskWorktreeCleanupService.resumePending(modelContext: reopened.mainContext, resourceQueue: fixture.resourceQueue, store: fixture.cleanupStore) == 0)
    }

    @Test("Deleting a duplicated draft keeps the original task's same-ID checkout", arguments: [false, true])
    func duplicateDraftKeepsOriginalCheckout(resumeAfterRestart: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let storeURL = fixture.root.appendingPathComponent("duplicate.sqlite")
        let store = try persistentContainer(at: storeURL)
        let context = store.mainContext
        let (original, _) = try await prepare(repository: repository, context: context, fixture: fixture)
        let workspace = try #require(original.workspace)
        let originalIdentity = original.persistentModelID
        let configURL = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: repository.path))
        try WorkspaceConfigManager.exportToFile(workspace: workspace, modelContext: context, url: configURL)
        let coordinator = TaskLifecycleCoordinator(
            modelContext: context, taskQueue: TaskQueue(poolSize: 0), worktreeCleanupStore: fixture.cleanupStore
        )
        let duplicateWorkspace = try #require(coordinator.importFromConfig(
            at: configURL, existingWorkspaces: [workspace], askDuplicateAction: { _, _ in .duplicate }
        ))
        let duplicate = try #require(duplicateWorkspace.tasks.first)
        try context.save()
        #expect(duplicateWorkspace.id != workspace.id)
        #expect(duplicate.id == original.id)
        #expect(duplicate.persistentModelID != originalIdentity)
        #expect(duplicate.executionRootPath == original.executionRootPath)
        let discard = try #require(TaskWorktreeService.discardSnapshots(for: duplicate, ownership: fixture.ownership).first)
        if resumeAfterRestart { try fixture.cleanupStore.record(discard) }
        context.delete(duplicate)
        try context.save()

        let reopened = try persistentContainer(at: storeURL)
        let cleanupContext = resumeAfterRestart ? reopened.mainContext : context
        if resumeAfterRestart {
            #expect(await TaskWorktreeCleanupService.resumePending(
                modelContext: cleanupContext, resourceQueue: fixture.resourceQueue, store: fixture.cleanupStore
            ) == 0)
            #expect(try fixture.cleanupStore.pendingURLs().isEmpty)
        } else {
            #expect(await TaskWorktreeService.discardOutcome(discard, modelContext: cleanupContext, resourceQueue: fixture.resourceQueue) == .kept("referenced"))
        }
        #expect(FileManager.default.fileExists(atPath: discard.worktreePath))
        #expect(try !fixture.git(["branch", "--list", discard.branch], at: repository).isEmpty)
        let survivors = try cleanupContext.fetch(FetchDescriptor<AgentTask>())
        #expect(survivors.count == 1)
        let survivor = try #require(survivors.first)
        #expect(survivor.id == original.id)
        #expect(survivor.workspace?.id == workspace.id)
        #expect(survivor.executionRootPath == discard.worktreePath)

        cleanupContext.delete(survivor)
        try cleanupContext.save()
        #expect(await TaskWorktreeService.discardUnusedWorktree(discard, modelContext: cleanupContext, resourceQueue: fixture.resourceQueue))
        #expect(!FileManager.default.fileExists(atPath: discard.worktreePath))
        #expect(try fixture.git(["branch", "--list", discard.branch], at: repository).isEmpty)
    }

    @Test("Symlinked workspace roots and task pins keep the checkout they reach", arguments: ["at", "inside", "above"])
    func aliasedReferencesKeepCheckout(placement: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let context = store.mainContext
        let (draft, discard) = try await prepare(repository: repository, context: context, fixture: fixture)
        let workspace = try #require(draft.workspace)
        let checkout = URL(fileURLWithPath: discard.worktreePath, isDirectory: true)
        let target = switch placement {
        case "inside": checkout.appendingPathComponent("Sources", isDirectory: true)
        case "above": fixture.worktrees
        default: checkout
        }
        let alias = fixture.root.appendingPathComponent("Alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let other = Workspace(name: "Alias", primaryPath: fixture.storage.path, additionalPaths: [alias.path])
        context.insert(other)
        context.delete(draft)
        try context.save()

        #expect(await TaskWorktreeService.discardOutcome(discard, modelContext: context, resourceQueue: fixture.resourceQueue) == .kept("referenced"))
        try #require(FileManager.default.fileExists(atPath: discard.worktreePath))
        context.delete(other)
        let survivor = AgentTask(title: "Alias", goal: "Use the checkout", workspace: workspace)
        survivor.executionRootPath = alias.path
        context.insert(survivor)
        try context.save()
        #expect(await TaskWorktreeService.discardOutcome(discard, modelContext: context, resourceQueue: fixture.resourceQueue) == .kept("referenced"))
        #expect(try !fixture.git(["branch", "--list", discard.branch], at: repository).isEmpty)

        context.delete(survivor)
        try context.save()
        #expect(await TaskWorktreeService.discardOutcome(discard, modelContext: context, resourceQueue: fixture.resourceQueue) == .removed)
    }

    @Test("Reference checks keep a checkout while its owning draft still exists")
    func liveTaskPinPreventsPrematureCleanup() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let (draft, discard) = try await prepare(repository: repository, context: store.mainContext, fixture: fixture)

        #expect(await TaskWorktreeService.discardOutcome(discard, modelContext: store.mainContext, resourceQueue: fixture.resourceQueue) == .kept("referenced"))
        #expect(!draft.isDeleted)
        #expect(try store.mainContext.fetchCount(FetchDescriptor<AgentTask>()) == 1)
        #expect(FileManager.default.fileExists(atPath: discard.worktreePath))
        #expect(try !fixture.git(["branch", "--list", discard.branch], at: repository).isEmpty)
    }

    @Test("The intent is saved before deletion and cleared only after cleanup finishes")
    func cleanupIntentPrecedesDeletion() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let context = store.mainContext
        let (draft, discard) = try await prepare(repository: repository, context: context, fixture: fixture)
        let saved = TaskWorktreeService.saveDeletionThenDiscard(
            [discard], workspace: draft.workspace, modelContext: context, resourceQueue: fixture.resourceQueue, cleanupStore: fixture.cleanupStore,
            delete: {
                #expect(FileManager.default.fileExists(atPath: fixture.cleanupStore.recordURL(for: discard).path))
                context.delete(draft)
            },
            persist: { _, context in
                #expect(FileManager.default.fileExists(atPath: discard.worktreePath))
                do { try context.save(); return true } catch { Issue.record(error); return false }
            }
        )
        let cleanup = try #require(saved.cleanup)
        #expect(saved.persisted)
        #expect(await cleanup.value)
        #expect(try fixture.cleanupStore.pendingURLs().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: discard.worktreePath))
    }

    @Test("An intent write failure leaves the draft and worktree untouched")
    func failedIntentWritePreventsDeletion() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let context = store.mainContext
        let (draft, discard) = try await prepare(repository: repository, context: context, fixture: fixture)
        let blocker = fixture.root.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blocker)
        let unavailable = TaskWorktreeCleanupStore(directory: blocker.appendingPathComponent("Cleanup"))
        var deletionRan = false
        var persistenceRan = false

        let failed = TaskWorktreeService.saveDeletionThenDiscard(
            [discard], workspace: draft.workspace, modelContext: context, resourceQueue: fixture.resourceQueue, cleanupStore: unavailable,
            delete: { deletionRan = true; context.delete(draft) },
            persist: { _, _ in persistenceRan = true; return true }
        )
        #expect(failed.cleanup == nil)
        #expect(!failed.persisted)
        #expect(!deletionRan)
        #expect(!persistenceRan)
        #expect(!draft.isDeleted)
        #expect(try ModelContext(store).fetchCount(FetchDescriptor<AgentTask>()) == 1)
        #expect(FileManager.default.fileExists(atPath: discard.worktreePath))
    }

    @Test("An unsaved deletion never removes a surviving draft's checkout on restart")
    func failedDeletionSaveKeepsCheckoutOnRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let context = store.mainContext
        let (draft, discard) = try await prepare(repository: repository, context: context, fixture: fixture)
        let failed = TaskWorktreeService.saveDeletionThenDiscard(
            [discard], workspace: draft.workspace, modelContext: context, resourceQueue: fixture.resourceQueue, cleanupStore: fixture.cleanupStore,
            delete: { context.delete(draft) }, persist: { _, _ in false }
        )
        #expect(failed.cleanup == nil)
        #expect(!failed.persisted)
        #expect(!draft.isDeleted)
        #expect(try fixture.cleanupStore.pendingURLs().count == 1)

        let durable = ModelContext(store)
        #expect(try durable.fetchCount(FetchDescriptor<AgentTask>()) == 1)
        #expect(await TaskWorktreeCleanupService.resumePending(modelContext: durable, resourceQueue: fixture.resourceQueue, store: fixture.cleanupStore) == 0)
        #expect(FileManager.default.fileExists(atPath: discard.worktreePath))
        #expect(try !fixture.git(["branch", "--list", discard.branch], at: repository).isEmpty)
        #expect(try fixture.cleanupStore.pendingURLs().isEmpty)
    }

    @Test("Cleanup resumes the branch phase after worktree removal", arguments: [false, true])
    func interruptedBranchCleanupResumes(branchAlreadyRemoved: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let context = store.mainContext
        let (draft, discard) = try await prepare(repository: repository, context: context, fixture: fixture)
        try fixture.cleanupStore.record(discard)
        context.delete(draft)
        try context.save()
        try fixture.git(["worktree", "remove", discard.worktreePath], at: repository)
        if branchAlreadyRemoved { try fixture.git(["branch", "--delete", discard.branch], at: repository) }

        #expect(await TaskWorktreeCleanupService.resumePending(modelContext: ModelContext(store), resourceQueue: fixture.resourceQueue, store: fixture.cleanupStore) == 1)
        #expect(try fixture.git(["branch", "--list", discard.branch], at: repository).isEmpty)
        #expect(try fixture.cleanupStore.pendingURLs().isEmpty)
    }

    @Test("A transient Git failure retains the durable intent until a later successful retry")
    func unavailableRepositoryRemainsPending() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let context = store.mainContext
        let (draft, discard) = try await prepare(repository: repository, context: context, fixture: fixture)
        try fixture.cleanupStore.record(discard)
        context.delete(draft)
        try context.save()
        let hidden = fixture.root.appendingPathComponent("Unavailable")
        try FileManager.default.moveItem(at: repository, to: hidden)

        #expect(await TaskWorktreeCleanupService.resumePending(modelContext: ModelContext(store), resourceQueue: fixture.resourceQueue, store: fixture.cleanupStore) == 0)
        #expect(try fixture.cleanupStore.pendingURLs().count == 1)
        #expect(FileManager.default.fileExists(atPath: discard.worktreePath))

        try FileManager.default.moveItem(at: hidden, to: repository)
        #expect(await TaskWorktreeCleanupService.resumePending(modelContext: ModelContext(store), resourceQueue: fixture.resourceQueue, store: fixture.cleanupStore) == 1)
        #expect(try fixture.cleanupStore.pendingURLs().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: discard.worktreePath))
    }

    @Test("Preserving user files or a changed checkout is a terminal cleanup outcome", arguments: [false, true])
    func protectedWorktreeSettlesIntent(detached: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        try fixture.commit(".gitignore", contents: "*.env\n", message: "Ignore env files", at: repository)
        let store = try Fixture.container()
        let context = store.mainContext
        let (draft, discard) = try await prepare(repository: repository, context: context, fixture: fixture)
        let file = URL(fileURLWithPath: discard.worktreePath).appendingPathComponent("local.env")
        if detached {
            try fixture.git(["checkout", "--detach"], at: URL(fileURLWithPath: discard.worktreePath))
        } else {
            try Data("local configuration".utf8).write(to: file)
        }
        try fixture.cleanupStore.record(discard)
        context.delete(draft)
        try context.save()

        #expect(await TaskWorktreeCleanupService.resumePending(modelContext: ModelContext(store), resourceQueue: fixture.resourceQueue, store: fixture.cleanupStore) == 0)
        #expect(FileManager.default.fileExists(atPath: discard.worktreePath))
        if !detached { #expect(FileManager.default.fileExists(atPath: file.path)) }
        #expect(try fixture.cleanupStore.pendingURLs().isEmpty)
    }

    @Test("Cleanup preserves commits reachable only through branch or worktree reflogs", arguments: [false, true])
    func reflogCommitsKeepCheckout(detachedCommit: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let context = store.mainContext
        let (draft, discard) = try await prepare(repository: repository, context: context, fixture: fixture)
        let checkout = URL(fileURLWithPath: discard.worktreePath)
        if detachedCommit { try fixture.git(["checkout", "--quiet", "--detach"], at: checkout) }
        try fixture.git([
            "-c", "user.name=ASTRA Tests", "-c", "user.email=astra-tests@example.invalid",
            "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
            "commit", "--quiet", "--allow-empty", "-m", "Local work"
        ], at: checkout)
        let commit = try fixture.git(["rev-parse", "HEAD"], at: checkout)
        if detachedCommit {
            try fixture.git(["checkout", "--quiet", discard.branch], at: checkout)
        } else {
            try fixture.git(["reset", "--soft", discard.baseCommit], at: checkout)
        }
        #expect(try fixture.git(["status", "--porcelain"], at: checkout).isEmpty)
        #expect(try fixture.git(["rev-parse", "HEAD"], at: checkout) == discard.baseCommit)
        try fixture.cleanupStore.record(discard)
        context.delete(draft)
        try context.save()

        #expect(await TaskWorktreeCleanupService.resumePending(
            modelContext: context, resourceQueue: fixture.resourceQueue, store: fixture.cleanupStore
        ) == 0)
        #expect(FileManager.default.fileExists(atPath: checkout.path))
        #expect(try fixture.git(["reflog", "--format=%H", "HEAD"], at: checkout).contains(commit))
        #expect(try !fixture.git(["branch", "--list", discard.branch], at: repository).isEmpty)
        #expect(try fixture.cleanupStore.pendingURLs().isEmpty)
    }

    @Test("A newly selected workspace checkout protects its worktree before autosave")
    func pendingWorkspacePinKeepsCheckout() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let context = store.mainContext
        let (draft, discard) = try await prepare(repository: repository, context: context, fixture: fixture)
        let workspace = try #require(draft.workspace)
        try fixture.cleanupStore.record(discard)
        context.delete(draft)
        try context.save()
        workspace.activeWorkingPath = discard.worktreePath

        #expect(await TaskWorktreeCleanupService.resumePending(modelContext: context, resourceQueue: fixture.resourceQueue, store: fixture.cleanupStore) == 0)
        #expect(FileManager.default.fileExists(atPath: discard.worktreePath))
        #expect(try fixture.cleanupStore.pendingURLs().isEmpty)
    }

    @Test("Corrupt cleanup records remain visible without deleting a checkout")
    func invalidRecordFailsClosed() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let (draft, discard) = try await prepare(repository: repository, context: store.mainContext, fixture: fixture)
        try fixture.cleanupStore.record(discard)
        store.mainContext.delete(draft)
        try store.mainContext.save()
        try Data("{invalid".utf8).write(to: fixture.cleanupStore.recordURL(for: discard), options: .atomic)

        #expect(await TaskWorktreeCleanupService.resumePending(modelContext: ModelContext(store), resourceQueue: fixture.resourceQueue, store: fixture.cleanupStore) == 0)
        #expect(try fixture.cleanupStore.pendingURLs().count == 1)
        #expect(FileManager.default.fileExists(atPath: discard.worktreePath))
    }

    @Test("Cleanup removes an untouched worktree when the primary checkout is unborn")
    func unbornPrimaryCheckoutCanBeCleanedUp() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let remote = try fixture.bareRemote("App.git")
        try fixture.git(["remote", "add", "origin", remote.path], at: repository)
        try fixture.push(["-u", "origin", "main"], at: repository)
        try fixture.git(["checkout", "--orphan", "unborn"], at: repository)
        let store = try Fixture.container()
        let context = store.mainContext
        let workspace = Workspace(name: "App", primaryPath: repository.path)
        context.insert(workspace)
        let draft = AgentTask(title: "Explore", goal: "Explore the implementation", workspace: workspace)
        context.insert(draft)
        try await TaskWorktreeService.prepare(
            task: draft,
            request: TaskWorktreeRequest(repositoryPath: repository.path, base: .defaultBranch),
            modelContext: context, resourceQueue: fixture.resourceQueue,
            worktreesRoot: fixture.worktrees.path, ownership: fixture.ownership
        )
        let discard = try #require(TaskWorktreeService.discardSnapshots(for: draft, ownership: fixture.ownership).first)
        context.delete(draft)
        try context.save()

        #expect(await TaskWorktreeService.discardOutcome(discard, modelContext: context, resourceQueue: fixture.resourceQueue) == .removed)
        #expect(!FileManager.default.fileExists(atPath: discard.worktreePath))
        #expect(try fixture.git(["branch", "--list", discard.branch], at: repository).isEmpty)
    }

    @Test("Cleanup refuses a new checkout pin until removal finishes")
    func cleanupReservationBlocksAdoption() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let context = store.mainContext
        let (draft, discard) = try await prepare(repository: repository, context: context, fixture: fixture)
        let workspace = try #require(draft.workspace)
        let successor = AgentTask(title: "Next", goal: "Next", workspace: workspace)
        context.insert(successor)
        context.delete(draft)
        try context.save()

        var adopted = true
        let outcome = await TaskWorktreeService.discardOutcome(discard, modelContext: context, resourceQueue: fixture.resourceQueue) {
            adopted = TaskCodeLocationPin.set(discard.worktreePath, workspace: workspace, task: successor)
            let source = AgentTask(title: "Source", goal: "Source", workspace: workspace)
            source.executionRootPath = discard.worktreePath
            let child = AgentTask(title: "Child", goal: "Child", workspace: workspace)
            #expect(TaskWorktreeBinding.inheritPin(from: source, into: child) == nil)
            #expect(child.executionRootPath != discard.worktreePath)
        }
        #expect(outcome == .removed)
        #expect(!adopted)
        #expect(successor.executionRootPath != discard.worktreePath)
        #expect(!TaskWorktreeCheckoutReservation.isReserved(discard.worktreePath))
        #expect(!FileManager.default.fileExists(atPath: discard.worktreePath))
    }

    @Test("An imported or crafted binding never schedules cleanup of a checkout ASTRA didn't create")
    func unownedWorktreeIsNeverDiscarded() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let manual = fixture.root.appendingPathComponent("Manual", isDirectory: true)
        try fixture.git(["worktree", "add", "-b", "manual", manual.path], at: repository)
        let head = try fixture.git(["rev-parse", "HEAD"], at: manual)
        let store = try Fixture.container()
        let context = store.mainContext
        let workspace = Workspace(name: "App", primaryPath: repository.path)
        context.insert(workspace)
        let draft = AgentTask(title: "Imported", goal: "Imported", workspace: workspace)
        context.insert(draft)
        draft.executionRootPath = manual.path
        let payload = try TaskEvent.encodePayload(TaskWorktreePayload(
            repositoryPath: repository.path, worktreePath: manual.path, branch: "manual", baseCommit: head
        )).get()
        context.insert(TaskEvent(task: draft, eventType: TaskEventTypes.Task.worktreePrepared, payload: payload))
        try context.save()
        #expect(TaskWorktreeService.activeWorktreeBinding(for: draft) != nil)
        #expect(TaskWorktreeService.discardSnapshots(for: draft, ownership: fixture.ownership).isEmpty)

        let coordinator = TaskLifecycleCoordinator(
            modelContext: context, taskQueue: TaskQueue(poolSize: 0), worktreeCleanupStore: fixture.cleanupStore
        )
        _ = coordinator.deleteTask(draft)
        try await Task.sleep(for: .milliseconds(100))

        #expect(try fixture.cleanupStore.pendingURLs().isEmpty)
        #expect(FileManager.default.fileExists(atPath: manual.path))
        #expect(try !fixture.git(["branch", "--list", "manual"], at: repository).isEmpty)
    }

    @Test("Ownership matches only the exact local creation and is dropped once the worktree is removed")
    func ownershipRecordMatchesExactCreation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let (draft, discard) = try await prepare(repository: repository, context: store.mainContext, fixture: fixture)
        #expect(fixture.ownership.owns(discard))
        #expect(!fixture.ownership.owns(TaskWorktreeDiscard(
            taskID: discard.taskID, repositoryPath: discard.repositoryPath, worktreePath: discard.worktreePath,
            branch: discard.branch, baseCommit: String(repeating: "0", count: 40)
        )))
        #expect(!TaskWorktreeOwnershipStore(directory: fixture.root.appendingPathComponent("Elsewhere")).owns(discard))

        let record = fixture.ownership.recordURL(forWorktree: discard.worktreePath)
        let outside = fixture.root.appendingPathComponent("outside.json")
        try FileManager.default.moveItem(at: record, to: outside)
        try FileManager.default.createSymbolicLink(at: record, withDestinationURL: outside)
        #expect(!fixture.ownership.owns(discard))
        try FileManager.default.removeItem(at: record)
        try FileManager.default.moveItem(at: outside, to: record)
        #expect(fixture.ownership.owns(discard))

        try fixture.cleanupStore.record(discard)
        store.mainContext.delete(draft)
        try store.mainContext.save()
        #expect(await TaskWorktreeCleanupService.resumePending(modelContext: ModelContext(store), resourceQueue: fixture.resourceQueue, store: fixture.cleanupStore) == 1)
        #expect(!FileManager.default.fileExists(atPath: discard.worktreePath))
        #expect(!FileManager.default.fileExists(atPath: record.path))
    }

    @Test("Pending cleanup rechecks local ownership before touching Git", arguments: ["missing", "corrupt", "replaced"])
    func pendingCleanupRechecksOwnership(state: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let context = store.mainContext
        let (draft, discard) = try await prepare(repository: repository, context: context, fixture: fixture)
        try fixture.cleanupStore.record(discard)
        context.delete(draft)
        try context.save()
        let record = fixture.ownership.recordURL(forWorktree: discard.worktreePath)
        switch state {
        case "missing":
            try FileManager.default.removeItem(at: record)
        case "corrupt":
            try Data("{invalid".utf8).write(to: record, options: .atomic)
        default:
            try fixture.ownership.record(.init(
                repositoryPath: discard.repositoryPath, worktreePath: discard.worktreePath,
                branch: "replacement", baseCommit: discard.baseCommit
            ))
        }
        #expect(!fixture.ownership.owns(discard))

        #expect(await TaskWorktreeCleanupService.resumePending(
            modelContext: ModelContext(store), resourceQueue: fixture.resourceQueue, store: fixture.cleanupStore
        ) == 0)

        #expect(FileManager.default.fileExists(atPath: discard.worktreePath))
        #expect(try !fixture.git(["branch", "--list", discard.branch], at: repository).isEmpty)
        #expect(try fixture.cleanupStore.pendingURLs().isEmpty)
        if state != "missing" { #expect(FileManager.default.fileExists(atPath: record.path)) }
    }

    @Test("A workspace configured at, inside, or above the worktree keeps it", arguments: ["at", "inside", "above"])
    func configuredWorkspacePathKeepsCheckout(placement: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let context = store.mainContext
        let (draft, discard) = try await prepare(repository: repository, context: context, fixture: fixture)
        let other = switch placement {
        case "at": Workspace(name: "Other", primaryPath: discard.worktreePath)
        case "inside":
            Workspace(name: "Other", primaryPath: fixture.storage.path, additionalPaths: [discard.worktreePath + "/Sources"])
        default: Workspace(name: "Other", primaryPath: fixture.storage.path, additionalPaths: [fixture.worktrees.path])
        }
        context.insert(other)
        context.delete(draft)
        try context.save()
        #expect(other.activeWorkingPath == nil)

        #expect(await TaskWorktreeService.discardOutcome(discard, modelContext: context, resourceQueue: fixture.resourceQueue) == .kept("referenced"))
        #expect(FileManager.default.fileExists(atPath: discard.worktreePath))
        #expect(try !fixture.git(["branch", "--list", discard.branch], at: repository).isEmpty)

        context.delete(other)
        try context.save()
        #expect(await TaskWorktreeService.discardOutcome(discard, modelContext: context, resourceQueue: fixture.resourceQueue) == .removed)
        #expect(!FileManager.default.fileExists(atPath: discard.worktreePath))
    }

    @Test("A configured folder at or above the worktrees root is not a reference", arguments: ["at", "above"])
    func folderAboveWorktreesRootDoesNotKeepCheckout(placement: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let context = store.mainContext
        let (draft, discard) = try await prepare(repository: repository, context: context, fixture: fixture)
        let root = placement == "at" ? fixture.worktrees.path : fixture.worktrees.deletingLastPathComponent().path
        let other = Workspace(name: "Documents", primaryPath: fixture.storage.path, additionalPaths: [root])
        context.insert(other)
        context.delete(draft)
        try context.save()
        let pins = { (modelContext: ModelContext) in
            try TaskWorktreeService.durableCheckoutPins(modelContext: modelContext, worktreesRoot: fixture.worktrees.path)
        }

        #expect(await TaskWorktreeService.discardOutcome(
            discard, modelContext: context, resourceQueue: fixture.resourceQueue, checkoutPins: pins
        ) == .removed)
        #expect(!FileManager.default.fileExists(atPath: discard.worktreePath))
        #expect(try fixture.git(["branch", "--list", discard.branch], at: repository).isEmpty)
    }

    @Test("A folder below the worktrees root, or a default pointing above it, still keeps the worktree")
    func folderBelowWorktreesRootKeepsCheckout() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let context = store.mainContext
        let (draft, discard) = try await prepare(repository: repository, context: context, fixture: fixture)
        let repositoryFolder = URL(fileURLWithPath: discard.worktreePath).deletingLastPathComponent().path
        let other = Workspace(name: "Checkouts", primaryPath: fixture.storage.path, additionalPaths: [repositoryFolder])
        context.insert(other)
        context.delete(draft)
        try context.save()
        let pins = { (modelContext: ModelContext) in
            try TaskWorktreeService.durableCheckoutPins(modelContext: modelContext, worktreesRoot: fixture.worktrees.path)
        }
        #expect(await TaskWorktreeService.discardOutcome(
            discard, modelContext: context, resourceQueue: fixture.resourceQueue, checkoutPins: pins
        ) == .kept("referenced"))

        other.additionalPaths = []
        other.activeWorkingPath = fixture.worktrees.path
        try context.save()
        #expect(await TaskWorktreeService.discardOutcome(
            discard, modelContext: context, resourceQueue: fixture.resourceQueue, checkoutPins: pins
        ) == .kept("referenced"))
        #expect(FileManager.default.fileExists(atPath: discard.worktreePath))
    }

    @Test("A task pinned above the worktree keeps it, and removal refuses roots above it")
    func ancestorTaskPinKeepsCheckout() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let context = store.mainContext
        let (draft, discard) = try await prepare(repository: repository, context: context, fixture: fixture)
        let workspace = try #require(draft.workspace)
        let above = AgentTask(title: "Above", goal: "Above", workspace: workspace)
        context.insert(above)
        above.executionRootPath = fixture.worktrees.path
        context.delete(draft)
        try context.save()

        #expect(await TaskWorktreeService.discardOutcome(discard, modelContext: context, resourceQueue: fixture.resourceQueue) == .kept("referenced"))
        #expect(FileManager.default.fileExists(atPath: discard.worktreePath))

        above.executionRootPath = nil
        try context.save()
        var ancestorPinned = true
        let outcome = await TaskWorktreeService.discardOutcome(discard, modelContext: context, resourceQueue: fixture.resourceQueue) {
            #expect(TaskWorktreeCheckoutReservation.isReserved(fixture.worktrees.path))
            #expect(TaskWorktreeCheckoutReservation.isReserved("/"))
            #expect(!TaskWorktreeCheckoutReservation.isReserved(fixture.worktrees.path + "-sibling"))
            #expect(!TaskWorktreeCheckoutReservation.isReserved(discard.worktreePath + "-sibling"))
            ancestorPinned = TaskCodeLocationPin.set(fixture.worktrees.path, workspace: workspace, task: above)
        }
        #expect(outcome == .removed)
        #expect(!ancestorPinned)
        #expect(above.executionRootPath == nil)
        #expect(!FileManager.default.fileExists(atPath: discard.worktreePath))
    }

    @Test("Checkout overlap is two-way, component-wise, and never matches an empty path")
    func checkoutOverlapIsTwoWay() {
        #expect(TaskWorktreeCheckoutReservation.overlaps("/a/b", "/a/b"))
        #expect(TaskWorktreeCheckoutReservation.overlaps("/a/b", "/a/b/c"))
        #expect(TaskWorktreeCheckoutReservation.overlaps("/a/b/c", "/a/b"))
        #expect(TaskWorktreeCheckoutReservation.overlaps("/", "/a/b"))
        #expect(TaskWorktreeCheckoutReservation.overlaps("/a/b", "/"))
        #expect(!TaskWorktreeCheckoutReservation.overlaps("/a/b", "/a/bc"))
        #expect(!TaskWorktreeCheckoutReservation.overlaps("/a/bc", "/a/b"))
        #expect(!TaskWorktreeCheckoutReservation.overlaps("", "/a/b"))
        #expect(!TaskWorktreeCheckoutReservation.overlaps("/a/b", ""))
    }

    @Test("Checkout reservations exclude overlapping removals without releasing the first owner")
    func overlappingReservationsKeepOriginalOwner() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let checkout = fixture.worktrees.appendingPathComponent("checkout", isDirectory: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let owner = try #require(TaskWorktreeCheckoutReservation.acquire(checkout.path))
        defer { TaskWorktreeCheckoutReservation.release(owner) }

        for path in [checkout.path, checkout.appendingPathComponent("Sources").path, fixture.worktrees.path] {
            let competing = TaskWorktreeCheckoutReservation.acquire(path)
            #expect(competing == nil)
            if let competing { TaskWorktreeCheckoutReservation.release(competing) }
            #expect(TaskWorktreeCheckoutReservation.isReserved(checkout.path))
        }
        let sibling = TaskWorktreeCheckoutReservation.acquire(checkout.path + "-sibling")
        TaskWorktreeCheckoutReservation.release(try #require(sibling))
        #expect(TaskWorktreeCheckoutReservation.isReserved(checkout.path))
        TaskWorktreeCheckoutReservation.release(owner)
        #expect(!TaskWorktreeCheckoutReservation.isReserved(checkout.path))
    }

    @Test("Reservations cover symlinked paths even after the checkout disappears", arguments: ["real", "parentAlias", "directAlias"])
    func reservationSurvivesAliasedCheckoutRemoval(acquireThrough: String) throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let checkout = fixture.worktrees.appendingPathComponent("checkout", isDirectory: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let alias = fixture.root.appendingPathComponent("Alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.worktrees)
        let aliasedCheckout = alias.appendingPathComponent("checkout", isDirectory: true)
        let directAlias = fixture.root.appendingPathComponent("CheckoutAlias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: directAlias, withDestinationURL: checkout)
        let path = switch acquireThrough {
        case "parentAlias": aliasedCheckout.path
        case "directAlias": directAlias.path
        default: checkout.path
        }
        let reservation = try #require(TaskWorktreeCheckoutReservation.acquire(path))
        defer { TaskWorktreeCheckoutReservation.release(reservation) }

        for path in [checkout.path, aliasedCheckout.path, directAlias.path, alias.path,
                     aliasedCheckout.appendingPathComponent("New/file").path] {
            #expect(TaskWorktreeCheckoutReservation.isReserved(path))
            let competing = TaskWorktreeCheckoutReservation.acquire(path)
            #expect(competing == nil)
            if let competing { TaskWorktreeCheckoutReservation.release(competing) }
        }
        try FileManager.default.removeItem(at: checkout)
        #expect(TaskWorktreeCheckoutReservation.isReserved(checkout.path))
        #expect(TaskWorktreeCheckoutReservation.isReserved(aliasedCheckout.path))
        #expect(TaskWorktreeCheckoutReservation.isReserved(directAlias.path))
        #expect(TaskWorktreeCheckoutReservation.isReserved(directAlias.appendingPathComponent("New/file").path))
        #expect(TaskWorktreeCheckoutReservation.isReserved(aliasedCheckout.appendingPathComponent("New/file").path))
        #expect(!TaskWorktreeCheckoutReservation.isReserved(aliasedCheckout.path + "-sibling"))
    }

    @Test("A competing cleanup retries without removing a reserved checkout")
    func concurrentCleanupKeepsReservation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let context = store.mainContext
        let (draft, discard) = try await prepare(repository: repository, context: context, fixture: fixture)
        let competing = TaskWorktreeDiscard(
            taskID: UUID(), repositoryPath: discard.repositoryPath, worktreePath: discard.worktreePath,
            branch: discard.branch, baseCommit: discard.baseCommit
        )
        context.delete(draft)
        try context.save()

        let outcome = await TaskWorktreeService.discardOutcome(discard, modelContext: context, resourceQueue: fixture.resourceQueue) {
            #expect(await TaskWorktreeService.discardOutcome(competing, modelContext: context, resourceQueue: fixture.resourceQueue) == .retry("cleanup_in_progress"))
            #expect(TaskWorktreeCheckoutReservation.isReserved(discard.worktreePath))
            #expect(FileManager.default.fileExists(atPath: discard.worktreePath))
        }

        #expect(outcome == .removed)
        #expect(!TaskWorktreeCheckoutReservation.isReserved(discard.worktreePath))
        #expect(!FileManager.default.fileExists(atPath: discard.worktreePath))
        #expect(try fixture.git(["branch", "--list", discard.branch], at: repository).isEmpty)
    }

    @Test("New tasks and imports never adopt a checkout cleanup is removing")
    func reservedCheckoutIsNeverAdopted() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let checkout = fixture.storage.appendingPathComponent("Checkout", isDirectory: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let store = try Fixture.container()
        let context = store.mainContext
        let workspace = Workspace(name: "App", primaryPath: fixture.storage.path)
        workspace.activeWorkingPath = checkout.path
        context.insert(workspace)
        let task = AgentTask(title: "Free", goal: "Free", workspace: workspace)
        #expect(task.executionRootPath == checkout.path)
        context.insert(task)
        try context.save()
        let configURL = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: fixture.storage.path))
        try WorkspaceConfigManager.exportToFile(workspace: workspace, modelContext: context, url: configURL)
        let config = try WorkspaceConfigManager.loadConfig(from: configURL)
        let scratchStore = try Fixture.container()
        let coordinator = TaskLifecycleCoordinator(
            modelContext: context, taskQueue: TaskQueue(poolSize: 0), worktreeCleanupStore: fixture.cleanupStore
        )
        func importCopy() -> Workspace? {
            coordinator.importFromConfig(
                at: configURL, existingWorkspaces: [workspace], askDuplicateAction: { _, _ in .duplicate }
            )
        }

        let reservation = try #require(TaskWorktreeCheckoutReservation.acquire(checkout.path))
        let reservedTaskPin = AgentTask(title: "Reserved", goal: "Reserved", workspace: workspace).executionRootPath
        let reservedImport = importCopy()
        let directImport = WorkspaceConfigManager.importWorkspace(from: config, modelContext: scratchStore.mainContext)
        TaskWorktreeCheckoutReservation.release(reservation)
        #expect(reservedTaskPin == nil)
        // The workspace folder contains the checkout, so the import waits for
        // cleanup instead of saving a root that still reaches it.
        #expect(reservedImport == nil)
        // Past that guard, the import still drops the checkout as the active
        // path and as every task's pin.
        #expect(directImport.activeWorkingPath == nil)
        #expect(directImport.tasks.map(\.executionRootPath) == [nil])

        let released = try #require(importCopy())
        #expect(released.activeWorkingPath == checkout.path)
        #expect(released.tasks.map(\.executionRootPath) == [checkout.path])
    }

    @Test("Workspace imports and recovery never add a root inside a checkout cleanup is removing")
    func reservedCheckoutIsNeverImportedAsWorkspaceRoot() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let context = store.mainContext
        let (draft, discard) = try await prepare(repository: repository, context: context, fixture: fixture)
        let app = try #require(draft.workspace)
        let checkout = URL(fileURLWithPath: discard.worktreePath)
        let kept = Workspace(name: "Kept", primaryPath: fixture.storage.path)
        context.insert(kept)
        context.delete(draft)
        try context.save()
        let scratchStore = try Fixture.container()
        let scratch = scratchStore.mainContext
        func writeConfig(root: URL, additionalPaths: [String] = []) throws -> URL {
            let source = Workspace(name: "Source", primaryPath: root.path, additionalPaths: additionalPaths)
            scratch.insert(source)
            let url = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: root.path))
            try WorkspaceConfigManager.exportToFile(workspace: source, modelContext: scratch, url: url)
            return url
        }
        let coordinator = TaskLifecycleCoordinator(
            modelContext: context, taskQueue: TaskQueue(poolSize: 0), worktreeCleanupStore: fixture.cleanupStore
        )
        let nestedConfig = try writeConfig(root: fixture.storage, additionalPaths: [checkout.path + "/Sources"])

        var refused: [Bool] = []
        var recovered = -1
        var directImportRoots = ["unset"]
        var prompted = false
        let outcome = await TaskWorktreeService.discardOutcome(discard, modelContext: context, resourceQueue: fixture.resourceQueue) {
            #expect(TaskWorktreeCheckoutReservation.isReserved(checkout.path + "/Sources"))
            #expect(!TaskWorktreeCheckoutReservation.isReserved(checkout.path + "-sibling"))
            refused.append(coordinator.importFromConfig(at: nestedConfig, existingWorkspaces: [kept]) { _, _ in
                prompted = true
                return .replace
            } == nil)
            refused.append(coordinator.createWorkspaceFromFolder(
                checkout, existingWorkspaces: [kept], askDuplicateAction: { _, _ in .duplicate }
            ) == nil)
            if let config = try? WorkspaceConfigManager.loadConfig(from: nestedConfig) {
                directImportRoots = WorkspaceConfigManager.importWorkspace(from: config, modelContext: scratch).additionalPaths
            }
            // A config inside the checkout must not block its removal afterwards.
            guard let rootConfig = try? writeConfig(root: checkout) else { return }
            defer { try? FileManager.default.removeItem(atPath: WorkspaceFileLayout.supportDirectory(for: checkout.path)) }
            refused.append(coordinator.importFromConfig(
                at: rootConfig, existingWorkspaces: [kept], askDuplicateAction: { _, _ in .duplicate }
            ) == nil)
            recovered = WorkspaceRecoveryService.recoverMissingWorkspaces(
                modelContext: context, extraRoots: [checkout.path], includeDefaultRoots: false
            )
        }

        #expect(outcome == .removed)
        #expect(refused == [true, true, true])
        #expect(!prompted)
        #expect(recovered == 0)
        #expect(directImportRoots.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: checkout.path))
        #expect(Set(try context.fetch(FetchDescriptor<Workspace>()).map(\.id)) == [app.id, kept.id])
        #expect(kept.additionalPaths.isEmpty)

        // Cleanup that starts while the duplicate prompt is open still wins
        // before Replace deletes the existing workspace.
        var lateReservation: TaskWorktreeCheckoutReservation.Token?
        let replaced = coordinator.importFromConfig(at: nestedConfig, existingWorkspaces: [kept]) { _, _ in
            lateReservation = TaskWorktreeCheckoutReservation.acquire(checkout.path)
            return .replace
        }
        try TaskWorktreeCheckoutReservation.release(#require(lateReservation))
        #expect(replaced == nil)
        #expect(Set(try context.fetch(FetchDescriptor<Workspace>()).map(\.id)) == [app.id, kept.id])

        let afterCleanup = coordinator.importFromConfig(
            at: nestedConfig, existingWorkspaces: [kept], askDuplicateAction: { _, _ in .duplicate }
        )
        #expect(try #require(afterCleanup).additionalPaths == [checkout.path + "/Sources"])
    }

    private func waitForOutbox(_ fixture: Fixture) async throws {
        var attempts = 0
        while try !fixture.cleanupStore.pendingURLs().isEmpty, attempts < 100 {
            attempts += 1
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(try fixture.cleanupStore.pendingURLs().isEmpty)
    }

    /// Prepares a draft's worktree, then retargets the draft to the repository
    /// itself, as the Repository panel does.
    private func retargetedDraft(
        repository: URL, context: ModelContext, fixture: Fixture
    ) async throws -> (draft: AgentTask, original: TaskWorktreeDiscard) {
        let (draft, original) = try await prepare(repository: repository, context: context, fixture: fixture)
        let workspace = try #require(draft.workspace)
        #expect(TaskCodeLocationPin.set(repository.path, workspace: workspace, task: draft))
        try context.save()
        guard case .retargeted = TaskWorktreeBinding.state(of: draft) else {
            Issue.record("Expected the draft to be retargeted")
            return (draft, original)
        }
        #expect(TaskWorktreeService.activeWorktreeBinding(for: draft) == nil)
        return (draft, original)
    }

    @Test(
        "A draft retargeted off its worktree still gives back that worktree when discarded",
        arguments: ["startOver", "delete", "modified"]
    )
    func retargetedDraftGivesBackItsWorktree(path: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let context = store.mainContext
        let (draft, original) = try await retargetedDraft(repository: repository, context: context, fixture: fixture)
        #expect(TaskWorktreeService.discardSnapshots(for: draft, ownership: fixture.ownership) == [original])
        if path == "modified" {
            try "work".write(
                to: URL(fileURLWithPath: original.worktreePath).appendingPathComponent("notes.txt"),
                atomically: true, encoding: .utf8
            )
        }

        if path == "delete" {
            let coordinator = TaskLifecycleCoordinator(
                modelContext: context, taskQueue: TaskQueue(poolSize: 0), worktreeCleanupStore: fixture.cleanupStore
            )
            _ = coordinator.deleteTask(draft)
        } else {
            #expect(NewTaskWorktreeComposerFlow.discardDraft(
                draft, modelContext: context, resourceQueue: fixture.resourceQueue, cleanupStore: fixture.cleanupStore, delete: { context.delete($0) }
            ))
        }
        try await waitForOutbox(fixture)

        #expect(try context.fetchCount(FetchDescriptor<AgentTask>()) == 0)
        let kept = path == "modified"
        #expect(FileManager.default.fileExists(atPath: original.worktreePath) == kept)
        #expect(try fixture.git(["branch", "--list", original.branch], at: repository).isEmpty == !kept)
    }

    @Test("A draft that prepared another worktree after retargeting gives back both")
    func retargetedDraftGivesBackEveryWorktree() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let context = store.mainContext
        let (draft, original) = try await retargetedDraft(repository: repository, context: context, fixture: fixture)
        try await TaskWorktreeService.prepare(
            task: draft, request: TaskWorktreeRequest(repositoryPath: repository.path, base: .currentBranch),
            modelContext: context, resourceQueue: fixture.resourceQueue, worktreesRoot: fixture.worktrees.path, ownership: fixture.ownership
        )
        let current = try #require(TaskWorktreeService.activeWorktreeBinding(for: draft))
        #expect(current.worktreePath != original.worktreePath)
        let discards = TaskWorktreeService.discardSnapshots(for: draft, ownership: fixture.ownership)
        #expect(Set(discards.map(\.worktreePath)) == [current.worktreePath, original.worktreePath])

        #expect(NewTaskWorktreeComposerFlow.discardDraft(
            draft, modelContext: context, resourceQueue: fixture.resourceQueue, cleanupStore: fixture.cleanupStore, delete: { context.delete($0) }
        ))
        try await waitForOutbox(fixture)

        for discard in discards {
            #expect(!FileManager.default.fileExists(atPath: discard.worktreePath))
            #expect(try fixture.git(["branch", "--list", discard.branch], at: repository).isEmpty)
        }
        #expect(await GitService.shared.listWorktrees(at: repository.path).count == 1)
    }

    @Test(
        "Promoting a draft keeps the task's checkout and gives back the worktree the draft was retargeted from",
        arguments: [false, true]
    )
    func promotedDraftGivesBackUnusedWorktrees(preparedAgain: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let context = store.mainContext
        let (draft, original) = try await retargetedDraft(repository: repository, context: context, fixture: fixture)
        let workspace = try #require(draft.workspace)
        if preparedAgain {
            try await TaskWorktreeService.prepare(
                task: draft, request: TaskWorktreeRequest(repositoryPath: repository.path, base: .currentBranch),
                modelContext: context, resourceQueue: fixture.resourceQueue, worktreesRoot: fixture.worktrees.path, ownership: fixture.ownership
            )
        }
        let task = AgentTask(title: "Explore", goal: "Explore the implementation", workspace: workspace)
        context.insert(task)
        try await TaskWorktreeService.prepare(
            task: task, request: nil, inheritingFrom: draft, modelContext: context, resourceQueue: fixture.resourceQueue,
            worktreesRoot: fixture.worktrees.path, ownership: fixture.ownership
        )
        let checkout = try #require(task.executionRootPath)
        #expect(checkout == draft.executionRootPath)

        #expect(NewTaskWorktreeComposerFlow.discardPromotedDraft(
            draft, keeping: task, modelContext: context, resourceQueue: fixture.resourceQueue, cleanupStore: fixture.cleanupStore
        ))
        try await waitForOutbox(fixture)

        #expect(!FileManager.default.fileExists(atPath: original.worktreePath))
        #expect(try fixture.git(["branch", "--list", original.branch], at: repository).isEmpty)
        #expect(FileManager.default.fileExists(atPath: checkout))
        #expect(task.executionRootPath == checkout)
        if preparedAgain {
            let binding = try #require(TaskWorktreeService.activeWorktreeBinding(for: task))
            #expect(binding.worktreePath == checkout)
            #expect(try !fixture.git(["branch", "--list", binding.branch], at: repository).isEmpty)
        }
    }

    @Test("Promotion stops, keeping the draft and its worktrees, when the draft's deletion can't be saved")
    func failedPromotionKeepsDraft() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let context = store.mainContext
        let (draft, original) = try await retargetedDraft(repository: repository, context: context, fixture: fixture)
        let task = AgentTask(title: "Explore", goal: "Explore the implementation", workspace: try #require(draft.workspace))
        context.insert(task)
        try await TaskWorktreeService.prepare(
            task: task, request: nil, inheritingFrom: draft, modelContext: context, resourceQueue: fixture.resourceQueue,
            worktreesRoot: fixture.worktrees.path, ownership: fixture.ownership
        )
        try context.save()
        let blocker = fixture.root.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blocker)
        let unavailable = TaskWorktreeCleanupStore(
            directory: blocker.appendingPathComponent("Cleanup"), ownership: fixture.ownership
        )

        #expect(throws: NewTaskDraftPromotionError.draftNotRemoved) {
            try NewTaskWorktreeComposerFlow.promote(draft, to: task, modelContext: context, resourceQueue: fixture.resourceQueue, cleanupStore: unavailable)
        }

        #expect(!draft.isDeleted)
        #expect(try ModelContext(store).fetchCount(FetchDescriptor<AgentTask>()) == 2)
        #expect(FileManager.default.fileExists(atPath: original.worktreePath))
        try NewTaskWorktreeComposerFlow.promote(nil, to: task, modelContext: context, resourceQueue: fixture.resourceQueue, cleanupStore: unavailable)
        try NewTaskWorktreeComposerFlow.promote(draft, to: draft, modelContext: context, resourceQueue: fixture.resourceQueue, cleanupStore: unavailable)
        #expect(try ModelContext(store).fetchCount(FetchDescriptor<AgentTask>()) == 2)
    }

    @Test("Deleting a task reports whether the deletion was saved and lets go of it only then")
    func coordinatorReportsUnsavedDeletion() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let context = store.mainContext
        let (draft, discard) = try await prepare(repository: repository, context: context, fixture: fixture)
        try context.save()
        let blocker = fixture.root.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blocker)
        let unavailable = TaskWorktreeCleanupStore(
            directory: blocker.appendingPathComponent("Cleanup"), ownership: fixture.ownership
        )
        func coordinator(_ cleanupStore: TaskWorktreeCleanupStore) -> TaskLifecycleCoordinator {
            TaskLifecycleCoordinator(modelContext: context, taskQueue: TaskQueue(poolSize: 0), worktreeCleanupStore: cleanupStore)
        }

        var releasedEarly = false
        #expect(!coordinator(unavailable).deleteTask(draft) { releasedEarly = true })
        #expect(!releasedEarly)
        #expect(!draft.isDeleted)
        #expect(try ModelContext(store).fetchCount(FetchDescriptor<AgentTask>()) == 1)
        #expect(FileManager.default.fileExists(atPath: discard.worktreePath))

        var releasedBeforeDeletion = false
        #expect(coordinator(fixture.cleanupStore).deleteTask(draft) { releasedBeforeDeletion = !draft.isDeleted })
        #expect(releasedBeforeDeletion)
        #expect(try ModelContext(store).fetchCount(FetchDescriptor<AgentTask>()) == 0)
        try await waitForOutbox(fixture)
        #expect(!FileManager.default.fileExists(atPath: discard.worktreePath))
    }

    @Test("The task list clears selection and sessions only for a saved deletion")
    func contentViewHonorsDeletionOutcome() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Astra/Views/ContentView.swift"), encoding: .utf8)
        let start = try #require(source.range(of: "private func deleteTask(_ task: AgentTask) {"))
        let end = try #require(source.range(of: "private func requestDeleteTask(", range: start.upperBound..<source.endIndex))
        let body = String(source[start.upperBound..<end.lowerBound])
        let delete = try #require(body.range(of: "coordinator.deleteTask(task) { if wasSelected { setSelectedTask(nil) } }"))
        let failed = try #require(body.range(of: "guard deleted else {"))
        let release = try #require(body.range(of: "browserSessionStore.releaseSession(for: deletedTaskID)"))
        #expect(body.components(separatedBy: "setSelectedTask(nil)").count == 2)
        #expect(delete.upperBound <= failed.lowerBound)
        #expect(failed.upperBound <= release.lowerBound)
        #expect(body.contains("taskDeletionFailure = "))
        #expect(source.contains(".taskDeletionFailureAlert($taskDeletionFailure)"))
    }

    @Test("The composer hands a new task off only after its draft's deletion is saved")
    func composerPromotesDraftBeforeHandoff() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Astra/Views/ChatPanelView.swift"), encoding: .utf8)
        for (function, handoff) in [
            ("private func quickRun()", "onQuickRun?(task)"),
            ("private func createTaskFromSpec()", "onTaskCreated?(task)")
        ] {
            let start = try #require(source.range(of: function))
            let promote = try #require(source.range(of: "try promoteDraft(to: task)", range: start.upperBound..<source.endIndex))
            let reset = try #require(source.range(of: "messageText = \"\"", range: start.upperBound..<source.endIndex))
            let handedOff = try #require(source.range(of: handoff, range: start.upperBound..<source.endIndex))
            #expect(promote.lowerBound < reset.lowerBound, "\(function) clears the composer before promotion")
            #expect(reset.lowerBound < handedOff.lowerBound, "\(function) hands off before clearing the composer")
        }
    }

    @Test("Workspace folder edits refuse a checkout cleanup is removing")
    func configuredRootsRefuseReservedCheckout() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let checkout = fixture.worktrees.appendingPathComponent("App/astra-explore", isDirectory: true).path
        let other = fixture.root.appendingPathComponent("Notes", isDirectory: true).path
        let store = try Fixture.container()
        let workspace = Workspace(name: "App", primaryPath: fixture.storage.path)
        store.mainContext.insert(workspace)

        let reservation = try #require(TaskWorktreeCheckoutReservation.acquire(checkout))
        let primary = WorkspaceConfiguredRoots.setPrimaryPath(checkout + "/Sources", on: workspace)
        let ancestorPrimary = WorkspaceConfiguredRoots.setPrimaryPath(fixture.worktrees.path, on: workspace)
        let additional = WorkspaceConfiguredRoots.addAdditionalPaths([other, checkout], to: workspace)
        let ancestorAdditional = WorkspaceConfiguredRoots.addAdditionalPaths([other, fixture.root.path], to: workspace)
        TaskWorktreeCheckoutReservation.release(reservation)

        #expect(primary == .refused(path: checkout + "/Sources"))
        #expect(ancestorPrimary == .refused(path: fixture.worktrees.path))
        #expect(additional == .refused(path: checkout))
        #expect(ancestorAdditional == .refused(path: fixture.root.path))
        #expect(additional.refusalMessage == WorkspaceConfiguredRoots.reservedRootMessage)
        #expect(workspace.primaryPath == fixture.storage.path)
        #expect(workspace.additionalPaths.isEmpty)

        #expect(WorkspaceConfiguredRoots.setPrimaryPath(checkout, on: workspace) == .updated)
        #expect(WorkspaceConfiguredRoots.setPrimaryPath(checkout, on: workspace) == .unchanged)
        #expect(WorkspaceConfiguredRoots.addAdditionalPaths([other, other], to: workspace) == .updated)
        #expect(WorkspaceConfiguredRoots.addAdditionalPaths([other], to: workspace) == .unchanged)
        #expect(WorkspaceConfiguredRoots.Outcome.updated.refusalMessage == nil)
        #expect(workspace.primaryPath == checkout)
        #expect(workspace.additionalPaths == [other])
    }

    @Test("Every workspace folder writer is reviewed against the cleanup reservation")
    func workspaceRootWritersAreReviewed() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        // The interactive writer, initializers, config values whose imports
        // check the reservation, and removals of folders a workspace lists.
        let reviewed: Set<String> = [
            "Astra/AppIntents/AstraAppEntities.swift",
            "Astra/Models/Workspace.swift",
            "Astra/Services/Persistence/WorkspaceConfigManager.swift",
            "Astra/Services/Persistence/WorkspaceRecoveryService.swift",
            "Astra/Services/Tasks/TaskLifecycleCoordinator.swift",
            "Astra/Services/Tasks/WorkspaceConfiguredRoots.swift",
            "Astra/Views/WorkspaceHomeView.swift",
            "Astra/Views/WorkspaceRightRailView.swift"
        ]
        let writer = try NSRegularExpression(pattern: #"""
        \.(primaryPath|additionalPaths)(\[[^\]]*\])?\s*(\+=|=(?!=))|\.additionalPaths\.(append|insert)\b|\$[A-Za-z_][\w.]*\.(primaryPath|additionalPaths)\b
        """#)
        var writers = Set<String>()
        let enumerator = FileManager.default.enumerator(
            at: root.appendingPathComponent("Astra"), includingPropertiesForKeys: nil
        )
        for case let url as URL in enumerator ?? FileManager.DirectoryEnumerator() where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard writer.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else { continue }
            writers.insert(String(url.path.dropFirst(root.path.count + 1)))
        }
        #expect(writers == reviewed)
    }

    @Test("Every persistent checkout pin writer is reviewed against the cleanup reservation")
    func checkoutPinWritersAreReviewed() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        // Reservation-aware writers, clears, detached launch copies, value
        // snapshots, and the Git panel's own mirror property.
        let reviewed: Set<String> = [
            "Astra/Models/AgentTask.swift",
            "Astra/Models/AgentTaskForkService.swift",
            "Astra/Models/TaskWorktreePayload.swift",
            "Astra/Models/Workspace.swift",
            "Astra/Services/Persistence/WorkspaceConfigManager.swift",
            "Astra/Services/Runtime/AgentRuntimeExecutionContext.swift",
            "Astra/Services/Runtime/AgentTaskLaunchSnapshot.swift",
            "Astra/Services/Tasks/TaskCodeLocationPin.swift",
            "Astra/Services/Tasks/TaskExecutionLaunchSnapshotApplicator.swift",
            "Astra/Views/WorkspaceGitViewModel.swift"
        ]
        let writer = try NSRegularExpression(pattern: #"\.(executionRootPath|activeWorkingPath)\s*=(?!=)"#)
        var writers = Set<String>()
        let enumerator = FileManager.default.enumerator(
            at: root.appendingPathComponent("Astra"), includingPropertiesForKeys: nil
        )
        for case let url as URL in enumerator ?? FileManager.DirectoryEnumerator() where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard writer.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else { continue }
            writers.insert(String(url.path.dropFirst(root.path.count + 1)))
        }
        #expect(writers == reviewed)
    }

    @Test("Startup awaits pending cleanup before replaying recovered runtime work")
    func startupWiresCleanupRecovery() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Astra/ASTRAApp.swift"), encoding: .utf8)
        let start = try #require(source.range(of: "static func recoverInterruptedWork("))
        let cleanup = try #require(source.range(
            of: "await recoverPendingWorktreeCleanup(modelContext: modelContext, taskQueue: taskQueue)", range: start.upperBound..<source.endIndex
        ))
        let runtime = try #require(source.range(
            of: "await recoverRuntimeSettlements(", range: start.upperBound..<source.endIndex
        ))
        #expect(cleanup.lowerBound < runtime.lowerBound)
        let creations = try #require(source.range(
            of: "TaskWorktreeCleanupService.resumeInterruptedCreations(modelContext: modelContext, resourceQueue: taskQueue)"
        ))
        let pending = try #require(source.range(
            of: "TaskWorktreeCleanupService.resumePending(modelContext: modelContext, resourceQueue: taskQueue)"
        ))
        #expect(creations.lowerBound < pending.lowerBound)
    }
}

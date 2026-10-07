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
            modelContext: context, worktreesRoot: fixture.worktrees.path, ownership: fixture.ownership
        )
        return (draft, try #require(TaskWorktreeService.discardSnapshot(for: draft, ownership: fixture.ownership)))
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
        #expect(try fixture.cleanupStore.read(fixture.cleanupStore.recordURL(for: discard.taskID)) == discard)

        let reopened = try persistentContainer(at: storeURL)
        #expect(try reopened.mainContext.fetchCount(FetchDescriptor<AgentTask>()) == 0)
        #expect(await TaskWorktreeCleanupService.resumePending(modelContext: reopened.mainContext, store: fixture.cleanupStore) == 1)
        #expect(!FileManager.default.fileExists(atPath: discard.worktreePath))
        #expect(try fixture.git(["branch", "--list", discard.branch], at: repository).isEmpty)
        #expect(try fixture.cleanupStore.pendingURLs().isEmpty)
        #expect(await TaskWorktreeCleanupService.resumePending(modelContext: reopened.mainContext, store: fixture.cleanupStore) == 0)
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
        let discard = try #require(TaskWorktreeService.discardSnapshot(for: duplicate, ownership: fixture.ownership))
        if resumeAfterRestart { try fixture.cleanupStore.record(discard) }
        context.delete(duplicate)
        try context.save()

        let reopened = try persistentContainer(at: storeURL)
        let cleanupContext = resumeAfterRestart ? reopened.mainContext : context
        if resumeAfterRestart {
            #expect(await TaskWorktreeCleanupService.resumePending(
                modelContext: cleanupContext, store: fixture.cleanupStore
            ) == 0)
            #expect(try fixture.cleanupStore.pendingURLs().isEmpty)
        } else {
            #expect(await TaskWorktreeService.discardOutcome(discard, modelContext: cleanupContext) == .kept("referenced"))
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
        #expect(await TaskWorktreeService.discardUnusedWorktree(discard, modelContext: cleanupContext))
        #expect(!FileManager.default.fileExists(atPath: discard.worktreePath))
        #expect(try fixture.git(["branch", "--list", discard.branch], at: repository).isEmpty)
    }

    @Test("Reference checks keep a checkout while its owning draft still exists")
    func liveTaskPinPreventsPrematureCleanup() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let (draft, discard) = try await prepare(repository: repository, context: store.mainContext, fixture: fixture)

        #expect(await TaskWorktreeService.discardOutcome(discard, modelContext: store.mainContext) == .kept("referenced"))
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
            discard, workspace: draft.workspace, modelContext: context, cleanupStore: fixture.cleanupStore,
            delete: {
                #expect(FileManager.default.fileExists(atPath: fixture.cleanupStore.recordURL(for: discard.taskID).path))
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
            discard, workspace: draft.workspace, modelContext: context, cleanupStore: unavailable,
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
            discard, workspace: draft.workspace, modelContext: context, cleanupStore: fixture.cleanupStore,
            delete: { context.delete(draft) }, persist: { _, _ in false }
        )
        #expect(failed.cleanup == nil)
        #expect(!failed.persisted)
        #expect(!draft.isDeleted)
        #expect(try fixture.cleanupStore.pendingURLs().count == 1)

        let durable = ModelContext(store)
        #expect(try durable.fetchCount(FetchDescriptor<AgentTask>()) == 1)
        #expect(await TaskWorktreeCleanupService.resumePending(modelContext: durable, store: fixture.cleanupStore) == 0)
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

        #expect(await TaskWorktreeCleanupService.resumePending(modelContext: ModelContext(store), store: fixture.cleanupStore) == 1)
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

        #expect(await TaskWorktreeCleanupService.resumePending(modelContext: ModelContext(store), store: fixture.cleanupStore) == 0)
        #expect(try fixture.cleanupStore.pendingURLs().count == 1)
        #expect(FileManager.default.fileExists(atPath: discard.worktreePath))

        try FileManager.default.moveItem(at: hidden, to: repository)
        #expect(await TaskWorktreeCleanupService.resumePending(modelContext: ModelContext(store), store: fixture.cleanupStore) == 1)
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

        #expect(await TaskWorktreeCleanupService.resumePending(modelContext: ModelContext(store), store: fixture.cleanupStore) == 0)
        #expect(FileManager.default.fileExists(atPath: discard.worktreePath))
        if !detached { #expect(FileManager.default.fileExists(atPath: file.path)) }
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

        #expect(await TaskWorktreeCleanupService.resumePending(modelContext: context, store: fixture.cleanupStore) == 0)
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
        try Data("{invalid".utf8).write(to: fixture.cleanupStore.recordURL(for: discard.taskID), options: .atomic)

        #expect(await TaskWorktreeCleanupService.resumePending(modelContext: ModelContext(store), store: fixture.cleanupStore) == 0)
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
            modelContext: context,
            worktreesRoot: fixture.worktrees.path, ownership: fixture.ownership
        )
        let discard = try #require(TaskWorktreeService.discardSnapshot(for: draft, ownership: fixture.ownership))
        context.delete(draft)
        try context.save()

        #expect(await TaskWorktreeService.discardOutcome(discard, modelContext: context) == .removed)
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
        let outcome = await TaskWorktreeService.discardOutcome(discard, modelContext: context) {
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
        #expect(TaskWorktreeService.discardSnapshot(for: draft, ownership: fixture.ownership) == nil)

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
        #expect(await TaskWorktreeCleanupService.resumePending(modelContext: ModelContext(store), store: fixture.cleanupStore) == 1)
        #expect(!FileManager.default.fileExists(atPath: discard.worktreePath))
        #expect(!FileManager.default.fileExists(atPath: record.path))
    }

    @Test("A workspace configured at or inside the worktree keeps it", arguments: [false, true])
    func configuredWorkspacePathKeepsCheckout(additional: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let context = store.mainContext
        let (draft, discard) = try await prepare(repository: repository, context: context, fixture: fixture)
        let other = additional
            ? Workspace(name: "Other", primaryPath: fixture.storage.path, additionalPaths: [discard.worktreePath + "/Sources"])
            : Workspace(name: "Other", primaryPath: discard.worktreePath)
        context.insert(other)
        context.delete(draft)
        try context.save()
        #expect(other.activeWorkingPath == nil)

        #expect(await TaskWorktreeService.discardOutcome(discard, modelContext: context) == .kept("referenced"))
        #expect(FileManager.default.fileExists(atPath: discard.worktreePath))
        #expect(try !fixture.git(["branch", "--list", discard.branch], at: repository).isEmpty)

        context.delete(other)
        try context.save()
        #expect(await TaskWorktreeService.discardOutcome(discard, modelContext: context) == .removed)
        #expect(!FileManager.default.fileExists(atPath: discard.worktreePath))
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
        let coordinator = TaskLifecycleCoordinator(
            modelContext: context, taskQueue: TaskQueue(poolSize: 0), worktreeCleanupStore: fixture.cleanupStore
        )
        func importCopy() -> Workspace? {
            coordinator.importFromConfig(
                at: configURL, existingWorkspaces: [workspace], askDuplicateAction: { _, _ in .duplicate }
            )
        }

        let reservation = TaskWorktreeCheckoutReservation.acquire(checkout.path)
        let reservedTaskPin = AgentTask(title: "Reserved", goal: "Reserved", workspace: workspace).executionRootPath
        let reservedImport = importCopy()
        TaskWorktreeCheckoutReservation.release(reservation)
        #expect(reservedTaskPin == nil)
        let reserved = try #require(reservedImport)
        #expect(reserved.activeWorkingPath == nil)
        #expect(reserved.tasks.map(\.executionRootPath) == [nil])

        let released = try #require(importCopy())
        #expect(released.activeWorkingPath == checkout.path)
        #expect(released.tasks.map(\.executionRootPath) == [checkout.path])
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
            of: "await recoverPendingWorktreeCleanup(modelContext: modelContext)", range: start.upperBound..<source.endIndex
        ))
        let runtime = try #require(source.range(
            of: "await recoverRuntimeSettlements(", range: start.upperBound..<source.endIndex
        ))
        #expect(cleanup.lowerBound < runtime.lowerBound)
        #expect(source.contains("TaskWorktreeCleanupService.resumePending(modelContext: modelContext)"))
    }
}

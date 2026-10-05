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
            modelContext: context, worktreesRoot: fixture.worktrees.path
        )
        return (draft, try #require(TaskWorktreeService.discardSnapshot(for: draft)))
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

    @Test("The intent is saved before deletion and cleared only after cleanup finishes")
    func cleanupIntentPrecedesDeletion() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let context = store.mainContext
        let (draft, discard) = try await prepare(repository: repository, context: context, fixture: fixture)
        let cleanup = try #require(TaskWorktreeService.saveDeletionThenDiscard(
            discard, workspace: draft.workspace, modelContext: context, cleanupStore: fixture.cleanupStore,
            delete: {
                #expect(FileManager.default.fileExists(atPath: fixture.cleanupStore.recordURL(for: discard.taskID).path))
                context.delete(draft)
            },
            persist: { _, context in
                #expect(FileManager.default.fileExists(atPath: discard.worktreePath))
                do { try context.save(); return true } catch { Issue.record(error); return false }
            }
        ))
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

        let cleanup = TaskWorktreeService.saveDeletionThenDiscard(
            discard, workspace: draft.workspace, modelContext: context, cleanupStore: unavailable,
            delete: { deletionRan = true; context.delete(draft) },
            persist: { _, _ in persistenceRan = true; return true }
        )
        #expect(cleanup == nil)
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
        let cleanup = TaskWorktreeService.saveDeletionThenDiscard(
            discard, workspace: draft.workspace, modelContext: context, cleanupStore: fixture.cleanupStore,
            delete: { context.delete(draft) }, persist: { _, _ in false }
        )
        #expect(cleanup == nil)
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

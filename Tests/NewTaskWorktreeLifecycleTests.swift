import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Worktree lifecycle admission and workspace deletion", .serialized)
struct NewTaskWorktreeLifecycleTests {
    private typealias Fixture = NewTaskWorktreeFixture

    private func prepare(_ task: AgentTask, repository: URL, context: ModelContext, fixture: Fixture) async throws {
        try await TaskWorktreeService.prepare(
            task: task, request: TaskWorktreeRequest(repositoryPath: repository.path, base: .currentBranch),
            modelContext: context, resourceQueue: fixture.resourceQueue,
            worktreesRoot: fixture.worktrees.path, ownership: fixture.ownership
        )
    }

    private func draft(repository: URL, context: ModelContext, fixture: Fixture) async throws -> AgentTask {
        let workspace = Workspace(name: "Workspace", primaryPath: fixture.storage.path, additionalPaths: [repository.path])
        context.insert(workspace)
        let draft = AgentTask(title: "Explore", goal: "Explore the implementation", workspace: workspace)
        try await prepare(draft, repository: repository, context: context, fixture: fixture)
        return draft
    }

    private func claims(kind: TaskExecutionResourceKind, path: String, taskID: UUID = UUID()) -> [TaskResourceLockClaim] {
        TaskExecutionResourceBroker.lockClaims(
            for: [TaskExecutionResourceClaim(kind: kind, key: path, access: .exclusive)],
            taskID: taskID, requestID: UUID(), runMode: "test"
        )
    }

    private func waitForCleanup(_ fixture: Fixture) async throws {
        for _ in 0..<250 {
            if try fixture.cleanupStore.pendingURLs().isEmpty, fixture.resourceQueue.activeResourceLocks.isEmpty { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try fixture.cleanupStore.pendingURLs().isEmpty)
        #expect(fixture.resourceQueue.activeResourceLocks.isEmpty)
    }

    @Test("Runtime metadata and enclosing-workspace leases block worktree creation before mutation",
          arguments: [TaskExecutionResourceKind.gitCommonDirectory, .workspace])
    func runningTaskBlocksCreation(kind: TaskExecutionResourceKind) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let otherRepository = try fixture.repository("Other")
        let container = try Fixture.container()
        let context = container.mainContext
        let workspace = Workspace(
            name: "Workspace", primaryPath: fixture.storage.path, additionalPaths: [repository.path, otherRepository.path]
        )
        context.insert(workspace)
        let task = AgentTask(title: "Explore", goal: "Explore", workspace: workspace)
        let resource = kind == .workspace ? repository.path : try #require(GitCheckoutLayout.commonDirectory(for: repository.path))
        let held = try #require(fixture.resourceQueue.acquireResourceLocksIfAvailable(
            claims(kind: kind, path: resource), task: nil
        ))
        defer { fixture.resourceQueue.releaseResourceLocks(held, task: nil) }

        await #expect(throws: TaskWorktreeCreationError.self) {
            try await prepare(task, repository: repository, context: context, fixture: fixture)
        }
        #expect(await GitService.shared.listWorktrees(at: repository.path).count == 1)
        #expect(try fixture.ownership.creationJournal.pendingURLs().isEmpty)
        #expect(task.executionRootPath == nil)

        let other = AgentTask(title: "Independent", goal: "Explore", workspace: workspace)
        try await prepare(other, repository: otherRepository, context: context, fixture: fixture)
        #expect(other.executionRootPath != nil)
        #expect(fixture.resourceQueue.activeResourceLocks == held)
        fixture.resourceQueue.releaseResourceLocks(held, task: nil)
        try await prepare(task, repository: repository, context: context, fixture: fixture)
        #expect(task.executionRootPath != nil)
        #expect(fixture.resourceQueue.activeResourceLocks.isEmpty)
    }

    @Test("Creation holds runtime admission and other composers through submodule setup",
          arguments: [false, true])
    func creationLeaseSpansSubmodules(failSetup: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        try fixture.commit(".gitmodules", contents: "", message: "Add empty submodule configuration", at: repository)
        let container = try Fixture.container()
        let context = container.mainContext
        let workspace = Workspace(name: "Workspace", primaryPath: repository.path)
        context.insert(workspace)
        let task = AgentTask(title: "Explore", goal: "Explore", workspace: workspace)
        let competing = AgentTask(title: "Another", goal: "Explore", workspace: workspace)
        let runtimeClaims = claims(
            kind: .gitCommonDirectory, path: try #require(GitCheckoutLayout.commonDirectory(for: repository.path))
        )
        var enteredSetup = false
        do {
            try await TaskWorktreeService.prepare(
                task: task, request: TaskWorktreeRequest(repositoryPath: repository.path, base: .currentBranch),
                modelContext: context, resourceQueue: fixture.resourceQueue,
                worktreesRoot: fixture.worktrees.path, ownership: fixture.ownership,
                setUpSubmodules: { _, _ in
                    enteredSetup = true
                    #expect(!fixture.resourceQueue.canAcquireResourceLocks(runtimeClaims))
                    #expect(!fixture.resourceQueue.canAcquireResourceLocks(claims(kind: .workspace, path: repository.path)))
                    await #expect(throws: TaskWorktreeCreationError.self) {
                        try await prepare(competing, repository: repository, context: context, fixture: fixture)
                    }
                    if failSetup { throw CancellationError() }
                }
            )
            #expect(!failSetup)
        } catch TaskWorktreeCreationError.submodulesUnavailable {
            #expect(failSetup)
        }
        #expect(enteredSetup)
        #expect(fixture.resourceQueue.activeResourceLocks.isEmpty)
        #expect(fixture.resourceQueue.canAcquireResourceLocks(runtimeClaims))
        #expect(try fixture.ownership.creationJournal.pendingURLs().isEmpty)
        #expect(await GitService.shared.listWorktrees(at: repository.path).count == (failSetup ? 1 : 2))
    }

    @Test("Cleanup retains its intent while runtime resources are held, then releases its own claims")
    func cleanupUsesRuntimeAdmission() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let container = try Fixture.container()
        let context = container.mainContext
        let task = try await draft(repository: repository, context: context, fixture: fixture)
        let discard = try #require(TaskWorktreeService.discardSnapshots(for: task, ownership: fixture.ownership).first)
        try fixture.cleanupStore.record(discard)
        context.delete(task)
        try context.save()
        let runtimeClaims = claims(
            kind: .gitCommonDirectory, path: try #require(GitCheckoutLayout.commonDirectory(for: repository.path))
        )
        let held = try #require(fixture.resourceQueue.acquireResourceLocksIfAvailable(runtimeClaims, task: nil))
        #expect(await TaskWorktreeCleanupService.process(
            discard, store: fixture.cleanupStore, modelContext: context, resourceQueue: fixture.resourceQueue
        ) == false)
        #expect(try !fixture.cleanupStore.pendingURLs().isEmpty)
        #expect(FileManager.default.fileExists(atPath: discard.worktreePath))
        #expect(!TaskWorktreeCheckoutReservation.isReserved(discard.worktreePath))
        fixture.resourceQueue.releaseResourceLocks(held, task: nil)

        let outcome = await TaskWorktreeService.discardOutcome(
            discard, modelContext: context, resourceQueue: fixture.resourceQueue,
            duringReservation: {
                #expect(!fixture.resourceQueue.canAcquireResourceLocks(runtimeClaims))
                #expect(!fixture.resourceQueue.canAcquireResourceLocks(claims(kind: .workspace, path: discard.worktreePath)))
                await fixture.resourceQueue.cancelAllAndWait()
                #expect(!fixture.resourceQueue.canAcquireResourceLocks(runtimeClaims))
            }
        )
        #expect(outcome == .removed)
        #expect(!FileManager.default.fileExists(atPath: discard.worktreePath))
        #expect(fixture.resourceQueue.activeResourceLocks.isEmpty)
        #expect(!TaskWorktreeCheckoutReservation.isReserved(discard.worktreePath))
        #expect(await TaskWorktreeCleanupService.resumePending(
            modelContext: context, resourceQueue: fixture.resourceQueue, store: fixture.cleanupStore
        ) == 1)
        #expect(try fixture.cleanupStore.pendingURLs().isEmpty)
    }

    @Test("Workspace cascade deletion cleans only unexecuted, untouched draft worktrees",
          arguments: ["unused", "dirty", "committed", "executed"])
    func workspaceDeletionCleansDrafts(state: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let container = try Fixture.container()
        let context = container.mainContext
        let task = try await draft(repository: repository, context: context, fixture: fixture)
        let workspace = try #require(task.workspace)
        let discard = try #require(TaskWorktreeService.discardSnapshots(for: task, ownership: fixture.ownership).first)
        let checkout = URL(fileURLWithPath: discard.worktreePath)
        switch state {
        case "dirty":
            try "unsaved work".write(to: checkout.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        case "committed":
            try fixture.commit("new.txt", contents: "saved work", message: "Task work", at: checkout)
        case "executed":
            let run = TaskRun(task: task)
            run.status = .completed
            context.insert(run)
        default: break
        }
        try context.save()
        let coordinator = TaskLifecycleCoordinator(
            modelContext: context, taskQueue: fixture.resourceQueue, worktreeCleanupStore: fixture.cleanupStore
        )
        let result = coordinator.deleteWorkspace(workspace, existingWorkspaces: [workspace])
        #expect(result.persisted)
        _ = await result.cleanup?.value
        #expect(try context.fetchCount(FetchDescriptor<Workspace>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<AgentTask>()) == 0)
        #expect(FileManager.default.fileExists(atPath: discard.worktreePath) == (state != "unused"))
        #expect(try fixture.git(["branch", "--list", discard.branch], at: repository).isEmpty == (state == "unused"))
        #expect(try fixture.cleanupStore.pendingURLs().isEmpty)
    }

    @Test("Config and folder replacement save imported bindings before cleaning omitted drafts",
          arguments: ["config_keep", "config_omit", "folder"])
    func workspaceReplacementHonorsImportedPins(mode: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let container = try Fixture.container()
        let context = container.mainContext
        let task = try await draft(repository: repository, context: context, fixture: fixture)
        let workspace = try #require(task.workspace)
        let taskID = task.id
        let discard = try #require(TaskWorktreeService.discardSnapshots(for: task, ownership: fixture.ownership).first)
        let other = AgentTask(title: "Keep this draft", goal: "Do not prepare it", workspace: workspace)
        context.insert(other)
        try context.save()
        var config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: context))
        if mode == "config_omit" { config.tasks?.removeAll { $0.id == taskID.uuidString } }
        let url = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: fixture.storage.path))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(config).write(to: url, options: .atomic)
        let coordinator = TaskLifecycleCoordinator(
            modelContext: context, taskQueue: fixture.resourceQueue, worktreeCleanupStore: fixture.cleanupStore
        )
        let imported = mode == "folder"
            ? coordinator.createWorkspaceFromFolder(fixture.storage, existingWorkspaces: [workspace]) { _, _ in .replace }
            : coordinator.importFromConfig(at: url, existingWorkspaces: [workspace]) { _, _ in .replace }
        let replacement = try #require(imported)
        #expect(replacement.tasks.contains { $0.id == taskID } == (mode != "config_omit"))
        try await waitForCleanup(fixture)
        #expect(FileManager.default.fileExists(atPath: discard.worktreePath) == (mode != "config_omit"))
        let fresh = ModelContext(container)
        let saved = try #require(fresh.fetch(FetchDescriptor<Workspace>()).first)
        #expect(saved.tasks.contains { $0.id == taskID } == (mode != "config_omit"))
    }

    @Test("Workspace deletion and replacement preserve drafts when intent or model persistence fails",
          arguments: ["delete_intent", "replace_intent", "delete_save", "replace_save"])
    func workspaceMutationFailureKeepsDraft(mode: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let container = try Fixture.container()
        let context = container.mainContext
        let task = try await draft(repository: repository, context: context, fixture: fixture)
        let workspace = try #require(task.workspace)
        let taskID = task.id
        let checkout = try #require(task.executionRootPath)
        let configURL = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: fixture.storage.path))
        let originalConfig = try Data(contentsOf: configURL)
        let blocker = fixture.root.appendingPathComponent("blocked-outbox")
        try Data().write(to: blocker)
        let outbox = mode.hasSuffix("intent")
            ? TaskWorktreeCleanupStore(directory: blocker, ownership: fixture.ownership)
            : fixture.cleanupStore
        var attemptedSave = false
        let coordinator = TaskLifecycleCoordinator(
            modelContext: context, taskQueue: fixture.resourceQueue, worktreeCleanupStore: outbox,
            persistWorkspaceChange: { _, _ in attemptedSave = true; return false }
        )
        if mode.hasPrefix("delete") {
            let result = coordinator.deleteWorkspace(workspace, existingWorkspaces: [workspace])
            #expect(!result.persisted)
            #expect(result.cleanup == nil)
        } else {
            #expect(coordinator.createWorkspaceFromFolder(
                fixture.storage, existingWorkspaces: [workspace], askDuplicateAction: { _, _ in .replace }
            ) == nil)
        }
        #expect(attemptedSave == mode.hasSuffix("save"))
        #expect(FileManager.default.fileExists(atPath: checkout))
        #expect(try Data(contentsOf: configURL) == originalConfig)
        let surviving = try #require(context.fetch(FetchDescriptor<AgentTask>()).first)
        #expect(surviving.id == taskID)
        #expect(surviving.executionRootPath == checkout)
        #expect(await TaskWorktreeCleanupService.resumePending(
            modelContext: context, resourceQueue: fixture.resourceQueue, store: fixture.cleanupStore
        ) == 0)
        #expect(FileManager.default.fileExists(atPath: checkout))
        #expect(try fixture.cleanupStore.pendingURLs().isEmpty)
    }
}

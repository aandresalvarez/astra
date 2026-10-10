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

    @Test("A running sibling worktree task shares the Git directory with creation and cleanup")
    func siblingWorktreeTaskDoesNotBlockLifecycle() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let container = try Fixture.container()
        let context = container.mainContext
        let running = try await draft(repository: repository, context: context, fixture: fixture)
        let metadata = try #require(GitCheckoutLayout.commonDirectory(for: repository.path))
        // What an admitted writer in `running`'s worktree holds.
        let siblingClaims = TaskExecutionResourceAdmissionPolicy.lockClaims(for: nil, task: running, runMode: "test")
        #expect(siblingClaims.contains {
            $0.resourceKind == .gitCommonDirectory && $0.resourceKey == metadata && $0.accessMode == .readOnly
        })
        let held = try #require(fixture.resourceQueue.acquireResourceLocksIfAvailable(siblingClaims, task: nil))
        defer { fixture.resourceQueue.releaseResourceLocks(held, task: nil) }

        let next = AgentTask(title: "Second", goal: "Explore", workspace: try #require(running.workspace))
        try await prepare(next, repository: repository, context: context, fixture: fixture)
        #expect(next.executionRootPath != nil)
        #expect(await GitService.shared.listWorktrees(at: repository.path).count == 3)
        #expect(fixture.resourceQueue.activeResourceLocks == held)

        let discard = try #require(TaskWorktreeService.discardSnapshots(for: next, ownership: fixture.ownership).first)
        context.delete(next)
        try context.save()
        #expect(await TaskWorktreeService.discardOutcome(discard, modelContext: context, resourceQueue: fixture.resourceQueue) == .removed)
        #expect(!FileManager.default.fileExists(atPath: discard.worktreePath))
        #expect(fixture.resourceQueue.activeResourceLocks == held)

        // A writer of the main checkout still excludes the lifecycle.
        let mainWriter = claims(kind: .gitCommonDirectory, path: metadata)
        #expect(!fixture.resourceQueue.canAcquireResourceLocks(mainWriter))
    }

    @Test("With sandboxing off, linked-worktree and repository-subfolder writers claim the Git directory")
    func sandboxOffWritersClaimGitDirectory() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        try fixture.commit("Sources/main.swift", contents: "// main", message: "Add sources", at: repository)
        let linked = fixture.root.appendingPathComponent("App-side", isDirectory: true)
        try fixture.git(["worktree", "add", "--quiet", "-b", "side", linked.path], at: repository)
        let metadata = try #require(GitCheckoutLayout.commonDirectory(for: repository.path))
        let container = try Fixture.container()
        let context = container.mainContext

        let subfolderWorkspace = Workspace(name: "Sources", primaryPath: repository.appendingPathComponent("Sources").path)
        let subfolderTask = AgentTask(title: "Edit sources", goal: "Edit", workspace: subfolderWorkspace)
        let worktreeWorkspace = Workspace(name: "App", primaryPath: repository.path)
        let linkedTask = AgentTask(title: "Edit side", goal: "Edit", workspace: worktreeWorkspace)
        linkedTask.executionRootPath = linked.path
        context.insert(subfolderWorkspace)
        context.insert(worktreeWorkspace)

        for task in [subfolderTask, linkedTask] {
            let enforced = TaskExecutionResourceAdmissionPolicy.lockClaims(for: nil, task: task, runMode: "test")
            #expect(!enforced.contains { $0.resourceKind == .gitCommonDirectory })
            let unenforced = TaskExecutionResourceAdmissionPolicy.lockClaims(
                for: nil, task: task, runMode: "test", sandboxEnforcement: .off
            )
            #expect(unenforced.contains {
                $0.resourceKind == .gitCommonDirectory && $0.resourceKey == metadata && $0.accessMode == .write
            })
            // The lifecycle lease and a prepared sibling's shared claim both wait for it.
            let held = try #require(fixture.resourceQueue.acquireResourceLocksIfAvailable(unenforced, task: nil))
            #expect(!fixture.resourceQueue.canAcquireResourceLocks(TaskExecutionResourceBroker.lockClaims(
                for: [TaskExecutionResourceClaim(kind: .gitCommonDirectory, key: metadata, access: .shared)],
                taskID: UUID(), requestID: UUID(), runMode: "test"
            )))
            fixture.resourceQueue.releaseResourceLocks(held, task: nil)
        }
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

        // Passes ownership as `process` does, so the removal mark a resumed
        // cleanup needs is recorded.
        let outcome = await TaskWorktreeService.discardOutcome(
            discard, modelContext: context, resourceQueue: fixture.resourceQueue, ownership: fixture.ownership,
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

    @Test("A workspace deletion whose save fails keeps the workspace, its connectors, and its drafts' worktrees")
    func failedWorkspaceDeletionSaveKeepsEverything() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let container = try Fixture.container()
        let context = container.mainContext
        let task = try await draft(repository: repository, context: context, fixture: fixture)
        let workspace = try #require(task.workspace)
        let connector = Connector(name: "Jira", serviceType: "jira")
        connector.workspace = workspace
        context.insert(connector)
        try context.save()
        let discard = try #require(TaskWorktreeService.discardSnapshots(for: task, ownership: fixture.ownership).first)
        let coordinator = TaskLifecycleCoordinator(
            modelContext: context, taskQueue: fixture.resourceQueue, worktreeCleanupStore: fixture.cleanupStore,
            persistWorkspaceChange: { _, _ in false }
        )
        let result = coordinator.deleteWorkspace(workspace, existingWorkspaces: [workspace])
        #expect(!result.persisted)
        #expect(result.nextWorkspace == nil)
        #expect(result.cleanup == nil)
        #expect(!workspace.isDeleted)
        #expect(!connector.isDeleted)
        #expect(try context.fetchCount(FetchDescriptor<Workspace>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<Connector>()) == 1)
        #expect(FileManager.default.fileExists(atPath: discard.worktreePath))
        #expect(try fixture.cleanupStore.pendingURLs().count == 1)
    }

    @Test("A deletion whose cancellation can't be saved stops nothing and keeps the task's requests", arguments: [false, true])
    func unsavedCancellationKeepsRequests(saves: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let container = try Fixture.container()
        let context = container.mainContext
        let workspace = Workspace(name: "App", primaryPath: repository.path)
        context.insert(workspace)
        let task = AgentTask(title: "Queued", goal: "Explore", workspace: workspace)
        context.insert(task)
        let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1, resourceClaims: [])
        context.insert(request)
        try context.save()
        let previousState = request.state
        #expect(!previousState.isTerminal)
        let coordinator = TaskLifecycleCoordinator(
            modelContext: context, taskQueue: fixture.resourceQueue, worktreeCleanupStore: fixture.cleanupStore,
            persistWorkspaceChange: { _, context in saves && (try? context.save()) != nil }
        )

        let deleted = coordinator.deleteTask(task)
        #expect(deleted == saves)
        if saves {
            #expect(try ModelContext(container).fetchCount(FetchDescriptor<TaskTurnRequest>()) == 0)
        } else {
            // Nothing was stopped or recorded: the request keeps its state
            // in memory and in the store, and the task is still there.
            #expect(!task.isDeleted)
            #expect(!request.isDeleted)
            #expect(request.state == previousState)
            #expect(request.terminalReason == nil)
            let durable = try #require(try ModelContext(container).fetch(FetchDescriptor<TaskTurnRequest>()).first)
            #expect(durable.state == previousState)
        }
    }

    @Test("A workspace deletion's mirror and credential cleanup is recorded first and finished after a quit")
    func workspaceDeletionCleanupSurvivesQuit() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let container = try Fixture.container()
        let context = container.mainContext
        let store = WorkspaceDeletionCleanupStore(directory: fixture.root.appendingPathComponent("DeletionCleanup"))
        func folder(_ name: String) throws -> String {
            let url = fixture.root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url.path
        }
        func writeMirror(_ path: String) throws -> String {
            let mirror = WorkspaceFileLayout.workspaceConfigFile(for: path)
            try FileManager.default.createDirectory(
                atPath: (mirror as NSString).deletingLastPathComponent, withIntermediateDirectories: true
            )
            try "{}".write(toFile: mirror, atomically: true, encoding: .utf8)
            return mirror
        }

        // A saved deletion removes the mirror and clears its record.
        let deleted = Workspace(name: "Deleted", primaryPath: try folder("Deleted"))
        context.insert(deleted)
        try context.save()
        let deletedMirror = try writeMirror(deleted.primaryPath)
        let coordinator = TaskLifecycleCoordinator(
            modelContext: context, taskQueue: fixture.resourceQueue, worktreeCleanupStore: fixture.cleanupStore,
            workspaceDeletionCleanupStore: store
        )
        #expect(coordinator.deleteWorkspace(deleted, existingWorkspaces: [deleted]).persisted)
        #expect(!FileManager.default.fileExists(atPath: deletedMirror))
        #expect(store.pending().isEmpty)

        // A quit after the deletion was saved leaves the record; the next
        // launch finishes it. A record for a workspace still in the store was
        // never saved and is dropped, and a mirror another workspace uses at
        // the same path is kept.
        let interrupted = Workspace(name: "Interrupted", primaryPath: try folder("Interrupted"))
        let survivor = Workspace(name: "Survivor", primaryPath: try folder("Survivor"))
        let shared = Workspace(name: "Shared", primaryPath: try folder("Shared"))
        let sharing = Workspace(name: "Shared copy", primaryPath: shared.primaryPath)
        for workspace in [interrupted, survivor, shared, sharing] { context.insert(workspace) }
        try context.save()
        let mirrors = try [interrupted, survivor, shared].map { try writeMirror($0.primaryPath) }
        for workspace in [interrupted, survivor, shared] {
            try store.record(WorkspaceDeletionCleanupRecord(workspace))
        }
        context.delete(interrupted)
        context.delete(shared)
        try context.save()

        #expect(WorkspaceDeletionCleanupService.resumePending(modelContext: context, store: store) == 3)
        #expect(!FileManager.default.fileExists(atPath: mirrors[0]))
        #expect(FileManager.default.fileExists(atPath: mirrors[1]))
        #expect(FileManager.default.fileExists(atPath: mirrors[2]))
        #expect(store.pending().isEmpty)
    }

    @Test("A replacement that isn't saved puts the workspace's SSH connections back")
    func failedReplacementRestoresSSHConnections() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let container = try Fixture.container()
        let context = container.mainContext
        let workspace = Workspace(name: "App", primaryPath: fixture.storage.path)
        context.insert(workspace)
        try context.save()
        let original = SSHConnection(name: "original", host: "original-host", user: "me", keyPath: "", configAlias: "original")
        SSHConnectionManager.save([original], workspacePath: fixture.storage.path)
        let sshFile = URL(fileURLWithPath: SSHConnectionManager.connectionsFilePath(for: fixture.storage.path))
        let originalData = try Data(contentsOf: sshFile)
        var config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: context))
        config.sshConnections = [
            SSHConnection(name: "replacement", host: "replacement-host", user: "me", keyPath: "", configAlias: "replacement")
        ]
        let configURL = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: fixture.storage.path))
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(config).write(to: configURL, options: .atomic)
        let coordinator = TaskLifecycleCoordinator(
            modelContext: context, taskQueue: fixture.resourceQueue, worktreeCleanupStore: fixture.cleanupStore,
            persistWorkspaceChange: { _, _ in false }
        )

        #expect(coordinator.importFromConfig(
            at: configURL, existingWorkspaces: [workspace], askDuplicateAction: { _, _ in .replace }
        ) == nil)
        #expect(try Data(contentsOf: sshFile) == originalData)
        #expect(SSHConnectionManager.load(workspacePath: fixture.storage.path).map(\.name) == ["original"])
    }

    @Test("A mirror that can't be removed keeps the deletion record for a retry")
    func unremovableMirrorKeepsRecord() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let container = try Fixture.container()
        let context = container.mainContext
        let store = WorkspaceDeletionCleanupStore(directory: fixture.root.appendingPathComponent("DeletionCleanup"))
        let folder = fixture.root.appendingPathComponent("Locked", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let workspace = Workspace(name: "Locked", primaryPath: folder.path)
        context.insert(workspace)
        try context.save()
        let mirror = WorkspaceFileLayout.workspaceConfigFile(for: folder.path)
        let mirrorFolder = (mirror as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: mirrorFolder, withIntermediateDirectories: true)
        try "{}".write(toFile: mirror, atomically: true, encoding: .utf8)
        try store.record(WorkspaceDeletionCleanupRecord(workspace))
        context.delete(workspace)
        try context.save()

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: mirrorFolder)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mirrorFolder) }
        #expect(WorkspaceDeletionCleanupService.resumePending(modelContext: context, store: store) == 0)
        #expect(FileManager.default.fileExists(atPath: mirror))
        #expect(store.pending().count == 1)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mirrorFolder)
        #expect(WorkspaceDeletionCleanupService.resumePending(modelContext: context, store: store) == 1)
        #expect(!FileManager.default.fileExists(atPath: mirror))
        #expect(store.pending().isEmpty)
    }

    @Test("Creation claims its destination, so a task whose root holds the worktrees folder blocks it")
    func creationClaimsDestination() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let container = try Fixture.container()
        let context = container.mainContext
        let workspace = Workspace(name: "Workspace", primaryPath: repository.path)
        context.insert(workspace)
        let task = AgentTask(title: "Explore", goal: "Explore", workspace: workspace)
        let held = try #require(fixture.resourceQueue.acquireResourceLocksIfAvailable(
            claims(kind: .workspace, path: fixture.worktrees.path), task: nil
        ))
        await #expect(throws: TaskWorktreeCreationError.self) {
            try await prepare(task, repository: repository, context: context, fixture: fixture)
        }
        #expect(await GitService.shared.listWorktrees(at: repository.path).count == 1)
        #expect(try fixture.ownership.creationJournal.pendingURLs().isEmpty)
        #expect(fixture.resourceQueue.activeResourceLocks == held)

        fixture.resourceQueue.releaseResourceLocks(held, task: nil)
        try await prepare(task, repository: repository, context: context, fixture: fixture)
        #expect(task.executionRootPath != nil)
        #expect(fixture.resourceQueue.activeResourceLocks.isEmpty)
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
        // Auto-export writes the mirror from a detached task; under load it
        // can land after `draft` returns, so wait for it by count, not time.
        for _ in 0..<500 where !FileManager.default.fileExists(atPath: configURL.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
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

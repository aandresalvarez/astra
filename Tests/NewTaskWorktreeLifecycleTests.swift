import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
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

    @Test("A running sibling worktree task shares the Git directory with creation; cleanup waits for it")
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
        var held = try #require(fixture.resourceQueue.acquireResourceLocksIfAvailable(siblingClaims, task: nil))
        defer { fixture.resourceQueue.releaseResourceLocks(held, task: nil) }

        let next = AgentTask(title: "Second", goal: "Explore", workspace: try #require(running.workspace))
        try await prepare(next, repository: repository, context: context, fixture: fixture)
        #expect(next.executionRootPath != nil)
        #expect(await GitService.shared.listWorktrees(at: repository.path).count == 3)
        #expect(fixture.resourceQueue.activeResourceLocks == held)

        let discard = try #require(TaskWorktreeService.discardSnapshots(for: next, ownership: fixture.ownership).first)
        context.delete(next)
        try context.save()
        // Cleanup checks a branch and then deletes it, so it waits for the
        // sibling rather than letting it check that branch out in between.
        #expect(await TaskWorktreeService.discardOutcome(
            discard, modelContext: context, resourceQueue: fixture.resourceQueue, ownership: fixture.ownership
        ) == .retry("repository_busy"))
        #expect(FileManager.default.fileExists(atPath: discard.worktreePath))
        fixture.resourceQueue.releaseResourceLocks(held, task: nil)
        #expect(await TaskWorktreeService.discardOutcome(
            discard, modelContext: context, resourceQueue: fixture.resourceQueue, ownership: fixture.ownership
        ) == .removed)
        #expect(!FileManager.default.fileExists(atPath: discard.worktreePath))
        held = try #require(fixture.resourceQueue.acquireResourceLocksIfAvailable(siblingClaims, task: nil))

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
          arguments: ["unused", "dirty", "hiddenUntracked", "committed", "executed"])
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
        case "hiddenUntracked":
            // Plain `git status` hides it, yet a non-forced removal deletes it.
            try fixture.git(["config", "status.showUntrackedFiles", "no"], at: repository)
            try "unsaved work".write(to: checkout.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
            #expect(try fixture.git(["status", "--porcelain"], at: checkout).isEmpty)
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
        // The unsaved deletion's cleanup intent goes with it.
        #expect(try fixture.cleanupStore.pendingURLs().isEmpty)
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
        // never saved; it settles without touching anything that workspace
        // owns, and a mirror another workspace uses at the same path is kept.
        let interrupted = Workspace(name: "Interrupted", primaryPath: try folder("Interrupted"))
        let survivor = Workspace(name: "Survivor", primaryPath: try folder("Survivor"))
        let shared = Workspace(name: "Shared", primaryPath: try folder("Shared"))
        let sharing = Workspace(name: "Shared copy", primaryPath: shared.primaryPath)
        for workspace in [interrupted, survivor, shared, sharing] { context.insert(workspace) }
        try context.save()
        let mirrors = try [interrupted, survivor, shared].map { try writeMirror($0.primaryPath) }
        for workspace in [interrupted, survivor, shared] {
            try store.pinMirrorIdentities(for: store.record(WorkspaceDeletionCleanupRecord(workspace)))
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

    @Test("An SSH connections link, dangling or not, is snapshotted and restored as a link", arguments: [false, true])
    func sshConnectionsLinkIsRestoredAsLink(dangling: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let folder = fixture.root.appendingPathComponent("Workspace", isDirectory: true)
        let file = SSHConnectionManager.connectionsFilePath(for: folder.path)
        try FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        #expect(try SSHConnectionManager.snapshot(workspacePath: folder.path) == .absent)
        let target = fixture.root.appendingPathComponent("managed-ssh.json")
        if !dangling { try Data("[]".utf8).write(to: target) }
        try FileManager.default.createSymbolicLink(atPath: file, withDestinationPath: target.path)
        let snapshot = try SSHConnectionManager.snapshot(workspacePath: folder.path)
        #expect(snapshot == .link(destination: target.path))

        // A replacement's write turns the link into a file; rollback puts the
        // link back without writing through it.
        SSHConnectionManager.save(
            [SSHConnection(name: "new", host: "new-host", user: "me", keyPath: "", configAlias: "new")], workspacePath: folder.path
        )
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: file)) == nil)
        try SSHConnectionManager.restore(snapshot, workspacePath: folder.path)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: file) == target.path)
        if !dangling { #expect(try Data(contentsOf: target) == Data("[]".utf8)) }
    }

    @Test("Startup settles pending workspace deletions only after mirror recovery has run")
    func startupSettlesDeletionsAfterRecovery() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Astra/ASTRAApp.swift"), encoding: .utf8)
        let recovery = try #require(source.range(of: "WorkspaceRecoveryService.recoverMissingWorkspacesAfterLaunch("))
        let awaited = try #require(source.range(of: "await recovery.value", range: recovery.upperBound..<source.endIndex))
        let settle = try #require(source.range(
            of: "WorkspaceDeletionCleanupService.resumePending(modelContext: modelContext", range: awaited.upperBound..<source.endIndex
        ))
        #expect(awaited.lowerBound < settle.lowerBound)
        // That is the only settlement: none before recovery runs, and none on
        // a launch that skips it.
        #expect(source.components(separatedBy: "WorkspaceDeletionCleanupService.resumePending").count == 2)
        // Worktree cleanup, whose pins mirrors may hold, waits for recovery too.
        let worktreeCleanup = try #require(source.range(of: "private static func recoverPendingWorktreeCleanup("))
        let gate = try #require(source.range(
            of: "guard workspaceRecoveryAfterLaunch != nil, workspaceRecoveryTrusted else {", range: worktreeCleanup.upperBound..<source.endIndex
        ))
        let creations = try #require(source.range(
            of: "TaskWorktreeCleanupService.resumeInterruptedCreations(", range: worktreeCleanup.upperBound..<source.endIndex
        ))
        #expect(gate.lowerBound < creations.lowerBound)
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

    @Test("A replacement at another path restores both SSH files, and an unreadable one stops it")
    func replacementAtAnotherPathRestoresBothSSHFiles() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let container = try Fixture.container()
        let context = container.mainContext
        let other = fixture.root.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let workspace = Workspace(name: "App", primaryPath: fixture.storage.path)
        context.insert(workspace)
        try context.save()
        func connection(_ name: String) -> SSHConnection {
            SSHConnection(name: name, host: name + "-host", user: "me", keyPath: "", configAlias: name)
        }
        SSHConnectionManager.save([connection("original")], workspacePath: fixture.storage.path)
        SSHConnectionManager.save([connection("other-original")], workspacePath: other.path)
        let files = [fixture.storage.path, other.path].map {
            URL(fileURLWithPath: SSHConnectionManager.connectionsFilePath(for: $0))
        }
        let before = try files.map { try Data(contentsOf: $0) }
        // Matched by ID, the replacement lives at the config's own folder.
        var config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: context))
        config.sshConnections = [connection("replacement")]
        let configURL = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: other.path))
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(config).write(to: configURL, options: .atomic)
        func replace(saves: Bool) -> Workspace? {
            TaskLifecycleCoordinator(
                modelContext: context, taskQueue: fixture.resourceQueue, worktreeCleanupStore: fixture.cleanupStore,
                persistWorkspaceChange: { _, context in saves && (try? context.save()) != nil }
            ).importFromConfig(at: configURL, existingWorkspaces: [workspace], askDuplicateAction: { _, _ in .replace })
        }

        #expect(replace(saves: false) == nil)
        #expect(try files.map { try Data(contentsOf: $0) } == before)

        // An SSH file that can't be read can't be restored, so nothing starts.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: files[1].path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: files[1].path) }
        #expect(replace(saves: true) == nil)
        #expect(!workspace.isDeleted)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: files[1].path)
        #expect(try Data(contentsOf: files[1]) == before[1])
    }

    @Test("Launch recovery vouches for the store only when every mirror it found loaded")
    func recoveryReportsUnloadableMirrors() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let source = try Fixture.container()
        let folder = fixture.root.appendingPathComponent("Good", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let workspace = Workspace(name: "Good", primaryPath: folder.path)
        source.mainContext.insert(workspace)
        try source.mainContext.save()
        let mirror = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: folder.path))
        try FileManager.default.createDirectory(at: mirror.deletingLastPathComponent(), withIntermediateDirectories: true)
        try WorkspaceConfigManager.exportToFile(workspace: workspace, modelContext: source.mainContext, url: mirror)

        // Imports that can't be saved leave the durable store without them.
        let unsaved = try Fixture.container()
        #expect(!(await WorkspaceRecoveryService.recoverMissingWorkspacesAfterLaunch(
            modelContext: unsaved.mainContext, extraRoots: [fixture.root.path], includeDefaultRoots: false,
            saveImports: { _ in throw CocoaError(.fileWriteUnknown) }
        ).value))
        let empty = try Fixture.container()
        #expect(await WorkspaceRecoveryService.recoverMissingWorkspacesAfterLaunch(
            modelContext: empty.mainContext, extraRoots: [fixture.root.path], includeDefaultRoots: false
        ).value)

        // A second mirror that can't be loaded may hold pins and owners.
        let broken = fixture.root.appendingPathComponent("Broken", isDirectory: true)
        let brokenMirror = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: broken.path))
        try FileManager.default.createDirectory(at: brokenMirror.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not a workspace".utf8).write(to: brokenMirror)
        let rebuilt = try Fixture.container()
        #expect(!(await WorkspaceRecoveryService.recoverMissingWorkspacesAfterLaunch(
            modelContext: rebuilt.mainContext, extraRoots: [fixture.root.path], includeDefaultRoots: false
        ).value))

        // A folder whose entries can be listed but not inspected may hold
        // mirrors too.
        let unsearchable = fixture.root.appendingPathComponent("Unsearchable", isDirectory: true)
        try FileManager.default.createDirectory(at: unsearchable.appendingPathComponent("Inner"), withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: unsearchable.path)
        let partialChildren = try Fixture.container()
        #expect(!(await WorkspaceRecoveryService.recoverMissingWorkspacesAfterLaunch(
            modelContext: partialChildren.mainContext, extraRoots: [fixture.root.path], includeDefaultRoots: false
        ).value))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unsearchable.path)

        // A folder the scan can't list may hold mirrors too.
        try FileManager.default.removeItem(at: broken)
        let locked = fixture.root.appendingPathComponent("Locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked.appendingPathComponent("Inner"), withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let marker = fixture.root.appendingPathComponent("RecoveryIncomplete")
        let partial = try Fixture.container()
        #expect(!(await WorkspaceRecoveryService.recoverMissingWorkspacesAfterLaunch(
            modelContext: partial.mainContext, extraRoots: [fixture.root.path], includeDefaultRoots: false,
            incompleteMarker: marker
        ).value))
        // The next launch rescans instead of trusting a nonempty store.
        #expect(FileManager.default.fileExists(atPath: marker.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        let complete = try Fixture.container()
        #expect(await WorkspaceRecoveryService.recoverMissingWorkspacesAfterLaunch(
            modelContext: complete.mainContext, extraRoots: [fixture.root.path], includeDefaultRoots: false,
            incompleteMarker: marker
        ).value)
        #expect(!FileManager.default.fileExists(atPath: marker.path))

        // Startup gates destructive cleanup on that answer.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let app = try String(contentsOf: root.appendingPathComponent("Astra/ASTRAApp.swift"), encoding: .utf8)
        #expect(app.contains("incompleteMarker: WorkspaceRecoveryService.defaultIncompleteRecoveryMarker"))
        #expect(app.contains("guard await recovery.value else {"))
        #expect(app.contains("guard workspaceRecoveryAfterLaunch != nil, workspaceRecoveryTrusted else {"))
    }

    @Test("A pinned mirror path now holding a different file is left alone")
    func pinnedPathWithNewMirrorIsSpared() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let container = try Fixture.container()
        let context = container.mainContext
        let store = WorkspaceDeletionCleanupStore(directory: fixture.root.appendingPathComponent("DeletionCleanup"))
        let folder = fixture.root.appendingPathComponent("Reused", isDirectory: true)
        let mirror = WorkspaceFileLayout.workspaceConfigFile(for: folder.path)
        try FileManager.default.createDirectory(atPath: (mirror as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "{}".write(toFile: mirror, atomically: true, encoding: .utf8)
        let record = WorkspaceDeletionCleanupRecord(workspaceID: UUID(), primaryPath: folder.path, connectors: [], skills: [])
        try store.write(record)
        try store.pinMirrorIdentities(for: record)
        #expect(store.pending().first?.mirrorFileIDs.isEmpty == false)

        // The folder is replaced by an ordinary one where another workspace
        // writes its own mirror, with a new identity.
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(atPath: (mirror as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "{\"new\":true}".write(toFile: mirror, atomically: true, encoding: .utf8)
        #expect(WorkspaceDeletionCleanupService.resumePending(modelContext: context, store: store) == 1)
        #expect(FileManager.default.fileExists(atPath: mirror))
    }

    @Test("Restoring an absent SSH file fails when the file there can't be checked or removed")
    func unreadableSSHFolderFailsAbsentRestore() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let folder = fixture.root.appendingPathComponent("Workspace", isDirectory: true)
        let file = SSHConnectionManager.connectionsFilePath(for: folder.path)
        let support = (file as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: support, withIntermediateDirectories: true)
        // Nothing there is already absent.
        try SSHConnectionManager.restore(.absent, workspacePath: folder.path)
        // A failed replacement wrote the file, and its folder can't be read.
        try Data("[]".utf8).write(to: URL(fileURLWithPath: file))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: support)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: support) }
        #expect(throws: (any Error).self) { try SSHConnectionManager.restore(.absent, workspacePath: folder.path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: support)
        #expect(FileManager.default.fileExists(atPath: file))
        try SSHConnectionManager.restore(.absent, workspacePath: folder.path)
        #expect(!FileManager.default.fileExists(atPath: file))
    }

    @Test("A mirror whose identity can't be read stops pinning; a missing one is left out")
    func unreadableMirrorIdentityStopsPinning() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = WorkspaceDeletionCleanupStore(directory: fixture.root.appendingPathComponent("DeletionCleanup"))
        let folder = fixture.root.appendingPathComponent("Locked", isDirectory: true)
        let record = WorkspaceDeletionCleanupRecord(workspaceID: UUID(), primaryPath: folder.path, connectors: [], skills: [])
        try store.write(record)
        #expect(try store.pinMirrorIdentities(for: record).mirrorFileIDs.isEmpty)
        let mirror = WorkspaceFileLayout.workspaceConfigFile(for: folder.path)
        let support = (mirror as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: support, withIntermediateDirectories: true)
        try "{}".write(toFile: mirror, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: support)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: support) }
        #expect(throws: (any Error).self) { try store.pinMirrorIdentities(for: record) }
        #expect(store.pending().first?.mirrorFileIDs.isEmpty == true)
    }

    @Test("A mirror whose identity can't be read at settlement keeps the deletion pending")
    func unreadableMirrorIdentityKeepsDeletionPending() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let container = try Fixture.container()
        let context = container.mainContext
        let store = WorkspaceDeletionCleanupStore(directory: fixture.root.appendingPathComponent("DeletionCleanup"))
        let folder = fixture.root.appendingPathComponent("Reused", isDirectory: true)
        let mirror = WorkspaceFileLayout.workspaceConfigFile(for: folder.path)
        try FileManager.default.createDirectory(atPath: (mirror as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "{}".write(toFile: mirror, atomically: true, encoding: .utf8)
        let record = WorkspaceDeletionCleanupRecord(workspaceID: UUID(), primaryPath: folder.path, connectors: [], skills: [])
        try store.write(record)
        let pinned = try store.pinMirrorIdentities(for: record)
        struct Unreadable: Error {}
        // The pinned path may now hold a replacement it can't tell apart.
        #expect(!WorkspaceDeletionCleanupService.settle(pinned, modelContext: context, identity: { _ in throw Unreadable() }))
        #expect(FileManager.default.fileExists(atPath: mirror))
        // A moved mirror that can't be read is no different.
        let moved = fixture.root.appendingPathComponent("Moved/.astra/.astra-workspace.json").path
        #expect(!WorkspaceDeletionCleanupService.settle(pinned, modelContext: context, movedMirrors: [moved], identity: { path in
            if path == moved { throw Unreadable() }
            return try WorkspaceFileLayout.itemIdentityConfirmingAbsence(at: path)
        }))
        #expect(WorkspaceDeletionCleanupService.settle(pinned, modelContext: context))
        #expect(!FileManager.default.fileExists(atPath: mirror))
    }

    @Test("A replacement mirror at a pending deletion's pinned path is recovered, so settlement counts its owners")
    func replacementMirrorAtPinnedPathIsRecovered() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let source = try Fixture.container()
        let scanned = fixture.root.appendingPathComponent("Workspaces", isDirectory: true)
        let folder = scanned.appendingPathComponent("Reused", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let deleted = Workspace(name: "Deleted", primaryPath: folder.path)
        source.mainContext.insert(deleted)
        try source.mainContext.save()
        let mirror = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: folder.path))
        try FileManager.default.createDirectory(at: mirror.deletingLastPathComponent(), withIntermediateDirectories: true)
        try WorkspaceConfigManager.exportToFile(workspace: deleted, modelContext: source.mainContext, url: mirror)
        let store = WorkspaceDeletionCleanupStore(directory: fixture.root.appendingPathComponent("DeletionCleanup"))
        try store.pinMirrorIdentities(for: store.record(WorkspaceDeletionCleanupRecord(deleted)))
        // Before the next launch the folder holds a new workspace's mirror.
        try FileManager.default.removeItem(at: mirror)
        let replacement = Workspace(name: "Replacement", primaryPath: folder.path)
        source.mainContext.insert(replacement)
        try source.mainContext.save()
        try WorkspaceConfigManager.exportToFile(workspace: replacement, modelContext: source.mainContext, url: mirror)

        let empty = try Fixture.container()
        var reported: [URL] = []
        #expect(await WorkspaceRecoveryService.recoverMissingWorkspacesAfterLaunch(
            modelContext: empty.mainContext, excludingConfigFiles: try #require(store.pendingMirrorPaths()),
            extraRoots: [scanned.path], includeDefaultRoots: false,
            excludingItemIdentities: try #require(store.pendingMirrorIdentities()),
            excludedByIdentity: { reported = $0 }
        ).value)
        #expect(try empty.mainContext.fetch(FetchDescriptor<Workspace>()).map(\.name) == ["Replacement"])
        #expect(reported.isEmpty)
    }

    @Test("A mirror that appears after every mirror was pinned absent is a replacement, never the deletion's")
    func mirrorAppearingAfterAbsentPinIsSpared() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let container = try Fixture.container()
        let context = container.mainContext
        let store = WorkspaceDeletionCleanupStore(directory: fixture.root.appendingPathComponent("DeletionCleanup"))
        let folder = fixture.root.appendingPathComponent("Reused", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let record = WorkspaceDeletionCleanupRecord(workspaceID: UUID(), primaryPath: folder.path, connectors: [], skills: [])
        try store.write(record)
        #expect(try store.pinMirrorIdentities(for: record).mirrorFileIDs.isEmpty)
        // A new workspace writes its mirror there before the next launch.
        let mirror = WorkspaceFileLayout.workspaceConfigFile(for: folder.path)
        try FileManager.default.createDirectory(atPath: (mirror as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "{\"new\":true}".write(toFile: mirror, atomically: true, encoding: .utf8)
        #expect(WorkspaceDeletionCleanupService.resumePending(modelContext: context, store: store) == 1)
        #expect(FileManager.default.fileExists(atPath: mirror))
    }

    @Test("A pending deletion record that can't be checked stops a new one rather than being replaced")
    func uncheckableDeletionRecordIsNotReplaced() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = WorkspaceDeletionCleanupStore(directory: fixture.root.appendingPathComponent("DeletionCleanup"))
        let record = WorkspaceDeletionCleanupRecord(
            workspaceID: UUID(), primaryPath: fixture.root.appendingPathComponent("Deleted").path, connectors: [], skills: []
        )
        let first = try store.record(record)
        let before = try Data(contentsOf: store.recordURL(for: record))
        struct Uncheckable: Error {}
        #expect(throws: Uncheckable.self) {
            try store.record(record, attributes: { _ in throw Uncheckable() })
        }
        #expect(try Data(contentsOf: store.recordURL(for: record)) == before)
        // A confirmed missing one starts fresh.
        store.remove(first)
        #expect(try store.record(record, attributes: { _ in throw CocoaError(.fileReadNoSuchFile) }) == record)
    }

    @Test("A deletion outbox that can't be checked is unknown, never empty")
    func untraversableOutboxIsUnknown() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let parent = fixture.root.appendingPathComponent("Support", isDirectory: true)
        let store = WorkspaceDeletionCleanupStore(directory: parent.appendingPathComponent("DeletionCleanup"))
        #expect(store.pendingMirrorPaths() == [])
        #expect(store.pendingMirrorIdentities() == [])
        try store.write(WorkspaceDeletionCleanupRecord(
            workspaceID: UUID(), primaryPath: fixture.root.appendingPathComponent("Deleted").path, connectors: [], skills: []
        ))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: parent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path) }
        #expect(store.pendingMirrorPaths() == nil)
        #expect(store.pendingMirrorIdentities() == nil)
    }

    @Test("A configured recovery root inside a protected folder is scanned, and one still skipped leaves the scan incomplete")
    func protectedConfiguredRootIsScannedOrIncomplete() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        // `Pictures` under the privacy home is protected from implicit scans.
        let root = fixture.root.appendingPathComponent("Pictures/Workspaces", isDirectory: true)
        let mirror = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: root.appendingPathComponent("App").path))
        try FileManager.default.createDirectory(at: mirror.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{}".write(to: mirror, atomically: true, encoding: .utf8)
        let scan = WorkspaceRecoveryService.discoverWorkspaceConfigFilesReportingCompleteness(
            extraRoots: [root.path], includeDefaultRoots: false, privacyHomeDirectory: fixture.root
        )
        #expect(scan.configs.map { WorkspacePathPresentation.resolvedPath($0.path) } == [WorkspacePathPresentation.resolvedPath(mirror.path)])
        #expect(scan.complete)
        // A configured root the policy skips regardless, such as an app
        // bundle, may hide mirrors.
        let bundle = fixture.root.appendingPathComponent("Tool.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        #expect(!WorkspaceRecoveryService.discoverWorkspaceConfigFilesReportingCompleteness(
            extraRoots: [bundle.path], includeDefaultRoots: false, privacyHomeDirectory: fixture.root
        ).complete)
    }

    @Test("A partial-recovery marker that can't be checked is resumed, never taken as finished")
    func uncheckableIncompleteMarkerIsResumed() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let folder = fixture.root.appendingPathComponent("Support", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let marker = folder.appendingPathComponent("WorkspaceRecoveryIncomplete")
        #expect(!WorkspaceRecoveryService.incompleteMarkerPresent(marker))
        try Data().write(to: marker)
        #expect(WorkspaceRecoveryService.incompleteMarkerPresent(marker))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        #expect(WorkspaceRecoveryService.incompleteMarkerPresent(marker))
    }

    @Test("Recovery trusts a nonempty store without scanning only while no deletion is pending")
    func recoveryShortcutWaitsForPendingDeletions() {
        #expect(WorkspaceRecoveryService.storeVouchesWithoutScan(
            extraRoots: [], includeDefaultRoots: true, resumingPartialRecovery: false, pendingDeletion: false, hasWorkspaces: true
        ))
        // A pending deletion's mirror may have moved; only the scan finds it.
        #expect(!WorkspaceRecoveryService.storeVouchesWithoutScan(
            extraRoots: [], includeDefaultRoots: true, resumingPartialRecovery: false, pendingDeletion: true, hasWorkspaces: true
        ))
        #expect(!WorkspaceRecoveryService.storeVouchesWithoutScan(
            extraRoots: [], includeDefaultRoots: true, resumingPartialRecovery: true, pendingDeletion: false, hasWorkspaces: true
        ))
        #expect(!WorkspaceRecoveryService.storeVouchesWithoutScan(
            extraRoots: [], includeDefaultRoots: true, resumingPartialRecovery: false, pendingDeletion: false, hasWorkspaces: false
        ))
    }

    @Test("A connections file whose folder can't be read stops the SSH snapshot")
    func unreadableSSHFolderFailsSnapshot() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let folder = fixture.root.appendingPathComponent("Workspace", isDirectory: true)
        let file = SSHConnectionManager.connectionsFilePath(for: folder.path)
        let support = (file as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: support, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: URL(fileURLWithPath: file))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: support)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: support) }
        #expect(throws: (any Error).self) { try SSHConnectionManager.snapshot(workspacePath: folder.path) }
    }

    @Test("A mirror whose folder can't be traversed keeps the deletion pending")
    func untraversableMirrorFolderKeepsRecord() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let container = try Fixture.container()
        let context = container.mainContext
        let store = WorkspaceDeletionCleanupStore(directory: fixture.root.appendingPathComponent("DeletionCleanup"))
        let folder = fixture.root.appendingPathComponent("Locked", isDirectory: true)
        let mirror = WorkspaceFileLayout.workspaceConfigFile(for: folder.path)
        try FileManager.default.createDirectory(atPath: (mirror as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "{}".write(toFile: mirror, atomically: true, encoding: .utf8)
        try store.pinMirrorIdentities(for: store.record(WorkspaceDeletionCleanupRecord(workspaceID: UUID(), primaryPath: folder.path, connectors: [], skills: [])))
        // The mirror is still there; only its folder can't be entered.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        #expect(WorkspaceDeletionCleanupService.resumePending(modelContext: context, store: store) == 0)
        #expect(store.pending().count == 1)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        #expect(WorkspaceDeletionCleanupService.resumePending(modelContext: context, store: store) == 1)
        #expect(!FileManager.default.fileExists(atPath: mirror))
    }

    @Test("A workspace deletion pins its mirror identities before the deletion is saved")
    func deletionPinsMirrorIdentitiesBeforeSaving() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let container = try Fixture.container()
        let context = container.mainContext
        let store = WorkspaceDeletionCleanupStore(directory: fixture.root.appendingPathComponent("DeletionCleanup"))
        let folder = fixture.root.appendingPathComponent("Deleted", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let workspace = Workspace(name: "Deleted", primaryPath: folder.path)
        context.insert(workspace)
        try context.save()
        let mirror = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: folder.path))
        try FileManager.default.createDirectory(at: mirror.deletingLastPathComponent(), withIntermediateDirectories: true)
        try WorkspaceConfigManager.exportToFile(workspace: workspace, modelContext: context, url: mirror)
        let identity = try #require(WorkspaceFileLayout.itemIdentity(at: mirror.path))
        // What a quit right after the save would leave on disk.
        var pinnedAtSave: [String] = []
        let coordinator = TaskLifecycleCoordinator(
            modelContext: context, taskQueue: fixture.resourceQueue, worktreeCleanupStore: fixture.cleanupStore,
            workspaceDeletionCleanupStore: store,
            persistWorkspaceChange: { _, context in
                pinnedAtSave = store.pending().flatMap(\.mirrorFileIDs)
                return (try? context.save()) != nil
            }
        )
        #expect(coordinator.deleteWorkspace(workspace, existingWorkspaces: [workspace]).persisted)
        #expect(pinnedAtSave == [identity])
    }

    @Test("Recovery imports nothing when it can't first record that it may be incomplete")
    func recoveryNeedsItsIncompleteMarker() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let source = try Fixture.container()
        let folder = fixture.root.appendingPathComponent("Good", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let workspace = Workspace(name: "Good", primaryPath: folder.path)
        source.mainContext.insert(workspace)
        try source.mainContext.save()
        let mirror = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: folder.path))
        try FileManager.default.createDirectory(at: mirror.deletingLastPathComponent(), withIntermediateDirectories: true)
        try WorkspaceConfigManager.exportToFile(workspace: workspace, modelContext: source.mainContext, url: mirror)
        let support = fixture.root.appendingPathComponent("Support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: support.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: support.path) }

        let empty = try Fixture.container()
        #expect(!(await WorkspaceRecoveryService.recoverMissingWorkspacesAfterLaunch(
            modelContext: empty.mainContext, extraRoots: [folder.path], includeDefaultRoots: false,
            incompleteMarker: support.appendingPathComponent("RecoveryIncomplete")
        ).value))
        #expect(try empty.mainContext.fetchCount(FetchDescriptor<Workspace>()) == 0)
    }

    @Test("A pending deletion's mirror moved with its workspace folder is still left out of recovery and removed")
    func movedDeletionMirrorIsRecognizedByIdentity() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let container = try Fixture.container()
        let context = container.mainContext
        let store = WorkspaceDeletionCleanupStore(directory: fixture.root.appendingPathComponent("DeletionCleanup"))
        let scanned = fixture.root.appendingPathComponent("Workspaces", isDirectory: true)
        let folder = scanned.appendingPathComponent("Deleted", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let workspace = Workspace(name: "Deleted", primaryPath: folder.path)
        context.insert(workspace)
        try context.save()
        let mirror = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: folder.path))
        try FileManager.default.createDirectory(at: mirror.deletingLastPathComponent(), withIntermediateDirectories: true)
        try WorkspaceConfigManager.exportToFile(workspace: workspace, modelContext: context, url: mirror)
        // The deletion is saved but its mirror can't be removed yet.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: mirror.deletingLastPathComponent().path)
        let coordinator = TaskLifecycleCoordinator(
            modelContext: context, taskQueue: fixture.resourceQueue, worktreeCleanupStore: fixture.cleanupStore,
            workspaceDeletionCleanupStore: store
        )
        #expect(coordinator.deleteWorkspace(workspace, existingWorkspaces: [workspace]).persisted)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mirror.deletingLastPathComponent().path)
        #expect(store.pending().first?.mirrorFileIDs.isEmpty == false)

        // The workspace folder is renamed before the next launch.
        let renamed = scanned.appendingPathComponent("Renamed", isDirectory: true)
        try FileManager.default.moveItem(at: folder, to: renamed)
        let movedMirror = WorkspaceFileLayout.workspaceConfigFile(for: renamed.path)
        // A mirror whose identity can't be read may be the moved one: it is
        // neither imported nor reported, and recovery isn't trusted.
        let unread = try Fixture.container()
        var reported: [URL] = []
        struct Unreadable: Error {}
        #expect(!(await WorkspaceRecoveryService.recoverMissingWorkspacesAfterLaunch(
            modelContext: unread.mainContext, excludingConfigFiles: try #require(store.pendingMirrorPaths()),
            extraRoots: [scanned.path], includeDefaultRoots: false,
            excludingItemIdentities: try #require(store.pendingMirrorIdentities()),
            excludedByIdentity: { reported = $0 }, itemIdentity: { _ in throw Unreadable() }
        ).value))
        #expect(try unread.mainContext.fetchCount(FetchDescriptor<Workspace>()) == 0)
        #expect(reported.isEmpty)
        let empty = try Fixture.container()
        var found: [URL] = []
        _ = await WorkspaceRecoveryService.recoverMissingWorkspacesAfterLaunch(
            modelContext: empty.mainContext, excludingConfigFiles: try #require(store.pendingMirrorPaths()),
            extraRoots: [scanned.path], includeDefaultRoots: false,
            excludingItemIdentities: try #require(store.pendingMirrorIdentities()),
            excludedByIdentity: { found = $0 }
        ).value
        #expect(try empty.mainContext.fetchCount(FetchDescriptor<Workspace>()) == 0)
        #expect(found.map { WorkspacePathPresentation.resolvedPath($0.path) } == [WorkspacePathPresentation.resolvedPath(movedMirror)])

        #expect(WorkspaceDeletionCleanupService.resumePending(
            modelContext: empty.mainContext, store: store, movedMirrors: found.map(\.path)
        ) == 1)
        #expect(!FileManager.default.fileExists(atPath: movedMirror))
        #expect(store.pending().isEmpty)
    }

    @Test("A failed same-path replacement exports the workspace only after its SSH file is restored")
    func failedReplacementExportsRestoredSSH() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let container = try Fixture.container()
        let context = container.mainContext
        let workspace = Workspace(name: "App", primaryPath: fixture.storage.path)
        context.insert(workspace)
        try context.save()
        func connection(_ name: String) -> SSHConnection {
            SSHConnection(name: name, host: name + "-host", user: "me", keyPath: "", configAlias: name)
        }
        SSHConnectionManager.save([connection("original")], workspacePath: fixture.storage.path)
        var config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: context))
        config.sshConnections = [connection("replacement")]
        let configURL = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: fixture.storage.path))
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(config).write(to: configURL, options: .atomic)

        #expect(TaskLifecycleCoordinator(
            modelContext: context, taskQueue: fixture.resourceQueue, worktreeCleanupStore: fixture.cleanupStore,
            persistWorkspaceChange: { _, _ in false }
        ).importFromConfig(at: configURL, existingWorkspaces: [workspace], askDuplicateAction: { _, _ in .replace }) == nil)

        // The rollback's export is written in the background.
        var names: [String] = []
        for _ in 0..<200 {
            names = ((try? WorkspaceConfigManager.loadConfig(from: configURL))?.sshConnections ?? []).map(\.name)
            if names == ["original"] { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(names == ["original"])
    }

    @Test("Startup recovery leaves out the mirror of an unsettled deletion, and waits when a record is unreadable")
    func unsettledDeletionMirrorIsNotRecovered() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let source = try Fixture.container()
        let folder = fixture.root.appendingPathComponent("Deleted", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The deleted workspace was configured through an alias; recovery
        // discovers the same mirror through the real path.
        let alias = fixture.root.appendingPathComponent("Alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder)
        let workspace = Workspace(name: "Deleted", primaryPath: alias.path)
        source.mainContext.insert(workspace)
        try source.mainContext.save()
        let mirror = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: folder.path))
        try FileManager.default.createDirectory(at: mirror.deletingLastPathComponent(), withIntermediateDirectories: true)
        try WorkspaceConfigManager.exportToFile(workspace: workspace, modelContext: source.mainContext, url: mirror)
        let store = WorkspaceDeletionCleanupStore(directory: fixture.root.appendingPathComponent("DeletionCleanup"))
        try store.pinMirrorIdentities(for: store.record(WorkspaceDeletionCleanupRecord(workspace)))

        let excluded = try #require(store.pendingMirrorPaths())
        #expect(excluded.contains(WorkspacePathPresentation.resolvedPath(mirror.path)))
        let empty = try Fixture.container()
        await WorkspaceRecoveryService.recoverMissingWorkspacesAfterLaunch(
            modelContext: empty.mainContext, excludingConfigFiles: excluded,
            extraRoots: [fixture.root.path], includeDefaultRoots: false,
            excludingItemIdentities: try #require(store.pendingMirrorIdentities())
        ).value
        #expect(try empty.mainContext.fetchCount(FetchDescriptor<Workspace>()) == 0)
        // Without the record the same mirror is recovered.
        await WorkspaceRecoveryService.recoverMissingWorkspacesAfterLaunch(
            modelContext: empty.mainContext, extraRoots: [fixture.root.path], includeDefaultRoots: false
        ).value
        #expect(try empty.mainContext.fetchCount(FetchDescriptor<Workspace>()) == 1)

        try Data("not json".utf8).write(to: store.directory.appendingPathComponent("broken.json"))
        #expect(store.pendingMirrorPaths() == nil)
    }

    @Test("Deletion records are keyed by workspace and path, and a same-path record merges instead of replacing")
    func deletionRecordsAreKeyedByWorkspaceAndPath() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = WorkspaceDeletionCleanupStore(directory: fixture.root.appendingPathComponent("DeletionCleanup"))
        let id = UUID()
        let first = Connector(name: "First", serviceType: "jira").keychainCleanup
        let second = Connector(name: "Second", serviceType: "jira").keychainCleanup
        func record(_ path: String, _ connectors: [ConnectorKeychainCleanup]) -> WorkspaceDeletionCleanupRecord {
            WorkspaceDeletionCleanupRecord(workspaceID: id, primaryPath: path, connectors: connectors, skills: [])
        }
        // Imports reuse workspace IDs, so one ID can be pending at two paths.
        try store.record(record(fixture.root.appendingPathComponent("A").path, [first]))
        try store.record(record(fixture.root.appendingPathComponent("B").path, []))
        #expect(store.pending().count == 2)

        let merged = try store.record(record(fixture.root.appendingPathComponent("A").path, [second]))
        #expect(Set(merged.connectors.map(\.connectorID)) == [first.connectorID, second.connectorID])
        #expect(store.pending().count == 2)

        // A reimported connector can keep its ID under another base URL, a
        // separate credential namespace; both snapshots are kept.
        let reused = Connector(name: "Reused", serviceType: "jira", baseURL: "https://old.example")
        let before = reused.keychainCleanup
        reused.baseURL = "https://new.example"
        let after = try store.record(record(fixture.root.appendingPathComponent("A").path, [before]))
            .merging(record(fixture.root.appendingPathComponent("A").path, [reused.keychainCleanup]))
        #expect(after.connectors.filter { $0.connectorID == reused.id }.map(\.baseURL).sorted()
            == ["https://new.example", "https://old.example"])

        // A pending record that can't be read is never overwritten.
        let url = store.recordURL(for: merged)
        try Data("not json".utf8).write(to: url)
        #expect(throws: (any Error).self) { try store.record(record(fixture.root.appendingPathComponent("A").path, [])) }
        #expect(try Data(contentsOf: url) == Data("not json".utf8))
    }

    @Test("A deletion stays pending when a workspace reusing its ID lives at another path")
    func sameIDElsewhereKeepsDeletionPending() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let container = try Fixture.container()
        let context = container.mainContext
        let store = WorkspaceDeletionCleanupStore(directory: fixture.root.appendingPathComponent("DeletionCleanup"))
        let original = fixture.root.appendingPathComponent("Original", isDirectory: true)
        let elsewhere = fixture.root.appendingPathComponent("Elsewhere", isDirectory: true)
        for folder in [original, elsewhere] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let deleted = Workspace(name: "Deleted", primaryPath: original.path)
        context.insert(deleted)
        try context.save()
        let mirror = WorkspaceFileLayout.workspaceConfigFile(for: original.path)
        try FileManager.default.createDirectory(atPath: (mirror as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "{}".write(toFile: mirror, atomically: true, encoding: .utf8)
        try store.pinMirrorIdentities(for: store.record(WorkspaceDeletionCleanupRecord(deleted)))
        let id = deleted.id
        context.delete(deleted)
        try context.save()
        // An import elsewhere reused the ID before the cleanup was retried.
        let reimported = Workspace(name: "Reimported", primaryPath: elsewhere.path)
        reimported.id = id
        context.insert(reimported)
        try context.save()

        #expect(WorkspaceDeletionCleanupService.resumePending(modelContext: context, store: store) == 1)
        #expect(!FileManager.default.fileExists(atPath: mirror))
        #expect(store.pending().isEmpty)
    }

    @Test("A saved deletion's cleanup survives a reimport at the same folder, sparing what the reimport owns")
    func deletionCleanupSurvivesSameFolderReimport() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let container = try Fixture.container()
        let context = container.mainContext
        let store = WorkspaceDeletionCleanupStore(directory: fixture.root.appendingPathComponent("DeletionCleanup"))
        let folder = fixture.root.appendingPathComponent("Reused", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // A saved deletion whose cleanup failed stays pending; no second
        // write after the save has to succeed for it to stay owed.
        let workspace = Workspace(name: "Reused", primaryPath: folder.path)
        context.insert(workspace)
        try context.save()
        let id = workspace.id
        let mirror = WorkspaceFileLayout.workspaceConfigFile(for: folder.path)
        let mirrorFolder = (mirror as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: mirrorFolder, withIntermediateDirectories: true)
        try "{}".write(toFile: mirror, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: mirrorFolder)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mirrorFolder) }
        let coordinator = TaskLifecycleCoordinator(
            modelContext: context, taskQueue: fixture.resourceQueue, worktreeCleanupStore: fixture.cleanupStore,
            workspaceDeletionCleanupStore: store
        )
        #expect(coordinator.deleteWorkspace(workspace, existingWorkspaces: [workspace]).persisted)
        #expect(store.pending().count == 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mirrorFolder)

        // The same workspace comes back, through an alias of the same folder,
        // before the retry. Its mirror is spared; the credentials only the
        // deleted copy had are still removed.
        let alias = fixture.root.appendingPathComponent("Alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder)
        let skill = Skill(name: "Dropped")
        let tempKeychain = AstraSecureKeychainTestSupport.tempKeychainPath()
        let bootstrap = "astra-test-bootstrap-\(UUID().uuidString)"
        let keychainAvailable = AstraSecureKeychainTestSupport.isAvailable
        if keychainAvailable { AstraSecureKeychainTestSupport.installTestBootstrapPassword(service: bootstrap) }
        defer {
            if keychainAvailable {
                AstraSecureKeychainTestSupport.cleanup(
                    keychainPath: tempKeychain, bootstrapService: bootstrap,
                    services: [KeychainSecretStore.skillEntityID(for: skill.id)]
                )
            }
        }
        try AstraSecureKeychainStore.$keychainPathOverride.withValue(tempKeychain) {
            try AstraSecureKeychainStore.$bootstrapServiceOverride.withValue(bootstrap) {
                skill.environmentVariables = ["TOKEN": "secret"]
                let owed = try #require(store.pending().first)
                try store.write(owed.merging(WorkspaceDeletionCleanupRecord(
                    workspaceID: id, primaryPath: folder.path, connectors: [], skills: [skill.keychainCleanup]
                )))
                let reimported = Workspace(name: "Reused", primaryPath: alias.path)
                reimported.id = id
                context.insert(reimported)
                try context.save()

                #expect(WorkspaceDeletionCleanupService.resumePending(modelContext: context, store: store) == 1)
                #expect(store.pending().isEmpty)
                #expect(FileManager.default.fileExists(atPath: mirror))
                if keychainAvailable {
                    #expect(!SkillSecretSeam.required.secretExists(key: "TOKEN", skillID: skill.id))
                }
            }
        }
    }

    @Test("Deletion cleanup removes only connector namespaces no live connector resolves to")
    func deletionCleanupSparesSharedConnectorNamespaces() {
        // A recreated connector shares the deleted one's stable endpoint
        // namespace under a new ID.
        let deleted = Connector(name: "Jira", serviceType: "jira", baseURL: "https://jira.example.invalid")
        let recreated = Connector(name: "Jira", serviceType: "jira", baseURL: "https://jira.example.invalid")
        let live = Set(KeychainSecretStore.connectorEntityIDs(for: recreated))
        let stable = KeychainSecretStore.stableConnectorEntityID(for: deleted)
        #expect(stable.map(live.contains) == true)
        #expect(ConnectorCredentialCleanup.unownedNamespaces(of: deleted.keychainCleanup, ownership: .init([recreated]))
            == [KeychainSecretStore.connectorEntityID(for: deleted.id)])
        // With no live owner every namespace goes; with the same connector
        // live, nothing does.
        #expect(ConnectorCredentialCleanup.unownedNamespaces(of: deleted.keychainCleanup, ownership: .init([]))
            == Set(KeychainSecretStore.connectorEntityIDs(for: deleted)))
        #expect(ConnectorCredentialCleanup.unownedNamespaces(of: deleted.keychainCleanup, ownership: .init([deleted])).isEmpty)
    }

    @Test("A deletion retry that isn't saved puts back the cleanup an earlier saved deletion still owes")
    func unsavedRetryRestoresEarlierRecord() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let container = try Fixture.container()
        let context = container.mainContext
        let store = WorkspaceDeletionCleanupStore(directory: fixture.root.appendingPathComponent("DeletionCleanup"))
        let folder = fixture.root.appendingPathComponent("Retried", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let workspace = Workspace(name: "Retried", primaryPath: folder.path)
        workspace.connectors.append(Connector(name: "Current", serviceType: "jira"))
        context.insert(workspace)
        try context.save()
        let coordinator = TaskLifecycleCoordinator(
            modelContext: context, taskQueue: fixture.resourceQueue, worktreeCleanupStore: fixture.cleanupStore,
            workspaceDeletionCleanupStore: store, persistWorkspaceChange: { _, _ in false }
        )

        // With nothing pending, the unsaved attempt leaves nothing behind.
        #expect(!coordinator.deleteWorkspace(workspace, existingWorkspaces: [workspace]).persisted)
        #expect(store.pending().isEmpty)

        let earlier = WorkspaceDeletionCleanupRecord(
            workspaceID: workspace.id, primaryPath: folder.path,
            connectors: [Connector(name: "Earlier", serviceType: "jira").keychainCleanup], skills: []
        )
        try store.write(earlier)
        #expect(!coordinator.deleteWorkspace(workspace, existingWorkspaces: [workspace]).persisted)
        #expect(store.pending() == [earlier])
    }

    @Test("A pending deletion's mirror cleanup stays on the folder it recorded after its symlink is retargeted")
    func deletionCleanupKeepsRecordedFolder() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let container = try Fixture.container()
        let context = container.mainContext
        let store = WorkspaceDeletionCleanupStore(directory: fixture.root.appendingPathComponent("DeletionCleanup"))
        func folderWithMirror(_ name: String) throws -> (folder: URL, mirror: String) {
            let folder = fixture.root.appendingPathComponent(name, isDirectory: true)
            let mirror = WorkspaceFileLayout.workspaceConfigFile(for: folder.path)
            try FileManager.default.createDirectory(
                atPath: (mirror as NSString).deletingLastPathComponent, withIntermediateDirectories: true
            )
            try "{}".write(toFile: mirror, atomically: true, encoding: .utf8)
            return (folder, mirror)
        }
        let original = try folderWithMirror("Original")
        let other = try folderWithMirror("Other")
        let link = fixture.root.appendingPathComponent("Link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original.folder)
        let workspace = Workspace(name: "Linked", primaryPath: link.path)
        context.insert(workspace)
        try context.save()
        try store.pinMirrorIdentities(for: store.record(WorkspaceDeletionCleanupRecord(workspace)))
        context.delete(workspace)
        try context.save()

        // Before the retry, the configured spelling now leads elsewhere.
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other.folder)
        #expect(WorkspaceDeletionCleanupService.resumePending(modelContext: context, store: store) == 1)
        #expect(!FileManager.default.fileExists(atPath: original.mirror))
        #expect(FileManager.default.fileExists(atPath: other.mirror))
        #expect(store.pending().isEmpty)
    }

    @Test("A deletion record without its pinned folder or mirror files fails closed", arguments: ["physicalFolder", "mirrorFiles"])
    func legacyDeletionRecordFailsClosed(missingKey: String) throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let container = try Fixture.container()
        let context = container.mainContext
        let store = WorkspaceDeletionCleanupStore(directory: fixture.root.appendingPathComponent("DeletionCleanup"))
        let original = fixture.root.appendingPathComponent("Original", isDirectory: true)
        let other = fixture.root.appendingPathComponent("Other", isDirectory: true)
        let otherMirror = WorkspaceFileLayout.workspaceConfigFile(for: other.path)
        try FileManager.default.createDirectory(atPath: (otherMirror as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "{}".write(toFile: otherMirror, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let link = fixture.root.appendingPathComponent("Link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        // As an earlier build wrote it, without one of the pinned fields.
        let record = WorkspaceDeletionCleanupRecord(workspaceID: UUID(), primaryPath: link.path, connectors: [], skills: [])
        try store.write(record)
        let url = store.recordURL(for: record)
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json.removeValue(forKey: missingKey)
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        // What it would clean can only be derived from today's links.
        #expect(store.pending().isEmpty)
        #expect(store.pendingMirrorPaths() == nil)

        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
        #expect(store.pending().isEmpty)
        #expect(store.pendingMirrorPaths() == nil)
        #expect(WorkspaceDeletionCleanupService.resumePending(modelContext: context, store: store) == 0)
        #expect(FileManager.default.fileExists(atPath: otherMirror))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("A deleted workspace's mirror that a survivor's mirror links to is kept")
    func mirrorLinkedFromSurvivorIsKept() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let container = try Fixture.container()
        let context = container.mainContext
        let store = WorkspaceDeletionCleanupStore(directory: fixture.root.appendingPathComponent("DeletionCleanup"))
        let deletedFolder = fixture.root.appendingPathComponent("Deleted", isDirectory: true)
        let survivorFolder = fixture.root.appendingPathComponent("Survivor", isDirectory: true)
        let deletedMirror = WorkspaceFileLayout.workspaceConfigFile(for: deletedFolder.path)
        let survivorMirror = WorkspaceFileLayout.workspaceConfigFile(for: survivorFolder.path)
        for mirror in [deletedMirror, survivorMirror] {
            try FileManager.default.createDirectory(atPath: (mirror as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        }
        try "{}".write(toFile: deletedMirror, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: survivorMirror, withDestinationPath: deletedMirror)
        let deleted = Workspace(name: "Deleted", primaryPath: deletedFolder.path)
        context.insert(deleted)
        context.insert(Workspace(name: "Survivor", primaryPath: survivorFolder.path))
        try context.save()
        try store.record(WorkspaceDeletionCleanupRecord(deleted))
        context.delete(deleted)
        try context.save()

        #expect(WorkspaceDeletionCleanupService.resumePending(modelContext: context, store: store) == 1)
        #expect(FileManager.default.fileExists(atPath: survivorMirror))
    }

    @Test("A replacement drops mirror writes queued for the workspace it replaces")
    func replacementRetiresQueuedExports() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let container = try Fixture.container()
        let context = container.mainContext
        let workspace = Workspace(name: "App", primaryPath: fixture.storage.path)
        context.insert(workspace)
        try context.save()
        let id = workspace.id.uuidString
        let config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: context))
        let configURL = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: fixture.storage.path))
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(config).write(to: configURL, options: .atomic)
        // An export of the old workspace, snapshotted and queued.
        let queued = WorkspaceAutoExportGate.shared.ticket(for: id)

        let replaced = TaskLifecycleCoordinator(
            modelContext: context, taskQueue: fixture.resourceQueue, worktreeCleanupStore: fixture.cleanupStore,
            persistWorkspaceChange: { _, context in (try? context.save()) != nil }
        ).importFromConfig(at: configURL, existingWorkspaces: [workspace], askDuplicateAction: { _, _ in .replace })
        #expect(replaced != nil)
        #expect(queued.generation != WorkspaceAutoExportGate.shared.ticket(for: id).generation)
    }

    @Test("A pinned mirror whose folder was replaced by a link to another workspace's is left alone")
    func pinnedMirrorBehindReplacedFolderIsSpared() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let container = try Fixture.container()
        let context = container.mainContext
        let store = WorkspaceDeletionCleanupStore(directory: fixture.root.appendingPathComponent("DeletionCleanup"))
        func folderWithMirror(_ name: String) throws -> (folder: URL, mirror: String) {
            let folder = fixture.root.appendingPathComponent(name, isDirectory: true)
            let mirror = WorkspaceFileLayout.workspaceConfigFile(for: folder.path)
            try FileManager.default.createDirectory(atPath: (mirror as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try "{}".write(toFile: mirror, atomically: true, encoding: .utf8)
            return (folder, mirror)
        }
        let deleted = try folderWithMirror("Deleted")
        let survivor = try folderWithMirror("Survivor")
        let workspace = Workspace(name: "Deleted", primaryPath: deleted.folder.path)
        context.insert(workspace)
        context.insert(Workspace(name: "Survivor", primaryPath: survivor.folder.path))
        try context.save()
        try store.record(WorkspaceDeletionCleanupRecord(workspace))
        context.delete(workspace)
        try context.save()

        // The deleted workspace's support folder becomes a link to the survivor's.
        let support = URL(fileURLWithPath: (deleted.mirror as NSString).deletingLastPathComponent)
        try FileManager.default.removeItem(at: support)
        try FileManager.default.createSymbolicLink(
            at: support, withDestinationURL: URL(fileURLWithPath: (survivor.mirror as NSString).deletingLastPathComponent)
        )
        // Recovery still excludes only the pinned mirror, never the survivor's.
        let excluded = try #require(store.pendingMirrorPaths())
        #expect(!excluded.contains(WorkspacePathPresentation.resolvedPath(survivor.mirror)))
        #expect(WorkspaceDeletionCleanupService.resumePending(modelContext: context, store: store) == 1)
        #expect(FileManager.default.fileExists(atPath: survivor.mirror))
        #expect(store.pending().isEmpty)
    }

    @Test("A deleted Outlook connector's mail-registry entry goes unless a live Outlook connector holds its ID")
    func deletedOutlookRegistryEntryNeedsALiveOutlookOwner() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let container = try Fixture.container()
        let context = container.mainContext
        let registry = fixture.root.appendingPathComponent("mail-accounts.json")
        try StanfordOutlookMail.$registryURLOverride.withValue(registry) {
            let outlook = Connector(name: "Mail")
            outlook.applyStanfordOutlookDefaults()
            StanfordOutlookMailRegistry.upsert(connector: outlook)
            let record = WorkspaceDeletionCleanupRecord(
                workspaceID: UUID(), primaryPath: fixture.root.appendingPathComponent("Gone").path,
                connectors: [outlook.keychainCleanup], skills: []
            )
            // An import reused the ID for another service: the entry goes.
            let reused = Connector(name: "Jira", serviceType: "jira")
            reused.id = outlook.id
            context.insert(reused)
            try context.save()
            _ = WorkspaceDeletionCleanupService.settle(record, modelContext: context)
            #expect(StanfordOutlookMailRegistry.entries().isEmpty)

            // A live Outlook connector with that ID keeps it.
            StanfordOutlookMailRegistry.upsert(connector: outlook)
            reused.applyStanfordOutlookDefaults()
            try context.save()
            _ = WorkspaceDeletionCleanupService.settle(record, modelContext: context)
            #expect(StanfordOutlookMailRegistry.entries().map(\.connectorID) == [outlook.id.uuidString])
        }
    }

    @Test("A mirror write queued before a workspace deletion never lands after it")
    func queuedMirrorWriteIsDroppedByDeletion() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let container = try Fixture.container()
        let context = container.mainContext
        let folder = fixture.root.appendingPathComponent("Deleted", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let workspace = Workspace(name: "Deleted", primaryPath: folder.path)
        context.insert(workspace)
        try context.save()
        let id = workspace.id.uuidString
        let mirror = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: folder.path))
        try FileManager.default.createDirectory(at: mirror.deletingLastPathComponent(), withIntermediateDirectories: true)
        // What `autoExport` snapshots and queues before the deletion runs.
        let config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: context))
        let queued = WorkspaceAutoExportGate.shared.ticket(for: id)
        let coordinator = TaskLifecycleCoordinator(
            modelContext: context, taskQueue: fixture.resourceQueue, worktreeCleanupStore: fixture.cleanupStore,
            workspaceDeletionCleanupStore: WorkspaceDeletionCleanupStore(directory: fixture.root.appendingPathComponent("DeletionCleanup"))
        )
        #expect(coordinator.deleteWorkspace(workspace, existingWorkspaces: [workspace]).persisted)
        try? FileManager.default.removeItem(at: mirror)

        await WorkspaceAutoExportWriter.shared.write(config, to: mirror, workspaceID: id, ticket: queued)
        #expect(!FileManager.default.fileExists(atPath: mirror.path))
        // An export taken after the deletion, such as a reimport's, lands.
        await WorkspaceAutoExportWriter.shared.write(
            config, to: mirror, workspaceID: id, ticket: WorkspaceAutoExportGate.shared.ticket(for: id)
        )
        #expect(FileManager.default.fileExists(atPath: mirror.path))
    }

    @Test("A dangling mirror symlink is removed, not taken as already gone")
    func danglingMirrorLinkIsRemoved() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let container = try Fixture.container()
        let context = container.mainContext
        let store = WorkspaceDeletionCleanupStore(directory: fixture.root.appendingPathComponent("DeletionCleanup"))
        let folder = fixture.root.appendingPathComponent("Linked", isDirectory: true)
        let mirror = WorkspaceFileLayout.workspaceConfigFile(for: folder.path)
        try FileManager.default.createDirectory(atPath: (mirror as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: mirror, withDestinationPath: fixture.root.appendingPathComponent("not-there.json").path
        )
        #expect(!FileManager.default.fileExists(atPath: mirror))
        try store.pinMirrorIdentities(for: store.record(WorkspaceDeletionCleanupRecord(workspaceID: UUID(), primaryPath: folder.path, connectors: [], skills: [])))

        #expect(WorkspaceDeletionCleanupService.resumePending(modelContext: context, store: store) == 1)
        #expect((try? FileManager.default.attributesOfItem(atPath: mirror)) == nil)
        #expect(store.pending().isEmpty)
    }

    @Test("A pending deletion removes the mirror it pinned, even after a symlinked .astra folder is retargeted")
    func deletionCleanupPinsMirrorFiles() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let container = try Fixture.container()
        let context = container.mainContext
        let store = WorkspaceDeletionCleanupStore(directory: fixture.root.appendingPathComponent("DeletionCleanup"))
        let folder = fixture.root.appendingPathComponent("Workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let support = URL(fileURLWithPath: (WorkspaceFileLayout.workspaceConfigFile(for: folder.path) as NSString).deletingLastPathComponent)
        let name = (WorkspaceFileLayout.workspaceConfigFile(for: folder.path) as NSString).lastPathComponent
        func supportFolder(_ label: String) throws -> URL {
            let url = fixture.root.appendingPathComponent(label, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try "{}".write(to: url.appendingPathComponent(name), atomically: true, encoding: .utf8)
            return url
        }
        let original = try supportFolder("SupportA")
        let other = try supportFolder("SupportB")
        try FileManager.default.createSymbolicLink(at: support, withDestinationURL: original)
        let workspace = Workspace(name: "Workspace", primaryPath: folder.path)
        context.insert(workspace)
        try context.save()
        try store.pinMirrorIdentities(for: store.record(WorkspaceDeletionCleanupRecord(workspace)))
        context.delete(workspace)
        try context.save()

        // Before the retry, the support folder now leads to another mirror.
        try FileManager.default.removeItem(at: support)
        try FileManager.default.createSymbolicLink(at: support, withDestinationURL: other)
        #expect(WorkspaceDeletionCleanupService.resumePending(modelContext: context, store: store) == 1)
        #expect(!FileManager.default.fileExists(atPath: original.appendingPathComponent(name).path))
        #expect(FileManager.default.fileExists(atPath: other.appendingPathComponent(name).path))
        #expect(store.pending().isEmpty)
    }

    @Test("Branch deletion and the Repository card's branch operations exclude each other")
    func branchDeletionGateExcludesCardOperations() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App").path
        let card = try #require(TaskBranchDeletionGate.beginCardOperation(at: repository))
        #expect(TaskBranchDeletionGate.beginDeletion(at: repository) == nil)
        TaskBranchDeletionGate.endCardOperation(card)
        let deletion = try #require(TaskBranchDeletionGate.beginDeletion(at: repository))
        #expect(TaskBranchDeletionGate.beginCardOperation(at: repository) == nil)
        TaskBranchDeletionGate.endDeletion(deletion)
        let again = try #require(TaskBranchDeletionGate.beginCardOperation(at: repository))
        TaskBranchDeletionGate.endCardOperation(again)
    }

    @Test("A branch deletion's hold is released by the key it took, even after the checkout moves")
    func branchDeletionGateReleasesItsOwnKey() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let original = try fixture.repository("App")
        let deletion = try #require(TaskBranchDeletionGate.beginDeletion(at: original.path))
        // The checkout moves while cleanup holds its repository.
        let moved = fixture.root.appendingPathComponent("App-moved", isDirectory: true)
        try FileManager.default.moveItem(at: original, to: moved)
        TaskBranchDeletionGate.endDeletion(deletion)
        // Put back, the repository is free again.
        try FileManager.default.moveItem(at: moved, to: original)
        let card = try #require(TaskBranchDeletionGate.beginCardOperation(at: original.path))
        TaskBranchDeletionGate.endCardOperation(card)
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
        try store.pinMirrorIdentities(for: store.record(WorkspaceDeletionCleanupRecord(workspace)))
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

    @Test("A workspace deletion saved only up to the cancellation settles its queued task back to draft")
    func unsavedDeletionAfterCancellationSettlesTask() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let container = try Fixture.container()
        let context = container.mainContext
        let workspace = Workspace(name: "App", primaryPath: repository.path)
        context.insert(workspace)
        let task = AgentTask(title: "Queued", goal: "Explore", workspace: workspace)
        context.insert(task)
        TaskStateMachine.enqueueFromChatSubmission(task, modelContext: context)
        let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1, resourceClaims: [])
        context.insert(request)
        try context.save()
        #expect(task.status == .queued)
        // The cancellation is saved; the deletion's own save then fails.
        var saves = 0
        let coordinator = TaskLifecycleCoordinator(
            modelContext: context, taskQueue: fixture.resourceQueue, worktreeCleanupStore: fixture.cleanupStore,
            workspaceDeletionCleanupStore: WorkspaceDeletionCleanupStore(directory: fixture.root.appendingPathComponent("DeletionCleanup")),
            persistWorkspaceChange: { _, context in
                saves += 1
                return saves == 1 && (try? context.save()) != nil
            }
        )

        #expect(!coordinator.deleteWorkspace(workspace, existingWorkspaces: [workspace]).persisted)
        #expect(saves == 2)
        #expect(!task.isDeleted)
        #expect(request.state == .cancelled)
        #expect(task.status == .draft)
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

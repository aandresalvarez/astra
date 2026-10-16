import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

/// State Git keeps for one worktree alone, in its registry entry or its
/// branch's configuration, which a removal deletes and no status or branch
/// check shows: cleanup keeps the worktree while any of it is there.
@MainActor
@Suite("Worktree-only Git state keeps a draft's worktree", .serialized)
struct NewTaskWorktreeOwnStateTests {
    private typealias Fixture = NewTaskWorktreeFixture

    @Test("A registered worktree moved on disk keeps its registration and branch; only ASTRA's own removal prunes it")
    func movedWorktreeKeepsRegistration() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let context = store.mainContext
        let (draft, discard) = try await prepare(repository: repository, context: context, fixture: fixture)
        // Renamed, not deleted: Git still registers the old path.
        let moved = discard.worktreePath + "-moved"
        try FileManager.default.moveItem(atPath: discard.worktreePath, toPath: moved)
        context.delete(draft)
        try context.save()

        #expect(await TaskWorktreeService.discardOutcome(
            discard, modelContext: context, resourceQueue: fixture.resourceQueue, ownership: fixture.ownership
        ) == .kept("worktree_missing"))
        #expect(try fixture.git(["status", "--porcelain"], at: URL(fileURLWithPath: moved)).isEmpty)
        #expect(try !fixture.git(["branch", "--list", discard.branch], at: repository).isEmpty)
    }

    @Test("A cleanup outbox that can't be checked throws rather than listing as empty")
    func uncheckableCleanupOutboxThrows() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let parent = fixture.root.appendingPathComponent("Outbox", isDirectory: true)
        let store = TaskWorktreeCleanupStore(directory: parent.appendingPathComponent("Records"))
        #expect(try store.pendingURLs().isEmpty)
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: parent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path) }
        #expect(throws: (any Error).self) { try store.pendingURLs() }
    }

    @Test("A Git directory whose HEAD can't be checked resolves nothing, never the repository storing it")
    func uncheckableGitDirectoryStopsAncestrySearch() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let stored = repository.appendingPathComponent(".git/modules/lib", isDirectory: true)
        for folder in ["objects", "refs"] {
            try FileManager.default.createDirectory(at: stored.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try "ref: refs/heads/main\n".write(to: stored.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        #expect(GitCheckoutLayout.commonDirectory(for: stored.path).map(WorkspacePathPresentation.resolvedPath)
            == WorkspacePathPresentation.resolvedPath(stored.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: stored.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stored.path) }
        #expect(GitCheckoutLayout.commonDirectory(for: stored.path) == nil)
    }

    @Test("A removal mark or cleanup record that can't be checked is never taken as absent")
    func uncheckableMarksAndRecordsFailClosed() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let (_, discard) = try await prepare(repository: repository, context: store.mainContext, fixture: fixture)
        // A record is created once, then found, and the caller learns which.
        let records = fixture.cleanupStore
        #expect(try records.record(discard))
        #expect(try !records.record(discard))
        try fixture.ownership.markRemoving(discard)
        let ownership = fixture.ownership.directory.path
        let outbox = records.directory.path
        for folder in [ownership, outbox] {
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder)
        }
        defer { for folder in [ownership, outbox] { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder) } }
        #expect(throws: (any Error).self) { try fixture.ownership.clearRemoving(discard) }
        #expect(throws: (any Error).self) { try records.record(discard) }
        for folder in [ownership, outbox] { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder) }
        #expect(fixture.ownership.isRemoving(discard))
        try fixture.ownership.clearRemoving(discard)
        #expect(!fixture.ownership.isRemoving(discard))
        try fixture.ownership.clearRemoving(discard)
    }

    @Test("An ownership record that can't be read keeps the cleanup record for a retry")
    func unreadableOwnershipKeepsCleanupRecord() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let context = store.mainContext
        let (draft, discard) = try await prepare(repository: repository, context: context, fixture: fixture)
        #expect(fixture.ownership.ownershipState(discard) == .owned)
        let ownership = fixture.ownership.directory.path
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: ownership)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ownership) }
        #expect(fixture.ownership.ownershipState(discard) == .unreadable)
        // A deletion taken now still queues the worktree, so cleanup can retry.
        #expect(TaskWorktreeService.discardSnapshots(for: draft, ownership: fixture.ownership).map(\.worktreePath)
            == [discard.worktreePath])
        try fixture.cleanupStore.record(discard)
        context.delete(draft)
        try context.save()
        // Unknown, never foreign: nothing is removed and nothing is dropped.
        #expect(!(await TaskWorktreeCleanupService.process(
            discard, store: fixture.cleanupStore, modelContext: context, resourceQueue: fixture.resourceQueue
        )))
        #expect(try fixture.cleanupStore.pendingURLs().count == 1)
        #expect(FileManager.default.fileExists(atPath: discard.worktreePath))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ownership)
        #expect(fixture.ownership.ownershipState(discard) == .owned)
    }

    @Test("A linked checkout whose commondir can't be read resolves no shared directory, so no gate key")
    func unreadableCommondirResolvesNothing() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let linked = fixture.root.appendingPathComponent("App-linked", isDirectory: true)
        try fixture.git(["worktree", "add", "--quiet", "--detach", linked.path, "HEAD"], at: repository)
        #expect(GitCheckoutLayout.commonDirectory(for: linked.path).map(WorkspacePathPresentation.resolvedPath)
            == WorkspacePathPresentation.resolvedPath(repository.appendingPathComponent(".git").path))
        let entries = try FileManager.default.contentsOfDirectory(
            at: repository.appendingPathComponent(".git/worktrees"), includingPropertiesForKeys: nil
        )
        let commondir = try #require(entries.first).appendingPathComponent("commondir").path
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: commondir)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: commondir) }
        #expect(GitCheckoutLayout.commonDirectory(for: linked.path) == nil)
        #expect(TaskBranchDeletionGate.beginCardOperation(at: linked.path) == nil)
        #expect(TaskBranchDeletionGate.beginDeletion(at: linked.path) == nil)
    }

    @Test("A checkout whose shared Git directory can't be resolved gets no branch gate, on either side")
    func unresolvableRepositoryHasNoGate() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let broken = fixture.root.appendingPathComponent("Broken", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        // A linked checkout's `.git` file that can't be read for the moment.
        let dotGit = broken.appendingPathComponent(".git")
        try "gitdir: /tmp/astra-gate-test/.git/worktrees/broken".write(to: dotGit, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dotGit.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dotGit.path) }
        #expect(GitCheckoutLayout.commonDirectory(for: broken.path) == nil)
        #expect(TaskBranchDeletionGate.beginCardOperation(at: broken.path) == nil)
        #expect(TaskBranchDeletionGate.beginDeletion(at: broken.path) == nil)
        // A folder confirmed not to be a checkout keys by its own path.
        let plain = fixture.root.appendingPathComponent("Plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let token = try #require(TaskBranchDeletionGate.beginCardOperation(at: plain.path))
        TaskBranchDeletionGate.endCardOperation(token)
    }

    @Test("Resolve-undo entries a resolved conflict left in the index count as local work")
    func resolveUndoEntriesCount() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let identity = ["-c", "user.name=ASTRA Tests", "-c", "user.email=astra-tests@example.invalid", "-c", "commit.gpgsign=false"]
        #expect(await GitService.shared.indexHiddenEntriesChanged(at: repository.path) == false)
        try fixture.git(identity + ["checkout", "--quiet", "-b", "side"], at: repository)
        try fixture.commit("conflict.txt", contents: "side", message: "Side", at: repository)
        try fixture.git(identity + ["checkout", "--quiet", "main"], at: repository)
        try fixture.commit("conflict.txt", contents: "main", message: "Main", at: repository)
        _ = try? fixture.git(identity + ["merge", "--quiet", "side"], at: repository)
        // Resolved back to HEAD and the merge forgotten: status is clean,
        // but the index keeps the conflict's stages for `--unresolve`.
        try fixture.git(["checkout", "--quiet", "--ours", "conflict.txt"], at: repository)
        try fixture.git(["add", "conflict.txt"], at: repository)
        try fixture.git(["merge", "--quit"], at: repository)
        #expect(try fixture.git(["status", "--porcelain"], at: repository).isEmpty)
        #expect(try !fixture.git(["ls-files", "--resolve-undo"], at: repository).isEmpty)
        #expect(await GitService.shared.indexHiddenEntriesChanged(at: repository.path))
    }

    @Test("A removal mark that can't be read is retried, never taken as unmarked")
    func unreadableRemovalMarkIsRetried() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let context = store.mainContext
        let (draft, discard) = try await prepare(repository: repository, context: context, fixture: fixture)
        context.delete(draft)
        try context.save()
        try fixture.ownership.markRemoving(discard)
        #expect(fixture.ownership.removalState(discard) == .marked)
        // The mark is written before Git removes anything, so a folder gone
        // while Git still registers it is kept even though it is marked: it
        // may have been moved after a quit, not removed.
        let moved = discard.worktreePath + "-moved"
        try FileManager.default.moveItem(atPath: discard.worktreePath, toPath: moved)
        #expect(await TaskWorktreeService.discardOutcome(
            discard, modelContext: context, resourceQueue: fixture.resourceQueue, ownership: fixture.ownership
        ) == .kept("worktree_missing"))
        #expect(try fixture.git(["status", "--porcelain"], at: URL(fileURLWithPath: moved)).isEmpty)
        // Once Git's entry is gone, the resumed branch phase reads the mark;
        // one it can't read is retried, never taken as unmarked.
        try FileManager.default.moveItem(atPath: moved, toPath: discard.worktreePath)
        try fixture.git(["worktree", "remove", "--force", discard.worktreePath], at: repository)
        let ownership = fixture.ownership.directory.path
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: ownership)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ownership) }
        #expect(fixture.ownership.removalState(discard) == .unreadable)
        #expect(await TaskWorktreeService.discardOutcome(
            discard, modelContext: context, resourceQueue: fixture.resourceQueue, ownership: fixture.ownership
        ) == .retry("removal_mark_unreadable"))
        #expect(try !fixture.git(["branch", "--list", discard.branch], at: repository).isEmpty)
    }

    @Test("A recreated worktree verifies against Git's identity even when an older incarnation sorts first")
    func olderSamePathIncarnationIsPassedOver() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let context = store.mainContext
        let (draft, _) = try await prepare(repository: repository, context: context, fixture: fixture)
        let current = try #require(draft.events.first { $0.hasType(TaskEventTypes.Task.worktreePrepared) })
        guard case .bound = TaskWorktreeBinding.state(of: draft) else {
            Issue.record("Expected the draft to be bound")
            return
        }
        // Another incarnation at the same path, with an identity Git no
        // longer registers, ordered first, as tied whole-second timestamps
        // from a mirror can leave it.
        var fields = try #require(try JSONSerialization.jsonObject(with: Data(current.payload.utf8)) as? [String: Any])
        #expect(fields["identity"] != nil)
        fields["identity"] = UUID().uuidString
        let stale = String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
        let older = TaskEvent(task: draft, eventType: TaskEventTypes.Task.worktreePrepared, payload: stale)
        older.timestamp = current.timestamp.addingTimeInterval(1)
        context.insert(older)
        guard case .bound(_, let event, _) = TaskWorktreeBinding.state(of: draft) else {
            Issue.record("The incarnation Git registers must still bind")
            return
        }
        #expect(event.id == current.id)
        // Deleting the draft queues the incarnation this install owns, not
        // nothing because the newer one at its path isn't owned.
        #expect(TaskWorktreeService.discardSnapshots(for: draft, ownership: fixture.ownership).map(\.identity)
            == [identity(of: current)])
        // While ownership can't be read, neither takes the path: both are
        // queued, and the deletion stops rather than recording either alone.
        let ownership = fixture.ownership.directory.path
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: ownership)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ownership) }
        let unknown = TaskWorktreeService.discardSnapshots(for: draft, ownership: fixture.ownership)
        #expect(Set(unknown.map(\.identity)) == [identity(of: current), fields["identity"] as? String])
        #expect(throws: (any Error).self) { for discard in unknown { try fixture.cleanupStore.record(discard) } }
    }

    private func identity(of event: TaskEvent) -> String? {
        guard case .success(let payload) = event.decodePayload(as: TaskWorktreePayload.self) else { return nil }
        return payload.identity
    }

    @Test("A failed adoption leaves a reserved prior checkout unpinned in memory and after saving", arguments: [false, true])
    func failedAdoptionClearsPinWhenPreviousIsReserved(onDisk: Bool) async throws {
        try await checkFailedAdoption(onDisk: onDisk, reservePreviousCheckout: true)
    }

    @Test("A failed adoption restores an available prior checkout without leaving adoption changes pending", arguments: [false, true])
    func failedAdoptionRestoresAvailablePin(onDisk: Bool) async throws {
        try await checkFailedAdoption(onDisk: onDisk, reservePreviousCheckout: false)
    }

    private func checkFailedAdoption(onDisk: Bool, reservePreviousCheckout: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let other = fixture.root.appendingPathComponent("App-other", isDirectory: true)
        try fixture.git(["worktree", "add", "--quiet", "-b", "other", other.path], at: repository)
        let store = try onDisk
            ? ModelContainer(for: ASTRASchema.current, configurations: [ModelConfiguration(url: fixture.root.appendingPathComponent("default.store"))])
            : Fixture.container()
        let context = ModelContext(store)
        context.autosaveEnabled = false
        let (task, _) = try await prepare(repository: repository, context: context, fixture: fixture)
        let worktree = try #require(task.executionRootPath)
        let draft = AgentTask(title: "Chat", goal: "Explore", workspace: task.workspace)
        draft.executionRootPath = other.path
        draft.isolationStrategy = .copy
        context.insert(draft)
        try context.save()
        TaskStateMachine.enqueueFromChatSubmission(task, modelContext: context)
        var reservation: TaskWorktreeCheckoutReservation.Token?
        defer { reservation.map(TaskWorktreeCheckoutReservation.release) }
        #expect(throws: TaskWorktreeCreationError.self) {
            _ = try TaskWorktreeService.recoverFailedSubmission(
                task: task, existingDraft: draft, modelContext: context,
                persist: { _, _, _ in
                    if reservePreviousCheckout {
                        // Cleanup reserves the draft's earlier checkout meanwhile.
                        reservation = TaskWorktreeCheckoutReservation.acquire(other.path)
                    }
                    throw CocoaError(.fileWriteNoPermission)
                }
            )
        }
        #expect((reservation != nil) == reservePreviousCheckout)
        let expectedPin: String? = reservePreviousCheckout ? nil : other.path
        #expect(draft.executionRootPath != worktree)
        #expect(draft.executionRootPath == expectedPin)
        #expect(draft.isolationStrategy == .copy)
        #expect(TaskWorktreeBinding.eventForInheritance(from: draft) == nil)
        #expect(!task.isDeleted)
        #expect(task.executionRootPath == worktree)
        // Clearing a newly reserved checkout is a new durable correction,
        // not part of the discarded adoption. A cached nil without a pending
        // update silently keeps the old path in the store on macOS 26.
        #expect(context.hasChanges == reservePreviousCheckout)
        let beforeSave = try #require(try ModelContext(store).fetch(FetchDescriptor<AgentTask>()).first { $0.id == draft.id })
        #expect(beforeSave.executionRootPath == other.path)
        // Force an unrelated save too, so the assertion cannot succeed just
        // because SwiftData skips saving a context it thinks is unchanged.
        let workspace = try #require(task.workspace)
        workspace.name = "Saved after failed adoption"
        try context.save()
        #expect(!context.hasChanges)
        let durable = try #require(try ModelContext(store).fetch(FetchDescriptor<AgentTask>()).first { $0.id == draft.id })
        #expect(durable.executionRootPath == expectedPin)
        #expect(durable.isolationStrategy == .copy)
        #expect(TaskWorktreeBinding.eventForInheritance(from: durable) == nil)
        #expect(durable.workspace?.name == workspace.name)
        let durableTask = try #require(try ModelContext(store).fetch(FetchDescriptor<AgentTask>()).first { $0.id == task.id })
        #expect(durableTask.executionRootPath == worktree)
        #expect(TaskWorktreeService.activeWorktreeBinding(for: durableTask)?.worktreePath == worktree)
    }

    @Test("A derived task isn't created onto another checkout when its source's is reserved")
    func reservedSourceCheckoutRefusesInheritance() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let context = store.mainContext
        let (draft, discard) = try await prepare(repository: repository, context: context, fixture: fixture)
        let child = AgentTask(title: "Follow-up", goal: "Continue", workspace: draft.workspace)
        let reservation = try #require(TaskWorktreeCheckoutReservation.acquire(discard.worktreePath))
        defer { TaskWorktreeCheckoutReservation.release(reservation) }
        guard case .refused = TaskWorktreeBinding.inheritCheckout(from: draft, into: child) else {
            Issue.record("A reserved checkout must refuse inheritance")
            return
        }
        #expect(child.executionRootPath != discard.worktreePath)
        // A fork isn't created either: it would carry the source's binding
        // onto no checkout.
        let run = TaskRun(task: draft)
        run.status = .completed
        context.insert(run)
        let taskCount = try context.fetchCount(FetchDescriptor<AgentTask>())
        #expect(throws: AgentTaskForkError.sourceCheckoutReserved) {
            try AgentTaskForkService.fork(from: draft, upToRun: run, in: context)
        }
        #expect(try context.fetchCount(FetchDescriptor<AgentTask>()) == taskCount)
        // Both derived-task paths stop on a refusal rather than continuing.
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for file in ["Astra/Services/Tasks/ChainedTaskSubmissionService.swift", "Astra/Services/Validation/TaskCorrectiveWorkService.swift"] {
            let source = try String(contentsOf: base.appendingPathComponent(file), encoding: .utf8)
            #expect(source.contains("guard case .inherited(let inheritedBinding) = TaskWorktreeBinding.inheritCheckout("))
            #expect(!source.contains("TaskWorktreeBinding.inheritPin("))
        }
    }

    @Test("With file modes ignored, an executable-bit edit still counts as local work")
    func modeOnlyEditCountsWithFileModeOff() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        try fixture.git(["config", "core.fileMode", "false"], at: repository)
        #expect(await GitService.shared.indexHiddenEntriesChanged(at: repository.path) == false)
        let file = try #require(try fixture.git(["ls-files"], at: repository).split(whereSeparator: \.isNewline).first.map(String.init))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repository.appendingPathComponent(file).path)
        #expect(try fixture.git(["status", "--porcelain"], at: repository).isEmpty)
        #expect(await GitService.shared.indexHiddenEntriesChanged(at: repository.path))
    }

    @Test("A stored submodule repository whose HEAD is a dangling link is still a repository")
    func danglingHeadStoredRepositoryCounts() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let modules = fixture.root.appendingPathComponent("modules", isDirectory: true)
        let stored = modules.appendingPathComponent("lib", isDirectory: true)
        for folder in ["objects", "refs", "logs"] {
            try FileManager.default.createDirectory(at: stored.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        // A reflog's HEAD alone, without objects, isn't a repository.
        try "".write(to: stored.appendingPathComponent("logs/HEAD"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            atPath: stored.appendingPathComponent("HEAD").path, withDestinationPath: fixture.root.appendingPathComponent("gone").path
        )
        #expect(try GitService.storedSubmoduleRepositories(in: modules) == [GitService.repositoryKey(stored.path)])
    }

    @Test("An auto-export lands only for a current ticket, and a retired one leaves no file behind")
    func autoExportGateWritesOnlyCurrentTickets() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let gate = WorkspaceAutoExportGate()
        let folder = fixture.root.appendingPathComponent("Mirror", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let mirror = folder.appendingPathComponent(".astra-workspace.json")
        let current = gate.ticket(for: "ws")
        #expect(try gate.writeIfCurrent(current, data: Data("one".utf8), to: mirror))
        #expect(try Data(contentsOf: mirror) == Data("one".utf8))
        let stale = gate.ticket(for: "ws")
        gate.retire(workspaceID: "ws")
        #expect(try !gate.writeIfCurrent(stale, data: Data("two".utf8), to: mirror))
        #expect(try Data(contentsOf: mirror) == Data("one".utf8))
        // The bytes are staged beside the mirror and never left there.
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [".astra-workspace.json"])
    }

    @Test("A Repository-card branch operation in flight keeps cleanup from removing the worktree at all")
    func cardOperationBlocksWorktreeRemoval() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let context = store.mainContext
        let (draft, discard) = try await prepare(repository: repository, context: context, fixture: fixture)
        context.delete(draft)
        try context.save()
        // The card may switch this folder's branch after cleanup's checks, so
        // nothing is removed while it holds the repository.
        let card = try #require(TaskBranchDeletionGate.beginCardOperation(at: repository.path))
        #expect(await TaskWorktreeService.discardOutcome(
            discard, modelContext: context, resourceQueue: fixture.resourceQueue, ownership: fixture.ownership
        ) == .retry("repository_busy"))
        #expect(FileManager.default.fileExists(atPath: discard.worktreePath))
        TaskBranchDeletionGate.endCardOperation(card)
        #expect(await TaskWorktreeService.discardOutcome(
            discard, modelContext: context, resourceQueue: fixture.resourceQueue, ownership: fixture.ownership
        ) == .removed)
    }

    @Test("Deleting a task branch turned into a symbolic ref deletes only that ref, never its target")
    func symbolicTaskRefDeletionKeepsTarget() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let main = try fixture.git(["rev-parse", "HEAD"], at: repository).trimmingCharacters(in: .whitespacesAndNewlines)
        try fixture.git(["symbolic-ref", "refs/heads/astra/linked-0badc0de", "refs/heads/main"], at: repository)
        try await GitService.shared.deleteLocalBranch("astra/linked-0badc0de", ifAt: main, at: repository.path)
        #expect(try fixture.git(["rev-parse", "--verify", "-q", "refs/heads/main"], at: repository)
            .trimmingCharacters(in: .whitespacesAndNewlines) == main)
        #expect(try fixture.git(["for-each-ref", "refs/heads/astra"], at: repository).isEmpty)
    }

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

    @Test("A creation marker that can't even be checked is unreadable, never absent")
    func uncheckableMarkerIsUnreadable() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let checkout = fixture.root.appendingPathComponent("Plain", isDirectory: true)
        try fixture.git(["worktree", "add", "--quiet", "--detach", checkout.path, "HEAD"], at: repository)
        // Neither marker is there: absent, unless they can't be checked.
        let missing = try #require(TaskWorktreeBinding.registeredMarkers(repositoryPath: repository.path, worktreePath: checkout.path))
        #expect(!missing.unreadable)
        let uncheckable = try #require(TaskWorktreeBinding.registeredMarkers(
            repositoryPath: repository.path, worktreePath: checkout.path,
            attributes: { _ in throw CocoaError(.fileReadNoPermission) }
        ))
        #expect(uncheckable.unreadable)
        #expect(uncheckable.lockReason == nil)
    }

    @Test("A worktree folder that can't be checked is retried, never taken as gone")
    func uncheckableWorktreeFolderIsRetried() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let context = store.mainContext
        let (draft, discard) = try await prepare(repository: repository, context: context, fixture: fixture)
        context.delete(draft)
        try context.save()
        let parent = (discard.worktreePath as NSString).deletingLastPathComponent
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: parent)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent) }
        #expect(await TaskWorktreeService.discardOutcome(
            discard, modelContext: context, resourceQueue: fixture.resourceQueue, ownership: fixture.ownership
        ) == .retry("worktree_unavailable"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent)
        #expect(FileManager.default.fileExists(atPath: discard.worktreePath))
    }

    @Test("Per-worktree configuration that can't be checked counts; only a missing file is absent")
    func unreadableWorktreeConfigCounts() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let (_, discard) = try await prepare(repository: repository, context: store.mainContext, fixture: fixture)
        func check(_ error: (any Error)?) -> Bool? {
            TaskWorktreeBinding.registeredWorktreeHasLocalConfig(
                repositoryPath: repository.path, worktreePath: discard.worktreePath,
                attributes: { path in
                    if let error { throw error }
                    return try FileManager.default.attributesOfItem(atPath: path)
                }
            )
        }
        #expect(check(nil) == false)
        #expect(check(CocoaError(.fileReadNoSuchFile)) == false)
        #expect(check(CocoaError(.fileReadNoPermission)) == true)
        #expect(check(NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))) == true)
    }

    @Test("State Git keeps for the worktree alone keeps an otherwise untouched worktree",
          arguments: ["merge", "squash", "fetch", "origHead"])
    func worktreeOwnStateKeepsWorktree(operation: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let context = store.mainContext
        let (draft, discard) = try await prepare(repository: repository, context: context, fixture: fixture)
        let checkout = URL(fileURLWithPath: discard.worktreePath)
        let identity = ["-c", "user.name=ASTRA Tests", "-c", "user.email=astra-tests@example.invalid", "-c", "commit.gpgsign=false"]
        // A divergent commit with the same tree: merging or squashing it
        // changes nothing the status or the branch shows, and a fetch of it
        // names it only in `FETCH_HEAD`.
        let side = try fixture.git(identity + ["commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "Side"], at: checkout)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch operation {
        case "merge": try fixture.git(identity + ["merge", "--quiet", "--no-commit", "--no-ff", side], at: checkout)
        case "squash": try fixture.git(identity + ["merge", "--quiet", "--squash", side], at: checkout)
        // `git worktree add` leaves it at the base; moved, it may be the
        // only name for a commit.
        case "origHead": try fixture.git(["update-ref", "ORIG_HEAD", side], at: checkout)
        default:
            try fixture.git(["update-ref", "refs/heads/side", side], at: repository)
            try fixture.git(["fetch", "--quiet", repository.path, "side"], at: checkout)
            try fixture.git(["update-ref", "-d", "refs/heads/side"], at: repository)
        }
        #expect(try fixture.git(["status", "--porcelain"], at: checkout).isEmpty)
        context.delete(draft)
        try context.save()

        #expect(await TaskWorktreeService.discardOutcome(
            discard, modelContext: context, resourceQueue: fixture.resourceQueue, ownership: fixture.ownership
        ) == .kept("worktree_state"))
        #expect(FileManager.default.fileExists(atPath: discard.worktreePath))

        guard operation == "merge" else { return }
        try fixture.git(["merge", "--abort"], at: checkout)
        #expect(await TaskWorktreeService.discardOutcome(
            discard, modelContext: context, resourceQueue: fixture.resourceQueue, ownership: fixture.ownership
        ) == .removed)
    }

    @Test("Branch configuration the user added keeps an otherwise untouched worktree and its branch")
    func branchConfigurationKeepsWorktree() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let context = store.mainContext
        let (draft, discard) = try await prepare(repository: repository, context: context, fixture: fixture)
        // A fresh task branch carries no configuration.
        #expect(await GitService.shared.branchHasConfiguration(discard.branch, at: repository.path) == false)
        try fixture.git(["config", "branch.\(discard.branch).description", "Keep this"], at: repository)
        context.delete(draft)
        try context.save()

        #expect(await TaskWorktreeService.discardOutcome(
            discard, modelContext: context, resourceQueue: fixture.resourceQueue, ownership: fixture.ownership
        ) == .kept("branch_config"))
        #expect(try !fixture.git(["branch", "--list", discard.branch], at: repository).isEmpty)

        try fixture.git(["config", "--unset", "branch.\(discard.branch).description"], at: repository)
        #expect(await TaskWorktreeService.discardOutcome(
            discard, modelContext: context, resourceQueue: fixture.resourceQueue, ownership: fixture.ownership
        ) == .removed)
    }

    @Test("A per-worktree ref keeps an otherwise untouched worktree")
    func worktreeRefKeepsWorktree() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let context = store.mainContext
        let (draft, discard) = try await prepare(repository: repository, context: context, fixture: fixture)
        let checkout = URL(fileURLWithPath: discard.worktreePath)
        // Git keeps it in the registry entry a removal deletes, and no status,
        // branch tip, or checked reflog shows it.
        try fixture.git(["update-ref", "refs/worktree/keep", "HEAD"], at: checkout)
        context.delete(draft)
        try context.save()

        #expect(await TaskWorktreeService.discardOutcome(
            discard, modelContext: context, resourceQueue: fixture.resourceQueue, ownership: fixture.ownership
        ) == .kept("worktree_refs"))
        #expect(FileManager.default.fileExists(atPath: discard.worktreePath))

        // Deleted again, it leaves only empty folders, and the worktree goes.
        try fixture.git(["update-ref", "-d", "refs/worktree/keep"], at: checkout)
        #expect(await TaskWorktreeService.discardOutcome(
            discard, modelContext: context, resourceQueue: fixture.resourceQueue, ownership: fixture.ownership
        ) == .removed)
        #expect(!FileManager.default.fileExists(atPath: discard.worktreePath))
    }

    @Test("An SSH file a rejected replacement can't put back is kept beside it, never applied")
    func unrestorableSSHFileIsKeptBesideIt() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let container = try Fixture.container()
        let context = container.mainContext
        let workspace = Workspace(name: "App", primaryPath: fixture.storage.path)
        context.insert(workspace)
        try context.save()
        SSHConnectionManager.save(
            [SSHConnection(name: "original", host: "original-host", user: "me", keyPath: "", configAlias: "original")],
            workspacePath: fixture.storage.path
        )
        let sshFile = SSHConnectionManager.connectionsFilePath(for: fixture.storage.path)
        let originalData = try Data(contentsOf: URL(fileURLWithPath: sshFile))
        let config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: context))
        let configURL = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: fixture.storage.path))
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(config).write(to: configURL, options: .atomic)
        // The save fails, and by then nothing can be written at the file's
        // path: a folder with contents sits there.
        let coordinator = TaskLifecycleCoordinator(
            modelContext: context, taskQueue: fixture.resourceQueue, worktreeCleanupStore: fixture.cleanupStore,
            persistWorkspaceChange: { _, _ in
                try? FileManager.default.removeItem(atPath: sshFile)
                try? FileManager.default.createDirectory(atPath: sshFile, withIntermediateDirectories: true)
                try? Data("x".utf8).write(to: URL(fileURLWithPath: sshFile).appendingPathComponent("blocker"))
                return false
            }
        )

        #expect(coordinator.importFromConfig(
            at: configURL, existingWorkspaces: [workspace], askDuplicateAction: { _, _ in .replace }
        ) == nil)
        let support = (sshFile as NSString).deletingLastPathComponent
        let name = (sshFile as NSString).lastPathComponent
        let copies = try FileManager.default.contentsOfDirectory(atPath: support).filter { $0.hasPrefix(name + ".unrestored-") }
        #expect(copies.count == 1)
        let copy = try #require(copies.first)
        #expect(try Data(contentsOf: URL(fileURLWithPath: support).appendingPathComponent(copy)) == originalData)
        // Kept, not loaded: the connections file is still what blocked it.
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: sshFile, isDirectory: &isDirectory) && isDirectory.boolValue)

        // A link is kept as a link to the same place; no file means nothing to keep.
        let target = fixture.root.appendingPathComponent("managed-ssh.json").path
        let linkCopy = try #require(try SSHConnectionManager.preserveUnrestored(
            .link(destination: target), workspacePath: fixture.storage.path, now: Date(timeIntervalSince1970: 0)
        ))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: linkCopy) == target)
        #expect(try SSHConnectionManager.preserveUnrestored(.absent, workspacePath: fixture.storage.path) == nil)
    }

    @Test("A reftable probe that fails counts as the worktree's own refs")
    func failedReftableProbeCountsAsOwnRefs() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let (_, discard) = try await prepare(repository: repository, context: store.mainContext, fixture: fixture)
        // Neither a table nor a refs folder: nothing of its own.
        #expect(TaskWorktreeBinding.registeredWorktreeHasOwnRefs(
            repositoryPath: discard.repositoryPath, worktreePath: discard.worktreePath
        ) == false)
        // A table that can't be checked may hold them.
        #expect(TaskWorktreeBinding.registeredWorktreeHasOwnRefs(
            repositoryPath: discard.repositoryPath, worktreePath: discard.worktreePath,
            attributes: { path in
                if (path as NSString).lastPathComponent == "reftable" { throw CocoaError(.fileReadNoPermission) }
                return try FileManager.default.attributesOfItem(atPath: path)
            }
        ) == true)
    }

    @Test("A newest worktree request that can't be read turns creation off until a newer choice")
    func unreadableNewestRequestTurnsCreationOff() throws {
        let store = try Fixture.container()
        let context = store.mainContext
        let workspace = Workspace(name: "App", primaryPath: "/repos/app")
        context.insert(workspace)
        let draft = AgentTask(title: "Draft", goal: "Explore", workspace: workspace)
        context.insert(draft)
        var selection = NewTaskWorktreeSelection()
        selection.repositories = [GitRepositoryInfo(name: "App", path: "/repos/app")]
        selection.repositoryPath = "/repos/app"
        selection.isEnabled = true
        selection.base = .currentBranch
        NewTaskWorktreeComposerFlow.recordChoice(selection, on: draft, modelContext: context)
        let readable = try #require(draft.events.first { $0.hasType(TaskEventTypes.Task.worktreeRequested) })
        readable.timestamp = Date(timeIntervalSince1970: 1_000)
        // An older damaged request changes nothing.
        let damaged = TaskEvent(task: draft, eventType: TaskEventTypes.Task.worktreeRequested, payload: "{")
        damaged.timestamp = Date(timeIntervalSince1970: 500)
        context.insert(damaged)
        #expect(TaskWorktreeService.latestRequest(for: draft)?.enabled == true)
        #expect(NewTaskWorktreeComposerFlow.launchRequest(selection, recordedOn: draft) != nil)

        // A newer one may have turned it off: the earlier choice isn't used.
        damaged.timestamp = Date(timeIntervalSince1970: 2_000)
        #expect(TaskWorktreeService.latestRequest(for: draft) == TaskWorktreeRequestPayload(enabled: false, base: .currentBranch))
        #expect(selection.request != nil)
        #expect(NewTaskWorktreeComposerFlow.launchRequest(selection, recordedOn: draft) == nil)
        var reopened = NewTaskWorktreeSelection()
        reopened.isEnabled = true
        NewTaskWorktreeComposerFlow.restoreChoice(&reopened, from: draft)
        #expect(!reopened.isEnabled)

        // Choosing again records a newer request, which wins.
        NewTaskWorktreeComposerFlow.recordChoice(selection, on: draft, modelContext: context)
        #expect(TaskWorktreeService.latestRequest(for: draft)?.enabled == true)
    }

    @Test("Recovery probes every folder a mirror was written into, even outside the scanned roots")
    func recoveryProbesRegisteredMirrorFolders() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        // The registry lives beside an on-disk store, never in App Support,
        // and an in-memory store has none.
        let memory = try Fixture.container()
        #expect(WorkspaceMirrorRegistry(for: memory.mainContext) == nil)
        let storeURL = fixture.root.appendingPathComponent("Store/default.store")
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let disk = try ModelContainer(for: ASTRASchema.current, configurations: [ModelConfiguration(url: storeURL)])
        let registry = try #require(WorkspaceMirrorRegistry(for: disk.mainContext))
        #expect(registry.directory.deletingLastPathComponent().standardizedFileURL.path
            == storeURL.deletingLastPathComponent().standardizedFileURL.path)

        // Exporting a workspace's mirror records its folder.
        let imported = fixture.root.appendingPathComponent("Elsewhere/Imported", isDirectory: true)
        try FileManager.default.createDirectory(at: imported, withIntermediateDirectories: true)
        let workspace = Workspace(name: "Imported", primaryPath: imported.path)
        disk.mainContext.insert(workspace)
        try disk.mainContext.save()
        WorkspaceConfigManager.autoExport(workspace: workspace, modelContext: disk.mainContext)
        #expect(registry.folders() == [WorkspacePathPresentation.resolvedPath(imported.path)])
        try WorkspaceConfigManager.exportToFile(
            workspace: workspace, modelContext: disk.mainContext,
            url: URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: imported.path))
        )

        // After the store is lost, a scan of an unrelated root finds nothing,
        // but the registered folder's mirror is recovered.
        let emptyRoot = fixture.root.appendingPathComponent("Workspaces", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        let lost = try Fixture.container()
        let trusted = await WorkspaceRecoveryService.recoverMissingWorkspacesAfterLaunch(
            modelContext: lost.mainContext, extraRoots: [emptyRoot.path], includeDefaultRoots: false,
            registeredFolders: registry.folders()
        ).value
        #expect(trusted)
        #expect(try lost.mainContext.fetch(FetchDescriptor<Workspace>()).map(\.name) == ["Imported"])

        // A registry that can't be read leaves recovery untrusted.
        let unread = try Fixture.container()
        #expect(await !WorkspaceRecoveryService.recoverMissingWorkspacesAfterLaunch(
            modelContext: unread.mainContext, extraRoots: [emptyRoot.path], includeDefaultRoots: false,
            registeredFolders: nil
        ).value)
        try Data([0xFF]).write(to: registry.directory.appendingPathComponent("broken.folder"))
        #expect(registry.folders() == nil)
        withExtendedLifetime((memory, disk, lost, unread)) {}
    }

    @Test("A mirror folder is registered by the folder it reaches, and one that can't be registered gets no mirror")
    func mirrorRegistrationIsPhysicalAndFailsClosed() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let registry = WorkspaceMirrorRegistry(directory: fixture.root.appendingPathComponent("Registry", isDirectory: true))
        let real = fixture.root.appendingPathComponent("Real", isDirectory: true)
        let other = fixture.root.appendingPathComponent("Other", isDirectory: true)
        for folder in [real, other] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let link = fixture.root.appendingPathComponent("Link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(registry.register([link.path]))
        // Retargeted later, the link no longer leads to the mirror's folder.
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
        #expect(registry.folders() == [WorkspacePathPresentation.resolvedPath(real.path)])

        // Through autoExport: a registry that can't be written stops the mirror.
        let storeURL = fixture.root.appendingPathComponent("Store/default.store")
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let disk = try ModelContainer(for: ASTRASchema.current, configurations: [ModelConfiguration(url: storeURL)])
        let context = disk.mainContext
        let stored = try #require(WorkspaceMirrorRegistry(for: context))
        try FileManager.default.createDirectory(at: stored.directory, withIntermediateDirectories: true)
        let blocked = Workspace(name: "Blocked", primaryPath: fixture.root.appendingPathComponent("Blocked").path)
        let allowed = Workspace(name: "Allowed", primaryPath: fixture.root.appendingPathComponent("Allowed").path)
        for workspace in [blocked, allowed] {
            try FileManager.default.createDirectory(atPath: workspace.primaryPath, withIntermediateDirectories: true)
            context.insert(workspace)
        }
        try context.save()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: stored.directory.path)
        WorkspaceConfigManager.autoExport(workspace: blocked, modelContext: context)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stored.directory.path)
        WorkspaceConfigManager.autoExport(workspace: allowed, modelContext: context)
        let allowedMirror = WorkspaceFileLayout.workspaceConfigFile(for: allowed.primaryPath)
        var polls = 0
        while !FileManager.default.fileExists(atPath: allowedMirror), polls < 500 {
            polls += 1
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(FileManager.default.fileExists(atPath: allowedMirror))
        #expect(!FileManager.default.fileExists(atPath: WorkspaceFileLayout.workspaceConfigFile(for: blocked.primaryPath)))
        #expect(stored.folders() == [WorkspacePathPresentation.resolvedPath(allowed.primaryPath)])
        withExtendedLifetime(disk) {}
    }

    @Test("Recovery keeps the newest of a workspace's mirrors, and isn't trusted when two can't be told apart")
    func duplicateMirrorsPickNewestOrStayUntrusted() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let source = try Fixture.container()
        let workspace = Workspace(name: "Current", primaryPath: fixture.root.appendingPathComponent("New").path)
        source.mainContext.insert(workspace)
        try source.mainContext.save()
        let config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: source.mainContext))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        func write(_ config: WorkspaceConfigManager.WorkspaceConfig, to name: String) throws -> String {
            let folder = fixture.root.appendingPathComponent(name, isDirectory: true)
            let mirror = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: folder.path))
            try FileManager.default.createDirectory(at: mirror.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(config).write(to: mirror)
            return folder.path
        }
        var stale = config
        stale.name = "Stale"
        stale.exportedAt = config.exportedAt.addingTimeInterval(-3600)
        let emptyRoot = fixture.root.appendingPathComponent("Workspaces", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        func recover(_ folders: [String]) async throws -> (trusted: Bool, names: [String]) {
            let lost = try Fixture.container()
            let trusted = await WorkspaceRecoveryService.recoverMissingWorkspacesAfterLaunch(
                modelContext: lost.mainContext, extraRoots: [emptyRoot.path], includeDefaultRoots: false,
                registeredFolders: folders
            ).value
            return (trusted, try lost.mainContext.fetch(FetchDescriptor<Workspace>()).map(\.name))
        }
        // "A-Old" sorts first, so only the export time picks the newer.
        let old = try write(stale, to: "A-Old")
        let new = try write(config, to: "B-New")
        let newest = try await recover([old, new])
        #expect(newest.trusted)
        #expect(newest.names == ["Current"])
        // A copy with the same contents is interchangeable.
        let copy = try write(config, to: "C-Copy")
        #expect(try await recover([new, copy]).trusted)
        // Exported at the same moment with different contents: untrusted.
        var rival = config
        rival.name = "Rival"
        let tied = try write(rival, to: "D-Rival")
        #expect(try await !recover([new, tied]).trusted)
        withExtendedLifetime(source) {}
    }
}

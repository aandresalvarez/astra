import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
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
        // The folder is gone while Git still registers it.
        try FileManager.default.moveItem(atPath: discard.worktreePath, toPath: discard.worktreePath + "-gone")
        let ownership = fixture.ownership.directory.path
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: ownership)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ownership) }
        #expect(fixture.ownership.removalState(discard) == .unreadable)
        #expect(await TaskWorktreeService.discardOutcome(
            discard, modelContext: context, resourceQueue: fixture.resourceQueue, ownership: fixture.ownership
        ) == .retry("removal_mark_unreadable"))
        #expect(try !fixture.git(["branch", "--list", discard.branch], at: repository).isEmpty)
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
        // Both derived-task paths stop on a refusal rather than continuing.
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for file in ["Astra/Services/Tasks/ChainedTaskSubmissionService.swift", "Astra/Services/Validation/TaskCorrectiveWorkService.swift"] {
            let source = try String(contentsOf: base.appendingPathComponent(file), encoding: .utf8)
            #expect(source.contains("guard case .inherited(let inheritedBinding) = TaskWorktreeBinding.inheritCheckout("))
            #expect(!source.contains("TaskWorktreeBinding.inheritPin("))
        }
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

}

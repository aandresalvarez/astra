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

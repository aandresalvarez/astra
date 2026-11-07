import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAGitContracts
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@MainActor
@Suite("Consultation worktree preparation", .serialized)
struct NewTaskWorktreeConsultationTests {
    @Test("A stale Goal or task creation cannot mutate Git after the draft becomes Consult",
          arguments: ["before", "scan", "list"], ["planning", "selected", "unselected"])
    func consultationPreventsNewWorktree(stage: String, route: String) async throws {
        let fixture = try NewTaskWorktreeFixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        // This unrelated outer checkout exercises the early mkdir used when
        // checking whether the worktrees folder is hidden from Git status.
        let outer = try fixture.repository("Outer")
        let destination = outer.appendingPathComponent("Worktrees")
        let store = try NewTaskWorktreeFixture.container()
        let context = store.mainContext
        let workspace = Workspace(name: "Synthetic", primaryPath: repository.path)
        let draft = AgentTask(title: "Question", goal: "Explain the files", workspace: workspace)
        draft.status = .draft
        context.insert(draft)
        let task = route == "planning" ? draft
            : AgentTask(title: "Copied question", goal: draft.goal, workspace: workspace)
        context.insert(task)
        let checkoutSource = route == "planning" ? nil
            : NewTaskWorktreeComposerFlow.checkoutSource(draft: draft, isSelectedDraft: route == "selected")
        if route == "unselected" { #expect(checkoutSource == nil) }
        let git = ConsultationWorktreeGit(repositoryPath: repository.path)
        let selectConsult: @MainActor () -> Void = {
            TaskWorkspaceConsultationPolicy.select(true, for: draft, in: context, persist: { try context.save() })
        }
        if stage == "before" { selectConsult() }
        else { git.afterRead = { if $0 == stage { selectConsult() } } }
        let filesBefore = try FileManager.default.subpathsOfDirectory(atPath: fixture.root.path).sorted()
        var failure: Error?
        do {
            try await TaskWorktreeService.prepare(
                task: task, request: .init(repositoryPath: repository.path),
                inheritingFrom: checkoutSource, modeSource: route == "unselected" ? draft : nil,
                modelContext: context, resourceQueue: fixture.resourceQueue,
                git: git, worktreesRoot: destination.path, ownership: fixture.ownership
            )
        } catch { failure = error }
        #expect(TaskWorkspaceConsultationPolicy.composerSelection(for: draft, newTaskSelection: false))
        #expect(failure?.localizedDescription == "Choose Work to create a new worktree. Consult can use an existing checkout.")
        #expect(git.mutations.isEmpty)
        #expect(try FileManager.default.subpathsOfDirectory(atPath: fixture.root.path).sorted() == filesBefore)
        #expect(try fixture.cleanupStore.pendingURLs().isEmpty)
        #expect(TaskWorktreeService.activeWorktreeBinding(for: task) == nil)
        #expect(!task.events.contains { $0.hasType(TaskEventTypes.Task.worktreePrepared) })
    }

    @Test("Work creates a checkout that Consult can reuse or inherit without another Git operation")
    func consultationPreservesExistingWorktree() async throws {
        let fixture = try NewTaskWorktreeFixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try NewTaskWorktreeFixture.container()
        let context = store.mainContext
        let workspace = Workspace(name: "Synthetic", primaryPath: repository.path)
        let draft = AgentTask(title: "Work", goal: "Prepare a change", workspace: workspace)
        draft.status = .draft
        context.insert(draft)
        let request = TaskWorktreeRequest(repositoryPath: repository.path)
        try await TaskWorktreeService.prepare(
            task: draft, request: request, modelContext: context, resourceQueue: fixture.resourceQueue,
            worktreesRoot: fixture.worktrees.path, ownership: fixture.ownership
        )
        let original = try #require(TaskWorktreeService.activeWorktreeBinding(for: draft))
        TaskWorkspaceConsultationPolicy.select(true, for: draft, in: context, persist: { try context.save() })
        let git = ConsultationWorktreeGit(repositoryPath: repository.path)
        let filesBefore = try FileManager.default.subpathsOfDirectory(atPath: fixture.root.path).sorted()
        try await TaskWorktreeService.prepare(
            task: draft, request: request, modelContext: context, resourceQueue: fixture.resourceQueue,
            git: git, worktreesRoot: fixture.worktrees.path, ownership: fixture.ownership
        )
        let reader = AgentTask(title: "Consult", goal: "Explain the existing checkout", workspace: workspace)
        TaskWorkspaceConsultationPolicy.apply(true, to: reader)
        context.insert(reader)
        try await TaskWorktreeService.prepare(
            task: reader, request: request, inheritingFrom: draft, modelContext: context,
            resourceQueue: fixture.resourceQueue, git: git,
            worktreesRoot: fixture.worktrees.path, ownership: fixture.ownership
        )
        #expect(draft.executionRootPath == original.worktreePath)
        #expect(reader.executionRootPath == original.worktreePath)
        #expect(TaskWorktreeService.activeWorktreeBinding(for: reader)?.identity == original.identity)
        #expect(git.reads.isEmpty && git.mutations.isEmpty)
        #expect(try FileManager.default.subpathsOfDirectory(atPath: fixture.root.path).sorted() == filesBefore)
        #expect(try fixture.cleanupStore.pendingURLs().isEmpty)
    }

    @Test("Admitted Work preparation completes before a new Consult request is frozen")
    func completedWorkPreparationUsesCurrentSubmissionMode() async throws {
        let fixture = try NewTaskWorktreeFixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try NewTaskWorktreeFixture.container()
        let context = store.mainContext
        let workspace = Workspace(name: "Synthetic", primaryPath: repository.path)
        let composer = AgentTask(title: "Work", goal: "Prepare a change", workspace: workspace)
        composer.status = .draft
        context.insert(composer)
        let created = AgentTask(title: "New task", goal: composer.goal, workspace: workspace)
        var requestID: UUID?
        try await NewTaskWorktreeComposerFlow.prepareAndSubmit(created, consultationSelection: {
            TaskWorkspaceConsultationPolicy.composerSelection(for: composer, newTaskSelection: false)
        }) {
            try await TaskWorktreeService.prepare(
                task: created, request: .init(repositoryPath: repository.path), modeSource: composer,
                modelContext: context, resourceQueue: fixture.resourceQueue,
                worktreesRoot: fixture.worktrees.path, ownership: fixture.ownership
            )
            #expect(TaskWorktreeService.activeWorktreeBinding(for: created) != nil)
            TaskWorkspaceConsultationPolicy.select(true, for: composer, in: context, persist: { try context.save() })
            await Task.yield()
        } submit: {
            context.insert(created)
            guard case .success(let submission) = ExecutionRequestSubmissionService.submitInitial(for: created, into: context)
            else { Issue.record("Synthetic submission failed"); return }
            requestID = submission.requestID
        }
        let id = try #require(requestID)
        let request = try #require(try TaskTurnRequestRepository.request(id: id, in: context))
        #expect(TaskWorkspaceConsultationPolicy.isRequired(by: request, task: created))
        #expect(TaskExecutionResourceClaimResolver.workspaceAccess(for: request) == .shared)
        #expect(TaskWorktreeService.activeWorktreeBinding(for: created) != nil)
        #expect(try fixture.cleanupStore.pendingURLs().isEmpty)
    }
}

/// Only read-only preflight is expected. A regression records mutation attempts
/// and fails before performing any real Git write or contacting a remote.
private final class ConsultationWorktreeGit: GitRepositoryOperating {
    let repositoryPath: String
    var afterRead: (@MainActor (String) -> Void)?
    var reads: [String] = []
    var mutations: [String] = []
    enum UnexpectedMutation: Error { case attempted }
    init(repositoryPath: String) { self.repositoryPath = repositoryPath }
    func acquireIndexGuard() -> Bool { mutations.append("index"); return false }
    func releaseIndexGuard() {}
    func scanForGitRepositories(primaryPath: String, additionalPaths: [String]) async -> [GitRepositoryInfo] {
        reads.append("scan")
        await afterRead?("scan")
        return [.init(name: "App", path: repositoryPath)]
    }
    func listWorktrees(at repoPath: String) async -> [GitWorktreeInfo] {
        reads.append("list")
        await afterRead?("list")
        return []
    }
    func getCurrentBranch(at repoPath: String) async -> String { "main" }
    func getCommitSHA(_ ref: String, at repoPath: String) async -> String? { String(repeating: "a", count: 40) }
    func getLocalBranches(at repoPath: String) async -> [String] { ["main"] }
    func checkoutBranch(_ branch: String, at repoPath: String) async throws { try mutation("checkout") }
    func createBranch(_ branch: String, from base: String?, at repoPath: String) async throws { try mutation("branch") }
    func getStatusFiles(at repoPath: String) async -> [GitStatusFile] { [] }
    func stageFile(_ file: GitStatusFile, at repoPath: String) async throws { try mutation("stage") }
    func stageAll(at repoPath: String) async throws { try mutation("stage") }
    func unstageFile(_ file: GitStatusFile, at repoPath: String) async throws { try mutation("unstage") }
    func unstageAll(at repoPath: String) async throws { try mutation("unstage") }
    func applyDiffPatchToIndex(_ patch: String, at repoPath: String, reverse: Bool) async throws { try mutation("patch") }
    func commit(message: String, at repoPath: String) async throws { try mutation("commit") }
    func pullRebase(at repoPath: String) async throws { try mutation("pull") }
    func push(at repoPath: String) async throws { try mutation("push") }
    func pushSetUpstream(branch: String, remote: String, at repoPath: String) async throws { try mutation("push") }
    func hasRemote(at repoPath: String) async -> Bool { true }
    func lookupOpenPullRequest(repoPath: String, head: String, ghPathOverride: String?) async -> GitHubPullRequestLookupResult { .none }
    func lookupPullRequestComments(repoPath: String, pullRequest: GitHubPullRequestRef, ghPathOverride: String?) async -> GitHubPullRequestCommentLookupResult { .unavailable("unused") }
    func lookupPullRequestChecks(repoPath: String, pullRequest: GitHubPullRequestRef, ghPathOverride: String?) async -> GitHubPullRequestCheckLookupResult { .unavailable("unused") }
    func getUnpushedCommitCount(at repoPath: String) async -> Int { 0 }
    func getAheadBehind(at repoPath: String) async -> (ahead: Int, behind: Int)? { nil }
    func hasUpstream(at repoPath: String) async -> Bool { false }
    func getDefaultRemote(at repoPath: String) async -> String? { "origin" }
    func getStagedDiff(at repoPath: String, limit: Int) async -> String { "" }
    func getFileDiff(at repoPath: String, file: GitStatusFile, limit: Int) async -> GitFileDiff {
        .init(id: file.id, file: file, kind: .unavailable, diff: "", isTruncated: false, message: nil)
    }
    func getRecentCommitSubjects(at repoPath: String, count: Int) async -> [String] { [] }
    func getDefaultBaseBranch(at repoPath: String, remote: String?) async -> String { "main" }
    func getBranchLog(at repoPath: String, base: String, branch: String, limit: Int, maxBytes: Int) async -> String { "" }
    func getBranchDiffStat(at repoPath: String, base: String, branch: String, maxBytes: Int) async -> String { "" }
    func getDiffStats(at repoPath: String) async -> (additions: Int, deletions: Int) { (0, 0) }
    func localBranchExists(_ branch: String, at repoPath: String) async -> Bool { false }
    func lookupRemoteHead(remote: String, at repoPath: String) async -> GitRemoteHeadLookupResult { .branch("main") }
    func fetchRemoteBranch(remote: String, branch: String, at repoPath: String) async -> Bool { mutations.append("fetch"); return true }
    func pathIsHiddenFromStatus(_ path: String, in checkout: String) async -> Bool { true }
    func addWorktree(repoPath: String, branch: String, createBranch: Bool, base: String?, worktreesRoot: String) async throws -> String { try mutation("add"); return "" }
    func removeWorktree(repoPath: String, worktreePath: String, force: Bool) async throws { try mutation("remove") }
    func getRemoteURL(at repoPath: String, remote: String?) async -> String? { nil }
    func createPullRequest(repoPath: String, base: String, head: String, title: String, body: String, ghPathOverride: String?) async throws -> String { try mutation("pull-request"); return "" }
    func normalizeBaseBranch(_ raw: String) -> String { raw }
    private func mutation(_ name: String) throws { mutations.append(name); throw UnexpectedMutation.attempted }
}

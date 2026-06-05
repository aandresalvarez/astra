import Foundation
import SwiftData
import Testing
@testable import ASTRA
import ASTRACore

/// Regression coverage for pushing/publishing from the Repository panel.
///
/// Guards the fix for: a committed branch with a clean working tree (and, in
/// particular, a branch that has never been published) must still be pushable.
/// Previously push enablement depended solely on `ahead`, which is 0 whenever no
/// upstream is configured, so an unpublished branch could never be pushed.
@Suite("Git Push Enablement")
struct GitPushEnablementTests {

    // MARK: - Helpers

    private func runShell(_ command: String, in directory: String) -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        process.waitUntilExit()
        return Int(process.terminationStatus)
    }

    private func makeTempGitRepo() throws -> String {
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-push-repo-\(UUID().uuidString)", isDirectory: true)
            .path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let initCommand = """
        git init -b work && \
        git -c commit.gpgsign=false -c user.name='ASTRA Tests' -c user.email='astra-tests@example.invalid' \
        commit --allow-empty -m 'init'
        """
        let exitCode = runShell(initCommand, in: path)
        guard exitCode == 0 else {
            throw NSError(domain: "GitPushEnablementTests", code: exitCode, userInfo: [
                NSLocalizedDescriptionKey: "Failed to initialize temp git repo at \(path)"
            ])
        }
        return path
    }

    private func makeBareRemote() throws -> String {
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-push-remote-\(UUID().uuidString).git", isDirectory: true)
            .path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let exitCode = runShell("git init --bare", in: path)
        guard exitCode == 0 else {
            throw NSError(domain: "GitPushEnablementTests", code: exitCode, userInfo: [
                NSLocalizedDescriptionKey: "Failed to initialize bare remote at \(path)"
            ])
        }
        return path
    }

    private func commit(file: String, in repo: String) {
        let url = URL(fileURLWithPath: repo).appendingPathComponent(file)
        try? "content-\(UUID().uuidString)".write(to: url, atomically: true, encoding: .utf8)
        _ = runShell(
            "git add \(file) && git -c commit.gpgsign=false -c user.name='ASTRA Tests' "
            + "-c user.email='astra-tests@example.invalid' commit -m 'change \(file)'",
            in: repo
        )
    }

    private func makeModelContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [config]
        )
    }

    // MARK: - ViewModel push-enablement logic

    @MainActor
    @Test("canPush requires a remote and unpushed work")
    func canPushLogic() {
        let vm = WorkspaceGitViewModel()

        // No remote at all → never pushable, regardless of ahead.
        vm.hasRemote = false; vm.hasUpstream = true; vm.ahead = 3
        #expect(vm.canPush == false)

        // Remote + upstream + commits ahead → pushable, count from `ahead`.
        vm.hasRemote = true; vm.hasUpstream = true; vm.ahead = 2; vm.unpushedCount = 0
        #expect(vm.pushableCommitCount == 2)
        #expect(vm.canPush == true)

        // Remote + upstream but in sync → not pushable.
        vm.ahead = 0
        #expect(vm.canPush == false)

        // Remote but no upstream (unpublished) with unpushed commits → pushable,
        // count from `unpushedCount`.
        vm.hasUpstream = false; vm.unpushedCount = 4
        #expect(vm.pushableCommitCount == 4)
        #expect(vm.canPush == true)

        // Remote, no upstream, nothing unpushed → not pushable.
        vm.unpushedCount = 0
        #expect(vm.canPush == false)
    }

    @MainActor
    @Test("Clean unpublished branch can still open the commit/push sheet")
    func canOpenSheetForUnpublishedCleanBranch() {
        let vm = WorkspaceGitViewModel()
        vm.statusFiles = []          // working tree clean
        vm.hasRemote = true
        vm.hasUpstream = false       // never published
        vm.unpushedCount = 1

        #expect(vm.hasChanges == false)
        #expect(vm.canPush == true)
        #expect(vm.canOpenCommitSheet == true)
    }

    @MainActor
    @Test("Changes summary carries group status from the file set, not just line counts")
    func changesSummaryReflectsFileSet() {
        let vm = WorkspaceGitViewModel()

        // No files → clean, regardless of stale line counts.
        vm.statusFiles = []
        vm.additions = 5
        vm.deletions = 2
        #expect(vm.changesSummary == .clean)

        // Tracked edits → modified with line counts.
        vm.statusFiles = [
            GitStatusFile(relativePath: "a.swift", status: "M", isStaged: true),
            GitStatusFile(relativePath: "a.swift", status: "M", isStaged: false)
        ]
        vm.additions = 5
        vm.deletions = 2
        #expect(vm.changesSummary == .modified(additions: 5, deletions: 2, fileCount: 1))

        // Untracked-only (no diff line counts) must NOT read as clean.
        vm.statusFiles = [GitStatusFile(relativePath: "new.txt", status: "?", isStaged: false)]
        vm.additions = 0
        vm.deletions = 0
        #expect(vm.changesSummary == .modified(additions: 0, deletions: 0, fileCount: 1))
    }

    @MainActor
    @Test("Clean branch in sync with remote cannot open the sheet")
    func cannotOpenSheetWhenInSync() {
        let vm = WorkspaceGitViewModel()
        vm.statusFiles = []
        vm.hasRemote = true
        vm.hasUpstream = true
        vm.ahead = 0
        vm.unpushedCount = 0

        #expect(vm.canOpenCommitSheet == false)
    }

    @MainActor
    @Test("Pull request readiness blocks dirty unpublished and unpushed branches")
    func pullRequestReadinessBlocksIncompleteStates() {
        let vm = WorkspaceGitViewModel()
        vm.currentBranch = "feature/pr"

        vm.hasRemote = false
        #expect(vm.pullRequestReadinessIssue?.contains("No remote") == true)

        vm.hasRemote = true
        vm.hasUpstream = false
        #expect(vm.pullRequestReadinessIssue?.contains("Publish") == true)

        vm.hasUpstream = true
        vm.statusFiles = [GitStatusFile(relativePath: "dirty.swift", status: "M", isStaged: false)]
        #expect(vm.pullRequestReadinessIssue?.contains("Commit or stash") == true)

        vm.statusFiles = []
        vm.ahead = 2
        vm.unpushedCount = 0
        #expect(vm.pullRequestReadinessIssue?.contains("Push 2 local commits") == true)
    }

    @MainActor
    @Test("Pull request snapshot invalidates after branch or location changes")
    func pullRequestSnapshotInvalidatesOnBranchOrPathChange() throws {
        let root = try makeTempGitRepo()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let worktree = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-pr-snapshot-\(UUID().uuidString)", isDirectory: true)
            .path
        try FileManager.default.createDirectory(atPath: worktree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: worktree) }

        let vm = WorkspaceGitViewModel()
        vm.selectedRepository = GitRepositoryInfo(name: "repo", path: root)
        vm.currentBranch = "feature/pr"
        let snapshot = try #require(vm.makePullRequestActionSnapshot())
        #expect(vm.isCurrentPullRequestActionSnapshot(snapshot) == true)

        vm.currentBranch = "feature/other"
        #expect(vm.isCurrentPullRequestActionSnapshot(snapshot) == false)

        vm.currentBranch = "feature/pr"
        vm.activeWorkingPath = worktree
        #expect(vm.isCurrentPullRequestActionSnapshot(snapshot) == false)
    }

    @MainActor
    @Test("Clean fully pushed branch is pull-request ready")
    func pullRequestReadyWhenCleanAndPushed() {
        let vm = WorkspaceGitViewModel()
        vm.currentBranch = "feature/pr"
        vm.hasRemote = true
        vm.hasUpstream = true
        vm.ahead = 0
        vm.unpushedCount = 0
        vm.statusFiles = []

        #expect(vm.canStartPullRequest == true)
        #expect(vm.pullRequestReadinessIssue == nil)
    }

    @MainActor
    @Test("Addressing PR comments creates an editable chat draft with review context")
    func createPullRequestCommentTaskSeedsChatContext() throws {
        let repo = try makeTempGitRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }

        let container = try makeModelContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Repo", primaryPath: repo)
        context.insert(workspace)

        let pr = GitHubPullRequestRef(
            number: 95,
            url: "https://github.com/coral/astra/pull/95",
            title: "Repo comments"
        )
        let comment = GitHubPullRequestComment(
            id: "c1",
            author: "copilot",
            body: "GitRepositoryInfo uses a fresh UUID for id.",
            path: "Astra/Services/Git/GitService.swift",
            line: 12,
            url: "https://github.com/coral/astra/pull/95#discussion_r1",
            createdAt: "2026-05-30T11:00:00Z",
            isReviewThread: true
        )

        let vm = WorkspaceGitViewModel()
        vm.setWorkspaceForTesting(workspace)
        vm.selectedRepository = GitRepositoryInfo(name: "Repo", path: repo)
        vm.currentBranch = "feature/pr-comments"
        vm.openPullRequest = pr
        vm.pullRequestComments = GitHubPullRequestCommentSummary(
            pullRequest: pr,
            comments: [comment],
            unresolvedThreadCount: 1,
            issueCommentCount: 0,
            fetchedAt: Date()
        )

        let task = try #require(vm.createPullRequestCommentTask(modelContext: context))

        #expect(task.status == .draft)
        #expect(task.title == "Address PR #95 comments")
        #expect(task.executionRootPath == repo)
        #expect(task.goal.contains("GitRepositoryInfo uses a fresh UUID"))
        #expect(task.goal.contains("re-fetch the latest unresolved review comments"))
        #expect(task.goal.contains("Do not merge the PR or post GitHub replies"))
        #expect(task.draftMessages.contains("GitRepositoryInfo uses a fresh UUID"))
        #expect(task.events.isEmpty)
    }

    // MARK: - GitService integration

    @Test("Unpushed count and remote detection track publish state")
    func unpushedCountTracksPublishState() async throws {
        let repo = try makeTempGitRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        let remote = try makeBareRemote()
        defer { try? FileManager.default.removeItem(atPath: remote) }

        // No remote configured yet.
        let hasRemoteBefore = await GitService.shared.hasRemote(at: repo)
        #expect(hasRemoteBefore == false)

        #expect(runShell("git remote add origin '\(remote)'", in: repo) == 0)
        let hasRemoteAfter = await GitService.shared.hasRemote(at: repo)
        #expect(hasRemoteAfter == true)

        // Remote exists but branch not published: there is unpushed work and no upstream.
        let branch = await GitService.shared.getCurrentBranch(at: repo)
        #expect(branch == "work")
        let unpushedBeforePublish = await GitService.shared.getUnpushedCommitCount(at: repo)
        #expect(unpushedBeforePublish >= 1)
        let upstreamBeforePublish = await GitService.shared.hasUpstream(at: repo)
        #expect(upstreamBeforePublish == false)

        // Publishing sets the upstream and clears unpushed work.
        try await GitService.shared.pushSetUpstream(branch: branch, at: repo)
        let upstreamAfterPublish = await GitService.shared.hasUpstream(at: repo)
        #expect(upstreamAfterPublish == true)
        let unpushedAfterPublish = await GitService.shared.getUnpushedCommitCount(at: repo)
        #expect(unpushedAfterPublish == 0)

        // A new local commit becomes unpushed again.
        commit(file: "feature.txt", in: repo)
        let unpushedAfterCommit = await GitService.shared.getUnpushedCommitCount(at: repo)
        #expect(unpushedAfterCommit == 1)
    }
}

import Foundation
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA
import ASTRACore
import ASTRAGitContracts

/// Reports when the panel's detached `gh pr list` lookups actually reach the
/// service, and can hold one in flight so a test observes the panel between
/// "the action fired" and "the follow-up probe answered".
///
/// Tests wait on this signal instead of a wall clock. The panel's recovery
/// paths chain several main-actor hops (`selectRepository` -> refresh ->
/// lookup, `createPullRequest` -> remote -> base -> create -> forced lookup),
/// and under full-suite load the main actor is saturated enough that any fixed
/// deadline expires mid-chain and leaves the assertions running against
/// un-advanced state. A continuation has no deadline to blow past: either the
/// lookup happens or the test hangs until the runner kills it, which is a
/// legible failure rather than a fake one.
private actor PullRequestLookupGate {
    private var startedCount = 0
    private var waiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var gatedCall: Int?
    private var gateWaiter: CheckedContinuation<Void, Never>?
    private var isGateOpen = false

    /// Called by the fake at lookup entry — ahead of the gate — so a waiter is
    /// released while the gated probe is still running.
    func noteStarted() async {
        startedCount += 1
        let reached = startedCount
        let ready = waiters.filter { $0.target <= reached }
        waiters.removeAll { $0.target <= reached }
        for waiter in ready { waiter.continuation.resume() }

        guard gatedCall == reached, !isGateOpen else { return }
        await withCheckedContinuation { gateWaiter = $0 }
    }

    /// Blocks until the `target`-th lookup has started. Unbounded on purpose.
    func waitForStart(_ target: Int) async {
        guard startedCount < target else { return }
        await withCheckedContinuation { waiters.append((target, $0)) }
    }

    /// Suspends the numbered lookup inside the service until `openGate()`.
    func gate(call: Int) {
        gatedCall = call
    }

    func openGate() {
        isGateOpen = true
        gateWaiter?.resume()
        gateWaiter = nil
    }
}

/// Keeps `createPullRequest` from launching a real browser during tests.
@MainActor
private final class RecordingPanelURLLauncher: GitHubAuthorizationURLLaunching, @unchecked Sendable {
    private(set) var openedURLs: [URL] = []

    func open(_ url: URL) -> Bool {
        openedURLs.append(url)
        return true
    }
}

@Suite("Git Repository Panel Integration")
struct GitRepositoryPanelIntegrationTests {
    private final class FakeGitRepositoryOperations: GitRepositoryOperating {
        var scannedPrimaryPath: String?
        var scannedAdditionalPaths: [String] = []
        var repositories: [GitRepositoryInfo] = []
        var acquiredIndexGuardCount = 0
        var releasedIndexGuardCount = 0
        var refreshedStatusPaths: [String] = []
        var refreshedWorktreeRoots: [String] = []
        var currentBranch = "feature/test"
        var localBranches = ["main", "feature/test"]
        var statusFiles: [GitStatusFile] = []
        var diffStats = (additions: 0, deletions: 0)
        var upstream = false
        var remote = false
        var unpushedCount = 0
        var aheadBehind: (ahead: Int, behind: Int)?
        var worktrees: [GitWorktreeInfo] = []
        var pullRequestLookupResult: GitHubPullRequestLookupResult = .none
        private(set) var pullRequestLookupCallCount = 0
        /// Signals each lookup as it reaches the service, and optionally holds
        /// one in flight. Tests block on this rather than on a clock.
        let lookupGate = PullRequestLookupGate()

        func acquireIndexGuard() -> Bool {
            acquiredIndexGuardCount += 1
            return true
        }

        func releaseIndexGuard() {
            releasedIndexGuardCount += 1
        }

        func scanForGitRepositories(primaryPath: String, additionalPaths: [String]) async -> [GitRepositoryInfo] {
            scannedPrimaryPath = primaryPath
            scannedAdditionalPaths = additionalPaths
            return repositories
        }

        func getCurrentBranch(at repoPath: String) async -> String {
            refreshedStatusPaths.append(repoPath)
            return currentBranch
        }

        func getCommitSHA(_ ref: String, at repoPath: String) async -> String? { "abc123" }

        func getLocalBranches(at repoPath: String) async -> [String] { localBranches }
        func checkoutBranch(_ branch: String, at repoPath: String) async throws {}
        func createBranch(_ branch: String, from base: String?, at repoPath: String) async throws {}
        func getStatusFiles(at repoPath: String) async -> [GitStatusFile] { statusFiles }
        func stageFile(_ file: GitStatusFile, at repoPath: String) async throws {}
        func stageAll(at repoPath: String) async throws {}
        func unstageFile(_ file: GitStatusFile, at repoPath: String) async throws {}
        func unstageAll(at repoPath: String) async throws {}
        func applyDiffPatchToIndex(_ patch: String, at repoPath: String, reverse: Bool) async throws {}
        func commit(message: String, at repoPath: String) async throws {}
        func pullRebase(at repoPath: String) async throws {}
        func push(at repoPath: String) async throws {}
        func pushSetUpstream(branch: String, remote: String, at repoPath: String) async throws {}
        func hasRemote(at repoPath: String) async -> Bool { remote }

        func lookupOpenPullRequest(
            repoPath: String,
            head: String,
            ghPathOverride: String?
        ) async -> GitHubPullRequestLookupResult {
            pullRequestLookupCallCount += 1
            await lookupGate.noteStarted()
            return pullRequestLookupResult
        }

        func lookupPullRequestComments(
            repoPath: String,
            pullRequest: GitHubPullRequestRef,
            ghPathOverride: String?
        ) async -> GitHubPullRequestCommentLookupResult {
            .unavailable("not implemented")
        }

        func lookupPullRequestChecks(
            repoPath: String,
            pullRequest: GitHubPullRequestRef,
            ghPathOverride: String?
        ) async -> GitHubPullRequestCheckLookupResult {
            .unavailable("not implemented")
        }

        func getUnpushedCommitCount(at repoPath: String) async -> Int { unpushedCount }
        func getAheadBehind(at repoPath: String) async -> (ahead: Int, behind: Int)? { aheadBehind }
        func hasUpstream(at repoPath: String) async -> Bool { upstream }
        func getDefaultRemote(at repoPath: String) async -> String? { nil }
        func getStagedDiff(at repoPath: String, limit: Int) async -> String { "" }

        func getFileDiff(at repoPath: String, file: GitStatusFile, limit: Int) async -> GitFileDiff {
            GitFileDiff(
                id: file.id,
                file: file,
                kind: .unavailable,
                diff: "",
                isTruncated: false,
                message: nil
            )
        }

        func getRecentCommitSubjects(at repoPath: String, count: Int) async -> [String] { [] }
        func getDefaultBaseBranch(at repoPath: String, remote: String?) async -> String { "origin/main" }

        func getBranchLog(
            at repoPath: String,
            base: String,
            branch: String,
            limit: Int,
            maxBytes: Int
        ) async -> String {
            ""
        }

        func getBranchDiffStat(at repoPath: String, base: String, branch: String, maxBytes: Int) async -> String {
            ""
        }

        func getDiffStats(at repoPath: String) async -> (additions: Int, deletions: Int) { diffStats }

        func listWorktrees(at repoPath: String) async -> [GitWorktreeInfo] {
            refreshedWorktreeRoots.append(repoPath)
            return worktrees
        }

        func localBranchExists(_ branch: String, at repoPath: String) async -> Bool { false }

        func addWorktree(
            repoPath: String,
            branch: String,
            createBranch: Bool,
            base: String?,
            worktreesRoot: String
        ) async throws -> String {
            repoPath
        }

        func removeWorktree(repoPath: String, worktreePath: String, force: Bool) async throws {}
        func getRemoteURL(at repoPath: String, remote: String?) async -> String? { nil }

        func createPullRequest(
            repoPath: String,
            base: String,
            head: String,
            title: String,
            body: String,
            ghPathOverride: String?
        ) async throws -> String {
            "https://github.com/example/repo/pull/1"
        }

        func createPullRequest(
            repoPath: String,
            base: String,
            head: String,
            title: String,
            body: String,
            isDraft: Bool,
            ghPathOverride: String?
        ) async throws -> String {
            "https://github.com/example/repo/pull/1"
        }

        func normalizeBaseBranch(_ raw: String) -> String {
            GitService.normalizeBaseBranch(raw)
        }
    }

    private func makeTempDir(_ label: String) throws -> String {
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-repo-panel-\(label)-\(UUID().uuidString)", isDirectory: true)
            .path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func markGitRepository(_ path: String) throws {
        #expect(runShell("git init -b main", in: path) == 0)
    }

    private func runShell(_ command: String, in directory: String) -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = GitLocalEnvironment.scrubbing(ProcessInfo.processInfo.environment)
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return Int(process.terminationStatus)
        } catch {
            return -1
        }
    }

    @Test("Repository context changes preserve hidden details and clear transient popovers")
    func repositoryContextChangesPreserveHiddenDetailsAndClearTransientPopovers() {
        let initial = WorkspaceGitTransientPresentationState(
            repositoryDetailsMode: .summary,
            isChangesDrawerExpanded: true,
            showRepositoryPopover: true,
            showLocationPopover: true,
            showPRCommentsPopover: true,
            showBranchPickerPopover: true
        )

        let next = WorkspaceGitPanelPresentation.transientStateAfterRepositoryContextChange(initial)

        #expect(next.repositoryDetailsMode == .summary)
        #expect(next.isChangesDrawerExpanded == false)
        #expect(next.showRepositoryPopover == false)
        #expect(next.showLocationPopover == false)
        #expect(next.showPRCommentsPopover == false)
        #expect(next.showBranchPickerPopover == false)
    }

    @Test("Repository context changes preserve expanded details while closing transients")
    func repositoryContextChangesPreserveExpandedDetails() {
        let initial = WorkspaceGitTransientPresentationState(
            repositoryDetailsMode: .details,
            isChangesDrawerExpanded: true,
            showRepositoryPopover: true,
            showLocationPopover: true,
            showPRCommentsPopover: true,
            showBranchPickerPopover: true
        )

        let next = WorkspaceGitPanelPresentation.transientStateAfterRepositoryContextChange(initial)

        #expect(next.repositoryDetailsMode == .details)
        #expect(next.isChangesDrawerExpanded == false)
        #expect(next.showRepositoryPopover == false)
        #expect(next.showLocationPopover == false)
        #expect(next.showPRCommentsPopover == false)
        #expect(next.showBranchPickerPopover == false)
    }

    @Test("Workspace path presentation uses folder names instead of ordinal additional labels")
    func workspacePathPresentationNamesFolders() throws {
        let root = try makeTempDir("root")
        let first = URL(fileURLWithPath: root).appendingPathComponent("Astra", isDirectory: true)
        let second = URL(fileURLWithPath: root).appendingPathComponent("Docs", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let descriptors = WorkspacePathPresentation.descriptors(
            primaryPath: root,
            additionalPaths: [first.path, second.path]
        )

        #expect(descriptors.map(\.title).contains("Astra"))
        #expect(descriptors.map(\.title).contains("Docs"))
        #expect(!descriptors.map(\.title).contains("Additional 1"))
        #expect(descriptors.filter { $0.role == .additional }.allSatisfy { $0.roleLabel == "Additional" })
    }

    @Test("Repository scan inputs reject stale workspace paths")
    func repositoryScanInputsRejectStaleWorkspacePaths() {
        let inputs = WorkspaceGitRepositoryScanInputs(
            primaryPath: "/workspaces/one",
            additionalPaths: ["/repos/a", "/repos/b"]
        )

        #expect(inputs.matches(
            primaryPath: "/workspaces/one",
            additionalPaths: ["/repos/a", "/repos/b"]
        ))
        #expect(!inputs.matches(
            primaryPath: "/workspaces/two",
            additionalPaths: ["/repos/a", "/repos/b"]
        ))
        #expect(!inputs.matches(
            primaryPath: "/workspaces/one",
            additionalPaths: ["/repos/b", "/repos/a"]
        ))
    }

    @Test("Workspace path presentation disambiguates duplicate folder names with parent folders")
    func workspacePathPresentationDisambiguatesDuplicateFolders() throws {
        let root = try makeTempDir("dupes")
        let firstParent = URL(fileURLWithPath: root).appendingPathComponent("One", isDirectory: true)
        let secondParent = URL(fileURLWithPath: root).appendingPathComponent("Two", isDirectory: true)
        let first = firstParent.appendingPathComponent("Astra", isDirectory: true)
        let second = secondParent.appendingPathComponent("Astra", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let descriptors = WorkspacePathPresentation.descriptors(
            primaryPath: root,
            additionalPaths: [first.path, second.path]
        )

        #expect(descriptors.map(\.title).contains("One/Astra"))
        #expect(descriptors.map(\.title).contains("Two/Astra"))
    }

    @Test("Repository scan includes only configured roots that are git repositories")
    func repositoryScanSkipsNonGitAdditionalFolders() async throws {
        let primary = try makeTempDir("primary")
        let repo = try makeTempDir("extra-repo")
        let notes = try makeTempDir("notes")
        try markGitRepository(repo)
        defer {
            try? FileManager.default.removeItem(atPath: primary)
            try? FileManager.default.removeItem(atPath: repo)
            try? FileManager.default.removeItem(atPath: notes)
        }

        let repos = await GitService.shared.scanForGitRepositories(
            primaryPath: primary,
            additionalPaths: [repo, notes]
        )

        #expect(repos.map(\.path) == [WorkspacePathPresentation.standardizedPath(repo)])
        #expect(repos.first?.name == URL(fileURLWithPath: repo).lastPathComponent)
        #expect(repos.first?.id == repos.first?.path)
    }

    @MainActor
    @Test("View model scans and refreshes through injected git operations")
    func viewModelUsesInjectedGitOperationsForScanAndRefresh() async throws {
        let primary = try makeTempDir("primary-injected")
        let repo = try makeTempDir("repo-injected")
        let docs = try makeTempDir("docs-injected")
        defer {
            try? FileManager.default.removeItem(atPath: primary)
            try? FileManager.default.removeItem(atPath: repo)
            try? FileManager.default.removeItem(atPath: docs)
        }

        let fakeGit = FakeGitRepositoryOperations()
        let repoInfo = GitRepositoryInfo(name: "Injected", path: repo)
        fakeGit.repositories = [repoInfo]
        fakeGit.statusFiles = [GitStatusFile(relativePath: "Astra/Injected.swift", status: "M", isStaged: false)]
        fakeGit.diffStats = (additions: 3, deletions: 1)
        fakeGit.aheadBehind = (ahead: 2, behind: 1)
        fakeGit.remote = false
        fakeGit.upstream = true
        fakeGit.unpushedCount = 2

        let workspace = Workspace(name: "Injected Ops", primaryPath: primary, additionalPaths: [repo, docs])
        let viewModel = WorkspaceGitViewModel(git: fakeGit)
        viewModel.setWorkspaceForTesting(workspace)
        viewModel.selectedRepository = repoInfo

        await viewModel.scanRepositories()

        #expect(fakeGit.scannedPrimaryPath == primary)
        #expect(fakeGit.scannedAdditionalPaths == [repo, docs])
        #expect(viewModel.repositories == [repoInfo])
        #expect(viewModel.selectedRepository == repoInfo)
        #expect(fakeGit.acquiredIndexGuardCount >= 1)
        #expect(fakeGit.releasedIndexGuardCount == fakeGit.acquiredIndexGuardCount)
        #expect(!fakeGit.refreshedStatusPaths.isEmpty)
        #expect(fakeGit.refreshedStatusPaths.allSatisfy { $0 == repo })
        #expect(!fakeGit.refreshedWorktreeRoots.isEmpty)
        #expect(fakeGit.refreshedWorktreeRoots.allSatisfy { $0 == repo })
        #expect(viewModel.currentBranch == "feature/test")
        #expect(viewModel.branches == ["main", "feature/test"])
        #expect(viewModel.statusFiles == fakeGit.statusFiles)
        #expect(viewModel.additions == 3)
        #expect(viewModel.deletions == 1)
        #expect(viewModel.ahead == 2)
        #expect(viewModel.behind == 1)
        #expect(viewModel.hasUpstream == true)
        #expect(viewModel.hasRemote == false)
        #expect(viewModel.unpushedCount == 2)
    }

    @Test("Files shelf roots use path presentation and mark git repositories")
    func filesShelfRootsUsePathPresentation() throws {
        let primary = try makeTempDir("primary-files")
        let repo = try makeTempDir("extra-files")
        let notes = try makeTempDir("notes-files")
        try markGitRepository(primary)
        try markGitRepository(repo)
        defer {
            try? FileManager.default.removeItem(atPath: primary)
            try? FileManager.default.removeItem(atPath: repo)
            try? FileManager.default.removeItem(atPath: notes)
        }

        let workspace = Workspace(name: "Files", primaryPath: primary, additionalPaths: [repo, notes])
        let roots = WorkspaceFileIndexService.roots(workspace: workspace, task: nil)

        #expect(roots.map(\.title).contains(URL(fileURLWithPath: repo).lastPathComponent))
        #expect(!roots.map(\.title).contains("Additional 1"))
        #expect(roots.first { $0.path == WorkspacePathPresentation.standardizedPath(primary) }?.isGitRepository == true)
        #expect(roots.first { $0.path == WorkspacePathPresentation.standardizedPath(repo) }?.isGitRepository == true)
        #expect(roots.first { $0.path == WorkspacePathPresentation.standardizedPath(notes) }?.isGitRepository == false)
    }

    @MainActor
    @Test("Selecting a repository stores the active workspace default")
    func selectingRepositoryStoresWorkspaceDefault() throws {
        let primary = try makeTempDir("primary-active")
        let repo = try makeTempDir("extra-active")
        defer {
            try? FileManager.default.removeItem(atPath: primary)
            try? FileManager.default.removeItem(atPath: repo)
        }

        let workspace = Workspace(name: "Repos", primaryPath: primary, additionalPaths: [repo])
        let viewModel = WorkspaceGitViewModel()
        viewModel.setWorkspaceForTesting(workspace)

        viewModel.selectRepository(GitRepositoryInfo(name: "Extra", path: repo))

        #expect(viewModel.selectedRepository?.path == WorkspacePathPresentation.standardizedPath(repo))
        #expect(workspace.activeWorkingPath == WorkspacePathPresentation.standardizedPath(repo))
    }

    @MainActor
    @Test("Scanning a repository from an added path makes it the workspace code default")
    func scanningAdditionalRepositoryPersistsWorkspaceCodeDefault() async throws {
        let primary = try makeTempDir("primary-scan-default")
        let repo = try makeTempDir("extra-scan-default")
        defer {
            try? FileManager.default.removeItem(atPath: primary)
            try? FileManager.default.removeItem(atPath: repo)
        }

        let fakeGit = FakeGitRepositoryOperations()
        fakeGit.repositories = [GitRepositoryInfo(name: "Extra", path: repo)]
        let workspace = Workspace(name: "Repos", primaryPath: primary, additionalPaths: [repo])
        let viewModel = WorkspaceGitViewModel(git: fakeGit)
        viewModel.setWorkspaceForTesting(workspace)

        await viewModel.scanRepositories()

        #expect(viewModel.selectedRepository?.path == WorkspacePathPresentation.standardizedPath(repo))
        #expect(workspace.activeWorkingPath == WorkspacePathPresentation.standardizedPath(repo))

        let task = AgentTask(title: "Status", goal: "Run git status", workspace: workspace)
        #expect(task.executionRootPath == WorkspacePathPresentation.standardizedPath(repo))
        #expect(TaskWorkspaceAccess(task: task).codeWorkingDirectory == WorkspacePathPresentation.standardizedPath(repo))
        #expect(TaskWorkspaceAccess(task: task).effectiveWorkspacePath == primary)
    }

    @MainActor
    @Test("Scanning with a draft task selected does not pin the draft")
    func scanningAdditionalRepositoryDoesNotPinDraftTask() async throws {
        let primary = try makeTempDir("primary-scan-draft")
        let repo = try makeTempDir("extra-scan-draft")
        defer {
            try? FileManager.default.removeItem(atPath: primary)
            try? FileManager.default.removeItem(atPath: repo)
        }

        let fakeGit = FakeGitRepositoryOperations()
        fakeGit.repositories = [GitRepositoryInfo(name: "Extra", path: repo)]
        let workspace = Workspace(name: "Repos", primaryPath: primary, additionalPaths: [repo])
        let task = AgentTask(title: "Draft", goal: "Work", workspace: workspace)
        let viewModel = WorkspaceGitViewModel(git: fakeGit)
        viewModel.setWorkspaceForTesting(workspace, selectedTask: task)

        await viewModel.scanRepositories()

        #expect(viewModel.selectedRepository?.path == WorkspacePathPresentation.standardizedPath(repo))
        #expect(task.executionRootPath == nil)
        #expect(workspace.activeWorkingPath == nil)
    }

    @MainActor
    @Test("Scanning an unchanged workspace repository default does not touch updatedAt")
    func scanningUnchangedRepositoryDefaultDoesNotTouchWorkspace() async throws {
        let primary = try makeTempDir("primary-scan-unchanged")
        let repo = try makeTempDir("extra-scan-unchanged")
        defer {
            try? FileManager.default.removeItem(atPath: primary)
            try? FileManager.default.removeItem(atPath: repo)
        }

        let fakeGit = FakeGitRepositoryOperations()
        fakeGit.repositories = [GitRepositoryInfo(name: "Extra", path: repo)]
        let workspace = Workspace(name: "Repos", primaryPath: primary, additionalPaths: [repo])
        workspace.activeWorkingPath = WorkspacePathPresentation.standardizedPath(repo)
        let expectedUpdatedAt = Date(timeIntervalSince1970: 100)
        workspace.updatedAt = expectedUpdatedAt
        let viewModel = WorkspaceGitViewModel(git: fakeGit)
        viewModel.setWorkspaceForTesting(workspace)

        await viewModel.scanRepositories()

        #expect(workspace.activeWorkingPath == WorkspacePathPresentation.standardizedPath(repo))
        #expect(workspace.updatedAt == expectedUpdatedAt)
    }

    @MainActor
    @Test("Selecting a repository for a draft task pins the draft without changing workspace default")
    func selectingRepositoryPinsDraftTask() throws {
        let primary = try makeTempDir("primary-draft")
        let repo = try makeTempDir("extra-draft")
        defer {
            try? FileManager.default.removeItem(atPath: primary)
            try? FileManager.default.removeItem(atPath: repo)
        }

        let workspace = Workspace(name: "Repos", primaryPath: primary, additionalPaths: [repo])
        let task = AgentTask(title: "Draft", goal: "Work", workspace: workspace)
        let viewModel = WorkspaceGitViewModel()
        viewModel.setWorkspaceForTesting(workspace, selectedTask: task)

        viewModel.selectRepository(GitRepositoryInfo(name: "Extra", path: repo))

        #expect(task.executionRootPath == WorkspacePathPresentation.standardizedPath(repo))
        #expect(workspace.activeWorkingPath == nil)
    }

    @MainActor
    @Test("Repository selection is read-only for tasks with execution history")
    func repositorySelectionBlockedForHistoricalTask() throws {
        let primary = try makeTempDir("primary-locked")
        let repo = try makeTempDir("extra-locked")
        defer {
            try? FileManager.default.removeItem(atPath: primary)
            try? FileManager.default.removeItem(atPath: repo)
        }

        let workspace = Workspace(name: "Repos", primaryPath: primary, additionalPaths: [repo])
        let task = AgentTask(title: "Done", goal: "Work", workspace: workspace)
        task.status = .completed
        task.executionRootPath = repo
        let viewModel = WorkspaceGitViewModel()
        viewModel.setWorkspaceForTesting(workspace, selectedTask: task)

        viewModel.selectRepository(GitRepositoryInfo(name: "Primary", path: primary))

        #expect(task.executionRootPath == repo)
        #expect(viewModel.errorMessage?.contains("pinned") == true)
    }

    @MainActor
    @Test("Repository scope label reflects whether a historical task is actually pinned")
    func repositoryScopeLabelReflectsDurablePin() throws {
        let primary = try makeTempDir("primary-label")
        let repo = try makeTempDir("extra-label")
        defer {
            try? FileManager.default.removeItem(atPath: primary)
            try? FileManager.default.removeItem(atPath: repo)
        }

        let workspace = Workspace(name: "Repos", primaryPath: primary, additionalPaths: [repo])
        let task = AgentTask(title: "Done", goal: "Work", workspace: workspace)
        task.status = .completed

        let viewModel = WorkspaceGitViewModel()
        viewModel.setWorkspaceForTesting(workspace, selectedTask: task)
        #expect(viewModel.activeSelectionScopeLabel == "Workspace default")

        task.executionRootPath = repo
        viewModel.setWorkspaceForTesting(workspace, selectedTask: task)
        #expect(viewModel.activeSelectionScopeLabel == "Pinned task")

        task.executionRootPath = "/definitely/missing-\(UUID().uuidString)"
        viewModel.setWorkspaceForTesting(workspace, selectedTask: task)
        #expect(viewModel.activeSelectionScopeLabel == "Workspace default")
    }

    @MainActor
    @Test("Changed file paths resolve from the active working path")
    func changedFilePathResolvesFromActiveWorkingPath() throws {
        let primary = try makeTempDir("primary-file")
        let worktree = try makeTempDir("worktree-file")
        defer {
            try? FileManager.default.removeItem(atPath: primary)
            try? FileManager.default.removeItem(atPath: worktree)
        }

        let viewModel = WorkspaceGitViewModel()
        viewModel.selectedRepository = GitRepositoryInfo(name: "Primary", path: primary)
        viewModel.activeWorkingPath = worktree

        let file = GitStatusFile(relativePath: "Astra/Views/Panel.swift", status: "M", isStaged: false)

        #expect(viewModel.absolutePath(for: file) == URL(fileURLWithPath: worktree)
            .appendingPathComponent("Astra/Views/Panel.swift")
            .standardizedFileURL
            .path)
    }

    // MARK: - Pull request lookup breaker

    /// Verbatim `gh pr list` stderr from the recorded production session.
    private static let samlLookupFailure = """
    GraphQL: Resource protected by organization SAML enforcement. You must grant your OAuth token access to this organization. (repository) Authorize in your web browser: https://github.com/orgs/example/sso?authorization_request=ABC123
    """

    @MainActor
    private func makePullRequestLookupPanel(
        _ label: String,
        result: GitHubPullRequestLookupResult
    ) throws -> (WorkspaceGitViewModel, FakeGitRepositoryOperations, String, Workspace) {
        let repo = try makeTempDir(label)
        let fakeGit = FakeGitRepositoryOperations()
        fakeGit.remote = true
        fakeGit.currentBranch = "feature/login"
        fakeGit.pullRequestLookupResult = result

        let workspace = Workspace(name: "PR Lookup", primaryPath: repo)
        // Mirrors a workspace whose code default is the repository itself, so a
        // panel re-setup resolves the same working path the breaker recorded.
        workspace.activeWorkingPath = repo
        let viewModel = WorkspaceGitViewModel(git: fakeGit, urlLauncher: RecordingPanelURLLauncher())
        viewModel.setWorkspaceForTesting(workspace)
        // `selectedRepository` is deliberately left unset: its didSet schedules a
        // background refresh whose own lookup would race the call counter.
        viewModel.activeWorkingPath = repo
        viewModel.currentBranch = "feature/login"
        viewModel.hasRemote = true
        return (viewModel, fakeGit, repo, workspace)
    }

    /// Opens the breaker on `feature/login` through the production failure path.
    @MainActor
    private func openLookupBreaker(
        _ viewModel: WorkspaceGitViewModel,
        _ fakeGit: FakeGitRepositoryOperations
    ) async {
        viewModel.refreshOpenPullRequest(force: true)
        await awaitLookups(viewModel, fakeGit, count: 1)
        #expect(viewModel.pullRequestLookupAuthBlocked)
    }

    /// Waits until the detached lookup task the view model spawns has reached
    /// `count` calls *and* the last of them has finished applying its result on
    /// the main actor. Both halves are signals, not sleeps: the fake reports the
    /// call, and the view model hands back the very task that applies it.
    @MainActor
    private func awaitLookups(
        _ viewModel: WorkspaceGitViewModel,
        _ fake: FakeGitRepositoryOperations,
        count: Int
    ) async {
        await awaitLookupStart(fake, count: count)
        await viewModel.waitForPendingPullRequestLookupForTesting()
    }

    /// Waits until the `count`-th lookup has *entered* the service. For a gated
    /// call that is while the probe is still in flight, which is the window the
    /// publish test needs to inspect.
    @MainActor
    private func awaitLookupStart(_ fake: FakeGitRepositoryOperations, count: Int) async {
        await fake.lookupGate.waitForStart(count)
    }

    /// Drains the main-actor work the preceding call enqueued — a notification
    /// hop, plus whatever lookup task it spawned — so a "no additional lookup"
    /// assertion is a fact rather than a race. A job enqueued on the main actor
    /// before this one runs before it, and `refreshOpenPullRequest` publishes
    /// its task handle synchronously, so there is nothing left to sleep for.
    @MainActor
    private func settleLookups(_ viewModel: WorkspaceGitViewModel) async {
        await Task { @MainActor in }.value
        await viewModel.waitForPendingPullRequestLookupForTesting()
    }

    @MainActor
    @Test("Repeated SAML lookup failures stop re-spawning gh on the polling path")
    func samlLookupFailuresStopPolling() async throws {
        let (viewModel, fakeGit, repo, _) = try makePullRequestLookupPanel(
            "pr-breaker-saml",
            result: .unavailable(Self.samlLookupFailure)
        )
        defer { try? FileManager.default.removeItem(atPath: repo) }

        viewModel.refreshOpenPullRequest(force: true)
        await awaitLookups(viewModel, fakeGit, count: 1)

        #expect(fakeGit.pullRequestLookupCallCount == 1)
        #expect(viewModel.pullRequestLookupAuthBlocked)
        #expect(viewModel.pullRequestLookupIssue?.contains("Repair access") == true)

        for _ in 0..<10 {
            viewModel.expirePullRequestLookupThrottleForTesting()
            viewModel.refreshOpenPullRequest(force: false)
            await settleLookups(viewModel)
        }

        #expect(fakeGit.pullRequestLookupCallCount == 1)
        #expect(viewModel.pullRequestLookupAuthBlocked)
    }

    @MainActor
    @Test("Transient lookup failures keep polling")
    func transientLookupFailuresKeepPolling() async throws {
        let (viewModel, fakeGit, repo, _) = try makePullRequestLookupPanel(
            "pr-breaker-transient",
            result: .unavailable("Post \"https://api.github.com/graphql\": dial tcp 140.82.116.6:443: i/o timeout")
        )
        defer { try? FileManager.default.removeItem(atPath: repo) }

        for attempt in 1...3 {
            viewModel.expirePullRequestLookupThrottleForTesting()
            viewModel.refreshOpenPullRequest(force: false)
            await awaitLookups(viewModel, fakeGit, count: attempt)
        }

        #expect(fakeGit.pullRequestLookupCallCount == 3)
        #expect(!viewModel.pullRequestLookupAuthBlocked)
        #expect(viewModel.pullRequestLookupIssue?.contains("i/o timeout") == true)
    }

    @MainActor
    @Test("Manual retry re-attempts a blocked pull request lookup")
    func manualRetryReattemptsBlockedLookup() async throws {
        let (viewModel, fakeGit, repo, _) = try makePullRequestLookupPanel(
            "pr-breaker-retry",
            result: .unavailable(Self.samlLookupFailure)
        )
        defer { try? FileManager.default.removeItem(atPath: repo) }

        viewModel.refreshOpenPullRequest(force: true)
        await awaitLookups(viewModel, fakeGit, count: 1)
        #expect(viewModel.pullRequestLookupAuthBlocked)

        viewModel.retryPullRequestLookup()
        await awaitLookups(viewModel, fakeGit, count: 2)
        #expect(fakeGit.pullRequestLookupCallCount == 2)

        fakeGit.pullRequestLookupResult = .found(
            GitHubPullRequestRef(
                number: 42,
                url: "https://github.com/example/repo/pull/42",
                title: "Add login",
                isDraft: false,
                state: "OPEN"
            )
        )
        viewModel.retryPullRequestLookup()
        await awaitLookups(viewModel, fakeGit, count: 3)

        #expect(fakeGit.pullRequestLookupCallCount == 3)
        #expect(!viewModel.pullRequestLookupAuthBlocked)
        #expect(viewModel.openPullRequest?.number == 42)
        #expect(viewModel.pullRequestLookupIssue == nil)
    }

    @MainActor
    @Test("Switching branches re-probes a blocked pull request lookup")
    func branchChangeReprobesBlockedLookup() async throws {
        let (viewModel, fakeGit, repo, _) = try makePullRequestLookupPanel(
            "pr-breaker-branch",
            result: .unavailable(Self.samlLookupFailure)
        )
        defer { try? FileManager.default.removeItem(atPath: repo) }

        viewModel.refreshOpenPullRequest(force: true)
        await awaitLookups(viewModel, fakeGit, count: 1)
        #expect(viewModel.pullRequestLookupAuthBlocked)

        viewModel.currentBranch = "feature/other"
        viewModel.refreshOpenPullRequest(force: false)
        await awaitLookups(viewModel, fakeGit, count: 2)

        #expect(fakeGit.pullRequestLookupCallCount == 2)
    }

    @MainActor
    @Test("Returning to the app re-probes a blocked pull request lookup")
    func foregroundingReprobesBlockedLookup() async throws {
        let (viewModel, fakeGit, repo, _) = try makePullRequestLookupPanel(
            "pr-breaker-foreground",
            result: .unavailable(Self.samlLookupFailure)
        )
        defer { try? FileManager.default.removeItem(atPath: repo) }
        await openLookupBreaker(viewModel, fakeGit)

        // The user leaves for the browser, authorizes, and comes back.
        viewModel.pauseRefresh()
        viewModel.agePullRequestLookupBreakerForTesting()
        viewModel.resumeRefresh()

        #expect(!viewModel.pullRequestLookupAuthBlocked)

        fakeGit.pullRequestLookupResult = .none
        viewModel.expirePullRequestLookupThrottleForTesting()
        viewModel.refreshOpenPullRequest(force: false)
        await awaitLookups(viewModel, fakeGit, count: 2)

        #expect(fakeGit.pullRequestLookupCallCount == 2)
        #expect(!viewModel.pullRequestLookupAuthBlocked)
    }

    @MainActor
    @Test("Re-opening the panel re-probes a blocked pull request lookup")
    func panelSetupReprobesBlockedLookup() async throws {
        let (viewModel, fakeGit, repo, workspace) = try makePullRequestLookupPanel(
            "pr-breaker-setup",
            result: .unavailable(Self.samlLookupFailure)
        )
        defer { try? FileManager.default.removeItem(atPath: repo) }
        await openLookupBreaker(viewModel, fakeGit)

        // The repository rail goes offscreen while the user authorizes, then
        // comes back. `setup` clears `isRefreshPaused` itself, so a scene-phase
        // resume afterwards can no longer be the thing that re-arms.
        viewModel.pauseRefresh()
        viewModel.agePullRequestLookupBreakerForTesting()
        viewModel.setup(for: workspace)
        #expect(!viewModel.pullRequestLookupAuthBlocked)
        viewModel.resumeRefresh()

        fakeGit.pullRequestLookupResult = .none
        viewModel.expirePullRequestLookupThrottleForTesting()
        viewModel.refreshOpenPullRequest(force: false)
        await awaitLookups(viewModel, fakeGit, count: 2)

        #expect(fakeGit.pullRequestLookupCallCount == 2)
        #expect(!viewModel.pullRequestLookupAuthBlocked)
    }

    @MainActor
    @Test("Switching tasks inside a visible panel does not re-arm a blocked lookup")
    func taskSwitchKeepsBlockedLookupPaused() async throws {
        let (viewModel, fakeGit, repo, workspace) = try makePullRequestLookupPanel(
            "pr-breaker-task-switch",
            result: .unavailable(Self.samlLookupFailure)
        )
        defer { try? FileManager.default.removeItem(atPath: repo) }
        await openLookupBreaker(viewModel, fakeGit)

        // The panel never went offscreen: only the sidebar selection moved. It
        // drives `setup` from `.task(id:)` over a signature that includes the
        // selected task, so this is what every click in the task list looks
        // like. Age the breaker past the foreground delay first, so the only
        // thing standing between this task switch and a fresh `gh` spawn is
        // the 900s cooldown itself.
        viewModel.agePullRequestLookupBreakerForTesting()
        let nextTask = AgentTask(title: "Another", goal: "Work", workspace: workspace)
        viewModel.setup(for: workspace, selectedTask: nextTask)

        #expect(viewModel.pullRequestLookupAuthBlocked)

        // And the cooldown still suppresses the poll, which is the behaviour
        // the caption promises: browsing tasks with a lapsed credential must
        // not degrade the 900s floor to the 60s foreground delay.
        viewModel.expirePullRequestLookupThrottleForTesting()
        viewModel.refreshOpenPullRequest(force: false)
        await settleLookups(viewModel)

        #expect(fakeGit.pullRequestLookupCallCount == 1)
        #expect(viewModel.pullRequestLookupAuthBlocked)
    }

    @MainActor
    @Test("Selecting another repository clears the blocked lookup state")
    func repositoryChangeClearsBlockedLookup() async throws {
        let (viewModel, fakeGit, repo, _) = try makePullRequestLookupPanel(
            "pr-breaker-repo-change",
            result: .unavailable(Self.samlLookupFailure)
        )
        let other = try makeTempDir("pr-breaker-repo-change-other")
        defer {
            try? FileManager.default.removeItem(atPath: repo)
            try? FileManager.default.removeItem(atPath: other)
        }
        await openLookupBreaker(viewModel, fakeGit)

        fakeGit.pullRequestLookupResult = .none
        viewModel.selectRepository(GitRepositoryInfo(name: "Other", path: other))

        // The paused caption belongs to the repository that failed; pointing
        // the panel somewhere else must drop it in the same turn, before the
        // forced lookup for the new repository has answered.
        #expect(!viewModel.pullRequestLookupAuthBlocked)

        await awaitLookups(viewModel, fakeGit, count: 2)
        #expect(fakeGit.pullRequestLookupCallCount >= 2)
        #expect(!viewModel.pullRequestLookupAuthBlocked)
    }

    @MainActor
    @Test("Publishing a pull request clears the blocked lookup before the follow-up probe answers")
    func publishClearsBlockedLookup() async throws {
        let (viewModel, fakeGit, repo, _) = try makePullRequestLookupPanel(
            "pr-breaker-publish",
            result: .unavailable(Self.samlLookupFailure)
        )
        defer { try? FileManager.default.removeItem(atPath: repo) }
        await openLookupBreaker(viewModel, fakeGit)

        // Branch is published and clean, so the panel can create the PR.
        viewModel.hasUpstream = true
        await fakeGit.lookupGate.gate(call: 2)

        viewModel.createPullRequest(with: PRSuggestion(title: "Add login", body: "Body"))
        // Entry-only: the follow-up probe is held inside the service, so the
        // panel is inspected mid-flight rather than after it answers.
        await awaitLookupStart(fakeGit, count: 2)

        // The PR now demonstrably exists, so the panel must stop telling the
        // user its pull-request check is paused while the probe runs.
        #expect(viewModel.openPullRequest?.number == 1)
        #expect(!viewModel.pullRequestLookupAuthBlocked)

        await fakeGit.lookupGate.openGate()
        await viewModel.waitForPendingPullRequestLookupForTesting()
    }

    @MainActor
    @Test("A verified GitHub access repair re-probes only the repaired repository")
    func accessRepairReprobesBlockedLookup() async throws {
        let (viewModel, fakeGit, repo, _) = try makePullRequestLookupPanel(
            "pr-breaker-repair",
            result: .unavailable(Self.samlLookupFailure)
        )
        let unrelated = try makeTempDir("pr-breaker-repair-unrelated")
        defer {
            try? FileManager.default.removeItem(atPath: repo)
            try? FileManager.default.removeItem(atPath: unrelated)
        }
        await openLookupBreaker(viewModel, fakeGit)

        // Repairing some other checkout says nothing about this credential.
        NotificationCenter.default.post(
            name: .gitHubRepositoryAccessRepaired,
            object: unrelated
        )
        await settleLookups(viewModel)
        #expect(fakeGit.pullRequestLookupCallCount == 1)
        #expect(viewModel.pullRequestLookupAuthBlocked)

        fakeGit.pullRequestLookupResult = .found(
            GitHubPullRequestRef(
                number: 42,
                url: "https://github.com/example/repo/pull/42",
                title: "Add login",
                isDraft: false,
                state: "OPEN"
            )
        )
        NotificationCenter.default.post(
            name: .gitHubRepositoryAccessRepaired,
            object: repo
        )
        await awaitLookups(viewModel, fakeGit, count: 2)

        #expect(fakeGit.pullRequestLookupCallCount == 2)
        #expect(!viewModel.pullRequestLookupAuthBlocked)
        #expect(viewModel.openPullRequest?.number == 42)
    }
}

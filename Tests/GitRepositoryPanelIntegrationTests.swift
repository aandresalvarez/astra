import Foundation
import Testing
@testable import ASTRA
import ASTRAGitContracts

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
            .none
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
}

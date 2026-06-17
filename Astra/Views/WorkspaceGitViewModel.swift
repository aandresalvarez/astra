import Foundation
import SwiftUI
import Combine
import SwiftData
import ASTRACore
import ASTRAGitContracts

@MainActor
final class WorkspaceGitViewModel: ObservableObject {
    // Repositories
    @Published var repositories: [GitRepositoryInfo] = []
    @Published var selectedRepository: GitRepositoryInfo? = nil {
        didSet {
            if oldValue?.path != selectedRepository?.path {
                scheduleRefresh()
            }
        }
    }

    // Branch + status
    @Published var currentBranch: String = ""
    @Published var branches: [String] = []
    @Published var statusFiles: [GitStatusFile] = []

    // Commit composer
    @Published var commitMessage: String = ""

    // Diff stats
    @Published var additions: Int = 0
    @Published var deletions: Int = 0
    @Published var selectedFileDiff: GitFileDiff? = nil
    @Published var isLoadingFileDiff: Bool = false

    // Sync (pull + push)
    @Published var ahead: Int = 0
    @Published var behind: Int = 0
    @Published var hasUpstream: Bool = false
    @Published var hasRemote: Bool = false
    @Published var unpushedCount: Int = 0
    @Published var isSyncing: Bool = false

    // Worktrees
    @Published var worktrees: [GitWorktreeInfo] = []
    /// Absolute path of the working location new chats default to and the panel
    /// operates in. `nil` means the repository root. Mirrors
    /// `workspace.activeWorkingPath` for SwiftUI observation.
    @Published var activeWorkingPath: String? = nil
    @Published var isManagingWorktrees: Bool = false
    @Published var newWorktreeBranch: String = ""
    /// Set when a removal was refused because the worktree has uncommitted
    /// changes, so the UI can ask the user to confirm a forced removal.
    @Published var worktreePendingForceRemoval: GitWorktreeInfo? = nil

    // Helper model
    @Published var isSuggestingCommit: Bool = false
    @Published var isSuggestingPR: Bool = false
    @Published var prDraft: PRSuggestion? = nil

    /// The open pull request for the current branch, when one exists. Drives the
    /// panel to link to the PR instead of offering to create a duplicate.
    @Published var openPullRequest: GitHubPullRequestRef? = nil
    @Published var pullRequestLookupIssue: String? = nil
    @Published var pullRequestComments: GitHubPullRequestCommentSummary? = nil
    @Published var pullRequestCommentsIssue: String? = nil
    @Published var isRefreshingPullRequestComments: Bool = false
    @Published var newPullRequestCommentCount: Int = 0
    @Published var pullRequestChecks: GitHubPullRequestCheckSummary? = nil
    @Published var pullRequestChecksIssue: String? = nil
    @Published var isRefreshingPullRequestChecks: Bool = false
    private var prLookupBranch: String?
    private var prLookupAt: Date?
    private var prCommentsKey: String?
    private var prCommentsLookupAt: Date?
    private var prChecksKey: String?
    private var prChecksLookupAt: Date?

    // UI state
    @Published var errorMessage: String? = nil
    @Published var showNewBranchPopover = false
    @Published var showBranchPickerPopover = false
    @Published var newBranchName = ""

    private var workspace: Workspace?
    private var selectedTask: AgentTask?
    private var refreshTimer: Timer?
    /// The most recently scheduled background status refresh. Refreshes are
    /// chained through this handle so they never overlap (each awaits the
    /// previous) and so callers — and tests — can drain pending work instead
    /// of racing a detached `didSet`/timer task.
    private var refreshTask: Task<Void, Never>?
    private var isRefreshPaused = false
    // Background git status refresh interval. Each tick fans out git
    // subprocesses, so we keep it lazy (30s) and pause it entirely when the
    // rail is offscreen or the app is backgrounded — see pause/resumeRefresh.
    private let refreshInterval: TimeInterval = 30.0
    private let git: GitRepositoryOperating

    var authoringServiceFactory: (() -> any GitCommitMessageGenerating & GitPullRequestGenerating)?

    init(git: GitRepositoryOperating = GitService.shared) {
        self.git = git
    }

    private func makeAuthoringService() -> any GitCommitMessageGenerating & GitPullRequestGenerating {
        if let factory = authoringServiceFactory { return factory() }
        let runtime = AgentRuntimeAdapterRegistry.registeredRuntime(
            rawValue: UserDefaults.standard.string(forKey: "defaultRuntimeID")
        )
        let model = RuntimeModelAvailability.normalizedModel(
            UserDefaults.standard.string(forKey: "validationModel") ?? "claude-haiku-4-5-20251001",
            for: runtime
        )
        return AgentGitAuthoringService(
            utilityRuntime: AgentUtilityRuntimeConfiguration(
                runtime: runtime,
                model: model,
                providerSettings: RuntimeProviderSettingsStore.settings()
            )
        )
    }

    func setup(for workspace: Workspace, selectedTask: AgentTask? = nil) {
        self.workspace = workspace
        self.selectedTask = selectedTask
        self.activeWorkingPath = initialActiveCodePath(workspace: workspace, selectedTask: selectedTask)
        Task { await scanRepositories() }

        // setup() runs on appear / task change, i.e. the rail is visible again.
        isRefreshPaused = false
        startRefreshTimer()
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        guard !isRefreshPaused else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleRefresh()
            }
        }
    }

    /// Stop the background refresh ticks. Call when the rail goes offscreen or
    /// the app is backgrounded so idle windows stop spawning git subprocesses.
    func pauseRefresh() {
        isRefreshPaused = true
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// Resume background refresh and refresh once immediately so the rail is
    /// current the moment it becomes visible/active again.
    func resumeRefresh() {
        guard isRefreshPaused else { return }
        isRefreshPaused = false
        guard workspace != nil else { return }
        scheduleRefresh()
        startRefreshTimer()
    }

    #if DEBUG
    func setWorkspaceForTesting(_ workspace: Workspace, selectedTask: AgentTask? = nil) {
        self.workspace = workspace
        self.selectedTask = selectedTask
        self.activeWorkingPath = initialActiveCodePath(workspace: workspace, selectedTask: selectedTask)
    }
    #endif

    deinit {
        refreshTimer?.invalidate()
    }

    // MARK: - Repository scan

    func scanRepositories() async {
        guard let workspace = workspace else { return }
        let repos = await git.scanForGitRepositories(
            primaryPath: workspace.primaryPath,
            additionalPaths: workspace.additionalPaths
        )
        self.repositories = repos
        if let preferred = preferredRepository(in: repos) {
            self.selectedRepository = preferred
        } else if self.selectedRepository == nil {
            self.selectedRepository = repos.first
        } else if !repos.contains(where: { $0.path == self.selectedRepository?.path }) {
            self.selectedRepository = repos.first
        }
        persistScannedRepositorySelectionIfNeeded()
        scheduleRefresh()
        await waitForPendingRefresh()
    }

    private func persistScannedRepositorySelectionIfNeeded() {
        // A scan is read-only with respect to task pinning: only adopt the
        // scanned selection as the workspace code default when no task is
        // selected. A selected task (including a draft) must be pinned only by an
        // explicit user selection in `selectRepository`, never as a side effect
        // of a background scan. `setActiveWorkingPath` skips no-op writes, so this
        // never churns `workspace.updatedAt` when the default already matches.
        guard selectedTask == nil,
              let selectedRepository
        else { return }
        _ = setActiveWorkingPath(selectedRepository.path)
    }

    /// Schedules a status refresh that runs after any in-flight refresh
    /// completes, replacing `refreshTask` with the chained handle.
    @MainActor
    private func scheduleRefresh(force: Bool = false) {
        let previous = refreshTask
        refreshTask = Task { @MainActor [weak self] in
            await previous?.value
            await self?.refreshRepoDetails(force: force)
        }
    }

    /// Awaits the most recently scheduled refresh (and, transitively, every
    /// refresh chained before it). Lets `scanRepositories` and tests observe a
    /// settled panel instead of racing a detached `didSet`/timer refresh.
    func waitForPendingRefresh() async {
        await refreshTask?.value
    }

    private func initialActiveCodePath(workspace: Workspace, selectedTask: AgentTask?) -> String? {
        if let pinned = selectedTask?.executionRootPath,
           !pinned.isEmpty,
           FileManager.default.fileExists(atPath: pinned) {
            return WorkspacePathPresentation.standardizedPath(pinned)
        }
        if let active = workspace.activeWorkingPath,
           !active.isEmpty,
           FileManager.default.fileExists(atPath: active) {
            return WorkspacePathPresentation.standardizedPath(active)
        }
        return nil
    }

    private func preferredRepository(in repos: [GitRepositoryInfo]) -> GitRepositoryInfo? {
        let candidates = [
            activeWorkingPath,
            selectedTask?.executionRootPath,
            workspace?.activeWorkingPath,
            selectedRepository?.path,
            workspace?.primaryPath
        ]
        .compactMap { $0 }
        .map(WorkspacePathPresentation.standardizedPath)

        for candidate in candidates {
            if let exact = repos.first(where: { $0.path == candidate }) {
                return exact
            }
        }
        return nil
    }

    /// The actual git repository (with a `.git` directory) backing the panel.
    /// Worktree management always runs against this root path.
    var rootRepoPath: String? { selectedRepository?.path }

    /// The checkout the panel currently operates in: the active worktree when
    /// one is selected and still on disk, otherwise the repository root. All
    /// status, staging, commit, and push actions resolve through here so the
    /// panel always reflects the working location the user picked.
    var workingPath: String? {
        if let active = activeWorkingPath,
           !active.isEmpty,
           FileManager.default.fileExists(atPath: active) {
            return active
        }
        return selectedRepository?.path
    }

    /// True when the panel is focused on a worktree rather than the root.
    var isUsingWorktree: Bool {
        guard let active = activeWorkingPath, !active.isEmpty else { return false }
        return active != selectedRepository?.path
    }

    var selectedRepositoryName: String {
        selectedRepository?.name ?? "No repository"
    }

    var selectedRepositorySubtitle: String {
        guard let repo = selectedRepository else { return "No git repository found" }
        if !repo.subtitle.isEmpty { return repo.subtitle }
        return WorkspacePathPresentation.abbreviatePath(repo.path)
    }

    /// Full, un-abbreviated path for the repository row tooltip so the
    /// truncated subtitle never hides where the repo actually lives.
    var selectedRepositoryFullPath: String? {
        guard let repo = selectedRepository else { return nil }
        return WorkspacePathPresentation.standardizedPath(repo.path)
    }

    var activeSelectionScopeLabel: String {
        guard let task = selectedTask else { return "Workspace default" }
        if task.status == .draft { return "Draft task" }
        // Only claim a durable pin when the pinned path still exists on disk:
        // `TaskWorkspaceAccess` falls back to the workspace default when the
        // pinned directory is missing, so a stale path is effectively unpinned.
        // This mirrors the file-existence checks in `initialActiveCodePath` /
        // `workingPath`.
        if let pinned = task.executionRootPath,
           !pinned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           FileManager.default.fileExists(atPath: pinned) {
            return "Pinned task"
        }
        return "Workspace default"
    }

    var canChangeActiveCodePath: Bool {
        guard let task = selectedTask else { return true }
        return task.status == .draft
    }

    var activeCodePathChangeBlockedMessage: String {
        "This task already has execution history, so its repository is pinned. Fork or start a new task to use another repository."
    }

    func selectRepository(_ repo: GitRepositoryInfo) {
        guard canChangeActiveCodePath else {
            errorMessage = activeCodePathChangeBlockedMessage
            AppLogger.audit(.gitActiveRepositoryChanged, category: "Git", fields: [
                "result": "blocked",
                "repo": repo.path,
                "scope": activeSelectionScopeLabel
            ], level: .warning)
            return
        }

        selectedRepository = repo
        setActiveWorkingPath(repo.path)
        clearPullRequestComments()
        openPullRequest = nil
        pullRequestLookupIssue = nil
        prLookupBranch = nil
        prLookupAt = nil
        AppLogger.audit(.gitActiveRepositoryChanged, category: "Git", fields: [
            "result": "changed",
            "repo": repo.path,
            "scope": activeSelectionScopeLabel
        ])
        Task { await refreshRepoDetails(force: true) }
    }

    func refreshRepoDetails(force: Bool = false) async {
        guard let path = workingPath, let rootPath = rootRepoPath else { return }
        if !force {
            guard git.acquireIndexGuard() else {
                AppLogger.debug("Git refresh skipped — another refresh in progress", category: "Git")
                return
            }
        }
        defer { if !force { git.releaseIndexGuard() } }

        async let branch = git.getCurrentBranch(at: path)
        async let localBranches = git.getLocalBranches(at: path)
        async let files = git.getStatusFiles(at: path)
        async let diffStats = git.getDiffStats(at: path)
        async let upstream = git.hasUpstream(at: path)
        async let aheadBehind = git.getAheadBehind(at: path)
        async let remote = git.hasRemote(at: path)
        async let unpushed = git.getUnpushedCommitCount(at: path)
        async let trees = git.listWorktrees(at: rootPath)

        self.currentBranch = await branch
        self.branches = await localBranches
        self.statusFiles = await files
        let stats = await diffStats
        self.additions = stats.additions
        self.deletions = stats.deletions
        self.hasUpstream = await upstream
        self.hasRemote = await remote
        self.unpushedCount = await unpushed
        self.worktrees = await trees
        if let ab = await aheadBehind {
            self.ahead = ab.ahead
            self.behind = ab.behind
        } else {
            self.ahead = 0
            self.behind = 0
        }
        reconcileActiveWorkingPathWithDisk()
        refreshOpenPullRequest(force: force)
    }

    /// Best-effort lookup of an existing open PR for the current branch. Runs
    /// off the status-refresh path (so it never blocks status updates), is
    /// throttled to avoid hammering the network on the periodic refresh, and is
    /// keyed by branch so a stale PR never lingers after a branch switch.
    func refreshOpenPullRequest(force: Bool) {
        guard let path = workingPath else { return }
        let branch = currentBranch
        guard hasRemote, !branch.isEmpty else {
            openPullRequest = nil
            pullRequestLookupIssue = nil
            prLookupBranch = nil
            prLookupAt = nil
            clearPullRequestComments()
            clearPullRequestChecks()
            return
        }

        let branchChanged = branch != prLookupBranch
        if !force,
           !branchChanged,
           let checkedAt = prLookupAt,
           Date().timeIntervalSince(checkedAt) < 60 {
            return
        }
        // Drop a previous branch's PR immediately so the panel never shows a
        // mismatched number while the async lookup is in flight.
        if branchChanged { openPullRequest = nil }
        if branchChanged { pullRequestLookupIssue = nil }
        if branchChanged { clearPullRequestComments() }
        if branchChanged { clearPullRequestChecks() }
        prLookupBranch = branch
        prLookupAt = Date()

        Task {
            let result = await git.lookupOpenPullRequest(repoPath: path, head: branch)
            if self.currentBranch == branch {
                switch result {
                case let .found(pr):
                    self.openPullRequest = pr
                    self.pullRequestLookupIssue = nil
                    self.refreshPullRequestComments(for: pr, repoPath: path, branch: branch, force: force || branchChanged)
                    self.refreshPullRequestChecks(for: pr, repoPath: path, branch: branch, force: force || branchChanged)
                case .none:
                    self.openPullRequest = nil
                    self.pullRequestLookupIssue = nil
                    self.clearPullRequestComments()
                    self.clearPullRequestChecks()
                case let .unavailable(detail):
                    self.openPullRequest = nil
                    self.pullRequestLookupIssue = detail
                    self.clearPullRequestComments()
                    self.clearPullRequestChecks()
                }
            }
        }
    }

    func refreshPullRequestComments(
        for pr: GitHubPullRequestRef,
        repoPath: String,
        branch: String,
        force: Bool
    ) {
        let key = "\(repoPath)|\(branch)|\(pr.number)|\(pr.url)"
        if !force,
           key == prCommentsKey,
           let checkedAt = prCommentsLookupAt,
           Date().timeIntervalSince(checkedAt) < 60 {
            return
        }
        prCommentsKey = key
        prCommentsLookupAt = Date()
        isRefreshingPullRequestComments = true

        Task {
            let result = await git.lookupPullRequestComments(
                repoPath: repoPath,
                pullRequest: pr
            )
            guard self.currentBranch == branch,
                  self.openPullRequest?.number == pr.number,
                  self.workingPath == repoPath else {
                if self.prCommentsKey == key {
                    self.isRefreshingPullRequestComments = false
                }
                return
            }
            self.isRefreshingPullRequestComments = false
            switch result {
            case let .found(summary):
                self.pullRequestComments = summary
                self.pullRequestCommentsIssue = nil
                self.updateNewPullRequestCommentCount(for: summary)
            case let .unavailable(detail):
                self.pullRequestComments = nil
                self.pullRequestCommentsIssue = detail
                self.newPullRequestCommentCount = 0
            }
        }
    }

    private func clearPullRequestComments() {
        pullRequestComments = nil
        pullRequestCommentsIssue = nil
        isRefreshingPullRequestComments = false
        newPullRequestCommentCount = 0
        prCommentsKey = nil
        prCommentsLookupAt = nil
    }

    private func refreshPullRequestChecks(
        for pr: GitHubPullRequestRef,
        repoPath: String,
        branch: String,
        force: Bool
    ) {
        let key = "\(repoPath)|\(branch)|\(pr.number)|\(pr.url)"
        if !force,
           key == prChecksKey,
           let checkedAt = prChecksLookupAt,
           Date().timeIntervalSince(checkedAt) < 60 {
            return
        }
        prChecksKey = key
        prChecksLookupAt = Date()
        isRefreshingPullRequestChecks = true

        Task {
            let result = await git.lookupPullRequestChecks(repoPath: repoPath, pullRequest: pr)
            guard self.currentBranch == branch,
                  self.openPullRequest?.number == pr.number,
                  self.workingPath == repoPath else {
                if self.prChecksKey == key {
                    self.isRefreshingPullRequestChecks = false
                }
                return
            }
            self.isRefreshingPullRequestChecks = false
            switch result {
            case let .found(summary):
                self.pullRequestChecks = summary
                self.pullRequestChecksIssue = nil
            case let .unavailable(detail):
                self.pullRequestChecks = nil
                self.pullRequestChecksIssue = detail
            }
        }
    }

    private func clearPullRequestChecks() {
        pullRequestChecks = nil
        pullRequestChecksIssue = nil
        isRefreshingPullRequestChecks = false
        prChecksKey = nil
        prChecksLookupAt = nil
    }

    func refreshPullRequestCommentsNow() {
        guard let pr = openPullRequest, let path = workingPath else { return }
        refreshPullRequestComments(for: pr, repoPath: path, branch: currentBranch, force: true)
        refreshPullRequestChecks(for: pr, repoPath: path, branch: currentBranch, force: true)
    }

    func markPullRequestCommentsSeen() {
        guard let summary = pullRequestComments,
              let key = pullRequestCommentsSeenKey(for: summary) else {
            return
        }
        let latest = summary.latestCommentCreatedAt ?? ""
        UserDefaults.standard.set(latest, forKey: key)
        newPullRequestCommentCount = 0
    }

    private func updateNewPullRequestCommentCount(for summary: GitHubPullRequestCommentSummary) {
        guard let key = pullRequestCommentsSeenKey(for: summary) else {
            newPullRequestCommentCount = 0
            return
        }
        let seenLatest = UserDefaults.standard.string(forKey: key) ?? ""
        guard !seenLatest.isEmpty else {
            newPullRequestCommentCount = summary.totalCommentCount
            return
        }
        newPullRequestCommentCount = summary.comments.filter { $0.createdAt > seenLatest }.count
    }

    private func pullRequestCommentsSeenKey(for summary: GitHubPullRequestCommentSummary) -> String? {
        let normalizedURL = summary.pullRequest.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedURL.isEmpty else { return nil }
        return "repositoryPanel.prCommentsSeen.\(normalizedURL)"
    }

    /// Opens the current branch's existing pull request in the browser.
    func openExistingPullRequest() {
        guard let pr = openPullRequest, let url = URL(string: pr.url) else { return }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #endif
    }

    /// Copies the existing pull request URL to the pasteboard.
    func copyPullRequestURL() {
        guard let pr = openPullRequest else { return }
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pr.url, forType: .string)
        #endif
    }

    func createPullRequestCommentTask(modelContext: ModelContext) -> AgentTask? {
        guard let workspace,
              let path = workingPath,
              let pr = openPullRequest,
              let summary = pullRequestComments,
              summary.hasComments else {
            return nil
        }

        let runtime = AgentRuntimeAdapterRegistry.registeredRuntime(
            rawValue: UserDefaults.standard.string(forKey: "defaultRuntimeID")
        )
        let model = RuntimeModelAvailability.normalizedModel(
            UserDefaults.standard.string(forKey: "defaultModel") ?? TaskExecutionDefaults.model,
            for: runtime
        )
        let budget = UserDefaults.standard.object(forKey: AppStorageKeys.defaultTokenBudget) as? Int
            ?? TaskExecutionDefaults.tokenBudget
        let goal = Self.pullRequestCommentTaskGoal(
            pullRequest: pr,
            summary: summary,
            branch: currentBranch,
            repoPath: path
        )
        let task = AgentTask(
            title: "Address PR #\(pr.number) comments",
            goal: goal,
            workspace: workspace,
            tokenBudget: budget,
            model: model,
            runtime: runtime
        )
        task.status = .draft
        task.executionRootPath = path
        task.draftMessages = AstraTaskIntentSupport.draftMessagesJSON(for: goal)
        modelContext.insert(task)
        TaskCapabilitySnapshotter.capture(for: task)
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
        AppLogger.audit(.gitPullRequestAddressTask, category: "Git", taskID: task.id, fields: [
            "pr": "#\(pr.number)",
            "comments": "\(summary.totalCommentCount)",
            "unresolved_threads": "\(summary.unresolvedThreadCount)",
            "branch": currentBranch,
            "mode": "draft"
        ])
        return task
    }

    static func pullRequestCommentTaskGoal(
        pullRequest pr: GitHubPullRequestRef,
        summary: GitHubPullRequestCommentSummary,
        branch: String,
        repoPath: String
    ) -> String {
        let comments = summary.comments.prefix(12).enumerated().map { index, comment in
            let kind = comment.isReviewThread ? "review thread" : "conversation"
            return """
            \(index + 1). \(kind) by @\(comment.author) at \(comment.locationLabel)
               \(comment.preview)
               \(comment.url)
            """
        }.joined(separator: "\n")
        let omitted = summary.comments.count > 12
            ? "\n\nAdditional comments omitted from this prompt: \(summary.comments.count - 12). Re-fetch before editing."
            : ""
        return """
        Address the review comments on GitHub pull request #\(pr.number): \(pr.title.isEmpty ? "Untitled PR" : pr.title)

        PR: \(pr.url)
        Branch: \(branch)
        Repository path: \(repoPath)
        Current unresolved review threads: \(summary.unresolvedThreadCount)
        Current visible comments: \(summary.totalCommentCount)

        Comments captured by ASTRA:
        \(comments)\(omitted)

        Before editing, re-fetch the latest unresolved review comments for this PR with the GitHub CLI, because comments may have changed since ASTRA captured this snapshot. Make focused code changes that address the actionable comments, add or update regression tests for each bug fixed, run the narrow relevant tests, and summarize what remains. Do not merge the PR or post GitHub replies unless explicitly asked.
        """
    }

    // MARK: - Worktrees

    /// Drops a stale active worktree binding when its directory disappeared
    /// (e.g. removed outside ASTRA), so the panel degrades to the root instead
    /// of showing an empty location.
    private func reconcileActiveWorkingPathWithDisk() {
        guard let active = activeWorkingPath, !active.isEmpty else { return }
        if !FileManager.default.fileExists(atPath: active) {
            if canChangeActiveCodePath {
                _ = setActiveWorkingPath(nil)
            } else {
                activeWorkingPath = nil
            }
        }
    }

    /// Persists the active code location for the current editing scope and
    /// mirrors it for the view. For a selected draft task this updates the task
    /// pin; otherwise it updates the workspace default used by new chats.
    @discardableResult
    private func setActiveWorkingPath(_ path: String?) -> Bool {
        guard canChangeActiveCodePath else {
            errorMessage = activeCodePathChangeBlockedMessage
            return false
        }

        let normalized = path
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            .map(WorkspacePathPresentation.standardizedPath)

        activeWorkingPath = normalized
        guard let workspace else { return true }
        let persistedOverride = normalized == WorkspacePathPresentation.standardizedPath(workspace.primaryPath)
            ? nil
            : normalized

        if let selectedTask {
            // Skip no-op writes so reselecting the same repo (or a scan) never
            // bumps updatedAt or marks the model dirty.
            guard selectedTask.executionRootPath != persistedOverride else { return true }
            selectedTask.executionRootPath = persistedOverride
            selectedTask.updatedAt = Date()
        } else {
            guard workspace.activeWorkingPath != persistedOverride else { return true }
            workspace.activeWorkingPath = persistedOverride
            workspace.updatedAt = Date()
        }
        return true
    }

    /// The worktree the panel is currently focused on, if any.
    var activeWorktree: GitWorktreeInfo? {
        guard let active = activeWorkingPath else { return nil }
        return worktrees.first { $0.path == active }
    }

    /// Switches the working location. Existing threads keep their own pinned
    /// location; only new chats follow this selection.
    func switchWorkingLocation(to worktree: GitWorktreeInfo) {
        guard setActiveWorkingPath(worktree.isPrimary ? selectedRepository?.path : worktree.path) else { return }
        errorMessage = nil
        Task { await refreshRepoDetails(force: true) }
    }

    /// Returns focus to the repository root for new chats.
    func switchToRoot() {
        guard setActiveWorkingPath(selectedRepository?.path) else { return }
        errorMessage = nil
        Task { await refreshRepoDetails(force: true) }
    }

    /// Creates a new worktree on a brand-new branch off the current HEAD and
    /// focuses the workspace on it, so the next chat starts there.
    func createWorktree(branch: String, makeActive: Bool = true) {
        guard let rootPath = rootRepoPath else { return }
        let cleanBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanBranch.isEmpty else {
            errorMessage = "Enter a branch name for the new worktree."
            return
        }
        AppLogger.audit(.gitBranchCreated, category: "Git", fields: [
            "branch": cleanBranch, "kind": "worktree"
        ])
        isSyncing = true
        Task {
            do {
                let exists = await git.localBranchExists(cleanBranch, at: rootPath)
                let createdPath = try await git.addWorktree(
                    repoPath: rootPath,
                    branch: cleanBranch,
                    createBranch: !exists,
                    base: exists ? nil : currentBranch
                )
                self.newWorktreeBranch = ""
                self.errorMessage = nil
                if makeActive {
                    _ = self.setActiveWorkingPath(createdPath)
                }
                await refreshRepoDetails(force: true)
            } catch {
                AppLogger.error("Create worktree failed: \(error.localizedDescription)", category: "Git")
                self.errorMessage = error.localizedDescription
            }
            isSyncing = false
        }
    }

    /// True when a non-terminal task is pinned to the given worktree, so the UI
    /// can block a removal that would pull the rug out from active work.
    func hasActiveTaskPinned(to worktree: GitWorktreeInfo) -> Bool {
        guard let workspace else { return false }
        return workspace.tasks.contains { !$0.isTerminal && $0.executionRootPath == worktree.path }
    }

    /// Removes a worktree. Refuses to remove the primary tree or a worktree that
    /// a running/queued thread is pinned to. Falls back to the root when the
    /// removed worktree was the active location.
    func removeWorktree(_ worktree: GitWorktreeInfo, force: Bool = false) {
        guard let rootPath = rootRepoPath else { return }
        guard !worktree.isPrimary else {
            errorMessage = GitWorktreeError.cannotRemovePrimary.localizedDescription
            return
        }
        guard !hasActiveTaskPinned(to: worktree) else {
            errorMessage = "A running task is using \"\(worktree.displayName)\". Stop it before removing the worktree."
            return
        }
        isSyncing = true
        Task {
            do {
                try await git.removeWorktree(
                    repoPath: rootPath,
                    worktreePath: worktree.path,
                    force: force
                )
                if activeWorkingPath == worktree.path {
                    _ = setActiveWorkingPath(selectedRepository?.path)
                }
                self.errorMessage = nil
                self.worktreePendingForceRemoval = nil
                await refreshRepoDetails(force: true)
            } catch let error as GitWorktreeError where isDirtyError(error) {
                // Don't discard uncommitted work silently — ask for confirmation.
                self.worktreePendingForceRemoval = worktree
            } catch {
                AppLogger.error("Remove worktree failed: \(error.localizedDescription)", category: "Git")
                self.errorMessage = error.localizedDescription
            }
            isSyncing = false
        }
    }

    private func isDirtyError(_ error: GitWorktreeError) -> Bool {
        if case .worktreeDirty = error { return true }
        return false
    }

    /// Number of local commits not yet on a remote, regardless of whether an
    /// upstream is configured. When an upstream exists this matches `ahead`;
    /// otherwise it reflects commits on an as-yet-unpublished branch.
    var pushableCommitCount: Int {
        hasUpstream ? ahead : unpushedCount
    }

    /// True when there is somewhere to push and unpushed work to send.
    /// False when in sync with the remote or when no remote is configured.
    var canPush: Bool {
        guard hasRemote else { return false }
        return pushableCommitCount > 0
    }

    var pullRequestReadinessIssue: String? {
        let branch = currentBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        if branch.isEmpty || branch == "unknown" {
            return "Cannot determine the current branch for a pull request."
        }
        guard hasRemote else {
            return "No remote configured. Add a remote before creating a pull request."
        }
        guard hasUpstream else {
            return "Publish the current branch before creating a pull request."
        }
        guard !hasConflicts else {
            return "Resolve merge conflicts before creating a pull request."
        }
        guard !hasChanges else {
            return "Commit or stash local changes before creating a pull request."
        }
        guard pushableCommitCount == 0 else {
            let noun = pushableCommitCount == 1 ? "commit" : "commits"
            return "Push \(pushableCommitCount) local \(noun) before creating a pull request."
        }
        return nil
    }

    var canStartPullRequest: Bool {
        pullRequestReadinessIssue == nil
    }

    struct PullRequestActionSnapshot: Equatable {
        let path: String
        let branch: String
    }

    func makePullRequestActionSnapshot() -> PullRequestActionSnapshot? {
        guard let path = workingPath else { return nil }
        let branch = currentBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty, branch != "unknown" else { return nil }
        return PullRequestActionSnapshot(path: path, branch: branch)
    }

    func isCurrentPullRequestActionSnapshot(_ snapshot: PullRequestActionSnapshot) -> Bool {
        currentBranch.trimmingCharacters(in: .whitespacesAndNewlines) == snapshot.branch
            && workingPath == snapshot.path
    }

    @discardableResult
    private func validatePullRequestReadiness() -> Bool {
        if let issue = pullRequestReadinessIssue {
            errorMessage = issue
            AppLogger.audit(.gitPullRequestCreate, category: "Git", fields: [
                "result": "blocked",
                "reason": issue,
                "branch": currentBranch
            ], level: .info, fieldMaxLength: 240)
            return false
        }
        return true
    }

    /// Group-level status for the Changes row, kept in one place so the row can
    /// carry shared status without each file repeating it (lean UI rule). Uses
    /// the working-tree file set — not just line counts — so an untracked-only
    /// repository is never mislabeled "Clean".
    enum ChangesSummary: Equatable {
        case clean
        case modified(additions: Int, deletions: Int, fileCount: Int)
    }

    var changesSummary: ChangesSummary {
        guard !statusFiles.isEmpty else { return .clean }
        let fileCount = Set(statusFiles.map(\.relativePath)).count
        return .modified(additions: additions, deletions: deletions, fileCount: fileCount)
    }

    var hasConflicts: Bool {
        statusFiles.contains(where: \.isConflict)
    }

    // MARK: - Branches

    func checkout(branch: String) {
        guard let path = workingPath else { return }
        AppLogger.audit(.gitCheckout, category: "Git", fields: ["branch": branch])
        Task {
            do {
                try await git.checkoutBranch(branch, at: path)
                self.errorMessage = nil
                await refreshRepoDetails(force: true)
            } catch {
                AppLogger.error("Checkout failed: \(error.localizedDescription)", category: "Git")
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func createAndCheckoutBranch() {
        guard let path = workingPath, !newBranchName.isEmpty else { return }
        AppLogger.audit(.gitBranchCreated, category: "Git", fields: ["branch": newBranchName, "from": currentBranch])
        Task {
            do {
                try await git.createBranch(newBranchName, from: currentBranch, at: path)
                self.newBranchName = ""
                self.showNewBranchPopover = false
                self.errorMessage = nil
                await refreshRepoDetails(force: true)
            } catch {
                AppLogger.error("Create branch failed: \(error.localizedDescription)", category: "Git")
                self.errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Staging

    func absolutePath(for file: GitStatusFile) -> String? {
        guard let path = workingPath else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
            .appendingPathComponent(file.relativePath)
            .standardizedFileURL
            .path
    }

    func noteChangedFileOpenedInShelf(_ file: GitStatusFile, absolutePath: String, exists: Bool) {
        if !exists {
            errorMessage = "\(file.relativePath) is not present in the working tree."
        }
    }

    func loadDiff(for file: GitStatusFile) {
        guard let path = workingPath else { return }
        selectedFileDiff = GitFileDiff(
            id: file.id,
            file: file,
            kind: file.isStaged ? .staged : (file.isUntracked ? .untracked : .unstaged),
            diff: "",
            isTruncated: false,
            message: nil
        )
        isLoadingFileDiff = true
        AppLogger.audit(.gitChangedFileDiffViewed, category: "Git", fields: [
            "file": file.relativePath,
            "status": file.status,
            "staged": file.isStaged ? "true" : "false",
            "repo": path
        ], level: .info)
        Task {
            let diff = await git.getFileDiff(at: path, file: file)
            await MainActor.run {
                self.selectedFileDiff = diff
                self.isLoadingFileDiff = false
            }
        }
    }

    func clearSelectedFileDiff() {
        selectedFileDiff = nil
        isLoadingFileDiff = false
    }

    func stage(file: GitStatusFile) {
        guard let path = workingPath else { return }
        AppLogger.audit(.gitStageFile, category: "Git", fields: ["file": file.relativePath])
        Task {
            do {
                try await git.stageFile(file, at: path)
                await refreshRepoDetails(force: true)
            } catch {
                AppLogger.error("Stage failed for \(file.relativePath): \(error.localizedDescription)", category: "Git")
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func stageAll() {
        guard let path = workingPath else { return }
        AppLogger.audit(.gitStageFile, category: "Git", fields: ["scope": "all"])
        Task {
            do {
                try await git.stageAll(at: path)
                await refreshRepoDetails(force: true)
            } catch {
                AppLogger.error("Stage all failed: \(error.localizedDescription)", category: "Git")
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func unstage(file: GitStatusFile) {
        guard let path = workingPath else { return }
        AppLogger.audit(.gitUnstageFile, category: "Git", fields: ["file": file.relativePath])
        Task {
            do {
                try await git.unstageFile(file, at: path)
                await refreshRepoDetails(force: true)
            } catch {
                AppLogger.error("Unstage failed for \(file.relativePath): \(error.localizedDescription)", category: "Git")
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func unstageAll() {
        guard let path = workingPath else { return }
        AppLogger.audit(.gitUnstageFile, category: "Git", fields: ["scope": "all"])
        Task {
            do {
                try await git.unstageAll(at: path)
                await refreshRepoDetails(force: true)
            } catch {
                AppLogger.error("Unstage all failed: \(error.localizedDescription)", category: "Git")
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func applyDiffHunk(_ patch: String, from diff: GitFileDiff) {
        guard let path = workingPath else { return }
        let reverse = diff.kind == .staged
        AppLogger.audit(reverse ? .gitUnstageFile : .gitStageFile, category: "Git", fields: [
            "file": diff.file.relativePath,
            "scope": "hunk"
        ])
        Task {
            do {
                try await git.applyDiffPatchToIndex(patch, at: path, reverse: reverse)
                self.clearSelectedFileDiff()
                await refreshRepoDetails(force: true)
            } catch {
                AppLogger.error("Apply hunk failed for \(diff.file.relativePath): \(error.localizedDescription)", category: "Git")
                self.errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Commit

    func commitChanges() {
        guard let path = workingPath, !commitMessage.isEmpty else { return }
        AppLogger.audit(.gitCommit, category: "Git")
        Task {
            do {
                try await git.commit(message: commitMessage, at: path)
                self.commitMessage = ""
                self.errorMessage = nil
                await refreshRepoDetails(force: true)
            } catch {
                AppLogger.error("Commit failed: \(error.localizedDescription)", category: "Git")
                self.errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Commit sheet actions

    var hasChanges: Bool {
        !statusFiles.isEmpty
    }

    var canOpenCommitSheet: Bool {
        hasChanges || canPush
    }

    /// Pushes the current branch, publishing it with `--set-upstream` when no
    /// upstream is configured yet. Centralizes push semantics so the commit
    /// sheet and the standalone push action behave identically.
    private func performPush(repoPath: String) async throws {
        if hasUpstream {
            try await git.push(at: repoPath)
        } else {
            let branch = currentBranch.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !branch.isEmpty, branch != "unknown" else {
                throw NSError(domain: "GitError", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Cannot determine the current branch to publish."
                ])
            }
            let remote = await git.getDefaultRemote(at: repoPath) ?? "origin"
            try await git.pushSetUpstream(branch: branch, remote: remote, at: repoPath)
        }
    }

    func commitFromSheet(message: String, includeUnstaged: Bool, andPush: Bool) {
        guard let path = workingPath else { return }
        isSyncing = true
        Task {
            do {
                if includeUnstaged {
                    try await git.stageAll(at: path)
                    await refreshRepoDetails(force: true)
                }

                let hasStaged = statusFiles.contains(where: { $0.isStaged })
                guard hasStaged else {
                    self.errorMessage = "No staged changes to commit."
                    isSyncing = false
                    return
                }

                var finalMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
                if finalMessage.isEmpty {
                    AppLogger.info("Auto-generating commit message", category: "Git")
                    isSuggestingCommit = true
                    let diff = await git.getStagedDiff(at: path)
                    let recent = await git.getRecentCommitSubjects(at: path)
                    let suggestion = try await makeAuthoringService().suggestCommitMessage(
                        repoPath: path,
                        diff: diff,
                        recentSubjects: recent
                    )
                    finalMessage = suggestion.formatted
                    isSuggestingCommit = false
                }

                AppLogger.audit(.gitCommit, category: "Git")
                try await git.commit(message: finalMessage, at: path)
                self.commitMessage = ""
                await refreshRepoDetails(force: true)

                if andPush {
                    AppLogger.audit(.gitPush, category: "Git", fields: [
                        "ahead": "\(self.pushableCommitCount)",
                        "published": self.hasUpstream ? "true" : "false"
                    ])
                    try await performPush(repoPath: path)
                }

                self.errorMessage = nil
                await refreshRepoDetails(force: true)
            } catch {
                AppLogger.error("Commit failed: \(error.localizedDescription)", category: "Git")
                self.errorMessage = error.localizedDescription
                isSuggestingCommit = false
            }
            isSyncing = false
        }
    }

    func pushOnly() {
        guard let path = workingPath else { return }
        guard hasRemote else {
            self.errorMessage = "No remote configured. Add a remote before pushing."
            return
        }
        guard canPush else { return }
        AppLogger.audit(.gitPush, category: "Git", fields: [
            "ahead": "\(pushableCommitCount)",
            "published": hasUpstream ? "true" : "false"
        ])
        isSyncing = true
        Task {
            do {
                try await performPush(repoPath: path)
                self.errorMessage = nil
                await refreshRepoDetails(force: true)
            } catch {
                AppLogger.error("Push failed: \(error.localizedDescription)", category: "Git")
                self.errorMessage = error.localizedDescription
            }
            isSyncing = false
        }
    }

    // MARK: - Sync (pull --rebase + push)

    func sync() {
        guard let path = workingPath else { return }
        guard hasUpstream else {
            self.errorMessage = "No upstream branch. Push the current branch first."
            return
        }
        AppLogger.info("sync: ahead=\(ahead) behind=\(behind)", category: "Git")
        isSyncing = true
        Task {
            do {
                if behind > 0 {
                    AppLogger.audit(.gitPull, category: "Git", fields: ["behind": "\(behind)"])
                    try await git.pullRebase(at: path)
                }
                if ahead > 0 || behind == 0 {
                    AppLogger.audit(.gitPush, category: "Git", fields: ["ahead": "\(ahead)"])
                    try await git.push(at: path)
                }
                self.errorMessage = nil
                await refreshRepoDetails(force: true)
            } catch {
                AppLogger.error("Sync failed: \(error.localizedDescription)", category: "Git")
                self.errorMessage = error.localizedDescription
            }
            isSyncing = false
        }
    }

    // MARK: - Helper-model assists

    func suggestCommitMessage() async {
        guard let path = workingPath else { return }
        let staged = statusFiles.contains(where: { $0.isStaged })
        guard staged else {
            self.errorMessage = "Stage some changes before requesting a commit suggestion."
            return
        }
        isSuggestingCommit = true
        defer { isSuggestingCommit = false }
        do {
            let diff = await git.getStagedDiff(at: path)
            let recent = await git.getRecentCommitSubjects(at: path)
            let suggestion = try await makeAuthoringService().suggestCommitMessage(
                repoPath: path,
                diff: diff,
                recentSubjects: recent
            )
            self.commitMessage = suggestion.formatted
            self.errorMessage = nil
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    func suggestPullRequest() async {
        guard validatePullRequestReadiness() else { return }
        guard let snapshot = makePullRequestActionSnapshot() else { return }
        isSuggestingPR = true
        defer { isSuggestingPR = false }
        let remote = await git.getDefaultRemote(at: snapshot.path)
        let base = await git.getDefaultBaseBranch(at: snapshot.path, remote: remote)
        let log = await git.getBranchLog(at: snapshot.path, base: base, branch: snapshot.branch)
        let diffStat = await git.getBranchDiffStat(at: snapshot.path, base: base, branch: snapshot.branch)
        guard isCurrentPullRequestActionSnapshot(snapshot) else {
            AppLogger.audit(.gitAuthoringFailed, category: "Git", fields: [
                "operation": "pull_request",
                "reason": "branch_changed",
                "original_branch": snapshot.branch,
                "current_branch": currentBranch
            ], level: .warning)
            self.errorMessage = "Branch changed while drafting the pull request. Try again."
            return
        }
        guard !log.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !diffStat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            AppLogger.audit(.gitAuthoringFailed, category: "Git", fields: [
                "operation": "pull_request",
                "reason": "empty_branch_delta",
                "branch": snapshot.branch,
                "base": base
            ], level: .info)
            self.errorMessage = "No committed branch changes were found for a pull request."
            return
        }
        do {
            let suggestion = try await makeAuthoringService().suggestPullRequest(
                repoPath: snapshot.path,
                branch: snapshot.branch,
                base: base,
                log: log,
                diffStat: diffStat
            )
            guard isCurrentPullRequestActionSnapshot(snapshot) else {
                self.errorMessage = "Branch changed while drafting the pull request. Try again."
                return
            }
            self.prDraft = suggestion
            self.errorMessage = nil
        } catch {
            AppLogger.audit(.gitAuthoringFailed, category: "Git", fields: [
                "operation": "pull_request",
                "reason": error.localizedDescription,
                "branch": snapshot.branch,
                "base": base,
                "log_bytes": "\(log.utf8.count)",
                "diffstat_bytes": "\(diffStat.utf8.count)"
            ], level: .error, fieldMaxLength: 240)
            self.errorMessage = error.localizedDescription
        }
    }

    // MARK: - Pull request creation

    /// Creates the pull request directly via the `gh` CLI and opens it in the
    /// browser. Falls back to the GitHub web compare flow when `gh` is missing
    /// or unauthenticated, so the action always results in a usable next step.
    func createPullRequest(with draft: PRSuggestion) {
        guard validatePullRequestReadiness() else { return }
        guard let snapshot = makePullRequestActionSnapshot() else { return }
        isSuggestingPR = true
        Task {
            let remote = await git.getDefaultRemote(at: snapshot.path)
            let base = await git.getDefaultBaseBranch(at: snapshot.path, remote: remote)
            guard self.isCurrentPullRequestActionSnapshot(snapshot) else {
                self.errorMessage = "Branch changed before creating the pull request. Try again."
                self.isSuggestingPR = false
                return
            }
            do {
                let url = try await git.createPullRequest(
                    repoPath: snapshot.path,
                    base: base,
                    head: snapshot.branch,
                    title: draft.title,
                    body: draft.body
                )
                AppLogger.info("Created pull request via gh", category: "Git")
                await MainActor.run {
                    #if os(macOS)
                    if let prURL = URL(string: url) { NSWorkspace.shared.open(prURL) }
                    #endif
                    self.prDraft = nil
                    self.errorMessage = nil
                    // Flip the panel to the link state at once; a forced lookup
                    // then backfills title/draft metadata.
                    if let ref = GitHubPullRequestRef.fromCreatedURL(url) {
                        self.openPullRequest = ref
                        self.pullRequestLookupIssue = nil
                    }
                    self.refreshOpenPullRequest(force: true)
                }
            } catch let error as GitHubCLIError {
                // Graceful fallback to the web compare page.
                AppLogger.warning("gh pr create unavailable: \(error.localizedDescription)", category: "Git")
                if case .commandFailed(let detail) = error {
                    self.errorMessage = detail
                } else {
                    self.errorMessage = "\(error.localizedDescription) Opening GitHub instead."
                }
                openPullRequestURL(with: draft, requireReady: true)
            } catch {
                AppLogger.error("Create pull request failed: \(error.localizedDescription)", category: "Git")
                self.errorMessage = error.localizedDescription
            }
            isSuggestingPR = false
        }
    }

    // MARK: - Pull request URL

    /// Opens the GitHub PR compare URL with the optional draft pre-filled via `?expand=1&title=...&body=...`.
    func openPullRequestURL(with draft: PRSuggestion?, requireReady: Bool = true) {
        if requireReady {
            guard validatePullRequestReadiness() else { return }
        }
        guard let snapshot = makePullRequestActionSnapshot() else { return }
        Task {
            let remote = await git.getDefaultRemote(at: snapshot.path)
            let base = await git.getDefaultBaseBranch(at: snapshot.path, remote: remote)
            let baseBranch = git.normalizeBaseBranch(base)
            guard let baseURL = await git.getRemoteURL(at: snapshot.path, remote: remote) else {
                self.errorMessage = "Could not detect the GitHub remote URL to create a pull request."
                return
            }
            guard self.isCurrentPullRequestActionSnapshot(snapshot) else {
                self.errorMessage = "Branch changed before opening the pull request page. Try again."
                return
            }
            let pathAllowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
            let branchSegment = snapshot.branch.addingPercentEncoding(withAllowedCharacters: pathAllowed) ?? snapshot.branch
            let baseSegment = baseBranch.addingPercentEncoding(withAllowedCharacters: pathAllowed) ?? baseBranch
            var urlString = "\(baseURL)/compare/\(baseSegment)...\(branchSegment)"
            if let draft = draft {
                var components = URLComponents()
                components.queryItems = [
                    URLQueryItem(name: "expand", value: "1"),
                    URLQueryItem(name: "title", value: draft.title),
                    URLQueryItem(name: "body", value: draft.body)
                ]
                if let query = components.percentEncodedQuery {
                    urlString += "?\(query)"
                }
            }
            guard let url = URL(string: urlString) else {
                self.errorMessage = "Could not build pull-request URL."
                return
            }
            await MainActor.run {
                #if os(macOS)
                NSWorkspace.shared.open(url)
                #endif
                self.prDraft = nil
            }
        }
    }

    func dismissPRDraft() {
        prDraft = nil
    }
}

import Foundation
import SwiftUI
import Combine
import ASTRACore

@MainActor
final class WorkspaceGitViewModel: ObservableObject {
    // Repositories
    @Published var repositories: [GitRepositoryInfo] = []
    @Published var selectedRepository: GitRepositoryInfo? = nil {
        didSet {
            if oldValue?.path != selectedRepository?.path {
                Task { await refreshRepoDetails() }
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

    // UI state
    @Published var errorMessage: String? = nil
    @Published var showNewBranchPopover = false
    @Published var showBranchPickerPopover = false
    @Published var newBranchName = ""

    private var workspace: Workspace?
    private var refreshTimer: Timer?

    var authoringServiceFactory: (() -> AgentGitAuthoringService)?

    private func makeAuthoringService() -> AgentGitAuthoringService {
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

    func setup(for workspace: Workspace) {
        self.workspace = workspace
        self.activeWorkingPath = workspace.isUsingWorktree ? workspace.activeWorkingPath : nil
        Task { await scanRepositories() }

        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshRepoDetails()
            }
        }
    }

    deinit {
        refreshTimer?.invalidate()
    }

    // MARK: - Repository scan

    func scanRepositories() async {
        guard let workspace = workspace else { return }
        let repos = await GitService.shared.scanForGitRepositories(
            primaryPath: workspace.primaryPath,
            additionalPaths: workspace.additionalPaths
        )
        self.repositories = repos
        if self.selectedRepository == nil {
            self.selectedRepository = repos.first
        } else if !repos.contains(where: { $0.path == self.selectedRepository?.path }) {
            self.selectedRepository = repos.first
        }
        await refreshRepoDetails()
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

    func refreshRepoDetails(force: Bool = false) async {
        guard let path = workingPath, let rootPath = rootRepoPath else { return }
        if !force {
            guard GitService.shared.acquireIndexGuard() else {
                AppLogger.debug("Git refresh skipped — another refresh in progress", category: "Git")
                return
            }
        }
        defer { if !force { GitService.shared.releaseIndexGuard() } }

        async let branch = GitService.shared.getCurrentBranch(at: path)
        async let localBranches = GitService.shared.getLocalBranches(at: path)
        async let files = GitService.shared.getStatusFiles(at: path)
        async let diffStats = GitService.shared.getDiffStats(at: path)
        async let upstream = GitService.shared.hasUpstream(at: path)
        async let aheadBehind = GitService.shared.getAheadBehind(at: path)
        async let remote = GitService.shared.hasRemote(at: path)
        async let unpushed = GitService.shared.getUnpushedCommitCount(at: path)
        async let trees = GitService.shared.listWorktrees(at: rootPath)

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
    }

    // MARK: - Worktrees

    /// Drops a stale active worktree binding when its directory disappeared
    /// (e.g. removed outside ASTRA), so the panel degrades to the root instead
    /// of showing an empty location.
    private func reconcileActiveWorkingPathWithDisk() {
        guard let active = activeWorkingPath, !active.isEmpty else { return }
        if !FileManager.default.fileExists(atPath: active) {
            setActiveWorkingPath(nil)
        }
    }

    /// Persists the active working location on the workspace and mirrors it for
    /// the view. Setting `nil` returns focus to the repository root.
    private func setActiveWorkingPath(_ path: String?) {
        let normalized = (path?.isEmpty == true) ? nil : path
        activeWorkingPath = normalized
        guard let workspace else { return }
        workspace.activeWorkingPath = normalized
        workspace.updatedAt = Date()
    }

    /// The worktree the panel is currently focused on, if any.
    var activeWorktree: GitWorktreeInfo? {
        guard let active = activeWorkingPath else { return nil }
        return worktrees.first { $0.path == active }
    }

    /// Switches the working location. Existing threads keep their own pinned
    /// location; only new chats follow this selection.
    func switchWorkingLocation(to worktree: GitWorktreeInfo) {
        setActiveWorkingPath(worktree.isPrimary ? nil : worktree.path)
        errorMessage = nil
        Task { await refreshRepoDetails(force: true) }
    }

    /// Returns focus to the repository root for new chats.
    func switchToRoot() {
        setActiveWorkingPath(nil)
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
                let exists = await GitService.shared.localBranchExists(cleanBranch, at: rootPath)
                let createdPath = try await GitService.shared.addWorktree(
                    repoPath: rootPath,
                    branch: cleanBranch,
                    createBranch: !exists,
                    base: exists ? nil : currentBranch
                )
                self.newWorktreeBranch = ""
                self.errorMessage = nil
                if makeActive {
                    self.setActiveWorkingPath(createdPath)
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
                try await GitService.shared.removeWorktree(
                    repoPath: rootPath,
                    worktreePath: worktree.path,
                    force: force
                )
                if activeWorkingPath == worktree.path {
                    setActiveWorkingPath(nil)
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

    // MARK: - Branches

    func checkout(branch: String) {
        guard let path = workingPath else { return }
        AppLogger.audit(.gitCheckout, category: "Git", fields: ["branch": branch])
        Task {
            do {
                try await GitService.shared.checkoutBranch(branch, at: path)
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
                try await GitService.shared.createBranch(newBranchName, from: currentBranch, at: path)
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

    func stage(file: GitStatusFile) {
        guard let path = workingPath else { return }
        AppLogger.audit(.gitStageFile, category: "Git", fields: ["file": file.relativePath])
        Task {
            do {
                try await GitService.shared.stageFile(file.relativePath, at: path)
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
                try await GitService.shared.stageAll(at: path)
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
                try await GitService.shared.unstageFile(file.relativePath, at: path)
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
                try await GitService.shared.unstageAll(at: path)
                await refreshRepoDetails(force: true)
            } catch {
                AppLogger.error("Unstage all failed: \(error.localizedDescription)", category: "Git")
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
                try await GitService.shared.commit(message: commitMessage, at: path)
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
            try await GitService.shared.push(at: repoPath)
        } else {
            let branch = currentBranch.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !branch.isEmpty, branch != "unknown" else {
                throw NSError(domain: "GitError", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Cannot determine the current branch to publish."
                ])
            }
            try await GitService.shared.pushSetUpstream(branch: branch, at: repoPath)
        }
    }

    func commitFromSheet(message: String, includeUnstaged: Bool, andPush: Bool) {
        guard let path = workingPath else { return }
        isSyncing = true
        Task {
            do {
                if includeUnstaged {
                    try await GitService.shared.stageAll(at: path)
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
                    let diff = await GitService.shared.getStagedDiff(at: path)
                    let recent = await GitService.shared.getRecentCommitSubjects(at: path)
                    let suggestion = try await makeAuthoringService().suggestCommitMessage(
                        repoPath: path,
                        diff: diff,
                        recentSubjects: recent
                    )
                    finalMessage = suggestion.formatted
                    isSuggestingCommit = false
                }

                AppLogger.audit(.gitCommit, category: "Git")
                try await GitService.shared.commit(message: finalMessage, at: path)
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
                    try await GitService.shared.pullRebase(at: path)
                }
                if ahead > 0 || behind == 0 {
                    AppLogger.audit(.gitPush, category: "Git", fields: ["ahead": "\(ahead)"])
                    try await GitService.shared.push(at: path)
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
            let diff = await GitService.shared.getStagedDiff(at: path)
            let recent = await GitService.shared.getRecentCommitSubjects(at: path)
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
        guard let path = workingPath else { return }
        guard hasUpstream else {
            self.errorMessage = "Push the current branch before drafting a pull request."
            return
        }
        isSuggestingPR = true
        defer { isSuggestingPR = false }
        let base = await GitService.shared.getDefaultBaseBranch(at: path)
        let log = await GitService.shared.getBranchLog(at: path, base: base, branch: currentBranch)
        let diffStat = await GitService.shared.getBranchDiffStat(at: path, base: base, branch: currentBranch)
        do {
            let suggestion = try await makeAuthoringService().suggestPullRequest(
                repoPath: path,
                branch: currentBranch,
                base: base,
                log: log,
                diffStat: diffStat
            )
            self.prDraft = suggestion
            self.errorMessage = nil
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    // MARK: - Pull request creation

    /// Creates the pull request directly via the `gh` CLI and opens it in the
    /// browser. Falls back to the GitHub web compare flow when `gh` is missing
    /// or unauthenticated, so the action always results in a usable next step.
    func createPullRequest(with draft: PRSuggestion) {
        guard let path = workingPath else { return }
        guard hasUpstream else {
            self.errorMessage = "Push the current branch before creating a pull request."
            return
        }
        isSuggestingPR = true
        Task {
            let base = await GitService.shared.getDefaultBaseBranch(at: path)
            do {
                let url = try await GitService.shared.createPullRequest(
                    repoPath: path,
                    base: base,
                    head: currentBranch,
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
                }
            } catch let error as GitHubCLIError {
                // Graceful fallback to the web compare page.
                AppLogger.warning("gh pr create unavailable: \(error.localizedDescription)", category: "Git")
                if case .commandFailed(let detail) = error {
                    self.errorMessage = detail
                } else {
                    self.errorMessage = "\(error.localizedDescription) Opening GitHub instead."
                }
                openPullRequestURL(with: draft)
            } catch {
                AppLogger.error("Create pull request failed: \(error.localizedDescription)", category: "Git")
                self.errorMessage = error.localizedDescription
            }
            isSuggestingPR = false
        }
    }

    // MARK: - Pull request URL

    /// Opens the GitHub PR compare URL with the optional draft pre-filled via `?expand=1&title=...&body=...`.
    func openPullRequestURL(with draft: PRSuggestion?) {
        guard let path = workingPath else { return }
        Task {
            guard let baseURL = await GitService.shared.getRemoteOriginURL(at: path) else {
                self.errorMessage = "Could not detect remote origin URL to create pull request."
                return
            }
            let branchSegment = currentBranch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? currentBranch
            var urlString = "\(baseURL)/pull/new/\(branchSegment)"
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

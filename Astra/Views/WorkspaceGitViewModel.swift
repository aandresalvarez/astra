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
    @Published var isSyncing: Bool = false

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

    func refreshRepoDetails(force: Bool = false) async {
        guard let repo = selectedRepository else { return }
        if !force {
            guard GitService.shared.acquireIndexGuard() else {
                AppLogger.debug("Git refresh skipped — another refresh in progress", category: "Git")
                return
            }
        }
        defer { if !force { GitService.shared.releaseIndexGuard() } }

        async let branch = GitService.shared.getCurrentBranch(at: repo.path)
        async let localBranches = GitService.shared.getLocalBranches(at: repo.path)
        async let files = GitService.shared.getStatusFiles(at: repo.path)
        async let diffStats = GitService.shared.getDiffStats(at: repo.path)
        async let upstream = GitService.shared.hasUpstream(at: repo.path)
        async let aheadBehind = GitService.shared.getAheadBehind(at: repo.path)

        self.currentBranch = await branch
        self.branches = await localBranches
        self.statusFiles = await files
        let stats = await diffStats
        self.additions = stats.additions
        self.deletions = stats.deletions
        self.hasUpstream = await upstream
        if let ab = await aheadBehind {
            self.ahead = ab.ahead
            self.behind = ab.behind
        } else {
            self.ahead = 0
            self.behind = 0
        }
    }

    // MARK: - Branches

    func checkout(branch: String) {
        guard let repo = selectedRepository else { return }
        AppLogger.audit(.gitCheckout, category: "Git", fields: ["branch": branch])
        Task {
            do {
                try await GitService.shared.checkoutBranch(branch, at: repo.path)
                self.errorMessage = nil
                await refreshRepoDetails(force: true)
            } catch {
                AppLogger.error("Checkout failed: \(error.localizedDescription)", category: "Git")
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func createAndCheckoutBranch() {
        guard let repo = selectedRepository, !newBranchName.isEmpty else { return }
        AppLogger.audit(.gitBranchCreated, category: "Git", fields: ["branch": newBranchName, "from": currentBranch])
        Task {
            do {
                try await GitService.shared.createBranch(newBranchName, from: currentBranch, at: repo.path)
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
        guard let repo = selectedRepository else { return }
        AppLogger.audit(.gitStageFile, category: "Git", fields: ["file": file.relativePath])
        Task {
            do {
                try await GitService.shared.stageFile(file.relativePath, at: repo.path)
                await refreshRepoDetails(force: true)
            } catch {
                AppLogger.error("Stage failed for \(file.relativePath): \(error.localizedDescription)", category: "Git")
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func stageAll() {
        guard let repo = selectedRepository else { return }
        AppLogger.audit(.gitStageFile, category: "Git", fields: ["scope": "all"])
        Task {
            do {
                try await GitService.shared.stageAll(at: repo.path)
                await refreshRepoDetails(force: true)
            } catch {
                AppLogger.error("Stage all failed: \(error.localizedDescription)", category: "Git")
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func unstage(file: GitStatusFile) {
        guard let repo = selectedRepository else { return }
        AppLogger.audit(.gitUnstageFile, category: "Git", fields: ["file": file.relativePath])
        Task {
            do {
                try await GitService.shared.unstageFile(file.relativePath, at: repo.path)
                await refreshRepoDetails(force: true)
            } catch {
                AppLogger.error("Unstage failed for \(file.relativePath): \(error.localizedDescription)", category: "Git")
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func unstageAll() {
        guard let repo = selectedRepository else { return }
        AppLogger.audit(.gitUnstageFile, category: "Git", fields: ["scope": "all"])
        Task {
            do {
                try await GitService.shared.unstageAll(at: repo.path)
                await refreshRepoDetails(force: true)
            } catch {
                AppLogger.error("Unstage all failed: \(error.localizedDescription)", category: "Git")
                self.errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Commit

    func commitChanges() {
        guard let repo = selectedRepository, !commitMessage.isEmpty else { return }
        AppLogger.audit(.gitCommit, category: "Git")
        Task {
            do {
                try await GitService.shared.commit(message: commitMessage, at: repo.path)
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
        hasChanges || ahead > 0
    }

    func commitFromSheet(message: String, includeUnstaged: Bool, andPush: Bool) {
        guard let repo = selectedRepository else { return }
        isSyncing = true
        Task {
            do {
                if includeUnstaged {
                    try await GitService.shared.stageAll(at: repo.path)
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
                    let diff = await GitService.shared.getStagedDiff(at: repo.path)
                    let recent = await GitService.shared.getRecentCommitSubjects(at: repo.path)
                    let suggestion = try await makeAuthoringService().suggestCommitMessage(
                        repoPath: repo.path,
                        diff: diff,
                        recentSubjects: recent
                    )
                    finalMessage = suggestion.formatted
                    isSuggestingCommit = false
                }

                AppLogger.audit(.gitCommit, category: "Git")
                try await GitService.shared.commit(message: finalMessage, at: repo.path)
                self.commitMessage = ""
                await refreshRepoDetails(force: true)

                if andPush {
                    if self.hasUpstream {
                        AppLogger.audit(.gitPush, category: "Git", fields: ["ahead": "\(self.ahead)"])
                        try await GitService.shared.push(at: repo.path)
                    } else {
                        AppLogger.warning("Cannot push — no upstream branch", category: "Git")
                    }
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
        guard let repo = selectedRepository else { return }
        guard hasUpstream else {
            self.errorMessage = "No upstream branch. Push the current branch first."
            return
        }
        guard ahead > 0 else { return }
        AppLogger.audit(.gitPush, category: "Git", fields: ["ahead": "\(ahead)"])
        isSyncing = true
        Task {
            do {
                try await GitService.shared.push(at: repo.path)
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
        guard let repo = selectedRepository else { return }
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
                    try await GitService.shared.pullRebase(at: repo.path)
                }
                if ahead > 0 || behind == 0 {
                    AppLogger.audit(.gitPush, category: "Git", fields: ["ahead": "\(ahead)"])
                    try await GitService.shared.push(at: repo.path)
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
        guard let repo = selectedRepository else { return }
        let staged = statusFiles.contains(where: { $0.isStaged })
        guard staged else {
            self.errorMessage = "Stage some changes before requesting a commit suggestion."
            return
        }
        isSuggestingCommit = true
        defer { isSuggestingCommit = false }
        do {
            let diff = await GitService.shared.getStagedDiff(at: repo.path)
            let recent = await GitService.shared.getRecentCommitSubjects(at: repo.path)
            let suggestion = try await makeAuthoringService().suggestCommitMessage(
                repoPath: repo.path,
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
        guard let repo = selectedRepository else { return }
        guard hasUpstream else {
            self.errorMessage = "Push the current branch before drafting a pull request."
            return
        }
        isSuggestingPR = true
        defer { isSuggestingPR = false }
        let base = await GitService.shared.getDefaultBaseBranch(at: repo.path)
        let log = await GitService.shared.getBranchLog(at: repo.path, base: base, branch: currentBranch)
        let diffStat = await GitService.shared.getBranchDiffStat(at: repo.path, base: base, branch: currentBranch)
        do {
            let suggestion = try await makeAuthoringService().suggestPullRequest(
                repoPath: repo.path,
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

    // MARK: - Pull request URL

    /// Opens the GitHub PR compare URL with the optional draft pre-filled via `?expand=1&title=...&body=...`.
    func openPullRequestURL(with draft: PRSuggestion?) {
        guard let repo = selectedRepository else { return }
        Task {
            guard let baseURL = await GitService.shared.getRemoteOriginURL(at: repo.path) else {
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

import Foundation
import SwiftUI
import Combine

@MainActor
class WorkspaceGitViewModel: ObservableObject {
    @Published var repositories: [GitRepositoryInfo] = []
    @Published var selectedRepository: GitRepositoryInfo? = nil {
        didSet {
            if oldValue?.path != selectedRepository?.path {
                Task { await refreshRepoDetails() }
            }
        }
    }
    
    @Published var currentBranch: String = ""
    @Published var branches: [String] = []
    @Published var statusFiles: [GitStatusFile] = []
    @Published var commitMessage: String = ""
    @Published var stageAllBeforeCommit: Bool = false
    
    @Published var additions: Int = 0
    @Published var deletions: Int = 0
    @Published var selectedEnvironment: String = "Local"
    
    @Published var isSyncing: Bool = false
    @Published var errorMessage: String? = nil
    @Published var showNewBranchPopover = false
    @Published var showBranchPickerPopover = false
    @Published var showCommitPopover = false
    @Published var showEnvironmentPopover = false
    @Published var newBranchName = ""
    
    private var workspace: Workspace?
    private var refreshTimer: Timer?

    func setup(for workspace: Workspace) {
        self.workspace = workspace
        Task {
            await scanRepositories()
        }
        
        // Auto-refresh every 10 seconds to catch agent or external changes
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
    
    func refreshRepoDetails() async {
        guard let repo = selectedRepository else { return }
        async let branch = GitService.shared.getCurrentBranch(at: repo.path)
        async let localBranches = GitService.shared.getLocalBranches(at: repo.path)
        async let files = GitService.shared.getStatusFiles(at: repo.path)
        async let diffStats = GitService.shared.getDiffStats(at: repo.path)
        
        let fetchedBranch = await branch
        let fetchedBranches = await localBranches
        let fetchedFiles = await files
        let fetchedStats = await diffStats
        
        self.currentBranch = fetchedBranch
        self.branches = fetchedBranches
        self.statusFiles = fetchedFiles
        self.additions = fetchedStats.additions
        self.deletions = fetchedStats.deletions
    }
    
    func checkout(branch: String) {
        guard let repo = selectedRepository else { return }
        Task {
            do {
                try await GitService.shared.checkoutBranch(branch, at: repo.path)
                self.errorMessage = nil
                await refreshRepoDetails()
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }
    
    func createAndCheckoutBranch() {
        guard let repo = selectedRepository, !newBranchName.isEmpty else { return }
        Task {
            do {
                try await GitService.shared.createBranch(newBranchName, from: currentBranch, at: repo.path)
                self.newBranchName = ""
                self.showNewBranchPopover = false
                self.errorMessage = nil
                await refreshRepoDetails()
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }
    
    func stage(file: GitStatusFile) {
        guard let repo = selectedRepository else { return }
        Task {
            do {
                try await GitService.shared.stageFile(file.relativePath, at: repo.path)
                await refreshRepoDetails()
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }
    
    func stageAll() {
        guard let repo = selectedRepository else { return }
        Task {
            do {
                try await GitService.shared.stageAll(at: repo.path)
                await refreshRepoDetails()
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }
    
    func unstage(file: GitStatusFile) {
        guard let repo = selectedRepository else { return }
        Task {
            do {
                try await GitService.shared.unstageFile(file.relativePath, at: repo.path)
                await refreshRepoDetails()
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }
    
    func unstageAll() {
        guard let repo = selectedRepository else { return }
        Task {
            do {
                try await GitService.shared.unstageAll(at: repo.path)
                await refreshRepoDetails()
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }
    
    func commitChanges() {
        guard let repo = selectedRepository, !commitMessage.isEmpty else { return }
        Task {
            do {
                if stageAllBeforeCommit {
                    try await GitService.shared.stageAll(at: repo.path)
                }
                try await GitService.shared.commit(message: commitMessage, at: repo.path)
                self.commitMessage = ""
                self.stageAllBeforeCommit = false
                self.errorMessage = nil
                await refreshRepoDetails()
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }
    
    func pull() {
        guard let repo = selectedRepository else { return }
        isSyncing = true
        Task {
            do {
                try await GitService.shared.pull(at: repo.path)
                self.errorMessage = nil
                await refreshRepoDetails()
            } catch {
                self.errorMessage = error.localizedDescription
            }
            isSyncing = false
        }
    }
    
    func push() {
        guard let repo = selectedRepository else { return }
        isSyncing = true
        Task {
            do {
                try await GitService.shared.push(at: repo.path)
                self.errorMessage = nil
                await refreshRepoDetails()
            } catch {
                self.errorMessage = error.localizedDescription
            }
            isSyncing = false
        }
    }
    
    func createPullRequest() {
        guard let repo = selectedRepository else { return }
        Task {
            if let baseURL = await GitService.shared.getRemoteOriginURL(at: repo.path) {
                let branch = currentBranch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? currentBranch
                let prURLString = "\(baseURL)/pull/new/\(branch)"
                if let url = URL(string: prURLString) {
                    DispatchQueue.main.async {
                        #if os(macOS)
                        NSWorkspace.shared.open(url)
                        #endif
                    }
                }
            } else {
                self.errorMessage = "Could not detect remote origin URL to create pull request."
            }
        }
    }
}

import Foundation
import Testing
@testable import ASTRA

@Suite("Git Repository Panel Integration")
struct GitRepositoryPanelIntegrationTests {
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

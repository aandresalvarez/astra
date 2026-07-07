import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA
import ASTRACore

/// Regression coverage for git worktree management and per-thread working-path
/// binding.
///
/// First principles guarded here:
/// - A thread is pinned to the checkout it was created in and always resolves
///   there, even if the workspace later switches worktrees (parallel-safe).
/// - The pin degrades to the repository root if its worktree disappears.
/// - Task metadata (`effectiveWorkspacePath`) never follows a worktree; only
///   the code root (`codeWorkingDirectory`) does.
/// - GitService worktree add/list/remove behave and surface typed errors.
@Suite("Git Worktrees")
struct GitWorktreeTests {
    private let _registerRuntimeSeams: Void = RuntimeSeamRegistration.registerAll() // AgentTaskForkService.fork() needs the Track A2.6 seams

    // MARK: - Helpers

    private func runShell(_ command: String, in directory: String) -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = GitLocalEnvironment.scrubbing(ProcessInfo.processInfo.environment)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        process.waitUntilExit()
        return Int(process.terminationStatus)
    }

    private func makeTempGitRepo() throws -> String {
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-wt-repo-\(UUID().uuidString)", isDirectory: true)
            .path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let initCommand = """
        git init -b work && \
        git -c commit.gpgsign=false -c user.name='ASTRA Tests' -c user.email='astra-tests@example.invalid' \
        commit --allow-empty -m 'init'
        """
        let exitCode = runShell(initCommand, in: path)
        guard exitCode == 0 else {
            throw NSError(domain: "GitWorktreeTests", code: exitCode, userInfo: [
                NSLocalizedDescriptionKey: "Failed to initialize temp git repo at \(path)"
            ])
        }
        return path
    }

    private func makeTempDir(_ label: String) throws -> String {
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-wt-\(label)-\(UUID().uuidString)", isDirectory: true)
            .path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    // MARK: - Porcelain parsing

    @Test("Worktree porcelain parses primary plus worktrees with flags")
    func parsesWorktreePorcelain() {
        let output = """
        worktree /repos/app
        HEAD aaaa1111
        branch refs/heads/main

        worktree /worktrees/app/feature-x
        HEAD bbbb2222
        branch refs/heads/feature/x

        worktree /worktrees/app/detached
        HEAD cccc3333
        detached
        locked maintenance
        prunable gitdir gone
        """

        let trees = GitService.parseWorktreePorcelain(output)
        #expect(trees.count == 3)

        #expect(trees[0].isPrimary == true)
        #expect(trees[0].branch == "main")

        #expect(trees[1].isPrimary == false)
        #expect(trees[1].branch == "feature/x")
        #expect(trees[1].displayName == "feature/x")

        #expect(trees[2].branch == nil)
        #expect(trees[2].isDetached == true)
        #expect(trees[2].isLocked == true)
        #expect(trees[2].isPrunable == true)
        #expect(trees[2].displayName == "detached") // folder name fallback
    }

    // MARK: - Location + sanitizing

    @Test("Worktree location namespaces by repo and sanitizes branch")
    func computesSanitizedLocation() {
        let location = GitService.worktreeLocation(
            repoPath: "/Users/me/Code/MyApp",
            branch: "feature/login-flow",
            worktreesRoot: "/tmp/Worktrees"
        )
        #expect(location == "/tmp/Worktrees/MyApp/feature-login-flow")
    }

    @Test("Folder sanitizer strips unsafe characters and never empties")
    func sanitizesFolderNames() {
        #expect(GitService.sanitizeForFolder("feature/x") == "feature-x")
        #expect(GitService.sanitizeForFolder("a b!@#c") == "abc")
        #expect(GitService.sanitizeForFolder("   ") == "worktree")
        #expect(GitService.sanitizeForFolder("keep.dots_and-dashes") == "keep.dots_and-dashes")
    }

    // MARK: - GitService integration

    @Test("Add, list, and remove a worktree on a new branch")
    func addListRemoveWorktree() async throws {
        let repo = try makeTempGitRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        let worktreesRoot = try makeTempDir("root")
        defer { try? FileManager.default.removeItem(atPath: worktreesRoot) }

        let base = await GitService.shared.getCurrentBranch(at: repo)
        let createdPath = try await GitService.shared.addWorktree(
            repoPath: repo,
            branch: "feature-a",
            createBranch: true,
            base: base,
            worktreesRoot: worktreesRoot
        )
        #expect(FileManager.default.fileExists(atPath: createdPath))

        let trees = await GitService.shared.listWorktrees(at: repo)
        #expect(trees.count == 2)
        let added = trees.first { !$0.isPrimary }
        #expect(added?.branch == "feature-a")
        // Compare canonical paths: git reports the resolved path (e.g. /private/var)
        // while the temp dir may be the /var symlink alias.
        let resolvedAdded = added.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path }
        let resolvedCreated = URL(fileURLWithPath: createdPath).resolvingSymlinksInPath().path
        #expect(resolvedAdded == resolvedCreated)

        try await GitService.shared.removeWorktree(repoPath: repo, worktreePath: createdPath, force: false)
        let afterRemoval = await GitService.shared.listWorktrees(at: repo)
        #expect(afterRemoval.count == 1)
        #expect(afterRemoval.first?.isPrimary == true)
    }

    @Test("Adding a worktree for an already-checked-out branch is a typed error")
    func rejectsBranchAlreadyCheckedOut() async throws {
        let repo = try makeTempGitRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        let worktreesRoot = try makeTempDir("root2")
        defer { try? FileManager.default.removeItem(atPath: worktreesRoot) }

        // "work" is checked out in the primary tree; reusing it must fail clearly.
        await #expect(throws: GitWorktreeError.self) {
            try await GitService.shared.addWorktree(
                repoPath: repo,
                branch: "work",
                createBranch: false,
                worktreesRoot: worktreesRoot
            )
        }
    }

    // MARK: - Per-thread resolution (TaskWorkspaceAccess)

    @Test("codeWorkingDirectory prefers the pinned worktree when it exists")
    func resolverPrefersExistingPin() throws {
        let primary = try makeTempDir("primary")
        defer { try? FileManager.default.removeItem(atPath: primary) }
        let worktree = try makeTempDir("pin")
        defer { try? FileManager.default.removeItem(atPath: worktree) }

        let workspace = Workspace(name: "WS", primaryPath: primary)
        let task = AgentTask(title: "t", goal: "g", workspace: workspace)
        task.executionRootPath = worktree

        let access = TaskWorkspaceAccess(task: task)
        #expect(access.codeWorkingDirectory == worktree)
        // Metadata must NOT follow the worktree.
        #expect(access.effectiveWorkspacePath == primary)
    }

    @Test("codeWorkingDirectory falls back to root when the pinned worktree is gone")
    func resolverDegradesWhenPinMissing() throws {
        let primary = try makeTempDir("primary2")
        defer { try? FileManager.default.removeItem(atPath: primary) }

        let workspace = Workspace(name: "WS", primaryPath: primary)
        let task = AgentTask(title: "t", goal: "g", workspace: workspace)
        task.executionRootPath = "/definitely/not/here-\(UUID().uuidString)"

        #expect(TaskWorkspaceAccess(task: task).codeWorkingDirectory == primary)
    }

    @Test("codeWorkingDirectory uses primary path until an active repository is selected")
    func resolverDoesNotImplicitlyUseFirstAdditionalPath() throws {
        let primary = try makeTempDir("primary3")
        let additional = try makeTempDir("additional3")
        defer {
            try? FileManager.default.removeItem(atPath: primary)
            try? FileManager.default.removeItem(atPath: additional)
        }

        let workspace = Workspace(name: "WS", primaryPath: primary, additionalPaths: [additional])
        let task = AgentTask(title: "t", goal: "g", workspace: workspace)

        #expect(TaskWorkspaceAccess(task: task).codeWorkingDirectory == primary)

        workspace.activeWorkingPath = additional
        let pinned = AgentTask(title: "t2", goal: "g", workspace: workspace)
        #expect(pinned.executionRootPath == additional)
        #expect(TaskWorkspaceAccess(task: pinned).codeWorkingDirectory == additional)
    }

    @Test("codeWorkingDirectory uses the only configured git repository when primary is storage")
    func resolverUsesSoleAdditionalGitRepositoryForLegacyTasks() throws {
        let primary = try makeTempDir("primary-storage")
        let repo = try makeTempGitRepo()
        defer {
            try? FileManager.default.removeItem(atPath: primary)
            try? FileManager.default.removeItem(atPath: repo)
        }

        let workspace = Workspace(name: "WS", primaryPath: primary, additionalPaths: [repo])
        let legacyTask = AgentTask(title: "t", goal: "g", workspace: workspace)
        legacyTask.executionRootPath = nil

        let access = TaskWorkspaceAccess(task: legacyTask)
        #expect(access.codeWorkingDirectory == repo)
        #expect(access.effectiveWorkspacePath == primary)
    }

    // MARK: - Pin snapshot at creation

    @Test("New task pins the workspace's active code path at creation")
    func taskPinsActiveWorktree() {
        let workspace = Workspace(name: "WS", primaryPath: "/repo/root")
        workspace.activeWorkingPath = "/worktrees/root/feature"

        let pinned = AgentTask(title: "t", goal: "g", workspace: workspace)
        #expect(pinned.executionRootPath == "/worktrees/root/feature")

        // No active worktree → no pin (resolves to root for existing behavior).
        workspace.activeWorkingPath = nil
        let unpinned = AgentTask(title: "t2", goal: "g", workspace: workspace)
        #expect(unpinned.executionRootPath == nil)

        // Active path equal to root is not a worktree → no pin.
        workspace.activeWorkingPath = "/repo/root"
        let rootTask = AgentTask(title: "t3", goal: "g", workspace: workspace)
        #expect(rootTask.executionRootPath == nil)
    }

    @MainActor
    @Test("Forked task inherits its source's worktree pin")
    func forkInheritsPin() throws {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext

        let workspace = Workspace(name: "WS", primaryPath: "/repo/root")
        context.insert(workspace)
        let source = AgentTask(title: "src", goal: "g", workspace: workspace)
        source.executionRootPath = "/worktrees/root/feature"
        context.insert(source)
        let run = TaskRun(task: source)
        context.insert(run)

        let forked = AgentTaskForkService.fork(from: source, upToRun: run, in: context)
        #expect(forked.executionRootPath == "/worktrees/root/feature")
    }

    // MARK: - ViewModel working-path resolution

    @MainActor
    @Test("workingPath follows the active worktree and degrades to root")
    func viewModelWorkingPathResolution() throws {
        let root = try makeTempDir("vm-root")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let worktree = try makeTempDir("vm-wt")
        defer { try? FileManager.default.removeItem(atPath: worktree) }

        let vm = WorkspaceGitViewModel()
        vm.selectedRepository = GitRepositoryInfo(name: "repo", path: root)

        // No worktree → root.
        vm.activeWorkingPath = nil
        #expect(vm.workingPath == root)
        #expect(vm.isUsingWorktree == false)

        // Active worktree that exists → worktree.
        vm.activeWorkingPath = worktree
        #expect(vm.workingPath == worktree)
        #expect(vm.isUsingWorktree == true)

        // Active worktree that no longer exists → falls back to root.
        vm.activeWorkingPath = "/gone/\(UUID().uuidString)"
        #expect(vm.workingPath == root)
    }
}

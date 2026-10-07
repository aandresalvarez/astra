import Foundation
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// Issue #479: a task pinned to a linked worktree replaces its source checkout,
/// and every root a run may write is one that admission claimed. Claims,
/// sandbox grants, Docker mounts, and provider directory arguments all read
/// `TaskWorkspaceAccess.runtimeWritablePaths`, so these tests pin that one
/// derivation and its invariant rather than each projection separately.
@Suite("Worktree resource scope")
@MainActor
struct TaskWorktreeResourceScopeTests {
    @Test("Tasks pinned to sibling worktrees no longer serialize on their source checkout")
    func siblingWorktreesDoNotClaimTheSourceCheckout() throws {
        let fixture = try WorktreeFixture(worktrees: ["wt-a", "wt-b"])
        defer { fixture.remove() }
        let workspace = fixture.workspace(additionalPaths: [fixture.checkout.path])
        let first = fixture.task("Ship feature A", pinnedTo: "wt-a", in: workspace)
        let second = fixture.task("Ship feature B", pinnedTo: "wt-b", in: workspace)

        let firstClaims = TaskExecutionResourceClaimResolver.claims(for: first)
        let secondClaims = TaskExecutionResourceClaimResolver.claims(for: second)

        #expect(TaskWorkspaceAccess(task: first).replacedSourceCheckoutPaths == [fixture.checkout.path])
        #expect(firstClaims.map(\.key) == [fixture.path("wt-a")])
        #expect(secondClaims.map(\.key) == [fixture.path("wt-b")])
        #expect(firstClaims.allSatisfy { $0.access == .exclusive })
        #expect(TaskExecutionResourceBroker.canAcquire(
            lease(secondClaims, taskID: second.id),
            active: lease(firstClaims, taskID: first.id)
        ))
    }

    @Test("Shared folders, unrelated repositories, and source subfolders keep their claims")
    func onlyTheReplacedCheckoutRootIsDropped() throws {
        let fixture = try WorktreeFixture(worktrees: ["wt-a", "wt-b"])
        defer { fixture.remove() }
        let other = try WorktreeFixture(worktrees: [])
        defer { other.remove() }
        let shared = try fixture.makeDirectory("shared-notes")
        let subfolder = try fixture.makeDirectory("main/Sources")
        let workspace = fixture.workspace(additionalPaths: [
            fixture.checkout.path, shared, other.checkout.path, subfolder
        ])
        let first = fixture.task("Ship feature A", pinnedTo: "wt-a", in: workspace)
        let second = fixture.task("Ship feature B", pinnedTo: "wt-b", in: workspace)

        #expect(TaskWorkspaceAccess(task: first).runtimeWritablePaths == [shared, other.checkout.path, subfolder])
        // An intentionally shared writable folder is still a real overlap.
        #expect(!TaskExecutionResourceBroker.canAcquire(
            lease(TaskExecutionResourceClaimResolver.claims(for: second), taskID: second.id),
            active: lease(TaskExecutionResourceClaimResolver.claims(for: first), taskID: first.id)
        ))
    }

    @Test("Every root a run may write is covered by its admission claims", arguments: Scenario.allCases)
    func writableRootsAreClaimed(_ scenario: Scenario) throws {
        let fixture = try WorktreeFixture(worktrees: ["wt-a", "wt-b"])
        defer { fixture.remove() }
        let shared = try fixture.makeDirectory("shared-notes")
        let task = scenario.task(in: fixture, shared: shared)
        let access = TaskWorkspaceAccess(task: task)
        let claimed = TaskExecutionResourceClaimResolver.claims(for: task)
            .filter { $0.kind == .workspace }.map(\.key)
        let plan = TaskLaunchResourceResolver.resolve(
            task: task,
            runID: UUID(),
            runtime: .claudeCode,
            phase: "run",
            prompt: task.goal,
            contextText: "",
            workspacePath: access.codeWorkingDirectory,
            gitCredentialContextProvider: { _, _, _, _ in .empty }
        )
        let writable = AgentRuntimeProcessRunner.runtimeWritablePaths(for: task)
            + plan.hostPathGrants.filter { $0.source == .workspace && $0.access != .read }.map(\.path)
        let taskFolder = access.taskFolder

        for path in writable where !contains(taskFolder, path) {
            #expect(claimed.contains { contains($0, path) }, "\(scenario): \(path) is writable but unclaimed")
        }
        #expect(!writable.contains(fixture.workspaceFolder.path) || claimed.contains(fixture.workspaceFolder.path))
    }

    @Test("A replaced source checkout stays readable at launch")
    func replacedCheckoutIsReadOnlyAtLaunch() throws {
        let fixture = try WorktreeFixture(worktrees: ["wt-a"])
        defer { fixture.remove() }
        let task = fixture.task(
            "Ship feature A",
            pinnedTo: "wt-a",
            in: fixture.workspace(additionalPaths: [fixture.checkout.path])
        )

        let plan = TaskLaunchResourceResolver.resolve(
            task: task,
            runID: UUID(),
            runtime: .codexCLI,
            phase: "run",
            prompt: task.goal,
            contextText: "",
            workspacePath: fixture.path("wt-a"),
            gitCredentialContextProvider: { _, _, _, _ in .empty }
        )

        #expect(plan.hostReadablePaths.contains(fixture.checkout.path))
        #expect(!plan.hostWritablePaths.contains(fixture.checkout.path))
        #expect(!plan.hostWritablePaths.contains(fixture.workspaceFolder.path))
        #expect(!AgentRuntimeProcessRunner.runtimeWritablePaths(for: task).contains(fixture.checkout.path))
    }

    @Test("Launch drift is a newly writable root, not a narrower one")
    func driftRequiresAnUnclaimedRoot() throws {
        let fixture = try WorktreeFixture(worktrees: ["wt-a"])
        defer { fixture.remove() }
        let workspace = fixture.workspace(additionalPaths: [fixture.checkout.path])
        let task = fixture.task("Ship feature A", pinnedTo: "wt-a", in: workspace)
        // A request queued before the source checkout was replaced claimed it
        // too. That lease still covers the narrower launch.
        let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1, resourceClaims: [
            TaskExecutionResourceClaim(kind: .workspace, key: fixture.path("wt-a"), access: .exclusive),
            TaskExecutionResourceClaim(kind: .workspace, key: fixture.checkout.path, access: .exclusive)
        ])
        #expect(!TaskExecutionResourceClaimResolver.hasWorkspacePathDrift(request: request, task: task))

        workspace.additionalPaths.append(try fixture.makeDirectory("added-later"))
        #expect(TaskExecutionResourceClaimResolver.hasWorkspacePathDrift(request: request, task: task))
    }

    @Test("External Git metadata is writable only where admission claimed it")
    func gitMetadataWritesFollowAdmittedClaims() throws {
        let fixture = try WorktreeFixture(worktrees: ["wt-a"])
        defer { fixture.remove() }
        let commonDirectory = fixture.checkout.appendingPathComponent(".git").path
        let adminDirectory = (commonDirectory as NSString).appendingPathComponent("worktrees/wt-a")
        let detected = GitCredentialSandboxContext(
            readablePaths: [], writablePaths: [adminDirectory], transports: [], diagnostics: []
        )
        func restricted(_ access: TaskExecutionResourceAccess, _ roots: [String]?) -> GitCredentialSandboxContext {
            TaskLaunchResourceResolver.restrictingGitWrites(detected, workspaceAccess: access, admittedWritableRoots: roots)
        }

        #expect(restricted(.exclusive, nil) == detected)
        #expect(restricted(.exclusive, [commonDirectory]).writablePaths == [adminDirectory])
        for denied in [restricted(.exclusive, []), restricted(.shared, nil), restricted(.shared, [commonDirectory])] {
            #expect(denied.writablePaths.isEmpty)
            #expect(denied.readablePaths.contains(adminDirectory))
            #expect(denied.diagnostics.contains("git_metadata_write_not_admitted"))
        }

        // End to end: the claim decision sees the goal, so a Git operation
        // named only in runtime context gets read-only metadata.
        let workspace = fixture.workspace(additionalPaths: [])
        for (goal, admitted) in [("Update the parser, then git push the result.", true), ("Update the parser.", false)] {
            let task = fixture.task("Ship feature A", pinnedTo: "wt-a", in: workspace)
            task.goal = goal
            let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1,
                                          resourceClaims: TaskExecutionResourceClaimResolver.claims(for: task))
            let plan = TaskLaunchResourceResolver.resolve(
                task: task,
                runID: UUID(),
                runtime: .claudeCode,
                phase: "run",
                prompt: goal,
                contextText: "Then git push the result.",
                workspacePath: fixture.path("wt-a"),
                admittedWritableGitMetadataRoots: TaskExecutionResourceClaimResolver
                    .admittedWritableGitMetadataRoots(for: request, task: task),
                gitCredentialContextProvider: { _, _, _, _ in detected }
            )
            let canonicalAdmin = URL(fileURLWithPath: adminDirectory).standardizedFileURL.path
            #expect(plan.hostWritablePaths.contains(canonicalAdmin) == admitted, "\(goal)")
            #expect(plan.hostReadablePaths.contains(canonicalAdmin))
        }
    }

    // MARK: - Fixtures

    enum Scenario: String, CaseIterable, CustomStringConvertible {
        case pinnedWorktreeWithSourceFolder
        case pinnedWorktreeWithSharedFolder
        case sourceCheckoutAsWorkspaceWithActiveWorktree
        case soleRepositoryFolder

        var description: String { rawValue }

        @MainActor
        func task(in fixture: WorktreeFixture, shared: String) -> AgentTask {
            switch self {
            case .pinnedWorktreeWithSourceFolder:
                return fixture.task("A", pinnedTo: "wt-a", in: fixture.workspace(additionalPaths: [fixture.checkout.path]))
            case .pinnedWorktreeWithSharedFolder:
                return fixture.task("A", pinnedTo: "wt-a", in: fixture.workspace(additionalPaths: [fixture.checkout.path, shared]))
            case .sourceCheckoutAsWorkspaceWithActiveWorktree:
                let workspace = Workspace(name: "Repo", primaryPath: fixture.checkout.path)
                workspace.activeWorkingPath = fixture.path("wt-b")
                return AgentTask(title: "A", goal: "Update the parser.", workspace: workspace)
            case .soleRepositoryFolder:
                return AgentTask(title: "A", goal: "Update the parser.",
                                 workspace: fixture.workspace(additionalPaths: [fixture.checkout.path]))
            }
        }
    }

    /// The on-disk shape `git worktree add` produces, without shelling out to
    /// git, next to a separate ASTRA workspace folder.
    struct WorktreeFixture {
        let root: URL
        let checkout: URL
        let workspaceFolder: URL

        init(worktrees names: [String]) throws {
            let fileManager = FileManager.default
            root = fileManager.temporaryDirectory
                .appendingPathComponent("astra-worktree-scope-\(UUID().uuidString)", isDirectory: true)
                .standardizedFileURL
            checkout = root.appendingPathComponent("main", isDirectory: true)
            workspaceFolder = root.appendingPathComponent("workspace", isDirectory: true)
            let commonDirectory = checkout.appendingPathComponent(".git", isDirectory: true)
            try fileManager.createDirectory(at: commonDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: workspaceFolder, withIntermediateDirectories: true)
            for name in names {
                let worktree = root.appendingPathComponent(name, isDirectory: true)
                let admin = commonDirectory.appendingPathComponent("worktrees/\(name)", isDirectory: true)
                try fileManager.createDirectory(at: worktree, withIntermediateDirectories: true)
                try fileManager.createDirectory(at: admin, withIntermediateDirectories: true)
                try "gitdir: \(admin.path)\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
                try "../..\n".write(to: admin.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
            }
        }

        func path(_ relative: String) -> String {
            root.appendingPathComponent(relative).standardizedFileURL.path
        }

        func makeDirectory(_ relative: String) throws -> String {
            try FileManager.default.createDirectory(atPath: path(relative), withIntermediateDirectories: true)
            return path(relative)
        }

        func workspace(additionalPaths: [String]) -> Workspace {
            Workspace(name: "Repo", primaryPath: workspaceFolder.path, additionalPaths: additionalPaths)
        }

        @MainActor
        func task(_ title: String, pinnedTo worktree: String, in workspace: Workspace) -> AgentTask {
            let task = AgentTask(title: title, goal: "Update the parser.", workspace: workspace)
            task.executionRootPath = path(worktree)
            return task
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func contains(_ root: String, _ path: String) -> Bool {
        !root.isEmpty && (path == root || path.hasPrefix(root + "/"))
    }

    private func lease(_ claims: [TaskExecutionResourceClaim], taskID: UUID) -> [TaskResourceLockClaim] {
        TaskExecutionResourceBroker.lockClaims(for: claims, taskID: taskID, requestID: nil, runMode: "test")
    }
}

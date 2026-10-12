import Foundation
import SwiftData
import Testing
import ASTRACore
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
        // Every configured folder is read-only here, so the worktree's own
        // grant is what keeps this an exclusive, writable launch.
        #expect(plan.hostWritablePaths.contains(fixture.path("wt-a")))
        #expect(plan.workspaceAccess == .exclusive)

        let shared = TaskLaunchResourceResolver.resolve(
            task: task,
            runID: UUID(),
            runtime: .codexCLI,
            phase: "run",
            prompt: task.goal,
            contextText: "",
            workspacePath: fixture.path("wt-a"),
            workspaceAccess: .shared,
            gitCredentialContextProvider: { _, _, _, _ in .empty }
        )
        #expect(shared.workspaceAccess == .shared)
        #expect(!shared.hostWritablePaths.contains(fixture.path("wt-a")))
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

        // A live root beneath a claimed one is covered by that claim.
        let parentClaim = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 2, resourceClaims: [
            TaskExecutionResourceClaim(kind: .workspace, key: fixture.root.path, access: .exclusive)
        ])
        #expect(!TaskExecutionResourceClaimResolver.hasWorkspacePathDrift(request: parentClaim, task: task))
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
        // A request without durable claims is admitted under its fallback
        // workspace claim, so it projects no Git writes rather than a direct launch.
        let preClaim = fixture.task("Legacy", pinnedTo: "wt-a", in: workspace)
        preClaim.goal = "Update the parser, then git push the result."
        #expect(TaskExecutionResourceClaimResolver.admittedWritableGitMetadataRoots(
            for: TaskTurnRequest(task: preClaim, messageEventID: UUID(), sequence: 1), task: preClaim) == [])
        #expect(TaskExecutionResourceClaimResolver.admittedWritableGitMetadataRoots(for: nil, task: preClaim) == nil)
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

    @Test("A local Git mutation in a worktree claims and writes the shared Git metadata")
    func localGitMutationClaimsSharedMetadata() throws {
        let fixture = try WorktreeFixture(worktrees: ["wt-a"])
        defer { fixture.remove() }
        // The replaced source checkout no longer covers `.git`, so the
        // mutation itself must claim the common directory.
        let workspace = fixture.workspace(additionalPaths: [fixture.checkout.path])
        let commonDirectory = fixture.checkout.appendingPathComponent(".git").path
        let canonicalCommon = URL(fileURLWithPath: commonDirectory).resolvingSymlinksInPath().path
        for goal in ["Fix the parser and commit the change.", "Then run git rebase main."] {
            let task = fixture.task("Ship feature A", pinnedTo: "wt-a", in: workspace)
            task.goal = goal
            let claims = TaskExecutionResourceClaimResolver.claims(for: task)
            #expect(claims.contains {
                $0.kind == .gitCommonDirectory && $0.key == commonDirectory && $0.access == .exclusive
            }, "\(goal)")
            let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1, resourceClaims: claims)
            let plan = TaskLaunchResourceResolver.resolve(
                task: task,
                runID: UUID(),
                runtime: .claudeCode,
                phase: "run",
                prompt: goal,
                contextText: "",
                workspacePath: fixture.path("wt-a"),
                admittedWritableGitMetadataRoots: TaskExecutionResourceClaimResolver
                    .admittedWritableGitMetadataRoots(for: request, task: task)
            )
            #expect(plan.hostWritablePaths.contains(canonicalCommon), "\(goal)")
        }
    }

    @Test("A source checkout named through a symlink is still replaced")
    func symlinkedSourceCheckoutIsReplaced() throws {
        let fixture = try WorktreeFixture(worktrees: ["wt-a"])
        defer { fixture.remove() }
        let alias = fixture.path("alias")
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: fixture.checkout.path)
        let task = fixture.task("Ship feature A", pinnedTo: "wt-a", in: fixture.workspace(additionalPaths: [alias]))

        #expect(TaskWorkspaceAccess(task: task).replacedSourceCheckoutPaths == [alias])
        #expect(TaskWorkspaceAccess(task: task).runtimeWritablePaths.isEmpty)
        #expect(TaskExecutionResourceClaimResolver.claims(for: task).map(\.key) == [fixture.path("wt-a")])
    }

    @Test("A primary source checkout replaced by the active worktree is read-only in the prompt")
    func replacedPrimaryCheckoutIsLabeledReadOnly() throws {
        let fixture = try WorktreeFixture(worktrees: ["wt-a"])
        defer { fixture.remove() }
        let shared = try fixture.makeDirectory("shared-notes")
        let workspace = Workspace(name: "Repo", primaryPath: fixture.checkout.path, additionalPaths: [shared])
        workspace.activeWorkingPath = fixture.path("wt-a")
        let task = AgentTask(title: "A", goal: "Update the parser.", workspace: workspace)

        #expect(TaskWorkspaceAccess(task: task).replacedSourceCheckoutPaths == [fixture.checkout.path])
        #expect(AgentPromptBuilder.buildPrompt(for: task)
            .contains("read-only, edit the worktree): \(fixture.checkout.path)"))
    }

    @Test("Docker keeps folders the run cannot write mounted read-only")
    func readOnlyWorkspaceFoldersStayMounted() throws {
        let fixture = try WorktreeFixture(worktrees: ["wt-a"])
        defer { fixture.remove() }
        let task = fixture.task(
            "Ship feature A",
            pinnedTo: "wt-a",
            in: fixture.workspace(additionalPaths: [fixture.checkout.path])
        )
        let mounts = DockerExecutionPlanner.mountPlan(
            currentDirectory: fixture.path("wt-a"),
            environment: WorkspaceExecutionEnvironment(
                id: "image:test", kind: .dockerImage, displayName: "Test", image: "astra/test:latest"
            ),
            task: task
        )
        func access(_ path: String) -> ExecutionEnvironmentMountAccess? {
            mounts.first { $0.hostPath == path }?.access
        }

        #expect(access(fixture.path("wt-a")) == .readWrite)
        #expect(access(fixture.checkout.path) == .readOnly)
        #expect(access(fixture.workspaceFolder.path) == .readOnly)
    }

    @Test("Local Git metadata writers count as Git intent")
    func gitMetadataWritersAreDetected() {
        let task = AgentTask(title: "Maintain the repository", goal: "Keep it tidy.")
        for command in ["git config --local core.hooksPath .githooks", "git update-ref refs/heads/x HEAD",
                        "git notes add -m reviewed", "git replace abc def", "git worktree add ../x",
                        "git -C repo add .", "git --git-dir=/x/.git checkout main",
                        "git -C '/tmp/a b' commit -m wip", "git --no-pager -c core.editor=true rebase main",
                        "git --work-tree /x reset --hard", "git remote add upstream git@example.com:x.git",
                        "git -C repo remote remove origin", "git submodule update --init"] {
            #expect(GitOperationIntentDetector.detectsLocalGitMutationOperation(prompt: command, task: task), "\(command)")
        }
        for command in ["git -C repo status", "git --no-pager log --oneline", "digit add"] {
            #expect(!GitOperationIntentDetector.detectsLocalGitMutationOperation(prompt: command, task: task), "\(command)")
        }
    }

    @Test("Copilot can read a replaced source checkout through its native directories")
    func copilotReachesReadOnlyWorkspaceFolders() throws {
        let fixture = try WorktreeFixture(worktrees: ["wt-a"])
        defer { fixture.remove() }
        let task = fixture.task(
            "Ship feature A",
            pinnedTo: "wt-a",
            in: fixture.workspace(additionalPaths: [fixture.checkout.path])
        )

        let directories = AgentRuntimeProcessRunner.copilotNativeDirectoryProjection(for: task).additionalDirectories
        #expect(directories.contains(fixture.checkout.path))
        #expect(!AgentRuntimeProcessRunner.runtimeWritablePaths(for: task).contains(fixture.checkout.path))
    }

    @Test("Without sandboxing, sibling worktrees still serialize on their source checkout")
    func unenforcedSourceCheckoutIsClaimedWhenSandboxIsOff() throws {
        let fixture = try WorktreeFixture(worktrees: ["wt-a", "wt-b"])
        defer { fixture.remove() }
        let workspace = fixture.workspace(additionalPaths: [fixture.checkout.path])
        let first = fixture.task("Ship feature A", pinnedTo: "wt-a", in: workspace)
        let second = fixture.task("Ship feature B", pinnedTo: "wt-b", in: workspace)
        func lease(_ task: AgentTask, _ enforcement: ExecutionSandboxEnforcement) -> [TaskResourceLockClaim] {
            let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1,
                                          resourceClaims: TaskExecutionResourceClaimResolver.claims(for: task))
            return TaskExecutionResourceAdmissionPolicy.lockClaims(
                for: request, task: task, runMode: "test", sandboxEnforcement: enforcement)
        }

        // The sandbox keeps the replaced checkout read-only, so siblings run together.
        #expect(TaskExecutionResourceBroker.canAcquire(lease(second, .bestEffort), active: lease(first, .bestEffort)))
        // With sandboxing Off nothing enforces that, so the checkout is claimed as a writer.
        let unenforced = lease(first, .off)
        #expect(unenforced.contains { $0.resourceKey == fixture.checkout.path && $0.accessMode == .write })
        #expect(!TaskExecutionResourceBroker.canAcquire(lease(second, .off), active: unenforced))
    }

    @Test("Every read-only workspace folder is labeled in the prompt")
    func readOnlyWorkspaceFolderIsLabeled() throws {
        let fixture = try WorktreeFixture(worktrees: [])
        defer { fixture.remove() }
        // The sole repository in Folder access becomes the code root, so the
        // primary workspace folder is read-only apart from the task folder.
        let task = AgentTask(title: "A", goal: "Update the parser.",
                             workspace: fixture.workspace(additionalPaths: [fixture.checkout.path]))

        #expect(TaskWorkspaceAccess(task: task).codeWorkingDirectory == fixture.checkout.path)
        #expect(AgentPromptBuilder.buildPrompt(for: task)
            .contains("(read-only for this task; write task files to the task output folder): \(fixture.workspaceFolder.path)"))
    }

    @Test("A checkout beneath a writable folder is not treated as replaced")
    func checkoutUnderWritableParentStaysWritable() throws {
        let fixture = try WorktreeFixture(worktrees: ["wt-a"])
        defer { fixture.remove() }
        // The fixture root holds the checkout, so it stays writable through it.
        let task = fixture.task(
            "Ship feature A",
            pinnedTo: "wt-a",
            in: fixture.workspace(additionalPaths: [fixture.root.path, fixture.checkout.path])
        )
        let access = TaskWorkspaceAccess(task: task)

        #expect(access.replacedSourceCheckoutPaths.isEmpty)
        #expect(access.runtimeWritablePaths == [fixture.root.path, fixture.checkout.path])
    }

    @Test("Git inspection with global options counts as Git intent")
    func gitInspectionWithGlobalOptionsIsDetected() {
        let task = AgentTask(title: "Inspect", goal: "Look around.")
        for command in ["git -C repo status", "git --no-pager -C '/tmp/a b' log --oneline", "git --git-dir=/x/.git diff"] {
            #expect(GitOperationIntentDetector.detectsLocalGitInspectionOperation(prompt: command, task: task), "\(command)")
        }
        for command in ["git -C repo push origin main", "git --git-dir=/x/.git fetch", "git -C repo pull --rebase",
                        "git lfs pull", "git -C repo lfs push origin main"] {
            #expect(GitOperationIntentDetector.detectsNetworkGitOperation(prompt: command, task: task), "\(command)")
        }
    }

    @Test("Preflight manifest keeps read-only workspace folders inside the boundary")
    func preflightManifestKeepsReadOnlyWorkspaceFoldersReadable() throws {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-read-only-workspace-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let durableWorkspace = root.appendingPathComponent("workspace").path
        let codeRoot = root.appendingPathComponent("repo").path
        try FileManager.default.createDirectory(atPath: durableWorkspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: codeRoot + "/.git", withIntermediateDirectories: true)
        // The sole repository becomes the code root, so the durable workspace
        // folder is read-only apart from the task folder.
        let workspace = Workspace(name: "Read only", primaryPath: durableWorkspace)
        workspace.additionalPaths = [codeRoot]
        let task = AgentTask(
            title: "OpenCode state read",
            goal: "Read task state then answer",
            workspace: workspace,
            model: "opencode/big-pickle",
            runtime: .openCodeCLI
        )
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        let manifest = AgentPolicyManifestService.recordPreflightManifest(
            task: task,
            run: run,
            runtime: .openCodeCLI,
            model: "opencode/big-pickle",
            workspacePath: codeRoot,
            phase: "test",
            permissionPolicy: .restricted,
            executionPolicy: .default,
            defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue,
            modelContext: context
        )

        #expect(TaskWorkspaceAccess(task: task).codeWorkingDirectory == codeRoot)
        #expect(manifest.additionalReadOnlyPaths.contains(durableWorkspace))
        #expect(!manifest.additionalPaths.contains(durableWorkspace))
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

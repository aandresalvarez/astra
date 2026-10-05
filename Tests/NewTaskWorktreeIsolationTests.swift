import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// Launch grants, derived tasks, recovery, and composer runs keep a task in
/// its worktree and away from the source checkout.
@MainActor
@Suite("New task worktree isolation and inheritance", .serialized)
struct NewTaskWorktreeIsolationTests {
    private typealias Fixture = NewTaskWorktreeFixture

    @discardableResult
    private func prepare(
        _ task: AgentTask,
        _ repository: URL,
        branchTitle: String? = nil,
        context: ModelContext,
        fixture: Fixture
    ) async throws -> String {
        try await TaskWorktreeService.prepare(
            task: task,
            request: TaskWorktreeRequest(repositoryPath: repository.path, base: .currentBranch),
            branchTitle: branchTitle,
            modelContext: context,
            worktreesRoot: fixture.worktrees.path
        )
        return try #require(task.executionRootPath)
    }

    private func launchPlan(
        _ task: AgentTask,
        workspaceAccess: TaskExecutionResourceAccess = .exclusive
    ) -> TaskLaunchResourcePlan {
        TaskLaunchResourceResolver.resolve(
            task: task, runID: UUID(), runtime: .claudeCode, phase: "run",
            prompt: task.goal, contextText: "", workspacePath: TaskWorkspaceAccess(task: task).codeWorkingDirectory,
            workspaceAccess: workspaceAccess,
            gitCredentialContextProvider: { _, _, _, _ in .empty }
        )
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - Launch grants

    @Test("A configured folder that contains the source checkout stays read-only; the worktree is the writable copy")
    func ancestorFolderStaysReadOnly() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let projects = fixture.root.appendingPathComponent("Projects", isDirectory: true)
        let repository = try fixture.repository("Projects/App")
        let store = try Fixture.container()
        let workspace = Workspace(name: "Projects", primaryPath: projects.path, additionalPaths: [repository.path])
        store.mainContext.insert(workspace)
        let task = AgentTask(title: "Update", goal: "Update files", workspace: workspace)
        let path = try await prepare(task, repository, context: store.mainContext, fixture: fixture)

        let access = TaskWorkspaceAccess(task: task)
        #expect(access.runtimeWorkspacePaths == [path])
        #expect(access.runtimeReadOnlyWorkspacePaths == [projects.path])
        let nativePaths = AgentRuntimeProcessRunner.runtimeWritablePaths(for: task)
        #expect(nativePaths.contains(path))
        #expect(!nativePaths.contains(projects.path))
        #expect(!nativePaths.contains(repository.path))
        let plan = launchPlan(task)
        #expect(plan.hostWritablePaths.contains(path))
        #expect(!plan.hostWritablePaths.contains(projects.path))
        #expect(!plan.hostWritablePaths.contains(repository.path))
        #expect(plan.hostReadablePaths.contains(projects.path))
        #expect(plan.hostWritablePaths.contains(repository.appendingPathComponent(".git").path))
    }

    @Test("The worktree's Git metadata reaches ASTRA-confined processes only, and only while Git registers the worktree")
    func gitMetadataGrantIsVerified() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let other = try fixture.repository("Other")
        let store = try Fixture.container()
        let workspace = Workspace(name: "App", primaryPath: repository.path)
        store.mainContext.insert(workspace)
        let task = AgentTask(title: "Commit", goal: "Commit the change", workspace: workspace)
        let path = try await prepare(task, repository, context: store.mainContext, fixture: fixture)
        let metadata = repository.appendingPathComponent(".git").path

        let access = TaskWorkspaceAccess(task: task)
        #expect(access.runtimeWorktreeGitMetadataPaths == [metadata])
        #expect(!access.runtimeWorkspacePaths.contains(metadata))
        // Provider-native sandboxes never get it: Codex keeps `.git` read-only.
        #expect(!AgentRuntimeProcessRunner.runtimeWritablePaths(for: task).contains(metadata))
        #expect(AgentRuntimeProcessRunner.confinedCommandWritablePaths(for: task).contains(metadata))
        #expect(!AgentRuntimeProcessRunner.confinedCommandWritablePaths(for: task).contains(repository.path))
        let grant = try #require(launchPlan(task).hostPathGrants.first { $0.path == metadata })
        #expect(grant.access == .readWrite)
        #expect(grant.lifetime == .task)
        #expect(!launchPlan(task).hostWritablePaths.contains(repository.path))
        #expect(launchPlan(task, workspaceAccess: .shared).hostPathGrants.first { $0.path == metadata }?.access == .read)

        // The grant comes from the recorded source repository, never from the
        // worktree's own `.git` file, which the task can rewrite.
        let pointer = URL(fileURLWithPath: path).appendingPathComponent(".git")
        let original = try String(contentsOf: pointer, encoding: .utf8)
        try "gitdir: \(other.appendingPathComponent(".git").path)\n".write(to: pointer, atomically: true, encoding: .utf8)
        #expect(TaskWorkspaceAccess(task: task).runtimeWorktreeGitMetadataPaths == [metadata])
        try original.write(to: pointer, atomically: true, encoding: .utf8)

        // A binding edited to name another repository opens nothing: that
        // repository doesn't register the worktree.
        let forged = AgentTask(title: "Forged", goal: "Commit", workspace: Workspace(name: "App", primaryPath: repository.path))
        forged.executionRootPath = path
        forged.events = [TaskEvent(task: forged, eventType: TaskEventTypes.Task.worktreePrepared, payload: try TaskEvent.encodePayload(
            TaskWorktreePayload(repositoryPath: other.path, worktreePath: path, branch: "astra/forged")
        ).get())]
        #expect(TaskWorkspaceAccess(task: forged).worktreeBinding?.repositoryPath == other.path)
        #expect(TaskWorkspaceAccess(task: forged).runtimeWorktreeGitMetadataPaths.isEmpty)
        #expect(!AgentRuntimeProcessRunner.confinedCommandWritablePaths(for: forged)
            .contains(other.appendingPathComponent(".git").path))

        try await GitService.shared.removeWorktree(repoPath: repository.path, worktreePath: path)
        #expect(TaskWorkspaceAccess(task: task).runtimeWorktreeGitMetadataPaths.isEmpty)
        #expect(!AgentRuntimeProcessRunner.confinedCommandWritablePaths(for: task).contains(metadata))
    }

    @Test("A linked source checkout grants its common Git directory, not its working tree")
    func linkedSourceCheckoutGrantsCommonGitDirectory() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let linked = fixture.root.appendingPathComponent("App-source", isDirectory: true)
        try fixture.git(["worktree", "add", "--quiet", "-b", "source", linked.path], at: repository)
        let store = try Fixture.container()
        let workspace = Workspace(name: "Linked", primaryPath: linked.path)
        store.mainContext.insert(workspace)
        let task = AgentTask(title: "Commit", goal: "Commit the change", workspace: workspace)
        let path = try await prepare(task, linked, context: store.mainContext, fixture: fixture)

        #expect(TaskWorkspaceAccess(task: task).runtimeWorkspacePaths == [path])
        let metadata = repository.appendingPathComponent(".git").path
        #expect(TaskWorkspaceAccess(task: task).runtimeWorktreeGitMetadataPaths == [metadata])
        let plan = launchPlan(task)
        #expect(plan.hostWritablePaths.contains(metadata))
        #expect(!plan.hostWritablePaths.contains(linked.path))
        #expect(!plan.hostWritablePaths.contains(repository.path))
    }

    @Test("Docker mounts a task worktree and its Git metadata without writable source checkout aliases")
    func dockerWorktreeMountsPreserveIsolation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let source = try fixture.repository("Projects/App")
        let other = try fixture.repository("Projects/Other")
        let nested = try fixture.repository("Projects/App/vendor/Nested")
        let generated = source.appendingPathComponent("Generated")
        try FileManager.default.createDirectory(at: generated, withIntermediateDirectories: true)
        let projects = source.deletingLastPathComponent()
        let store = try Fixture.container()
        let workspace = Workspace(
            name: "Projects", primaryPath: projects.path,
            additionalPaths: [source.path, other.path, generated.path, nested.path]
        )
        store.mainContext.insert(workspace)
        let task = AgentTask(title: "Update", goal: "Update files", workspace: workspace)
        let path = try await prepare(task, source, context: store.mainContext, fixture: fixture)
        let metadata = source.appendingPathComponent(".git").path
        let environment = WorkspaceExecutionEnvironment(
            id: "image:test",
            kind: .dockerImage,
            displayName: "Test",
            image: "astra/test:latest",
            mounts: [
                ExecutionEnvironmentMount(hostPath: projects.path, containerPath: "/workspace", access: .readWrite, role: .workspace),
                ExecutionEnvironmentMount(hostPath: source.path, containerPath: "/mnt/source", access: .readWrite, role: .additionalPath),
                ExecutionEnvironmentMount(hostPath: other.path, containerPath: "/mnt/other", access: .readWrite, role: .additionalPath),
                ExecutionEnvironmentMount(hostPath: generated.path, containerPath: "/mnt/generated", access: .readWrite, role: .additionalPath),
                ExecutionEnvironmentMount(hostPath: nested.path, containerPath: "/mnt/nested", access: .readWrite, role: .additionalPath)
            ]
        )

        let mounts = DockerExecutionPlanner.mountPlan(currentDirectory: path, environment: environment, task: task)
        #expect(mounts.first { $0.hostPath == path }?.containerPath == "/workspace")
        #expect(mounts.first { $0.hostPath == path }?.access == .readWrite)
        #expect(!mounts.contains { $0.hostPath == projects.path })
        #expect(mounts.first { $0.hostPath == source.path }?.access == .readOnly)
        #expect(mounts.first { $0.hostPath == generated.path }?.access == .readOnly)
        #expect(mounts.first { $0.hostPath == nested.path }?.access == .readWrite)
        #expect(mounts.first { $0.hostPath == other.path }?.access == .readWrite)
        let gitMount = try #require(mounts.first { $0.hostPath == metadata && $0.containerPath == metadata })
        #expect(gitMount.access == .readWrite)
        #expect(DockerExecutionPlanner.mountPlan(
            currentDirectory: path, environment: environment, task: task, workspaceAccess: .shared
        ).first { $0.hostPath == metadata }?.access == .readOnly)
        let mcpVariables = DockerWorkspaceMCPProjection.environmentVariables(
            task: task, environment: environment, currentDirectory: path, runID: nil, workspaceAccess: .shared
        )
        let mcpMounts = try #require(mcpVariables["ASTRA_WORKSPACE_DOCKER_MOUNTS"]?.data(using: .utf8))
        let projected = try JSONDecoder().decode([ExecutionEnvironmentMount].self, from: mcpMounts)
        #expect(projected.first { $0.hostPath == path }?.access == .readOnly)
        #expect(projected.first { $0.hostPath == metadata }?.access == .readOnly)
        #expect(projected.first { $0.hostPath == other.path }?.access == .readOnly)
    }

    @Test("Docker refuses a removed worktree or an unreadable binding instead of mounting a new empty checkout")
    func dockerDoesNotRecreateMissingWorktree() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let source = try fixture.repository("App")
        let store = try Fixture.container()
        let workspace = Workspace(name: "App", primaryPath: source.path)
        store.mainContext.insert(workspace)
        let task = AgentTask(title: "Run", goal: "Run", workspace: workspace)
        let path = try await prepare(task, source, context: store.mainContext, fixture: fixture)
        let environment = WorkspaceExecutionEnvironment(
            id: "image:test", kind: .dockerImage, displayName: "Test", image: "astra/test:latest"
        )
        func base(_ directory: String) -> AgentRuntimeProcessLaunchPlan {
            AgentRuntimeProcessLaunchPlan(
                runtime: .claudeCode, executablePath: "/host/claude", arguments: [],
                currentDirectory: directory, environment: [:], browserShimDirectory: nil,
                providerVersion: nil, parsesJSONLines: false
            )
        }

        try await GitService.shared.removeWorktree(repoPath: source.path, worktreePath: path)
        switch DockerExecutionPlanner.plan(base: base(path), environment: environment, task: task, runID: nil) {
        case .success: Issue.record("A removed worktree must not become an empty Docker volume")
        case .failure(let error): #expect(error == .worktreeUnavailable(path))
        }
        #expect(!FileManager.default.fileExists(atPath: path))

        let invalid = AgentTask(title: "Invalid", goal: "Run", workspace: workspace)
        invalid.executionRootPath = source.path
        store.mainContext.insert(invalid)
        store.mainContext.insert(TaskEvent(
            task: invalid, eventType: TaskEventTypes.Task.worktreePrepared, payload: "{"
        ))
        switch DockerExecutionPlanner.plan(base: base(source.path), environment: environment, task: invalid, runID: nil) {
        case .success: Issue.record("An unreadable binding must not mount the original checkout")
        case .failure(let error): #expect(error == .invalidWorktreeBinding)
        }
    }

    @Test("Under ASTRA's Seatbelt, a validation command can commit in the worktree through the Git metadata grant")
    func sandboxedValidationCommitsInWorktree() async throws {
        guard FileManager.default.isExecutableFile(atPath: ExecutionSandbox.sandboxExecPath) else { return }
        // Outside TMPDIR, which the command sandbox makes writable wholesale.
        let fixture = try Fixture(parent: URL(fileURLWithPath: "/var/tmp"))
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let workspace = Workspace(name: "App", primaryPath: repository.path)
        store.mainContext.insert(workspace)
        let task = AgentTask(title: "Commit", goal: "Commit the change", workspace: workspace)
        let path = try await prepare(task, repository, context: store.mainContext, fixture: fixture)
        let runner = ShellValidationCommandRunner(sandboxSettingsProvider: {
            ExecutionSandboxSettings(enforcement: .strict)
        })
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        let commit = "git -c user.name=ASTRA -c user.email=astra@example.invalid -c commit.gpgsign=false "
            + "-c core.hooksPath=/dev/null commit --allow-empty --quiet -m"

        let withoutGrant = await runner.run(
            command: "\(commit) Denied",
            workingDirectory: path,
            environment: environment,
            additionalWritablePaths: AgentRuntimeProcessRunner.runtimeWritablePaths(for: task)
        )
        #expect(withoutGrant.exitCode != 0)

        let withGrant = await runner.run(
            command: "\(commit) Granted",
            workingDirectory: path,
            environment: environment,
            additionalWritablePaths: AgentRuntimeProcessRunner.confinedCommandWritablePaths(for: task)
        )
        #expect(withGrant.exitCode == 0, "\(withGrant.stderr)")
        #expect(try fixture.git(["log", "-1", "--format=%s"], at: URL(fileURLWithPath: path)) == "Granted")
    }

    @Test("A nested repository keeps its own checkout; plain source subfolders map into the worktree")
    func nestedRepositoryKeepsItsPath() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let nested = try fixture.repository("App/Vendor/Lib")
        let sources = repository.appendingPathComponent("Sources").path
        let store = try Fixture.container()
        let workspace = Workspace(name: "App", primaryPath: repository.path, additionalPaths: [nested.path, sources])
        store.mainContext.insert(workspace)
        let task = AgentTask(title: "Update", goal: "Update files", workspace: workspace)
        let path = try await prepare(task, repository, context: store.mainContext, fixture: fixture)

        #expect(TaskWorkspaceAccess(task: task).runtimeWorkspacePaths == [path, nested.path, path + "/Sources"])
        #expect(launchPlan(task).hostWritablePaths.contains(nested.path))
    }

    @Test("A draft switched to another checkout gets that checkout's grants")
    func retargetedPinStaysWritable() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let workspace = Workspace(name: "App", primaryPath: repository.path)
        store.mainContext.insert(workspace)
        let draft = AgentTask(title: "Draft", goal: "Explore", workspace: workspace)
        let prepared = try await prepare(draft, repository, context: store.mainContext, fixture: fixture)
        let selected = fixture.root.appendingPathComponent("App-side", isDirectory: true)
        try fixture.git(["worktree", "add", "--quiet", "-b", "side", selected.path], at: repository)

        // What the Repository card does when the user picks another checkout.
        draft.executionRootPath = selected.path

        let access = TaskWorkspaceAccess(task: draft)
        #expect(access.worktreeBinding == nil)
        #expect(access.codeWorkingDirectory == selected.path)
        #expect(access.runtimeWorkspacePaths.contains(selected.path))
        #expect(!access.runtimeWorkspacePaths.contains(prepared))
        #expect(AgentRuntimeProcessRunner.runtimeWritablePaths(for: draft).contains(selected.path))
        #expect(launchPlan(draft).hostWritablePaths.contains(selected.path))
    }

    // MARK: - Derived tasks and recovery

    @Test("Chained, corrective, and forked tasks keep the worktree binding, not just its path")
    func derivedTasksKeepBinding() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let context = store.mainContext
        let workspace = Workspace(name: "WS", primaryPath: fixture.storage.path, additionalPaths: [repository.path])
        context.insert(workspace)
        let task = AgentTask(title: "Build", goal: "Build it", workspace: workspace)
        let path = try await prepare(task, repository, context: context, fixture: fixture)
        let run = TaskRun(task: task)
        run.status = .completed
        context.insert(run)

        ChainedTaskSubmissionService.create(from: task, run: run, modelContext: context, goal: "Follow up")
        let chained = try #require(try context.fetch(FetchDescriptor<AgentTask>()).first { $0.chainedFromID == task.id })
        let planID = UUID()
        TaskCorrectiveWorkService.recordProposedStep(
            planID: planID, sourceRunID: run.id, failedAssertionID: "tests-pass",
            failureSummary: "Tests failed", suggestedRepair: "Fix the tests",
            task: task, run: run, modelContext: context
        )
        let corrective = try #require(TaskCorrectiveWorkService.createCorrectiveTask(
            from: task,
            correctiveStepID: TaskCorrectiveWorkQueries.correctiveStepID(planID: planID, failedAssertionID: "tests-pass"),
            modelContext: context
        ))
        let forked = try AgentTaskForkService.fork(from: task, upToRun: run, in: context)

        for child in [chained, corrective, forked] {
            #expect(child.executionRootPath == path)
            #expect(TaskWorktreeService.activeWorktreeBinding(for: child)?.worktreePath == path)
            #expect(TaskWorkspaceAccess(task: child).runtimeWorkspacePaths == [fixture.storage.path, path])
        }
    }

    @Test("An unreadable worktree binding remains unreadable in derived tasks, never becoming a legacy pin")
    func invalidBindingRemainsBoundToMissingCheckout() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let context = store.mainContext
        let workspace = Workspace(name: "WS", primaryPath: fixture.storage.path, additionalPaths: [repository.path])
        context.insert(workspace)
        let source = AgentTask(title: "Source", goal: "Do work", workspace: workspace)
        let missing = fixture.root.appendingPathComponent("missing-worktree").path
        source.executionRootPath = missing
        context.insert(source)
        context.insert(TaskEvent(task: source, eventType: TaskEventTypes.Task.worktreePrepared, payload: "invalid payload"))
        let run = TaskRun(task: source)
        run.status = .completed
        context.insert(run)

        ChainedTaskSubmissionService.create(from: source, run: run, modelContext: context, goal: "Follow up")
        let chained = try #require(try context.fetch(FetchDescriptor<AgentTask>()).first { $0.chainedFromID == source.id })
        let prepared = AgentTask(title: "Next", goal: "Keep working", workspace: workspace)
        context.insert(prepared)
        try await TaskWorktreeService.prepare(
            task: prepared, request: nil, inheritingFrom: source, modelContext: context
        )
        for child in [chained, prepared] {
            #expect(child.executionRootPath == missing)
            guard case .invalid = TaskWorktreeBinding.state(of: child) else {
                Issue.record("The child lost its unreadable worktree binding")
                continue
            }
            #expect(TaskWorkspaceAccess(task: child).codeWorkingDirectory == missing)
            #expect(TaskWorkspaceAccess(task: child).runtimeWorkspacePaths.isEmpty)
        }
        NewTaskWorktreeComposerFlow.followWorkspaceDefault(source)
        #expect(source.executionRootPath == missing)

        let replacement = AgentTask(title: "New checkout", goal: "Keep working", workspace: workspace)
        try await TaskWorktreeService.prepare(
            task: replacement,
            request: TaskWorktreeRequest(repositoryPath: repository.path, base: .currentBranch),
            inheritingFrom: source, modelContext: context, worktreesRoot: fixture.worktrees.path
        )
        #expect(replacement.executionRootPath != missing)
        #expect(TaskWorktreeService.activeWorktreeBinding(for: replacement)?.worktreePath == replacement.executionRootPath)

        let replacementPath = replacement.executionRootPath
        let legacy = AgentTask(title: "Legacy", goal: "No worktree", workspace: workspace)
        legacy.executionRootPath = repository.path
        try await TaskWorktreeService.prepare(
            task: replacement, request: nil, inheritingFrom: legacy, modelContext: context
        )
        #expect(replacement.executionRootPath == replacementPath)
        #expect(TaskWorktreeService.activeWorktreeBinding(for: replacement)?.worktreePath == replacementPath)
    }

    @Test("Recovery exports keep the worktree binding after many later events")
    func recoveryMirrorKeepsBinding() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let context = store.mainContext
        let workspace = Workspace(name: "WS", primaryPath: fixture.storage.path, additionalPaths: [repository.path])
        context.insert(workspace)
        let task = AgentTask(title: "Build", goal: "Build it", workspace: workspace)
        let path = try await prepare(task, repository, context: context, fixture: fixture)
        let later = Date().addingTimeInterval(60)
        for index in 0..<(WorkspaceConfigManager.MirrorLimits.maxEventsPerTask + 5) {
            let event = TaskEvent(task: task, eventType: TaskEventTypes.System.info, payload: "Later event \(index)")
            event.timestamp = later.addingTimeInterval(Double(index))
            context.insert(event)
        }
        try context.save()

        let config = try #require(WorkspaceConfigManager.export(workspace: workspace, modelContext: context))
        let decoded = try JSONDecoder().decode(
            WorkspaceConfigManager.WorkspaceConfig.self, from: try JSONEncoder().encode(config)
        )
        let recoveredStore = try ModelContainer(
            for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let imported = WorkspaceConfigManager.importWorkspace(
            from: decoded, modelContext: recoveredStore.mainContext, taskRecoveryTrustPolicy: .trustedLocalRecovery
        )
        let recovered = try #require(imported.tasks.first)
        #expect(recovered.executionRootPath == path)
        #expect(TaskWorktreeService.activeWorktreeBinding(for: recovered)?.worktreePath == path)
        #expect(TaskWorkspaceAccess(task: recovered).runtimeWorkspacePaths == [fixture.storage.path, path])
    }

    // MARK: - Templates

    @Test("Template tasks started from a worktree draft run in that worktree, named after the template")
    func templateTasksInheritWorktree() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let context = store.mainContext
        let workspace = Workspace(name: "WS", primaryPath: fixture.storage.path, additionalPaths: [repository.path])
        context.insert(workspace)
        let draft = AgentTask(title: "Chat", goal: "/template review", workspace: workspace)
        context.insert(draft)
        let path = try await prepare(
            draft, repository, branchTitle: "Review the login flow", context: context, fixture: fixture
        )
        let shortID = String(draft.id.uuidString.lowercased().prefix(8))
        #expect(TaskWorktreeService.activeWorktreeBinding(for: draft)?.branch == "astra/review-login-flow-\(shortID)")
        let template = TaskTemplate(name: "Review", mainGoal: "Review the change", workspace: workspace)
        template.beforeGoal = "Prepare the checkout"
        context.insert(template)

        let creation = WorkspaceCommandService.createTemplateTasks(
            template: template, taskTitle: "Review the login flow", variables: [:], selectedSkills: [],
            defaultModel: "", defaultRuntimeID: "claude_code", workspace: workspace,
            modelContext: context, source: "test", checkoutSource: draft
        )

        let before = try #require(creation.beforeTask)
        #expect(creation.initialRequestSubmitted)
        for task in [before, creation.mainTask] {
            #expect(task.executionRootPath == path)
            #expect(TaskWorktreeService.activeWorktreeBinding(for: task)?.worktreePath == path)
            #expect(TaskWorkspaceAccess(task: task).runtimeWorkspacePaths == [fixture.storage.path, path])
        }

        let elsewhere = Workspace(name: "Elsewhere", primaryPath: fixture.root.path)
        context.insert(elsewhere)
        let otherTemplate = TaskTemplate(name: "Review", mainGoal: "Review the change", workspace: elsewhere)
        context.insert(otherTemplate)
        let unrelated = WorkspaceCommandService.createTemplateTasks(
            template: otherTemplate, taskTitle: "Review", variables: [:], selectedSkills: [],
            defaultModel: "", defaultRuntimeID: "claude_code", workspace: elsewhere,
            modelContext: context, source: "test", checkoutSource: draft
        )
        #expect(unrelated.mainTask.executionRootPath == nil)
        #expect(TaskWorktreeService.activeWorktreeBinding(for: unrelated.mainTask) == nil)
    }

    // MARK: - Workspace switches

    @Test("A draft from another workspace lends neither its worktree nor its pin, and never adopts a failed task")
    func otherWorkspaceDraftIsIgnored() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let repository = try fixture.repository("App")
        let store = try Fixture.container()
        let context = store.mainContext
        let first = Workspace(name: "First", primaryPath: repository.path)
        let second = Workspace(name: "Second", primaryPath: fixture.storage.path)
        context.insert(first)
        context.insert(second)
        let draft = AgentTask(title: "Draft", goal: "Explore", workspace: first)
        let path = try await prepare(draft, repository, context: context, fixture: fixture)

        let task = AgentTask(title: "Other", goal: "Explore", workspace: second)
        context.insert(task)
        try await TaskWorktreeService.prepare(
            task: task, request: nil, inheritingFrom: draft, modelContext: context, worktreesRoot: fixture.worktrees.path
        )
        #expect(task.executionRootPath == nil)
        #expect(TaskWorktreeService.activeWorktreeBinding(for: task) == nil)

        let otherDraft = AgentTask(title: "Second draft", goal: "Explore", workspace: second)
        context.insert(otherDraft)
        let failed = AgentTask(title: "Run", goal: "Explore", workspace: first)
        let failedPath = try await prepare(failed, repository, context: context, fixture: fixture)
        TaskStateMachine.enqueueFromChatSubmission(failed, modelContext: context)

        let recovered = TaskWorktreeService.recoverFailedSubmission(
            task: failed, existingDraft: otherDraft, modelContext: context
        )

        #expect(recovered === failed)
        #expect(failed.status == .draft)
        #expect(failed.executionRootPath == failedPath)
        #expect(failedPath != path)
        #expect(otherDraft.executionRootPath == nil)
        #expect(TaskWorktreeService.activeWorktreeBinding(for: otherDraft) == nil)
    }

    @Test("The composer ignores drafts from a workspace it has switched away from")
    func staleWorkspaceDraftIsIgnored() throws {
        let store = try Fixture.container()
        let context = store.mainContext
        let first = Workspace(name: "First", primaryPath: "/projects/first")
        let second = Workspace(name: "Second", primaryPath: "/projects/second")
        context.insert(first)
        context.insert(second)
        let draft = AgentTask(title: "Old draft", goal: "Explore", workspace: first)
        context.insert(draft)

        #expect(NewTaskWorktreeComposerFlow.liveDraft(draft, in: first) === draft)
        #expect(NewTaskWorktreeComposerFlow.liveDraft(draft, in: second) == nil)
    }

    @Test("Detaching a task creation cancels it, frees the composer at once, and reports nothing late")
    func creationRunDetaches() async throws {
        @MainActor final class Probe {
            var releaseFirst = false
            var releaseSecond = false
            var releasePreparation = false
            var firstResumed = false
            var secondFinished = false
            var ignoredRan = false
            var observedPreparing = false
            var errors: [String] = []
        }
        let run = NewTaskCreationRun()
        let probe = Probe()

        run.start({
            while !probe.releaseFirst, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
            }
            probe.firstResumed = true
            throw TaskWorktreeCreationError.repositoryUnavailable
        }, onError: { probe.errors.append($0.localizedDescription) })
        #expect(run.isPreparing)
        run.start({ probe.ignoredRan = true }, onError: { probe.errors.append($0.localizedDescription) })

        run.detach()
        #expect(!run.isPreparing)
        run.start({
            while !probe.releaseSecond {
                try await Task.sleep(for: .milliseconds(5))
            }
            probe.secondFinished = true
        }, onError: { probe.errors.append($0.localizedDescription) })
        try await waitUntil { probe.firstResumed }
        try await Task.sleep(for: .milliseconds(20))
        // The detached run's late failure is not shown, and its end doesn't
        // free the composer from the run that replaced it.
        #expect(probe.errors.isEmpty)
        #expect(run.isPreparing)

        probe.releaseSecond = true
        try await waitUntil { !run.isPreparing }
        #expect(probe.secondFinished)
        #expect(!probe.ignoredRan)
        #expect(probe.errors.isEmpty)

        run.start({ throw TaskWorktreeCreationError.repositoryUnavailable },
                  onError: { probe.errors.append($0.localizedDescription) })
        try await waitUntil { !run.isPreparing }
        #expect(probe.errors == [TaskWorktreeCreationError.repositoryUnavailable.localizedDescription])

        let preparation = Task { @MainActor in
            try await run.preparing {
                probe.observedPreparing = run.isPreparing
                while !probe.releasePreparation {
                    try await Task.sleep(for: .milliseconds(5))
                }
            }
        }
        try await waitUntil { probe.observedPreparing }
        run.start({ probe.ignoredRan = true }, onError: { probe.errors.append($0.localizedDescription) })
        probe.releasePreparation = true
        try await preparation.value
        #expect(!run.isPreparing)
        #expect(!probe.ignoredRan)
    }
}

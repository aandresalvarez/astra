import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// Real Git repositories in a temporary folder for worktree tests.
struct NewTaskWorktreeFixture {
    let root: URL
    let storage: URL
    let worktrees: URL

    init(parent: URL = FileManager.default.temporaryDirectory) throws {
        root = parent
            .appendingPathComponent("astra-new-task-worktree-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        storage = root.appendingPathComponent("Workspace", isDirectory: true)
        worktrees = root.appendingPathComponent("Worktrees", isDirectory: true)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
    }

    static func container() throws -> ModelContainer {
        try ModelContainer(
            for: ASTRASchema.current,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    func repository(_ name: String, committed: Bool = true, branch: String = "main") throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        _ = try git(["init", "-b", branch], at: url)
        if committed {
            let sources = url.appendingPathComponent("Sources", isDirectory: true)
            try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
            try "committed \(name)".write(
                to: sources.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8
            )
            _ = try git(["add", "Sources/file.txt"], at: url)
            _ = try git([
                "-c", "user.name=ASTRA Tests", "-c", "user.email=astra-tests@example.invalid",
                "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
                "commit", "-m", "Initial commit"
            ], at: url)
        }
        return url
    }

    /// Commits `contents` to `file` and returns the new HEAD.
    @discardableResult
    func commit(_ file: String, contents: String, message: String, at repository: URL) throws -> String {
        let url = repository.appendingPathComponent(file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try git(["add", file], at: repository)
        try git([
            "-c", "user.name=ASTRA Tests", "-c", "user.email=astra-tests@example.invalid",
            "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
            "commit", "-m", message
        ], at: repository)
        return try git(["rev-parse", "HEAD"], at: repository)
    }

    func bareRemote(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try git(["init", "--bare", "-b", "main", url.path], at: root)
        return url
    }

    func clone(_ remote: URL, as name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try git(["clone", "--quiet", remote.path, url.path], at: root)
        return url
    }

    func push(_ arguments: [String], at repository: URL) throws {
        try git(["-c", "core.hooksPath=/dev/null", "push", "--quiet"] + arguments, at: repository)
    }

    @discardableResult
    func git(_ arguments: [String], at directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = GitLocalEnvironment.scrubbing(ProcessInfo.processInfo.environment)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "NewTaskWorktreeFixture", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: output
            ])
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
@Suite("New task worktrees", .serialized)
struct NewTaskWorktreeTests {
    private typealias Fixture = NewTaskWorktreeFixture

    private func container() throws -> ModelContainer {
        try Fixture.container()
    }

    @Test("Worktree creation is opt-in and requires a selected available repository")
    func optInSelection() {
        var selection = NewTaskWorktreeSelection()
        #expect(!selection.isEnabled)
        #expect(selection.canSubmit)
        selection.isEnabled = true
        #expect(!selection.canSubmit)
        selection.updateRepositories([GitRepositoryInfo(name: "App", path: "/repos/app")], selectedPath: nil)
        #expect(selection.repositoryPath == "/repos/app")
        #expect(selection.canSubmit)
        selection.isLoading = true
        #expect(!selection.canSubmit)
        selection.isEnabled = false
        #expect(selection.canSubmit)
    }

    @Test("The repository follows the shared code location; base labels reset only when it changes")
    func selectionFollowsSharedCodeLocation() {
        let app = GitRepositoryInfo(name: "App", path: "/repos/app")
        let api = GitRepositoryInfo(name: "API", path: "/repos/api")
        var selection = NewTaskWorktreeSelection()
        selection.updateRepositories([app, api], selectedPath: api.path, checkoutPath: "/worktrees/api/feature")
        #expect(selection.repositoryPath == api.path)
        #expect(selection.checkoutPath == "/worktrees/api/feature")
        #expect(selection.request == nil)
        selection.isEnabled = true
        selection.defaultBaseLabel = "main"
        #expect(selection.request == TaskWorktreeRequest(
            repositoryPath: api.path, checkoutPath: "/worktrees/api/feature", base: .defaultBranch
        ))
        selection.updateRepositories([api, app], selectedPath: api.path)
        #expect(selection.defaultBaseLabel == "main")
        #expect(selection.checkoutPath == api.path)
        selection.base = .currentBranch
        #expect(selection.request?.base == .currentBranch)
        #expect(selection.requestPayload == TaskWorktreeRequestPayload(enabled: true, base: .currentBranch))
        selection.updateRepositories([app, api], selectedPath: app.path)
        #expect(selection.repositoryPath == app.path)
        #expect(selection.defaultBaseLabel == nil)
        // A shared location outside every repository falls back to the first one.
        selection.updateRepositories([api], selectedPath: "/elsewhere")
        #expect(selection.repositoryPath == api.path)
        #expect(selection.canSubmit)
    }

    @Test("A new workspace or composer starts with worktree creation disabled")
    func composerResetDoesNotCarryRepositoryChoice() {
        var selection = NewTaskWorktreeSelection()
        selection.updateRepositories([GitRepositoryInfo(name: "App", path: "/repos/app")], selectedPath: nil)
        selection.isEnabled = true
        selection = NewTaskWorktreeSelection()
        selection.updateRepositories([GitRepositoryInfo(name: "Other", path: "/repos/other")], selectedPath: nil)
        #expect(!selection.isEnabled)
        #expect(selection.repositoryPath == "/repos/other")
    }

    @Test("Discovery includes primary and additional Git roots, disambiguates names, and excludes other folders")
    func discoversAssociatedRepositories() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = try fixture.repository("client/App")
        let second = try fixture.repository("server/App")
        let repositories = await GitService.shared.scanForGitRepositories(
            primaryPath: first.path,
            additionalPaths: [first.path, second.path, fixture.storage.path]
        )
        #expect(repositories.map(\.path) == [first.path, second.path])
        #expect(Set(repositories.map(\.name)).count == 2)
    }

    @Test("Leaving worktrees off preserves the existing checkout without creating or persisting a task")
    func disabledDoesNotCreateWorktree() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repository = try fixture.repository("App")
        let store = try container()
        let workspace = Workspace(name: "Workspace", primaryPath: fixture.storage.path, additionalPaths: [repository.path])
        workspace.activeWorkingPath = repository.path
        let task = AgentTask(title: "Task", goal: "Update a file", workspace: workspace)

        try await TaskWorktreeService.prepare(
            task: task, request: nil, modelContext: store.mainContext, worktreesRoot: fixture.worktrees.path
        )

        #expect(task.executionRootPath == repository.path)
        #expect(task.modelContext == nil)
        #expect(task.events.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.worktrees.path))
        #expect(try fixture.git(["branch", "--show-current"], at: repository) == "main")
    }

    @Test("Only the selected repository gets a worktree; its branch and dirty files stay untouched")
    func createsSelectedRepositoryWorktree() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = try fixture.repository("First")
        let second = try fixture.repository("Second")
        let originalFile = second.appendingPathComponent("Sources/file.txt")
        try "uncommitted edits".write(to: originalFile, atomically: true, encoding: .utf8)
        _ = try fixture.git(["add", "Sources/file.txt"], at: second)
        try "untracked".write(to: second.appendingPathComponent("local.txt"), atomically: true, encoding: .utf8)
        let head = try fixture.git(["rev-parse", "HEAD"], at: second)
        let store = try container()
        let workspace = Workspace(name: "Workspace", primaryPath: fixture.storage.path, additionalPaths: [first.path, second.path])
        workspace.activeWorkingPath = first.path
        let task = AgentTask(title: "Fix login / UI", goal: "Implement login", workspace: workspace)
        store.mainContext.insert(workspace)

        try await TaskWorktreeService.prepare(
            task: task, request: TaskWorktreeRequest(repositoryPath: second.path), modelContext: store.mainContext, worktreesRoot: fixture.worktrees.path
        )

        let path = try #require(task.executionRootPath)
        let worktree = URL(fileURLWithPath: path)
        #expect(path.hasPrefix(fixture.worktrees.path + "/Second/"))
        #expect(try fixture.git(["rev-parse", "HEAD"], at: worktree) == head)
        #expect(try fixture.git(["branch", "--show-current"], at: worktree) == TaskWorktreeService.branchName(for: task))
        #expect(try fixture.git(["branch", "--show-current"], at: second) == "main")
        #expect(try String(contentsOf: worktree.appendingPathComponent("Sources/file.txt"), encoding: .utf8) == "committed Second")
        #expect(try String(contentsOf: originalFile, encoding: .utf8) == "uncommitted edits")
        #expect(!FileManager.default.fileExists(atPath: worktree.appendingPathComponent("local.txt").path))
        #expect(workspace.activeWorkingPath == first.path)
        #expect(await GitService.shared.listWorktrees(at: first.path).count == 1)
        #expect(await GitService.shared.listWorktrees(at: second.path).count == 2)
        #expect(TaskWorkspaceAccess(task: task).effectiveWorkspacePath == fixture.storage.path)
        #expect(TaskWorkspaceAccess(task: task).runtimeWritablePaths == [first.path, path])
        let prepared = try #require(task.events.first { $0.hasType(TaskEventTypes.Task.worktreePrepared) })
        #expect(prepared.typedCategory == .lifecycle)
        let payload = try prepared.decodePayload(as: TaskWorktreePayload.self).get()
        #expect(payload.worktreePath == path)
        // Without a remote the default base is the local main branch.
        #expect(payload.baseRef == "main")
        #expect(payload.baseCommit == head)
        #expect(payload.baseSource == .defaultBranch)
        #expect(payload.baseFetched == false)

        let taskID = task.id
        let reloadedContext = ModelContext(store)
        let reloaded = try #require(try reloadedContext.fetch(
            FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == taskID })
        ).first)
        #expect(reloaded.executionRootPath == path)
        #expect(reloaded.events.contains { $0.hasType(TaskEventTypes.Task.worktreePrepared) })

        let panel = WorkspaceGitViewModel()
        panel.setWorkspaceForTesting(workspace, selectedTask: task)
        await panel.scanRepositories()
        #expect(panel.rootRepoPath == second.path)
        #expect(panel.workingPath == path)
        #expect(workspace.activeWorkingPath == first.path)
    }

    @Test("Primary-repository worktrees drive prompts, provider directories, and launch grants")
    func primaryRepositoryLaunchPathsStayInWorktree() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repository = try fixture.repository("App")
        let store = try container()
        let workspace = Workspace(name: "App", primaryPath: repository.path)
        let task = AgentTask(title: "Update file", goal: "Change Sources/file.txt", workspace: workspace)
        store.mainContext.insert(workspace)
        try await TaskWorktreeService.prepare(
            task: task, request: TaskWorktreeRequest(repositoryPath: repository.path), modelContext: store.mainContext, worktreesRoot: fixture.worktrees.path
        )
        let path = try #require(task.executionRootPath)
        let access = TaskWorkspaceAccess(task: task)
        #expect(access.codeWorkingDirectory == path)
        #expect(access.runtimeWorkspacePaths == [path])
        #expect(access.runtimeWorkspaceFolders.map(\.path) == [path])
        #expect(access.taskFolder.hasPrefix(repository.path + "/.astra/tasks/"))
        let nativePaths = AgentRuntimeProcessRunner.runtimeWritablePaths(for: task)
        #expect(nativePaths.contains(path))
        #expect(nativePaths.contains(access.taskFolder))
        #expect(!nativePaths.contains(repository.path))
        let resourcePlan = TaskLaunchResourceResolver.resolve(
            task: task, runID: UUID(), runtime: .claudeCode, phase: "run",
            prompt: task.goal, contextText: "", workspacePath: path,
            gitCredentialContextProvider: { _, _, _, _ in .empty }
        )
        #expect(resourcePlan.hostWritablePaths.contains(path))
        #expect(!resourcePlan.hostWritablePaths.contains(repository.path))
        let prompt = AgentPromptBuilder.buildPrompt(for: task)
        #expect(prompt.contains("WORKING DIRECTORY: Your process is running in \(path)."))
        #expect(prompt.contains("(active code root): \(path)"))
        #expect(!prompt.contains("(active code root): \(repository.path)"))
        let followUp = AgentPromptBuilder.buildFollowUpMessage(message: "Continue", task: task)
        #expect(followUp.contains("Workspace folders:"))
        #expect(followUp.contains(path))
    }

    @Test("Source subfolders and symlink aliases map into the task checkout without changing unrelated folders")
    func projectsAdditionalPaths() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repository = try fixture.repository("App")
        let alias = fixture.root.appendingPathComponent("App-link")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: repository)
        let store = try container()
        let workspace = Workspace(
            name: "App", primaryPath: fixture.storage.path,
            additionalPaths: [repository.path, repository.appendingPathComponent("Sources").path, alias.path]
        )
        let task = AgentTask(title: "Update", goal: "Update files", workspace: workspace)
        store.mainContext.insert(workspace)
        try await TaskWorktreeService.prepare(
            task: task, request: TaskWorktreeRequest(repositoryPath: repository.path), modelContext: store.mainContext, worktreesRoot: fixture.worktrees.path
        )
        let path = try #require(task.executionRootPath)
        #expect(TaskWorkspaceAccess(task: task).runtimeWritablePaths == [path, path + "/Sources"])
        #expect(TaskWorkspaceAccess(task: task).runtimeWorkspacePaths == [fixture.storage.path, path, path + "/Sources"])
        #expect(TaskWorkspaceAccess(task: task).runtimeWorkspaceFolders.map(\.path) == [fixture.storage.path, path, path + "/Sources"])
        #expect(workspace.additionalPaths == [repository.path, repository.appendingPathComponent("Sources").path, alias.path])
    }

    @Test("Draft promotion inherits its pin and immutable request snapshots claim the new checkout")
    func draftPromotionPreservesWorktree() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repository = try fixture.repository("App")
        let other = try fixture.repository("Other")
        let store = try container()
        let context = store.mainContext
        let workspace = Workspace(name: "App", primaryPath: repository.path)
        context.insert(workspace)
        let draft = AgentTask(title: "Draft", goal: "Update files", workspace: workspace)
        try await TaskWorktreeService.prepare(
            task: draft, request: TaskWorktreeRequest(repositoryPath: repository.path), modelContext: context, worktreesRoot: fixture.worktrees.path
        )
        let path = try #require(draft.executionRootPath)
        workspace.activeWorkingPath = other.path
        let task = AgentTask(title: "Approved goal", goal: "Update files", workspace: workspace)
        try await TaskWorktreeService.prepare(
            task: task, request: nil, inheritingFrom: draft, modelContext: context, worktreesRoot: fixture.worktrees.path
        )
        context.insert(task)
        TaskStateMachine.enqueueFromChatSubmission(task, modelContext: context)
        let submission = try ExecutionRequestSubmissionService.submitInitial(for: task, into: context).get()
        let request = try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: context))
        let snapshot = try #require(TaskExecutionLaunchSnapshotApplicator.snapshot(request: request, from: task))
        let launchTask = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: task)

        #expect(task.executionRootPath == path)
        #expect(snapshot.executionRootPath == path)
        #expect(TaskWorkspaceAccess(task: launchTask).runtimeWorkspacePaths == [path])
        #expect(request.resourceClaims.filter { $0.kind == .workspace }.map(\.key) == [path])
        #expect(!TaskExecutionResourceClaimResolver.hasWorkspacePathDrift(request: request, task: launchTask))
        #expect(await GitService.shared.listWorktrees(at: repository.path).count == 2)
        #expect(workspace.activeWorkingPath == other.path)
    }

    @Test("A removed explicit worktree never falls back to the source repository")
    func missingWorktreeDoesNotFallBack() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repository = try fixture.repository("App")
        let store = try container()
        let workspace = Workspace(name: "App", primaryPath: repository.path)
        store.mainContext.insert(workspace)
        let task = AgentTask(title: "Update", goal: "Update files", workspace: workspace)
        try await TaskWorktreeService.prepare(
            task: task, request: TaskWorktreeRequest(repositoryPath: repository.path), modelContext: store.mainContext, worktreesRoot: fixture.worktrees.path
        )
        let path = try #require(task.executionRootPath)
        try await GitService.shared.removeWorktree(repoPath: repository.path, worktreePath: path)
        #expect(TaskWorkspaceAccess(task: task).codeWorkingDirectory == path)
        #expect(TaskWorkspaceAccess(task: task).runtimeWorkspacePaths.isEmpty)
        #expect(TaskWorktreeService.activeWorktreeBinding(for: task) == nil)
    }

    @Test("Invalid or removed repository choices fail before a task or worktree is persisted")
    func removedRepositoryFailsClosed() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repository = try fixture.repository("No-longer-associated")
        let store = try container()
        let task = AgentTask(title: "Update", goal: "Update", workspace: Workspace(name: "WS", primaryPath: fixture.storage.path))
        await #expect(throws: TaskWorktreeCreationError.self) {
            try await TaskWorktreeService.prepare(
                task: task, request: TaskWorktreeRequest(repositoryPath: repository.path), modelContext: store.mainContext, worktreesRoot: fixture.worktrees.path
            )
        }
        #expect(task.executionRootPath == nil)
        #expect(task.modelContext == nil)
        #expect(task.events.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.worktrees.path))
    }

    @Test("Empty repositories report the missing initial commit without starting work")
    func emptyRepositoryFailsClosed() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repository = try fixture.repository("Empty", committed: false)
        let store = try container()
        let task = AgentTask(title: "Update", goal: "Update", workspace: Workspace(name: "WS", primaryPath: repository.path))
        await #expect(throws: TaskWorktreeCreationError.self) {
            try await TaskWorktreeService.prepare(
                task: task, request: TaskWorktreeRequest(repositoryPath: repository.path), modelContext: store.mainContext, worktreesRoot: fixture.worktrees.path
            )
        }
        #expect(task.executionRootPath == nil)
        #expect(task.events.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.worktrees.path))
    }

    @Test("Git destination failures leave the original task checkout and branch unchanged")
    func destinationFailureDoesNotPinTask() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repository = try fixture.repository("App")
        try "not a directory".write(to: fixture.worktrees, atomically: true, encoding: .utf8)
        let store = try container()
        let task = AgentTask(title: "Update", goal: "Update", workspace: Workspace(name: "WS", primaryPath: repository.path))
        await #expect(throws: (any Error).self) {
            try await TaskWorktreeService.prepare(
                task: task, request: TaskWorktreeRequest(repositoryPath: repository.path), modelContext: store.mainContext, worktreesRoot: fixture.worktrees.path
            )
        }
        #expect(task.executionRootPath == nil)
        #expect(task.events.isEmpty)
        #expect(try fixture.git(["branch", "--show-current"], at: repository) == "main")
        #expect(await GitService.shared.listWorktrees(at: repository.path).count == 1)
    }

    @Test("Failed submission retains a prepared draft so retry can reuse the same checkout")
    func failedSubmissionRetainsPreparedDraft() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repository = try fixture.repository("App")
        let store = try container()
        let context = store.mainContext
        let workspace = Workspace(name: "App", primaryPath: repository.path)
        context.insert(workspace)
        let task = AgentTask(title: "Update", goal: "Update files", workspace: workspace)
        try await TaskWorktreeService.prepare(
            task: task, request: TaskWorktreeRequest(repositoryPath: repository.path), modelContext: context, worktreesRoot: fixture.worktrees.path
        )
        TaskStateMachine.enqueueFromChatSubmission(task, modelContext: context)
        let recovered = try TaskWorktreeService.recoverFailedSubmission(task: task, existingDraft: nil, modelContext: context)
        #expect(recovered === task)
        #expect(task.status == .draft)
        #expect(task.executionRootPath != nil)
        let retry = AgentTask(title: "Retry", goal: task.goal, workspace: workspace)
        try await TaskWorktreeService.prepare(task: retry, request: nil, inheritingFrom: task, modelContext: context)
        #expect(retry.executionRootPath == task.executionRootPath)
        #expect(await GitService.shared.listWorktrees(at: repository.path).count == 2)
        TaskStateMachine.enqueueFromChatSubmission(retry, modelContext: context)
        let original = try TaskWorktreeService.recoverFailedSubmission(task: retry, existingDraft: task, modelContext: context)
        #expect(original === task)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<AgentTask>()) == 1)
        #expect(task.executionRootPath != nil)
    }

    @Test("Corrupt worktree bindings do not restore writable access to original folders")
    func corruptBindingFailsClosed() {
        let workspace = Workspace(name: "App", primaryPath: "/repo", additionalPaths: ["/repo/Sources"])
        let task = AgentTask(title: "Update", goal: "Update files", workspace: workspace)
        task.executionRootPath = "/worktrees/app/task"
        task.events = [TaskEvent(task: task, eventType: TaskEventTypes.Task.worktreePrepared, payload: "invalid")]
        let access = TaskWorkspaceAccess(task: task)
        #expect(access.codeWorkingDirectory == "/worktrees/app/task")
        #expect(access.runtimeWritablePaths.isEmpty)
        #expect(access.runtimeWorkspacePaths.isEmpty)
    }

    @Test("Legacy pinned tasks keep their configured runtime folders")
    func legacyPinsKeepExistingPathBehavior() {
        let workspace = Workspace(name: "App", primaryPath: "/repo", additionalPaths: ["/docs"])
        let task = AgentTask(title: "Legacy", goal: "Update files", workspace: workspace)
        task.executionRootPath = "/worktrees/legacy"
        #expect(TaskWorkspaceAccess(task: task).runtimeWorkspacePaths == ["/repo", "/docs"])
        #expect(TaskWorkspaceAccess(task: task).runtimeWritablePaths == ["/docs"])
    }

    @Test("Cancelled task creation does not create a branch or change the pin")
    func cancelledCreationDoesNotMutateRepository() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repository = try fixture.repository("App")
        let store = try container()
        let task = AgentTask(title: "Update", goal: "Update", workspace: Workspace(name: "WS", primaryPath: repository.path))
        let operation = Task { @MainActor in
            try await TaskWorktreeService.prepare(
                task: task, request: TaskWorktreeRequest(repositoryPath: repository.path), modelContext: store.mainContext, worktreesRoot: fixture.worktrees.path
            )
        }
        operation.cancel()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(task.executionRootPath == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.worktrees.path))
    }

    @Test("Generated branch names are safe and unique even for identical or non-ASCII task titles")
    func branchNamesAreSafeAndUnique() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repository = try fixture.repository("App")
        let first = AgentTask(title: "../ fix: login? [UI] / @main", goal: "Update")
        let second = AgentTask(title: first.title, goal: first.goal)
        #expect(TaskWorktreeService.branchName(for: first) != TaskWorktreeService.branchName(for: second))
        #expect(TaskWorktreeService.branchName(for: first).hasPrefix("astra/fix-login-ui-main-"))
        for title in ["", "???", "\u{1F680}", String(repeating: "very long task ", count: 30)] {
            let task = AgentTask(title: title, goal: "Update")
            let branch = TaskWorktreeService.branchName(for: task)
            #expect(!branch.contains(".."))
            #expect(try fixture.git(["check-ref-format", "--branch", branch], at: repository) == branch)
        }
    }
}

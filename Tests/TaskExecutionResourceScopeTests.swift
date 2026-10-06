import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Accepted execution resource scope")
@MainActor
struct TaskExecutionResourceScopeTests {
    private let runtimes: [AgentRuntimeID] = [
        .claudeCode, .copilotCLI, .codexCLI, .cursorCLI, .antigravityCLI, .openCodeCLI
    ]

    @Test("Accepted input files are rejected when replaced by directories")
    func acceptedInputFileReplacedByDirectoryIsInvalid() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-scope-kind-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("input.txt")
        try Data("x".utf8).write(to: input)
        let scope = TaskExecutionResourceScope(
            workingDirectory: "", workspacePath: "",
            resources: [.init(path: input.path, access: .shared, role: .input)])
        #expect(scope.isValid)
        try FileManager.default.removeItem(at: input)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        #expect(!scope.isValid)
    }

    @Test("All provider pairs admit independent worktrees without granting the source checkout")
    func providerPairs() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for firstRuntime in runtimes {
            for secondRuntime in runtimes {
                let first = fixture.task(root: fixture.first, runtime: firstRuntime)
                let second = fixture.task(root: fixture.second, runtime: secondRuntime)
                let firstScope = TaskExecutionResourceScopeResolver.resolve(task: first)
                let secondScope = TaskExecutionResourceScopeResolver.resolve(task: second)
                #expect(!conflicts(first, firstScope, second, secondScope))
                for (task, scope, runtime) in [(first, firstScope, firstRuntime), (second, secondScope, secondRuntime)] {
                    task.acceptedResourceScope = scope
                    let plan = launch(task, runtime: runtime, home: fixture.root)
                    #expect(scope.isValid)
                    #expect(scope.replacedCheckoutPaths == [fixture.repository.path])
                    #expect(!plan.hostWritablePaths.contains(fixture.repository.path))
                    #expect(!plan.hostWritablePaths.contains(fixture.workspace.primaryPath))
                    #expect(plan.hostWritablePaths.allSatisfy { scope.coversWrite(to: $0) })
                    #expect(plan.diagnostics.allSatisfy { $0.severity != .error })
                    #expect(!AgentRuntimeProcessRunner.runtimeWritablePaths(for: task).contains(fixture.repository.path))
                    #expect(!AgentRuntimeProcessRunner.copilotNativeDirectoryProjection(for: task)
                        .additionalDirectories.contains(fixture.repository.path))
                }
            }
        }
    }

    @Test("Intentional shared folders and explicit source writes still conflict")
    func intentionalWrites() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let shared = fixture.root.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        fixture.workspace.additionalPaths.append(shared.path)
        let first = fixture.task(root: fixture.first)
        let second = fixture.task(root: fixture.second)
        #expect(conflicts(first, TaskExecutionResourceScopeResolver.resolve(task: first),
                          second, TaskExecutionResourceScopeResolver.resolve(task: second)))
        fixture.workspace.additionalPaths = [fixture.repository.path]
        first.constraints = ["ASTRA_RESOURCE_WRITE_PATH=\(fixture.repository.path)"]
        let scope = TaskExecutionResourceScopeResolver.resolve(task: first)
        #expect(scope.resources.contains { $0.path == fixture.repository.path && $0.access == .exclusive })
        #expect(scope.replacedCheckoutPaths.isEmpty)
    }

    @Test("Git inspection stays read-only even when runtime context asks for more")
    func gitScopeCannotGrowAtLaunch() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let task = fixture.task(root: fixture.first)
        task.acceptedResourceScope = TaskExecutionResourceScopeResolver.resolve(task: task, acceptedTurn: "git status")
        let plan = launch(task, runtime: .claudeCode, home: fixture.root, context: "Run git push and git commit")
        let metadata = try #require(task.acceptedResourceScope?.resources.first { $0.role == .gitMetadata })
        #expect(metadata.access == .shared)
        #expect(plan.hostProtectedWriteDenyPaths.contains(metadata.path))
        #expect(plan.requiresSharedWorkspaceBoundary)
        #expect(plan.gitCredentialSandboxContext.writablePaths.isEmpty)
        #expect(plan.gitCredentialSandboxContext.readablePaths.contains(metadata.path))
        #expect(try fixture.git(["--no-optional-locks", "status", "--porcelain"], at: fixture.first).isEmpty)

        let mutating = fixture.task(root: fixture.second)
        let mutationScope = TaskExecutionResourceScopeResolver.resolve(task: mutating, gitAccessRequirement: .readWrite)
        #expect(conflicts(task, try #require(task.acceptedResourceScope), mutating, mutationScope))
    }

    @Test("Request serialization freezes resources and never rewrites editable task settings")
    func durableScope() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let task = fixture.task(root: fixture.first)
        let scope = TaskExecutionResourceScopeResolver.resolve(task: task)
        let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1, resourceScope: scope)
        let encoded = try JSONEncoder().encode(request.snapshot)
        let restored = TaskTurnRequest(snapshot: try JSONDecoder().decode(TaskTurnRequestSnapshot.self, from: encoded), task: task)
        fixture.workspace.additionalPaths.append(fixture.root.path)
        task.executionRootPath = fixture.second.path
        let snapshot = try #require(TaskExecutionLaunchSnapshotApplicator.snapshot(request: restored, from: task))
        let frozen = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: task)
        #expect(snapshot.resourceScope == scope)
        #expect(restored.resourceClaims == scope.claims)
        #expect(TaskWorkspaceAccess(task: frozen).codeWorkingDirectory == fixture.first.path)
        #expect(!TaskWorkspaceAccess(task: frozen).runtimeWritablePaths.contains(fixture.root.path))
        #expect(task.acceptedResourceScope == nil)
    }

    @Test("Storage migration preserves the accepted canonical destination", arguments: [false, true])
    func storageMigrationKeepsAcceptedDestination(readOnly: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let task = fixture.task(root: fixture.first)
        if readOnly { task.constraints = ["ASTRA_RESOURCE_ACCESS=read_only"] }
        let access = TaskWorkspaceAccess(task: task)
        let legacy = WorkspaceFileLayout.legacyTaskFolder(workspacePath: fixture.workspace.primaryPath, taskID: task.id)
        try FileManager.default.createDirectory(atPath: legacy, withIntermediateDirectories: true)
        try "retained".write(toFile: legacy + "/state.txt", atomically: true, encoding: .utf8)
        let scope = TaskExecutionResourceScopeResolver.resolve(task: task)
        let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1, resourceScope: scope)
        task.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encodeSnapshot(
            WorkspaceExecutionEnvironment(id: "legacy-mounts", kind: .dockerImage, displayName: "Legacy", image: "test:latest",
                mounts: [
                    .init(hostPath: legacy, containerPath: "/astra/task", access: .readWrite, role: .taskFolder),
                    .init(hostPath: fixture.repository.path, containerPath: "/workspace", access: .readWrite, role: .workspace)
                ]))
        let normalized = TaskExecutionResourceScopeResolver.resolve(task: task)
        #expect(normalized.executionEnvironment.mounts.first { $0.role == .taskFolder }?.hostPath == access.canonicalTaskFolder)
        #expect(normalized.executionEnvironment.mounts.first { $0.role == .workspace }?.hostPath == fixture.first.path)
        #expect(!normalized.resources.contains { $0.path == legacy })
        #expect(normalized.coversWrite(to: access.canonicalTaskFolder))
        _ = try TaskExecutionResourcePreparation.ensureTaskFolder(task: task)
        let snapshot = try #require(TaskExecutionLaunchSnapshotApplicator.snapshot(request: request, from: task))
        let frozen = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: task)
        #expect(TaskWorkspaceAccess(task: frozen).taskFolder == access.canonicalTaskFolder)
        #expect(try String(contentsOfFile: access.canonicalTaskFolder + "/state.txt") == "retained")
        #expect(!FileManager.default.fileExists(atPath: legacy))
        #expect(AgentRuntimeProcessRunner.runtimeWritablePaths(for: frozen).allSatisfy { scope.coversWrite(to: $0) })
        #expect(launch(frozen, runtime: .claudeCode, home: fixture.root).diagnostics.allSatisfy { $0.severity != .error })
    }

    @Test("Prompt inputs cannot be replaced or promoted after admission")
    func frozenPromptInputs() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let task = fixture.task(root: fixture.first)
        let accepted = fixture.root.appendingPathComponent("accepted.txt")
        let late = fixture.root.appendingPathComponent("late.txt")
        let injected = fixture.root.appendingPathComponent("injected.txt")
        try "accepted-content".write(to: accepted, atomically: true, encoding: .utf8)
        task.inputs = ["Keep this prose", accepted.path, late.path]
        let scope = TaskExecutionResourceScopeResolver.resolve(task: task, attachmentPaths: [late.path])
        let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1, resourceScope: scope)
        try "late-content".write(to: late, atomically: true, encoding: .utf8)
        try "injected-content".write(to: injected, atomically: true, encoding: .utf8)
        task.inputs = [injected.path]
        let snapshot = try #require(TaskExecutionLaunchSnapshotApplicator.snapshot(request: request, from: task))
        let frozen = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: task)
        let context = AgentPromptBuilder.buildPrompt(for: frozen)
        #expect(frozen.inputs == ["Keep this prose", accepted.path, late.path])
        #expect(context.contains("Keep this prose"))
        #expect(context.contains("accepted-content"))
        #expect(context.contains("Input unavailable"))
        #expect(!context.contains("late-content"))
        #expect(!context.contains("injected-content"))
        #expect(!scope.coversRead(to: injected.path))
        #expect(!scope.coversRead(to: late.path))
    }

    @Test("Inherited environments freeze and unknown read-only mounts fail admission validation")
    func frozenEnvironmentAndMounts() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let task = fixture.task(root: fixture.first)
        let original = WorkspaceExecutionEnvironment(id: "accepted", kind: .dockerImage,
            displayName: "Accepted", image: "test:accepted")
        fixture.workspace.activeExecutionEnvironmentJSON = ExecutionEnvironmentStore.encodeSnapshot(original)
        task.executionEnvironmentSnapshotJSON = nil
        let scope = TaskExecutionResourceScopeResolver.resolve(task: task)
        let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 1, resourceScope: scope)
        let unaccepted = fixture.root.appendingPathComponent("private")
        try FileManager.default.createDirectory(at: unaccepted, withIntermediateDirectories: true)
        var changed = original
        changed.mounts = [.init(hostPath: unaccepted.path, containerPath: "/private", access: .readOnly, role: .additionalPath)]
        fixture.workspace.activeExecutionEnvironmentJSON = ExecutionEnvironmentStore.encodeSnapshot(changed)
        let snapshot = try #require(TaskExecutionLaunchSnapshotApplicator.snapshot(request: request, from: task))
        let frozen = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: task)
        #expect(DockerExecutionPlanner.resolveEnvironment(for: frozen) == original)
        let mounts = DockerExecutionPlanner.mountPlan(currentDirectory: fixture.first.path, environment: changed, task: frozen)
        #expect(!mounts.contains { $0.hostPath == unaccepted.path })
        let plan = TaskLaunchResourceResolver.resolve(task: frozen, runID: nil, runtime: .claudeCode,
            phase: "run", prompt: task.goal, contextText: "", workspacePath: fixture.first.path,
            executionEnvironment: changed, homeDirectoryPath: fixture.root.path,
            gitCredentialContextProvider: { _, _, _, _ in .empty })
        #expect(plan.diagnostics.contains { $0.code == "execution_resource_scope_expansion" && $0.severity == .error })
    }

    @Test("Submission materializes ephemeral inputs before freezing the request")
    func submissionMaterializesBeforeFreezing() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("astra_paste_\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try "pasted-content".write(to: temporary, atomically: true, encoding: .utf8)
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let task = fixture.task(root: fixture.first)
        task.inputs = [temporary.path, "preserved prose"]
        context.insert(fixture.workspace)
        context.insert(task)
        let submission = try ExecutionRequestSubmissionService.submitInitial(for: task, into: context).get()
        let request = try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: context))
        let scope = try #require(request.executionPolicySnapshot?.resourceScope)
        let input = try #require(scope.promptInputs.first { $0.kind == .path })
        #expect(input.value != temporary.path)
        #expect(input.value.hasPrefix(TaskWorkspaceAccess(task: task).canonicalTaskFolder + "/inputs/"))
        #expect(try String(contentsOfFile: input.value) == "pasted-content")
        #expect(!scope.resources.contains { $0.path == temporary.path })
        #expect(scope.coversRead(to: input.value))
        #expect(!scope.coversWrite(to: input.value))
        #expect(scope.promptInputs.contains { $0.value == "preserved prose" && $0.kind == .text })
    }

    @Test("Git requirements are explicit and independent of prose or negation")
    func gitRequirements() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let task = fixture.task(root: fixture.first)
        for instruction in ["commit your changes", "commit this change", "make a commit", "git -C '/tmp/a b' commit -m done",
                            "Git push origin main", "GIT COMMIT -m done", "GH PR CHECKOUT 1", "Git branch -D obsolete",
                            "Do not amend existing commits. git commit the changes",
                            "Never git push! Git commit -m done",
                            "Do not git push, but commit your changes",
                            "git commit the changes without git push",
                            "git commit the changes. Do not git push",
                            "Avoid git reset; then git -C '/tmp/a.b' commit -m done",
                            "Without delay, git commit the changes", "Without further changes, git push"] {
            #expect(TaskExecutionResourceScopeResolver.resolve(task: task, acceptedTurn: instruction).gitAccess == .readOnly)
            let scope = TaskExecutionResourceScopeResolver.resolve(task: task, acceptedTurn: instruction, gitAccessRequirement: .readWrite)
            #expect(scope.gitAccess == .readWrite)
            #expect(scope.resources.contains { $0.role == .gitMetadata && $0.access == .exclusive })
        }
        for instruction in ["git branch --show-current", "git config --get user.name", "git worktree list", "git tag --list", "do not commit your changes",
                            "Git branch -a", "GIT config --get user.name", "Git -C '/tmp/a b' status", "DO NOT GIT COMMIT -m done",
                            "Do not git commit. Never git push.", "Avoid git commit; git status",
                            "Do not git commit or git push", "Do not git push, but git status"] {
            #expect(TaskExecutionResourceScopeResolver.resolve(task: task, acceptedTurn: instruction).gitAccess == .readOnly)
        }
        task.constraints = ["ASTRA_GIT_ACCESS=read_only"]
        #expect(TaskExecutionResourceScopeResolver.resolve(task: task, acceptedTurn: "commit your changes").gitAccess == .readOnly)
        task.constraints = ["ASTRA_GIT_ACCESS=read_write"]
        #expect(TaskExecutionResourceScopeResolver.resolve(task: task, acceptedTurn: "proceed").gitAccess == .readWrite)
        task.constraints = ["ASTRA_GIT_ACCESS=typo"]
        #expect(!TaskExecutionResourceScopeResolver.resolve(task: task).isValid)
    }

    @Test("Scoped follow-up prompts include folder guidance once", arguments: [false, true])
    func followUpScopeGuidanceOnce(nativeContinuation: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let task = fixture.task(root: fixture.first)
        task.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encodeSnapshot(
            .init(id: "container", kind: .dockerImage, displayName: "Accepted container", image: "test:latest"))
        task.acceptedResourceScope = TaskExecutionResourceScopeResolver.resolve(task: task)
        let prompt = AgentPromptBuilder.buildFreshFollowUpPrompt(message: "Continue the work", task: task,
            usesNativeContinuation: nativeContinuation)
        #expect(prompt.components(separatedBy: "Accepted execution folders:").count == 2)
        #expect(prompt.contains("Execution Environment: Accepted container"))
        #expect(prompt.contains("Container working directory:"))
        #expect(prompt.contains("Continue the work"))
        #expect(!AgentPromptBuilder.buildFollowUpMessage(message: "Continue", task: task).contains("Accepted execution folders:"))
    }

    @Test("Copied linked worktrees reject admitted Git writes instead of promising unavailable access")
    func copiedLinkedGitWritesRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let task = fixture.task(root: fixture.first)
        task.isolationStrategy = .copy
        context.insert(fixture.workspace)
        context.insert(task)
        for instruction in ["commit your changes", "GIT COMMIT -m done"] {
            #expect(TaskExecutionResourceScopeResolver.resolve(task: task, acceptedTurn: instruction, gitAccessRequirement: .readWrite).gitAccess == .invalid)
        }
        task.constraints = ["ASTRA_GIT_ACCESS=read_write"]
        guard case .failure(.persistenceFailed(let message)) = ExecutionRequestSubmissionService.submitInitial(
            for: task, into: context) else { Issue.record("Copied linked Git writes were admitted"); return }
        #expect(message.contains("copied linked worktrees"))
        #expect(try TaskTurnRequestRepository.requests(for: task, in: context).isEmpty)
        task.constraints = []
        task.validationStrategy = .runTests
        #expect(!TaskExecutionResourceScopeResolver.resolve(task: task).isValid)
        task.validationStrategy = .manual
        #expect(TaskExecutionResourceScopeResolver.resolve(task: task).isValid)
        task.executionRootPath = fixture.repository.path
        task.constraints = ["ASTRA_GIT_ACCESS=read_write"]
        #expect(TaskExecutionResourceScopeResolver.resolve(task: task).gitAccess == .readWrite)
    }

    @Test("Legacy submission settles the workspace environment before freezing it")
    func legacyEnvironmentSettlement() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = container.mainContext
        context.insert(fixture.workspace)
        let environment = WorkspaceExecutionEnvironment(id: "legacy", kind: .dockerImage,
            displayName: "Legacy", image: "test:legacy")
        fixture.workspace.activeExecutionEnvironmentJSON = ExecutionEnvironmentStore.encodeSnapshot(environment)
        for state in [TaskStatus.queued, .completed] {
            let task = fixture.task(root: fixture.first)
            task.status = state
            task.executionEnvironmentSnapshotJSON = nil
            context.insert(task)
            let submission = try ExecutionRequestSubmissionService.submitRetry(
                message: "Retry", continuation: false, for: task, into: context).get()
            let request = try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: context))
            #expect(request.executionPolicySnapshot?.resourceScope?.executionEnvironment == environment)
            let snapshot = try #require(TaskExecutionLaunchSnapshotApplicator.snapshot(request: request, from: task))
            fixture.workspace.activeExecutionEnvironmentJSON = ExecutionEnvironmentStore.encodeSnapshot(.host)
            let frozen = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: task)
            #expect(DockerExecutionPlanner.resolveEnvironment(for: frozen) == environment)
            fixture.workspace.activeExecutionEnvironmentJSON = ExecutionEnvironmentStore.encodeSnapshot(environment)
        }
        let pinned = fixture.task(root: fixture.first)
        pinned.status = .completed
        pinned.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encodeSnapshot(.host)
        #expect(TaskExecutionResourceScopeResolver.resolve(task: pinned).executionEnvironment == .host)
    }

    @Test("Readers retain task output writes without gaining execution-root writes")
    func readerOutputs() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let task = fixture.task(root: fixture.first)
        task.constraints = ["ASTRA_RESOURCE_ACCESS=read_only"]
        task.acceptedResourceScope = TaskExecutionResourceScopeResolver.resolve(task: task)
        let plan = launch(task, runtime: .codexCLI, home: fixture.root)
        #expect(plan.workspaceAccess == .shared)
        #expect(!plan.hostWritablePaths.contains(fixture.first.path))
        #expect(plan.hostWritablePaths.contains(TaskWorkspaceAccess(task: task).taskFolder))
        #expect(plan.requiresSharedWorkspaceBoundary)
    }

    @Test("Approved plans capture typed Git requirements from the selected step or the full plan",
          arguments: [TaskPlanPayloadStepStatus.pending, .running, .blocked, .done, .skipped])
    func approvedPlanGitIntent(firstStatus: TaskPlanPayloadStepStatus) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = container.mainContext
        context.insert(fixture.workspace)
        let plan = TaskPlanPayload(title: "Update parser", goal: "Improve parsing", steps: [
            .init(id: "inspect", title: "Inspect", detail: "git status", status: firstStatus),
            .init(id: "commit", title: "Save work", detail: "git commit -am 'Fix parser'", gitAccessRequirement: .readWrite)
        ])
        for mode in [TaskPlanExecutionMode.nextStep, .fullPlan] {
            let task = fixture.task(root: fixture.first)
            context.insert(task)
            let submission = try ExecutionRequestSubmissionService.submitPlan(plan: plan, mode: mode,
                mutation: .existingTask, for: task, into: context).get()
            let request = try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: context))
            let scope = try #require(request.executionPolicySnapshot?.resourceScope)
            let writes = mode == .fullPlan || firstStatus == .done || firstStatus == .skipped
            #expect(scope.gitAccess == (writes ? .readWrite : .readOnly))
            #expect(scope.resources.filter { $0.role == .gitMetadata }.allSatisfy {
                $0.access == (writes ? .exclusive : .shared)
            })
            var edited = plan
            edited.steps = [.init(id: "different", title: "git push")]
            TaskPlanService.recordApproved(edited, task: task, modelContext: context)
            #expect(request.executionPolicySnapshot?.resourceScope == scope)
            let source = try #require(task.events.first { $0.id == request.sourceEventID })
            #expect(ExecutionRequestSubmissionService.decodeSourcePayload(source)?.planSnapshot == plan)
        }
        let task = fixture.task(root: fixture.first)
        task.constraints = ["ASTRA_GIT_ACCESS=read_only"]
        context.insert(task)
        guard case .failure = ExecutionRequestSubmissionService.submitPlan(plan: plan, mode: .fullPlan,
            mutation: .existingTask, for: task, into: context) else {
            Issue.record("A plan requiring Git writes overrode an explicit read-only constraint")
            return
        }
    }

    @Test("Copilot exposes accepted read-only folders without widening file or write grants")
    func copilotSharedDirectories() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let shared = fixture.root.appendingPathComponent("shared")
        let files = fixture.root.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let input = files.appendingPathComponent("input.txt")
        try "input".write(to: input, atomically: true, encoding: .utf8)
        fixture.workspace.additionalPaths.append(shared.path)
        let task = fixture.task(root: fixture.first, runtime: .copilotCLI)
        task.constraints = ["ASTRA_RESOURCE_ACCESS=read_only"]
        task.inputs = [input.path]
        let scope = TaskExecutionResourceScopeResolver.resolve(task: task)
        task.acceptedResourceScope = scope
        let projection = AgentRuntimeProcessRunner.copilotNativeDirectoryProjection(for: task)
        #expect(projection.additionalDirectories.contains(shared.path))
        #expect(!projection.additionalDirectories.contains(fixture.repository.path))
        #expect(!projection.additionalDirectories.contains(input.path))
        #expect(!projection.additionalDirectories.contains(files.path))
        #expect(projection.unreachableFiles == [input.path])
        #expect(!AgentRuntimeProcessRunner.runtimeWritablePaths(for: task).contains(shared.path))
        #expect(scope.coversRead(to: shared.path))
        #expect(!scope.coversWrite(to: shared.path))
        let capabilities = CopilotCLICapabilities(helpText: "--output-format=FORMAT --no-ask-user")
        let command = CopilotCLIRuntime.buildCommand(executablePath: "/bin/copilot", prompt: "Read the shared folder",
            model: "gpt-5.6-sol", workspacePath: fixture.first.path,
            additionalPaths: projection.additionalDirectories, permissionPolicy: .restricted,
            allowedTools: [], timeoutSeconds: 60, capabilities: capabilities, taskEnvironment: [:],
            copilotHome: fixture.root.path,
            permissionArguments: ProviderPolicyRender.copilotLaunchPermissionArguments(policy: .restricted,
                allowedTools: [], capabilities: capabilities, localToolCommands: [], runtimeSupportTools: [],
                allowAllPathsForSSHConnections: false))
        let directories = command.arguments.indices.filter { command.arguments[$0] == "--add-dir" }
            .map { command.arguments[$0 + 1] }
        #expect(directories.contains(shared.path))
        #expect(!command.arguments.contains("--allow-all-paths"))
        let resources = launch(task, runtime: .copilotCLI, home: fixture.root)
        #expect(resources.requiresSharedWorkspaceBoundary)
        try "readable".write(to: shared.appendingPathComponent("content.txt"), atomically: true, encoding: .utf8)
        let probe = AgentRuntimeProcessLaunchPlan(runtime: .copilotCLI, executablePath: "/bin/sh",
            arguments: ["-c", """
                /bin/cat "$1/content.txt" >/dev/null || exit 11
                if /usr/bin/touch "$1/forbidden" 2>/dev/null; then exit 12; fi
                """, "copilot-reader", shared.path],
            currentDirectory: fixture.first.path, environment: ProcessInfo.processInfo.environment,
            browserShimDirectory: nil, providerVersion: nil, parsesJSONLines: false)
        let decision = ExecutionSandbox.decide(plan: probe, providerHomeDirectory: fixture.root.path,
            additionalWritablePaths: resources.hostWritablePaths, additionalReadablePaths: resources.hostReadablePaths,
            workspaceWritable: false, resourceScope: scope,
            settings: .init(enforcement: .strict, wrappedRuntimes: [.copilotCLI], allowNetwork: false))
        guard case .applied(let sandboxed, _) = decision else {
            Issue.record("Expected a confined Copilot reader, got \(decision)")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sandboxed.executablePath)
        process.arguments = sandboxed.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: sandboxed.currentDirectory)
        process.environment = sandboxed.environment
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(!FileManager.default.fileExists(atPath: shared.appendingPathComponent("forbidden").path))
    }

    @Test("Workspace readers share while task storage remains isolated from writers")
    func sharedReadersWithStorage() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.workspace.additionalPaths = []
        let root = URL(fileURLWithPath: fixture.workspace.primaryPath)
        let first = fixture.task(root: root)
        let second = fixture.task(root: root)
        first.constraints = ["ASTRA_RESOURCE_ACCESS=read_only"]
        second.constraints = first.constraints
        let left = TaskExecutionResourceScopeResolver.resolve(task: first)
        let right = TaskExecutionResourceScopeResolver.resolve(task: second)
        #expect(!conflicts(first, left, second, right))
        #expect(left.coversWrite(to: TaskWorkspaceAccess(task: first).taskFolder))
        #expect(!left.coversWrite(to: TaskWorkspaceAccess(task: second).taskFolder))
        second.constraints = []
        #expect(conflicts(first, left, second, TaskExecutionResourceScopeResolver.resolve(task: second)))
    }

    @Test("Docker mounts preserve custom write claims and overlay read-only Git metadata")
    func dockerScope() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let task = fixture.task(root: fixture.repository)
        let custom = fixture.root.appendingPathComponent("custom")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        let environment = WorkspaceExecutionEnvironment(
            id: "scope-image", kind: .dockerImage, displayName: "Scope", image: "test:latest",
            mounts: [.init(hostPath: custom.path, containerPath: "/custom", access: .readWrite, role: .additionalPath)])
        task.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encodeSnapshot(environment)
        let scope = TaskExecutionResourceScopeResolver.resolve(task: task)
        task.acceptedResourceScope = scope
        let mounts = DockerExecutionPlanner.mountPlan(currentDirectory: fixture.repository.path,
            environment: environment, task: task)
        #expect(scope.claims.contains { $0.key == custom.path && $0.access == .exclusive })
        #expect(mounts.contains { $0.hostPath == custom.path && $0.access == .readWrite })
        let gitPath = fixture.repository.appendingPathComponent(".git").path
        #expect(mounts.contains {
            $0.hostPath == gitPath && $0.containerPath == environment.containerWorkingDirectory + "/.git"
                && $0.access == .readOnly
        })
        #expect(mounts.filter { $0.access == .readWrite }.allSatisfy { scope.coversWrite(to: $0.hostPath) })
    }

    @Test("Linked worktree pointers follow accepted Git access in scope and Docker", arguments: [false, true])
    func linkedWorktreePointerScope(writableGit: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let nested = fixture.first.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let pointer = fixture.first.appendingPathComponent(".git").path
        for root in [fixture.first, nested] {
            let task = fixture.task(root: root)
            task.constraints = ["ASTRA_GIT_ACCESS=\(writableGit ? "read_write" : "read_only")"]
            let environment = WorkspaceExecutionEnvironment(
                id: "pointer", kind: .dockerImage, displayName: "Pointer", image: "test:latest")
            task.executionEnvironmentSnapshotJSON = ExecutionEnvironmentStore.encodeSnapshot(environment)
            let scope = TaskExecutionResourceScopeResolver.resolve(task: task)
            task.acceptedResourceScope = scope
            #expect(scope.resources.contains {
                $0.path == pointer && $0.role == .gitMetadata
                    && $0.access == (writableGit ? .exclusive : .shared)
            })
            #expect(scope.coversWrite(to: pointer) == writableGit)
            let mounts = DockerExecutionPlanner.mountPlan(currentDirectory: root.path, environment: environment, task: task)
            #expect(mounts.contains {
                $0.hostPath == pointer && $0.access == (writableGit ? .readWrite : .readOnly)
            })
            if !writableGit, root == fixture.first {
                #expect(mounts.contains {
                    $0.hostPath == pointer && $0.containerPath == environment.containerWorkingDirectory + "/.git"
                        && $0.access == .readOnly
                })
            }
        }
        let copy = fixture.task(root: fixture.first)
        copy.isolationStrategy = .copy
        let scope = TaskExecutionResourceScopeResolver.resolve(task: copy)
        #expect(scope.resources.contains {
            $0.path == scope.workingDirectory + "/.git" && $0.role == .gitMetadata && $0.access == .shared
        })
        #expect(!scope.coversWrite(to: scope.workingDirectory + "/.git"))
    }

    @Test("Scopes accepted before pointer protection require resubmission")
    func legacyPointerScopeRequiresResubmission() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let task = fixture.task(root: fixture.first)
        let scope = TaskExecutionResourceScopeResolver.resolve(task: task)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(scope)) as? [String: Any])
        json["version"] = 2
        let legacy = try JSONDecoder().decode(TaskExecutionResourceScope.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!legacy.isValid)
        task.acceptedResourceScope = legacy
        #expect(launch(task, runtime: .claudeCode, home: fixture.root).diagnostics.contains {
            $0.code == "execution_resource_scope_invalid" && $0.severity == .error
        })
    }

    @Test("An accepted symlink identity cannot silently move to another folder")
    func symlinkDrift() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let alias = fixture.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.first)
        let task = fixture.task(root: alias)
        let scope = TaskExecutionResourceScopeResolver.resolve(task: task)
        #expect(scope.isValid)
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.second)
        #expect(!scope.isValid)
    }

    @Test("Replacing a checkout alias freezes the original source identity")
    func replacedCheckoutIdentity() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let alias = fixture.root.appendingPathComponent("source-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.repository)
        fixture.workspace.additionalPaths = [alias.path]
        let scope = TaskExecutionResourceScopeResolver.resolve(task: fixture.task(root: fixture.first))
        #expect(scope.replacedCheckoutPaths == [fixture.repository.path])
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.second)
        #expect(scope.isValid)
        #expect(scope.replacedCheckoutPaths == [fixture.repository.path])
    }

    @Test("The enforced inspection boundary allows edits but denies shared Git writes")
    func enforcedGitInspection() throws {
        let fixture = try Fixture(base: TestRepositoryRoot.resolve().appendingPathComponent(".build"))
        defer { fixture.remove() }
        let task = fixture.task(root: fixture.first)
        let pointer = fixture.first.appendingPathComponent(".git")
        let originalPointer = try String(contentsOf: pointer, encoding: .utf8)
        task.acceptedResourceScope = TaskExecutionResourceScopeResolver.resolve(task: task)
        let resourcePlan = launch(task, runtime: .claudeCode, home: fixture.root)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["HOME"] = fixture.root.path
        let processPlan = AgentRuntimeProcessLaunchPlan(
            runtime: .claudeCode, executablePath: "/bin/sh",
            arguments: ["-c", """
                /usr/bin/git --no-optional-locks status --porcelain >/dev/null || exit 11
                /usr/bin/touch scope-edit || exit 12
                if /usr/bin/git update-ref refs/heads/unadmitted HEAD 2>/dev/null; then exit 13; fi
                if /usr/bin/touch "$1/escaped" 2>/dev/null; then exit 14; fi
                if (printf 'gitdir: /tmp/redirected\\n' > "$2") 2>/dev/null; then exit 15; fi
                if /bin/rm "$2" 2>/dev/null; then exit 16; fi
                printf 'replacement\\n' > replacement-pointer || exit 17
                if /bin/mv -f replacement-pointer "$2" 2>/dev/null; then exit 18; fi
                /usr/bin/git --no-optional-locks status --porcelain >/dev/null || exit 19
                """, "scope-test", fixture.repository.path, pointer.path],
            currentDirectory: fixture.first.path, environment: environment,
            browserShimDirectory: nil, providerVersion: nil, parsesJSONLines: false,
            sandboxReadablePaths: resourcePlan.hostReadablePaths,
            sandboxProtectedWriteDenyPaths: resourcePlan.hostProtectedWriteDenyPaths)
        let decision = ExecutionSandbox.decide(plan: processPlan, providerHomeDirectory: fixture.root.path,
            additionalWritablePaths: resourcePlan.hostWritablePaths,
            additionalReadablePaths: resourcePlan.hostReadablePaths,
            resourceScope: resourcePlan.resourceScope,
            settings: ExecutionSandboxSettings(enforcement: .strict, wrappedRuntimes: [.claudeCode], allowNetwork: false))
        guard case .applied(let sandboxed, _) = decision else {
            Issue.record("Expected an enforced scope, got \(decision)")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sandboxed.executablePath)
        process.arguments = sandboxed.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: sandboxed.currentDirectory)
        process.environment = sandboxed.environment
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(try String(contentsOf: pointer, encoding: .utf8) == originalPointer)
        #expect(FileManager.default.fileExists(atPath: fixture.first.appendingPathComponent("scope-edit").path))
    }

    @Test("Read-only execution denies ambient temporary writes but permits owned output")
    func enforcedReaderOutput() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.workspace.additionalPaths = []
        let task = fixture.task(root: URL(fileURLWithPath: fixture.workspace.primaryPath))
        task.constraints = ["ASTRA_RESOURCE_ACCESS=read_only"]
        task.acceptedResourceScope = TaskExecutionResourceScopeResolver.resolve(task: task)
        let output = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        let resources = launch(task, runtime: .claudeCode, home: fixture.root)
        let plan = AgentRuntimeProcessLaunchPlan(runtime: .claudeCode, executablePath: "/bin/sh",
            arguments: ["-c", """
                /usr/bin/touch "$1/allowed" || exit 11
                if /usr/bin/touch forbidden 2>/dev/null; then exit 12; fi
                """, "scope-reader", output],
            currentDirectory: fixture.workspace.primaryPath, environment: ProcessInfo.processInfo.environment,
            browserShimDirectory: nil, providerVersion: nil, parsesJSONLines: false)
        let decision = ExecutionSandbox.decide(plan: plan, providerHomeDirectory: fixture.root.path,
            additionalWritablePaths: resources.hostWritablePaths, additionalReadablePaths: resources.hostReadablePaths,
            workspaceWritable: false, resourceScope: resources.resourceScope,
            settings: ExecutionSandboxSettings(enforcement: .strict, wrappedRuntimes: [.claudeCode], allowNetwork: false))
        guard case .applied(let sandboxed, _) = decision else {
            Issue.record("Expected a confined reader, got \(decision)")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sandboxed.executablePath)
        process.arguments = sandboxed.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: sandboxed.currentDirectory)
        process.environment = sandboxed.environment
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(FileManager.default.fileExists(atPath: output + "/allowed"))
        #expect(!FileManager.default.fileExists(atPath: fixture.workspace.primaryPath + "/forbidden"))
        let receipt = try #require(sandboxed.executionSandboxBoundaryReceipt)
        #expect(!receipt.explains(.init(operation: .write, path: output + "/allowed", detail: "POSIX denial")))
        #expect(receipt.explains(.init(operation: .write,
            path: fixture.workspace.primaryPath + "/forbidden", detail: "Scope denial")))
    }

    @Test("Copy isolation enforces source read-only access under ambient temporary roots")
    func copySourceBoundary() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.workspace.additionalPaths = []
        let task = fixture.task(root: URL(fileURLWithPath: fixture.workspace.primaryPath))
        task.isolationStrategy = .copy
        let captured = TaskExecutionResourceScopeResolver.resolve(task: task)
        #expect(captured.readOnlyRoots.contains(fixture.workspace.primaryPath))
        task.acceptedResourceScope = captured
        #expect(launch(task, runtime: .claudeCode, home: fixture.root).requiresSharedWorkspaceBoundary)
        let scope = TaskExecutionResourceScope(workingDirectory: fixture.first.path,
            workspacePath: fixture.workspace.primaryPath, resources: [
                .init(path: fixture.first.path, access: .exclusive, role: .execution),
                .init(path: fixture.workspace.primaryPath, access: .shared, role: .isolationSource)
            ])
        let plan = AgentRuntimeProcessLaunchPlan(runtime: .claudeCode, executablePath: "/bin/sh",
            arguments: ["-c", """
                /usr/bin/touch allowed || exit 11
                if /usr/bin/touch "$1/forbidden" 2>/dev/null; then exit 12; fi
                """, "copy-source", fixture.workspace.primaryPath],
            currentDirectory: fixture.first.path, environment: ProcessInfo.processInfo.environment,
            browserShimDirectory: nil, providerVersion: nil, parsesJSONLines: false)
        let decision = ExecutionSandbox.decide(plan: plan, providerHomeDirectory: fixture.root.path,
            resourceScope: scope,
            settings: .init(enforcement: .strict, wrappedRuntimes: [.claudeCode], allowNetwork: false))
        guard case .applied(let sandboxed, _) = decision else {
            Issue.record("Expected an enforced copy boundary")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sandboxed.executablePath)
        process.arguments = sandboxed.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: sandboxed.currentDirectory)
        process.environment = sandboxed.environment
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.workspace.primaryPath + "/forbidden"))
        let receipt = try #require(sandboxed.executionSandboxBoundaryReceipt)
        #expect(receipt.explains(.init(operation: .write,
            path: fixture.workspace.primaryPath + "/forbidden", detail: "copy source")))
    }

    @Test("Hooks and subagent permissions are launch settings, never workspace mutations")
    func isolatedHookSettings() throws {
        let hooks = #"{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo hook"}]}]}"#
        let json = try ClaudeSettingsStore.launchSettingsJSON(hooksJSON: hooks, policy: .restricted, allowedTools: ["Read"])
        let settings = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(settings["hooks"] != nil)
        #expect(settings["permissions"] != nil)
        #expect(throws: (any Error).self) {
            try ClaudeSettingsStore.launchSettingsJSON(hooksJSON: "{", policy: .restricted, allowedTools: [])
        }
    }

    private func launch(_ task: AgentTask, runtime: AgentRuntimeID, home: URL, context: String = "") -> TaskLaunchResourcePlan {
        TaskLaunchResourceResolver.resolve(task: task, runID: nil, runtime: runtime, phase: "run",
            prompt: task.goal, contextText: context, workspacePath: TaskWorkspaceAccess(task: task).codeWorkingDirectory,
            homeDirectoryPath: home.path, gitCredentialContextProvider: { _, _, _, _ in .empty })
    }

    private func conflicts(_ first: AgentTask, _ left: TaskExecutionResourceScope,
                           _ second: AgentTask, _ right: TaskExecutionResourceScope) -> Bool {
        !TaskExecutionResourceBroker.canAcquire(
            TaskExecutionResourceBroker.lockClaims(for: left.claims, taskID: first.id, requestID: nil, runMode: "test"),
            active: TaskExecutionResourceBroker.lockClaims(for: right.claims, taskID: second.id, requestID: nil, runMode: "test"))
    }

    private struct Fixture {
        let root: URL
        let repository: URL
        let first: URL
        let second: URL
        let workspace: Workspace

        init(base: URL = FileManager.default.temporaryDirectory) throws {
            root = base.appendingPathComponent("astra-scope-\(UUID().uuidString)")
            repository = root.appendingPathComponent("source")
            first = root.appendingPathComponent("first")
            second = root.appendingPathComponent("second")
            workspace = Workspace(name: "Scope", primaryPath: root.appendingPathComponent("workspace").path,
                                  additionalPaths: [repository.path])
            try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: workspace.primaryPath, withIntermediateDirectories: true)
            _ = try git(["init", "-q"], at: repository)
            _ = try git(["-c", "commit.gpgsign=false", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                         "commit", "-qm", "Initial", "--allow-empty"], at: repository)
            _ = try git(["worktree", "add", "-qb", "first", first.path], at: repository)
            _ = try git(["worktree", "add", "-qb", "second", second.path], at: repository)
        }

        func task(root: URL, runtime: AgentRuntimeID = .claudeCode) -> AgentTask {
            let task = AgentTask(title: "Edit", goal: "Update the parser", workspace: workspace, runtime: runtime)
            task.executionRootPath = root.path
            return task
        }

        func git(_ arguments: [String], at directory: URL) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = directory
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "ScopeGitFixture", code: Int(process.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)])
            }
            return String(decoding: data, as: UTF8.self)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRAPersistence
@testable import ASTRA

@Suite("Execution authority lifecycle", .serialized)
@MainActor
struct ExecutionAuthorityLifecycleTests {
    typealias Fixture = PermissionApprovalContinuationTests.Fixture
    let runtime = RuntimeTurnSettlementTests()

    @Test("Legacy session recording preserves task-folder migration")
    func legacySessionFolderMigration() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let legacy = WorkspaceFileLayout.legacyTaskFolder(workspacePath: fixture.root.path, taskID: fixture.task.id)
        let canonical = WorkspaceFileLayout.taskFolder(workspacePath: fixture.root.path, taskID: fixture.task.id)
        try FileManager.default.createDirectory(atPath: legacy, withIntermediateDirectories: true)
        try "Existing proof".write(toFile: legacy + "/report.md", atomically: true, encoding: .utf8)
        let execution = TaskExecutionContext.legacy(task: fixture.task)
        #expect(execution.taskFolder == legacy)
        let run = TaskRun(task: fixture.task)
        fixture.context.insert(run)
        #expect(AgentRuntimeRunPersistence.recordSessionTurn(task: fixture.task, run: run,
            message: "Continue legacy work", executionContext: execution))
        #expect(FileManager.default.fileExists(atPath: canonical + "/report.md"))
        #expect(FileManager.default.fileExists(atPath: canonical + "/session_history.md"))
        #expect(!FileManager.default.fileExists(atPath: legacy))
    }

    @Test("Inferred discovery and its final refresh stay on accepted storage")
    func inferredValidationAfterWorkspaceMove() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let (_, request) = try runtime.runningTurn(fixture)
        let scope = try #require(request.executionPolicySnapshot?.resourceScope)
        let folder = try TaskWorkspaceAccess(task: fixture.task).ensureTaskFolder()
        try "Open tickets".write(toFile: folder + "/report.md", atomically: true, encoding: .utf8)
        let changed = fixture.root.deletingLastPathComponent().appendingPathComponent("unaccepted-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: changed) }
        try FileManager.default.createDirectory(at: changed, withIntermediateDirectories: true)
        fixture.task.workspace?.primaryPath = changed.path
        let execution = TaskExecutionContext(taskID: fixture.task.id, acceptedScope: scope)
        let suggestion = try #require(TaskInferredValidationService.suggestion(for: fixture.task, executionContext: execution))
        #expect(suggestion.artifactCount == 1)
        let result = await TaskInferredValidationService.run(task: fixture.task, modelContext: fixture.context,
            executionContext: execution)
        #expect(result.didRun && result.canComplete)
        #expect(FileManager.default.fileExists(atPath: folder + "/current_state.json"))
        #expect(!FileManager.default.fileExists(atPath: WorkspaceFileLayout.taskFolder(workspacePath: changed.path, taskID: fixture.task.id)))
        #expect(try TaskStorageBinding.load(for: fixture.task)?.path == folder)
    }

    @Test("Restarted settlement retains storage; the next turn uses the edited execution root")
    func restartedSettlementAndNextAdmission() async throws {
        let fixture = try Fixture(disk: true)
        defer { fixture.cleanup() }
        let (run, request) = try runtime.runningTurn(fixture)
        let scope = try #require(request.executionPolicySnapshot?.resourceScope)
        let folder = try TaskWorkspaceAccess(task: fixture.task).ensureTaskFolder()
        let captured = runtime.checkpoint(fixture, request: request)
        try RuntimeTurnSettlementService.capture(captured, task: fixture.task, run: run, modelContext: fixture.context)
        let changed = fixture.root.deletingLastPathComponent().appendingPathComponent("unaccepted-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: changed) }
        try FileManager.default.createDirectory(at: changed, withIntermediateDirectories: true)
        fixture.task.workspace?.primaryPath = changed.path
        try fixture.context.save()

        let (reopened, task) = try runtime.reopen(fixture)
        let savedRun = try #require(task.runs.first { $0.id == run.id })
        let restored = try #require(try RuntimeTurnSettlementService.checkpoint(for: savedRun, task: task))
        #expect(restored.launchSnapshot.resourceScope == scope)
        #expect(await RuntimeTurnSettlementService.settle(checkpoint: restored, task: task, run: savedRun, modelContext: reopened.mainContext))
        #expect(try TaskTurnRequestRepository.request(id: request.id, in: reopened.mainContext)?.state == .completed)
        #expect(FileManager.default.fileExists(atPath: folder + "/session_history.md"))
        #expect(FileManager.default.fileExists(atPath: folder + "/current_state.json"))
        #expect(!FileManager.default.fileExists(atPath: WorkspaceFileLayout.taskFolder(workspacePath: changed.path, taskID: task.id)))

        let submitted = try ExecutionRequestSubmissionService.submitRetry(message: "Continue", continuation: true,
            for: task, into: reopened.mainContext).get()
        let next = try #require(try TaskTurnRequestRepository.request(id: submitted.requestID, in: reopened.mainContext))
        let snapshot = try #require(TaskExecutionLaunchSnapshotApplicator.snapshot(request: next, from: task))
        #expect(snapshot.resourceScope?.workingDirectory == changed.path)
        #expect(snapshot.resourceScope?.resources.first { $0.role == .taskStorage }?.canonicalPath == folder)
        let launchTask = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: task)
        #expect(try TaskWorkspaceAccess(task: launchTask).ensureTaskFolder() == folder)
    }

    @Test("A missing checkpoint scope cannot turn an accepted request into legacy execution")
    func missingCheckpointScopeFailsClosed() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let (run, request) = try runtime.runningTurn(fixture)
        let invalid = runtime.checkpoint(fixture, request: request, launchSnapshot: .init(task: fixture.task))
        try RuntimeTurnSettlementService.capture(invalid, task: fixture.task, run: run, modelContext: fixture.context)
        #expect(!(await RuntimeTurnSettlementService.settle(checkpoint: invalid, task: fixture.task,
            run: run, modelContext: fixture.context)))
        #expect(RuntimeTurnSettlementService.hasUnsettledResult(task: fixture.task, run: run))
        #expect(!FileManager.default.fileExists(atPath: TaskWorkspaceAccess(task: fixture.task).taskFolder + "/session_history.md"))
    }

    @Test("Workspace edits across a command await cannot redirect subsequent proof or refresh")
    func commandAwaitRetainsAuthority() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let (run, request) = try runtime.runningTurn(fixture)
        let scope = try #require(request.executionPolicySnapshot?.resourceScope)
        let folder = try TaskWorkspaceAccess(task: fixture.task).ensureTaskFolder()
        try "Accepted proof".write(toFile: folder + "/report.md", atomically: true, encoding: .utf8)
        let changed = fixture.root.deletingLastPathComponent().appendingPathComponent("unaccepted-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: changed) }
        try FileManager.default.createDirectory(at: changed, withIntermediateDirectories: true)
        let runner = CallbackValidationRunner {
            await Task.yield()
            fixture.task.workspace?.primaryPath = changed.path
        }
        let plan = TaskPlanPayload(title: "Proof", goal: "Proof", steps: [.init(id: "verify", title: "Verify")],
            validationContract: .init(assertions: [
                .init(id: "command", description: "Tests pass", method: .command, command: "make test"),
                .init(id: "artifact", description: "Original proof exists", method: .artifact, path: "report.md")
            ]))
        let result = await ValidationService.runContract(task: fixture.task, plan: plan, run: run,
            modelContext: fixture.context, executionContext: .init(taskID: fixture.task.id, acceptedScope: scope),
            commandRunner: runner)
        #expect(result.canComplete)
        #expect(FileManager.default.fileExists(atPath: folder + "/current_state.json"))
        #expect(!FileManager.default.fileExists(atPath: WorkspaceFileLayout.taskFolder(workspacePath: changed.path, taskID: fixture.task.id)))
    }

    @Test("Invalid inferred authority is a failed evaluation, not unnecessary validation")
    func invalidInferredAuthorityFails() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let (_, request) = try runtime.runningTurn(fixture)
        let scope = try #require(request.executionPolicySnapshot?.resourceScope)
        let invalid = TaskExecutionContext(taskID: UUID(), acceptedScope: scope)
        for automatic in [false, true] {
            let result = if automatic {
                await TaskInferredValidationService.runAutomaticBaselineIfNeeded(task: fixture.task,
                    modelContext: fixture.context, executionContext: invalid)
            } else {
                await TaskInferredValidationService.run(task: fixture.task,
                    modelContext: fixture.context, executionContext: invalid)
            }
            #expect(result.didRun && !result.canComplete && result.outcome == .failed)
        }
        #expect(fixture.task.events.contains { $0.payload.contains("Validation authority is invalid") })
    }

    @Test("Scoped verifier and utility children are rejected before provider launch")
    func scopedChildrenFailBeforeLaunch() async throws {
        let fixture = try Fixture(runtime: .claudeCode)
        defer { fixture.cleanup() }
        let (run, request) = try runtime.runningTurn(fixture)
        let scope = try #require(request.executionPolicySnapshot?.resourceScope)
        let execution = TaskExecutionContext(taskID: fixture.task.id, acceptedScope: scope)
        let marker = fixture.root.appendingPathComponent("unexpected-child")
        let executable = fixture.root.appendingPathComponent("verifier.sh")
        try "#!/bin/sh\ntouch '\(marker.path)'\nprintf PASS\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let config = AgentUtilityRuntimeConfiguration.claude(path: executable.path)
        let plan = TaskPlanPayload(title: "Verify", goal: "Verify", steps: [.init(id: "verify", title: "Verify")],
            validationContract: .init(assertions: [.init(id: "independent", description: "Review output", method: .verifier)]))
        let result = await ValidationService.runContract(task: fixture.task, plan: plan, run: run,
            modelContext: fixture.context, executionContext: execution, verifierRuntime: config)
        #expect(!result.canComplete)
        #expect(fixture.task.events.contains { $0.payload.contains("scoped_verifier_not_supported") })
        let child = await AgentUtilityRuntimeRunner.runBoundPrompt("Read outside the accepted folders",
            executionContext: execution, configuration: config)
        #expect(child.exitCode != 0 && child.error.contains("scoped_utility_not_supported"))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("Slash and tilde prose stays text; explicit missing attachments stay unavailable")
    func typedInputIdentity() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let missing = fixture.root.appendingPathComponent("missing-attachment.txt").path
        fixture.task.inputs = ["/health", "~5 minutes", missing]
        let scope = TaskExecutionResourceScopeResolver.resolve(task: fixture.task, attachmentPaths: [missing])
        #expect(scope.promptInputs.map(\.kind) == [.text, .text, .unavailablePath])
        #expect(scope.promptInputs.map(\.value) == fixture.task.inputs)
        #expect(!scope.resources.contains { $0.role == .input && $0.path == missing })
    }

    @Test("Storage bindings survive compaction but do not grant authority on file import")
    func bindingPersistenceAndImportTrust() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try runtime.runningTurn(fixture)
        let binding = try #require(try TaskStorageBinding.load(for: fixture.task))
        for index in 0..<260 {
            fixture.context.insert(TaskEvent(task: fixture.task, type: "tool.use", payload: "Read \(index)"))
        }
        AgentEventCompactor.compactEvents(for: fixture.task, modelContext: fixture.context)
        #expect(try TaskStorageBinding.load(for: fixture.task) == binding)
        #expect(WorkspaceConfigManager.isTaskRecoveryEvent(TaskStorageBinding.eventType))
        #expect(WorkspaceConfigManager.importedRecoveryEventType(TaskStorageBinding.eventType, trust: .quarantine) != TaskStorageBinding.eventType)
        #expect(WorkspaceConfigManager.importedRecoveryEventType(TaskStorageBinding.eventType, trust: .trustedLocalRecovery) == TaskStorageBinding.eventType)
    }

    @Test("A failed submission rolls back its storage owner with the request")
    func failedSubmissionRollsBackBinding() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let failed = ExecutionRequestSubmissionService.submitPermissionResume(message: "Continue",
            executionPolicy: .default, for: fixture.task, into: fixture.context,
            persist: { throw RuntimeTurnSettlementTests.SaveFailure.injected })
        guard case .failure = failed else { Issue.record("The injected save failure was ignored"); return }
        #expect(try TaskStorageBinding.load(for: fixture.task) == nil)
        #expect(try TaskTurnRequestRepository.requests(for: fixture.task, in: fixture.context).isEmpty)
        #expect(!fixture.task.events.contains { !$0.isDeleted && $0.type == TaskEventTypes.ExecutionRequest.permissionResume.rawValue })
        _ = try ExecutionRequestSubmissionService.submitInitial(for: fixture.task, into: fixture.context).get()
        #expect(try TaskStorageBinding.load(for: fixture.task) != nil)
    }

    @Test("Corrupt storage authority fails visibly without falling back to live folders")
    func corruptStorageFailsClosed() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let (_, request) = try runtime.runningTurn(fixture)
        let scope = try #require(request.executionPolicySnapshot?.resourceScope)
        let bindingEvent = try #require(fixture.task.events.first { $0.type == TaskStorageBinding.eventType })
        bindingEvent.payload = "corrupt"
        #expect(throws: (any Error).self) { try TaskWorkspaceAccess(task: fixture.task).ensureTaskFolder() }
        let result = await TaskInferredValidationService.run(task: fixture.task, modelContext: fixture.context,
            executionContext: .init(taskID: fixture.task.id, acceptedScope: scope))
        #expect(result.didRun && !result.canComplete)
        #expect(fixture.task.events.contains { $0.payload.contains("Validation authority is invalid") })
    }
}

private struct CallbackValidationRunner: ValidationCommandRunning {
    let callback: @MainActor @Sendable () async -> Void

    func run(command: String, workingDirectory: String, environment: [String: String],
        additionalWritablePaths: [String], resourceScope: TaskExecutionResourceScope?) async -> ValidationCommandResult {
        #expect(resourceScope?.workingDirectory == workingDirectory)
        await callback()
        return .init(exitCode: 0, stdout: "passed", stderr: "")
    }
}

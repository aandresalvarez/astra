import Foundation
import SwiftData
import Testing
@testable import ASTRA
import ASTRACore

private func makeValidationServiceContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

private actor StubValidationCommandRunner: ValidationCommandRunning {
    struct Call: Equatable {
        let command: String
        let workingDirectory: String
        let pathContainsShellSuffix: Bool
    }

    private var results: [ValidationCommandResult]
    private var calls: [Call] = []

    init(results: [ValidationCommandResult]) {
        self.results = results
    }

    func run(command: String, workingDirectory: String, environment: [String: String]) async -> ValidationCommandResult {
        calls.append(Call(
            command: command,
            workingDirectory: workingDirectory,
            pathContainsShellSuffix: environment["PATH"]?.contains(RuntimePathResolver.shellPathSuffix) == true
        ))
        return results.isEmpty
            ? ValidationCommandResult(exitCode: 0, stdout: "", stderr: "")
            : results.removeFirst()
    }

    func recordedCalls() -> [Call] {
        calls
    }
}

@Suite("Validation service")
@MainActor
struct ValidationServiceTests {
    @Test("runTests uses injected command runner")
    func runTestsUsesInjectedCommandRunner() async throws {
        let root = "/tmp/astra-validation-runner-\(UUID().uuidString.prefix(8))"
        let workspace = Workspace(name: "Validation Runner", primaryPath: root)
        let task = AgentTask(title: "Validate", goal: "Run injected tests", workspace: workspace)
        task.testCommand = "swift test --filter Focused"
        let runner = StubValidationCommandRunner(results: [
            ValidationCommandResult(exitCode: 0, stdout: "focused pass", stderr: "")
        ])

        let result = await ValidationService.runTests(task: task, commandRunner: runner)

        if case .passed(let details) = result {
            #expect(details.contains("focused pass"))
        } else {
            Issue.record("Expected injected validation command to pass")
        }
        #expect(await runner.recordedCalls() == [
            StubValidationCommandRunner.Call(
                command: "swift test --filter Focused",
                workingDirectory: root,
                pathContainsShellSuffix: true
            )
        ])
    }

    @Test("validation contract command assertions use injected runner")
    func validationContractCommandAssertionsUseInjectedRunner() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Validation Runner", primaryPath: root)
        let task = AgentTask(title: "Validate", goal: "Run command through injected runner", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        let runner = StubValidationCommandRunner(results: [
            ValidationCommandResult(exitCode: 7, stdout: "stdout detail", stderr: "stderr detail")
        ])
        let plan = TaskPlanPayload(
            title: "Proof",
            goal: "Run a proof command",
            steps: [TaskPlanPayloadStep(id: "verify", title: "Verify")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "command-runner",
                    description: "Command exits zero",
                    method: .command,
                    command: "swift test --filter Focused"
                )
            ])
        )

        let result = await ValidationService.runContract(
            task: task,
            plan: plan,
            run: run,
            modelContext: context,
            commandRunner: runner
        )

        #expect(result.didRun)
        #expect(!result.canComplete)
        #expect(await runner.recordedCalls() == [
            StubValidationCommandRunner.Call(
                command: "swift test --filter Focused",
                workingDirectory: root,
                pathContainsShellSuffix: true
            )
        ])
        let assertionEvent = try #require(task.events.first { $0.type == TaskValidationEventTypes.assertionFailed })
        let payload = try JSONDecoder().decode(
            TaskValidationAssertionEventPayload.self,
            from: Data(assertionEvent.payload.utf8)
        )
        #expect(payload.exitCode == 7)
        #expect(payload.evidence == "stdout detail\nstderr detail")
        #expect(payload.reason == "command_failed")
    }

    @Test("validation contract command pass records assertion and contract events")
    func validationContractCommandPasses() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Validation", primaryPath: root)
        let task = AgentTask(title: "Validate", goal: "Run a proof command", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        let plan = TaskPlanPayload(
            title: "Proof",
            goal: "Run a proof command",
            steps: [TaskPlanPayloadStep(id: "verify", title: "Verify")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "command-pass",
                    description: "Command exits zero",
                    method: .command,
                    command: "true"
                )
            ])
        )

        let result = await ValidationService.runContract(
            task: task,
            plan: plan,
            run: run,
            modelContext: context
        )

        #expect(result.didRun)
        #expect(result.canComplete)
        #expect(task.events.contains { $0.type == TaskValidationEventTypes.assertionStarted })
        #expect(task.events.contains { $0.type == TaskValidationEventTypes.assertionPassed })
        #expect(task.events.contains { $0.type == TaskValidationEventTypes.contractPassed })
    }

    @Test("validation contract command failure blocks completion")
    func validationContractCommandFailureBlocksCompletion() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Validation Failure", primaryPath: root)
        let task = AgentTask(title: "Validate", goal: "Run a failing proof command", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        let plan = TaskPlanPayload(
            title: "Proof",
            goal: "Run a failing proof command",
            steps: [TaskPlanPayloadStep(id: "verify", title: "Verify")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "command-fails",
                    description: "Command exits zero",
                    method: .command,
                    command: "false"
                )
            ])
        )

        let result = await ValidationService.runContract(
            task: task,
            plan: plan,
            run: run,
            modelContext: context
        )

        #expect(result.didRun)
        #expect(!result.canComplete)
        #expect(result.failedRequiredAssertionIDs == ["command-fails"])
        #expect(task.events.contains { $0.type == TaskValidationEventTypes.assertionFailed })
        #expect(task.events.contains { $0.type == TaskValidationEventTypes.contractFailed })
        let correctiveEvent = try #require(task.events.first { $0.type == TaskCorrectiveEventTypes.stepCreated })
        #expect(correctiveEvent.payload.contains("command-fails"))
        #expect(correctiveEvent.payload.contains("Fix the work until this command exits 0"))
    }

    @Test("validation contract command allowlist blocks shell composition before execution")
    func validationContractCommandAllowlistBlocksShellCompositionBeforeExecution() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Validation Guard", primaryPath: root)
        let task = AgentTask(title: "Validate safely", goal: "Reject composed validation commands", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        let markerPath = (root as NSString).appendingPathComponent("should-not-exist.txt")
        let plan = TaskPlanPayload(
            title: "Proof",
            goal: "Reject unsafe proof command",
            steps: [TaskPlanPayloadStep(id: "verify", title: "Verify")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "unsafe-command",
                    description: "Composed shell command is rejected",
                    method: .command,
                    command: "true; touch \(markerPath)"
                )
            ])
        )

        let result = await ValidationService.runContract(
            task: task,
            plan: plan,
            run: run,
            modelContext: context
        )

        #expect(result.didRun)
        #expect(!result.canComplete)
        #expect(!FileManager.default.fileExists(atPath: markerPath))
        #expect(task.events.contains {
            $0.type == TaskValidationEventTypes.assertionFailed &&
                $0.payload.contains("command_not_allowed")
        })
        #expect(task.events.contains {
            $0.type == TaskCorrectiveEventTypes.stepCreated &&
                $0.payload.contains("Replace this command assertion with structured artifact") &&
                $0.payload.contains("text_contains")
        })
    }

    @Test("validation contract command allowlist blocks repo scripts before execution")
    func validationContractCommandAllowlistBlocksRepoScriptsBeforeExecution() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Script Guard", primaryPath: root)
        let task = AgentTask(title: "Validate safely", goal: "Reject repo script validation commands", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        let scriptDirectory = (root as NSString).appendingPathComponent("script")
        try FileManager.default.createDirectory(atPath: scriptDirectory, withIntermediateDirectories: true)
        let markerPath = (root as NSString).appendingPathComponent("script-ran.txt")
        let scriptPath = (scriptDirectory as NSString).appendingPathComponent("validation-danger.sh")
        try """
        #!/bin/sh
        touch "\(markerPath)"
        """.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)

        let plan = TaskPlanPayload(
            title: "Proof",
            goal: "Reject repo script command",
            steps: [TaskPlanPayloadStep(id: "verify", title: "Verify")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "script-command",
                    description: "Repo scripts are not trusted validation commands",
                    method: .command,
                    command: "script/validation-danger.sh"
                )
            ])
        )

        let result = await ValidationService.runContract(
            task: task,
            plan: plan,
            run: run,
            modelContext: context
        )

        #expect(result.didRun)
        #expect(!result.canComplete)
        #expect(!FileManager.default.fileExists(atPath: markerPath))
        #expect(task.events.contains {
            $0.type == TaskValidationEventTypes.assertionFailed &&
                $0.payload.contains("command_not_allowed")
        })
    }

    @Test("validation contract command allowlist blocks python before pytest module")
    func validationContractCommandAllowlistBlocksPythonBeforePytestModule() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Python Guard", primaryPath: root)
        let task = AgentTask(title: "Validate safely", goal: "Reject arbitrary Python before pytest", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        let markerPath = (root as NSString).appendingPathComponent("python-ran.txt")
        let plan = TaskPlanPayload(
            title: "Proof",
            goal: "Reject unsafe Python command",
            steps: [TaskPlanPayloadStep(id: "verify", title: "Verify")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "python-command",
                    description: "Python must start with -m pytest",
                    method: .command,
                    command: #"python -c 'open("\#(markerPath)","w").write("x")' -m pytest"#
                )
            ])
        )

        let result = await ValidationService.runContract(
            task: task,
            plan: plan,
            run: run,
            modelContext: context
        )

        #expect(result.didRun)
        #expect(!result.canComplete)
        #expect(!FileManager.default.fileExists(atPath: markerPath))
        #expect(task.events.contains {
            $0.type == TaskValidationEventTypes.assertionFailed &&
                $0.payload.contains("command_not_allowed")
        })
    }

    @Test("validation contract artifact check resolves task output folder paths")
    func validationContractArtifactCheckUsesTaskFolder() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Artifact Validation", primaryPath: root)
        let task = AgentTask(title: "Validate artifact", goal: "Require an output artifact", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        let taskFolder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        try "report".write(
            toFile: (taskFolder as NSString).appendingPathComponent("report.md"),
            atomically: true,
            encoding: .utf8
        )
        let plan = TaskPlanPayload(
            title: "Proof",
            goal: "Require an output artifact",
            steps: [TaskPlanPayloadStep(id: "verify", title: "Verify")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "report-exists",
                    description: "Report exists",
                    method: .artifact,
                    path: "report.md"
                )
            ])
        )

        let result = await ValidationService.runContract(
            task: task,
            plan: plan,
            run: run,
            modelContext: context
        )

        #expect(result.canComplete)
        #expect(task.events.contains { $0.type == TaskValidationEventTypes.assertionPassed && $0.payload.contains("report.md") })
    }

    @Test("validation contract artifact rejects directories unless expected")
    func validationContractArtifactRejectsDirectoriesUnlessExpected() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Artifact Directory", primaryPath: root)
        let task = AgentTask(title: "Validate artifact directory", goal: "Reject directory as file artifact", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        let taskFolder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        let directoryPath = (taskFolder as NSString).appendingPathComponent("report")
        try FileManager.default.createDirectory(atPath: directoryPath, withIntermediateDirectories: true)
        let plan = TaskPlanPayload(
            title: "Proof",
            goal: "Reject directory artifact",
            steps: [TaskPlanPayloadStep(id: "verify", title: "Verify")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "report-file",
                    description: "Report file exists",
                    method: .artifact,
                    path: "report"
                )
            ])
        )

        let result = await ValidationService.runContract(
            task: task,
            plan: plan,
            run: run,
            modelContext: context
        )

        #expect(result.didRun)
        #expect(!result.canComplete)
        #expect(result.failedRequiredAssertionIDs == ["report-file"])
        #expect(task.events.contains {
            $0.type == TaskValidationEventTypes.assertionFailed &&
                $0.payload.contains("artifact_directory_not_allowed")
        })
    }

    @Test("validation contract artifact allows explicit directory type")
    func validationContractArtifactAllowsExplicitDirectoryType() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Artifact Directory Allowed", primaryPath: root)
        let task = AgentTask(title: "Validate artifact directory", goal: "Allow directory artifact", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        let taskFolder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        let directoryPath = (taskFolder as NSString).appendingPathComponent("report")
        try FileManager.default.createDirectory(atPath: directoryPath, withIntermediateDirectories: true)
        let plan = TaskPlanPayload(
            title: "Proof",
            goal: "Allow directory artifact",
            steps: [TaskPlanPayloadStep(id: "verify", title: "Verify")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "report-directory",
                    description: "Report directory exists",
                    method: .artifact,
                    path: "report",
                    expectedArtifactType: "directory"
                )
            ])
        )

        let result = await ValidationService.runContract(
            task: task,
            plan: plan,
            run: run,
            modelContext: context
        )

        #expect(result.didRun)
        #expect(result.canComplete)
        #expect(task.events.contains {
            $0.type == TaskValidationEventTypes.assertionPassed &&
                $0.payload.contains("report-directory")
        })
    }

    @Test("validation contract text contains resolves task output files")
    func validationContractTextContainsUsesTaskFolder() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Text Contains", primaryPath: root)
        let task = AgentTask(title: "Validate text", goal: "Require generated page text", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        let taskFolder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        try "<html><body><h1>Med13 Foundation</h1></body></html>".write(
            toFile: (taskFolder as NSString).appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
        let plan = TaskPlanPayload(
            title: "Text proof",
            goal: "Require generated page text",
            steps: [TaskPlanPayloadStep(id: "verify", title: "Verify")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "index-exists",
                    description: "Index page exists",
                    method: .artifact,
                    path: "index.html"
                ),
                TaskValidationAssertion(
                    id: "index-med13",
                    description: "Index page names Med13",
                    method: .textContains,
                    path: "index.html",
                    evidenceQuery: "Med13 Foundation"
                )
            ])
        )

        let result = await ValidationService.runContract(
            task: task,
            plan: plan,
            run: run,
            modelContext: context
        )

        #expect(result.didRun)
        #expect(result.canComplete)
        #expect(task.events.contains {
            $0.type == TaskValidationEventTypes.assertionPassed &&
                $0.payload.contains("index-med13") &&
                $0.payload.contains("text_contains")
        })
    }

    @Test("validation contract text contains failure blocks completion")
    func validationContractTextContainsFailureBlocksCompletion() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Text Missing", primaryPath: root)
        let task = AgentTask(title: "Validate text", goal: "Require missing text", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        let taskFolder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        try "<html><body><h1>Other Foundation</h1></body></html>".write(
            toFile: (taskFolder as NSString).appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
        let plan = TaskPlanPayload(
            title: "Text proof",
            goal: "Require missing text",
            steps: [TaskPlanPayloadStep(id: "verify", title: "Verify")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "index-med13",
                    description: "Index page names Med13",
                    method: .textContains,
                    path: "index.html",
                    evidenceQuery: "Med13 Foundation"
                )
            ])
        )

        let result = await ValidationService.runContract(task: task, plan: plan, run: run, modelContext: context)

        #expect(result.didRun)
        #expect(!result.canComplete)
        #expect(result.failedRequiredAssertionIDs == ["index-med13"])
        #expect(task.events.contains {
            $0.type == TaskValidationEventTypes.assertionFailed &&
                $0.payload.contains("expected_text_missing")
        })
        #expect(task.events.contains {
            $0.type == TaskCorrectiveEventTypes.stepCreated &&
                $0.payload.contains("index-med13") &&
                $0.payload.contains("index.html") &&
                $0.payload.contains("expected text")
        })
    }

    @Test("validation contract text contains requires evidence query")
    func validationContractTextContainsRequiresEvidenceQuery() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Text Contract", primaryPath: root)
        let task = AgentTask(title: "Validate text contract", goal: "Reject malformed text assertion", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        let taskFolder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        try "<html><body><h1>Index page names Med13</h1></body></html>".write(
            toFile: (taskFolder as NSString).appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
        let plan = TaskPlanPayload(
            title: "Malformed text proof",
            goal: "Reject text_contains without evidence query",
            steps: [TaskPlanPayloadStep(id: "verify", title: "Verify")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "index-med13",
                    description: "Index page names Med13",
                    method: .textContains,
                    path: "index.html"
                )
            ])
        )

        let result = await ValidationService.runContract(task: task, plan: plan, run: run, modelContext: context)

        #expect(result.didRun)
        #expect(!result.canComplete)
        #expect(result.failedRequiredAssertionIDs == ["index-med13"])
        #expect(task.events.contains {
            $0.type == TaskValidationEventTypes.assertionFailed &&
                $0.payload.contains("missing_expected_text")
        })
        #expect(!task.events.contains {
            $0.type == TaskValidationEventTypes.assertionPassed &&
                $0.payload.contains("index-med13")
        })
    }

    @Test("validation contract text contains rejects unknown file size before reading")
    func validationContractTextContainsRejectsUnknownFileSize() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Text Contract", primaryPath: root)
        let task = AgentTask(title: "Validate text contract", goal: "Reject unknown-size text assertion", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        let taskFolder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        try "<html><body><h1>Index page names Med13</h1></body></html>".write(
            toFile: (taskFolder as NSString).appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
        let plan = TaskPlanPayload(
            title: "Unknown size text proof",
            goal: "Reject text_contains when file size cannot be determined",
            steps: [TaskPlanPayloadStep(id: "verify", title: "Verify")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "index-med13",
                    description: "Index page names Med13",
                    method: .textContains,
                    path: "index.html",
                    evidenceQuery: "Med13"
                )
            ])
        )

        let originalProbe = ValidationService.textContainsFileSizeProbe
        ValidationService.textContainsFileSizeProbe = { _ in nil }
        defer { ValidationService.textContainsFileSizeProbe = originalProbe }

        let result = await ValidationService.runContract(task: task, plan: plan, run: run, modelContext: context)

        #expect(result.didRun)
        #expect(!result.canComplete)
        #expect(result.failedRequiredAssertionIDs == ["index-med13"])
        #expect(task.events.contains {
            $0.type == TaskValidationEventTypes.assertionFailed &&
                $0.payload.contains("artifact_size_unknown")
        })
        #expect(!task.events.contains {
            $0.type == TaskValidationEventTypes.assertionPassed &&
                $0.payload.contains("index-med13")
        })
    }

    @Test("validation contract rejects artifact paths outside task scope")
    func validationContractRejectsArtifactPathsOutsideTaskScope() async throws {
        let root = try temporaryRoot()
        let outsideRoot = try temporaryRoot()
        defer {
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(atPath: outsideRoot)
        }
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Artifact Scope", primaryPath: root)
        let task = AgentTask(title: "Validate artifact scope", goal: "Reject outside artifacts", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        let outsidePath = (outsideRoot as NSString).appendingPathComponent("existing-report.md")
        try "outside".write(toFile: outsidePath, atomically: true, encoding: .utf8)
        let plan = TaskPlanPayload(
            title: "Proof",
            goal: "Reject outside artifacts",
            steps: [TaskPlanPayloadStep(id: "verify", title: "Verify")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "absolute-artifact",
                    description: "Absolute paths are not trusted evidence",
                    method: .artifact,
                    path: outsidePath
                ),
                TaskValidationAssertion(
                    id: "parent-artifact",
                    description: "Parent traversal is not trusted evidence",
                    method: .artifact,
                    path: "../existing-report.md"
                )
            ])
        )

        let result = await ValidationService.runContract(
            task: task,
            plan: plan,
            run: run,
            modelContext: context
        )

        #expect(result.didRun)
        #expect(!result.canComplete)
        #expect(result.failedRequiredAssertionIDs.contains("absolute-artifact"))
        #expect(result.failedRequiredAssertionIDs.contains("parent-artifact"))
        let scopedFailures = task.events.filter {
            $0.type == TaskValidationEventTypes.assertionFailed &&
                $0.payload.contains("path_outside_scope")
        }
        #expect(scopedFailures.count == 2)
    }

    @Test("validation contract rejects artifact symlinks outside task scope")
    func validationContractRejectsArtifactSymlinksOutsideTaskScope() async throws {
        let root = try temporaryRoot()
        let outsideRoot = try temporaryRoot()
        defer {
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(atPath: outsideRoot)
        }
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Artifact Symlink Scope", primaryPath: root)
        let task = AgentTask(title: "Validate artifact symlink scope", goal: "Reject symlinked outside artifacts", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        let outsidePath = (outsideRoot as NSString).appendingPathComponent("existing-report.md")
        try "outside".write(toFile: outsidePath, atomically: true, encoding: .utf8)
        let taskFolder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        let linkPath = (taskFolder as NSString).appendingPathComponent("linked-report.md")
        try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: outsidePath)

        let plan = TaskPlanPayload(
            title: "Proof",
            goal: "Reject symlinked outside artifacts",
            steps: [TaskPlanPayloadStep(id: "verify", title: "Verify")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "symlink-artifact",
                    description: "Symlink targets outside scope are not trusted evidence",
                    method: .artifact,
                    path: "linked-report.md"
                )
            ])
        )

        let result = await ValidationService.runContract(
            task: task,
            plan: plan,
            run: run,
            modelContext: context
        )

        #expect(result.didRun)
        #expect(!result.canComplete)
        #expect(result.failedRequiredAssertionIDs == ["symlink-artifact"])
        #expect(task.events.contains {
            $0.type == TaskValidationEventTypes.assertionFailed &&
                $0.payload.contains("path_outside_scope")
        })
    }

    @Test("validation contract rejects browser behavior paths outside task scope")
    func validationContractRejectsBrowserBehaviorPathsOutsideTaskScope() async throws {
        let root = try temporaryRoot()
        let outsideRoot = try temporaryRoot()
        defer {
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(atPath: outsideRoot)
        }
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Browser Scope", primaryPath: root)
        let task = AgentTask(title: "Validate browser scope", goal: "Reject outside HTML", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        let outsidePath = (outsideRoot as NSString).appendingPathComponent("existing.html")
        try "<html><body>ready</body></html>".write(toFile: outsidePath, atomically: true, encoding: .utf8)
        let plan = TaskPlanPayload(
            title: "Proof",
            goal: "Reject outside browser artifacts",
            steps: [TaskPlanPayloadStep(id: "verify", title: "Verify")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "absolute-browser",
                    description: "ready",
                    method: .browserBehavior,
                    path: outsidePath
                )
            ])
        )

        let result = await ValidationService.runContract(
            task: task,
            plan: plan,
            run: run,
            modelContext: context
        )

        #expect(result.didRun)
        #expect(!result.canComplete)
        #expect(result.failedRequiredAssertionIDs == ["absolute-browser"])
        #expect(task.events.contains {
            $0.type == TaskValidationEventTypes.assertionFailed &&
                $0.payload.contains("path_outside_scope")
        })
        #expect(task.events.contains {
            $0.type == TaskValidationBehaviorEventTypes.failed &&
                $0.payload.contains("path_outside_scope")
        })
    }

    @Test("validation contract rejects browser behavior symlinks outside task scope")
    func validationContractRejectsBrowserBehaviorSymlinksOutsideTaskScope() async throws {
        let root = try temporaryRoot()
        let outsideRoot = try temporaryRoot()
        defer {
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(atPath: outsideRoot)
        }
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Browser Symlink Scope", primaryPath: root)
        let task = AgentTask(title: "Validate browser symlink scope", goal: "Reject symlinked outside HTML", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)

        let outsidePath = (outsideRoot as NSString).appendingPathComponent("existing.html")
        try "<html><body>ready</body></html>".write(toFile: outsidePath, atomically: true, encoding: .utf8)
        let taskFolder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        let linkPath = (taskFolder as NSString).appendingPathComponent("linked.html")
        try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: outsidePath)

        let plan = TaskPlanPayload(
            title: "Proof",
            goal: "Reject symlinked outside browser artifacts",
            steps: [TaskPlanPayloadStep(id: "verify", title: "Verify")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "symlink-browser",
                    description: "ready",
                    method: .browserBehavior,
                    path: "linked.html"
                )
            ])
        )

        let result = await ValidationService.runContract(
            task: task,
            plan: plan,
            run: run,
            modelContext: context
        )

        #expect(result.didRun)
        #expect(!result.canComplete)
        #expect(result.failedRequiredAssertionIDs == ["symlink-browser"])
        #expect(task.events.contains {
            $0.type == TaskValidationEventTypes.assertionFailed &&
                $0.payload.contains("path_outside_scope")
        })
        #expect(task.events.contains {
            $0.type == TaskValidationBehaviorEventTypes.failed &&
                $0.payload.contains("path_outside_scope")
        })
    }

    @Test("failed validation creates one corrective item with auditable lifecycle")
    func failedValidationCreatesOneCorrectiveItemWithAuditableLifecycle() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Corrective", primaryPath: root)
        let task = AgentTask(title: "Corrective validation", goal: "Create a failing correction", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        let plan = TaskPlanPayload(
            title: "Proof",
            goal: "Require corrective work",
            steps: [TaskPlanPayloadStep(id: "verify", title: "Verify")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "must-pass",
                    description: "Command passes",
                    method: .command,
                    command: "false"
                )
            ])
        )

        _ = await ValidationService.runContract(task: task, plan: plan, run: run, modelContext: context)
        _ = await ValidationService.runContract(task: task, plan: plan, run: run, modelContext: context)

        let proposedEvents = task.events.filter { $0.type == TaskCorrectiveEventTypes.stepCreated }
        #expect(proposedEvents.count == 1)
        let record = try #require(TaskCorrectiveWorkService.openCorrectiveSteps(for: task).first)
        let correctiveStepID = TaskCorrectiveWorkService.normalizedCorrectiveStepID(record.payload)

        var state = try #require(TaskContextStateManager.load(taskFolder: TaskWorkspaceAccess(task: task).taskFolder))
        let corrective = try #require(state.correctiveWork?.first)
        #expect(corrective.correctiveStepID == correctiveStepID)
        #expect(corrective.status == "proposed")
        #expect(corrective.failedAssertionID == "must-pass")
        #expect(state.nextLikelyAction?.contains("failed assertion must-pass") == true)
        let prompt = AgentPromptBuilder.buildFreshFollowUpPrompt(message: "Continue", task: task)
        #expect(prompt.contains("Corrective work:"))
        #expect(prompt.contains("must-pass"))

        let approved = try #require(TaskCorrectiveWorkService.approveStep(
            task: task,
            correctiveStepID: correctiveStepID,
            modelContext: context
        ))
        #expect(approved.status == "approved")
        #expect(task.events.contains { $0.type == TaskCorrectiveEventTypes.stepApproved })

        let child = try #require(TaskCorrectiveWorkService.createCorrectiveTask(
            from: task,
            correctiveStepID: correctiveStepID,
            modelContext: context
        ))
        #expect(child.goal.contains("must-pass"))
        #expect(task.events.contains { $0.type == TaskCorrectiveEventTypes.taskCreated && $0.payload.contains(child.id.uuidString) })

        let duplicateChild = try #require(TaskCorrectiveWorkService.createCorrectiveTask(
            from: task,
            correctiveStepID: correctiveStepID,
            modelContext: context
        ))
        #expect(duplicateChild.id == child.id)
        #expect(workspace.tasks.filter { $0.constraints.contains("Failed assertion ID: must-pass") }.count == 1)
        #expect(task.events.filter { $0.type == TaskCorrectiveEventTypes.taskCreated }.count == 1)

        let dismissed = try #require(TaskCorrectiveWorkService.dismissStep(
            task: task,
            correctiveStepID: correctiveStepID,
            reason: "Handled in a different task",
            modelContext: context
        ))
        #expect(dismissed.status == "dismissed")
        #expect(dismissed.dismissedReason == "Handled in a different task")
        #expect(task.events.contains { $0.type == TaskCorrectiveEventTypes.stepDismissed })

        state = try #require(TaskContextStateManager.load(taskFolder: TaskWorkspaceAccess(task: task).taskFolder))
        let finalCorrective = try #require(state.correctiveWork?.first)
        #expect(finalCorrective.status == "dismissed")
        #expect(finalCorrective.correctiveTaskID == child.id.uuidString)
        let markdown = try String(
            contentsOfFile: (TaskWorkspaceAccess(task: task).taskFolder as NSString)
                .appendingPathComponent(TaskContextStateManager.markdownFileName),
            encoding: .utf8
        )
        #expect(markdown.contains("## Corrective Work"))
        #expect(markdown.contains("Handled in a different task"))
    }

    @Test("browser behavior assertion passes with deterministic evidence")
    func browserBehaviorAssertionPassesWithDeterministicEvidence() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Browser Behavior", primaryPath: root)
        let task = AgentTask(title: "Browser behavior", goal: "Validate rendered artifact", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        let taskFolder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        try """
        <html><head><title>Demo</title></head><body><h1>Checkout Ready</h1></body></html>
        """.write(
            toFile: (taskFolder as NSString).appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
        let plan = TaskPlanPayload(
            title: "Browser proof",
            goal: "Validate rendered artifact",
            steps: [TaskPlanPayloadStep(id: "browser", title: "Browser")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "browser-visible",
                    description: "Checkout Ready",
                    method: .browserBehavior,
                    path: "index.html",
                    evidenceQuery: "Checkout Ready"
                )
            ])
        )
        TaskPlanService.recordCreated(plan, task: task, modelContext: context)

        let result = await ValidationService.runContract(task: task, plan: plan, run: run, modelContext: context)

        #expect(result.canComplete)
        #expect(task.events.contains { $0.type == TaskValidationBehaviorEventTypes.started })
        #expect(task.events.contains { $0.type == TaskValidationBehaviorEventTypes.evidenceAttached })
        #expect(task.events.contains { $0.type == TaskValidationBehaviorEventTypes.passed })
        let assertionEvent = try #require(task.events.first {
            $0.type == TaskValidationEventTypes.assertionPassed && $0.payload.contains("browser-visible")
        })
        #expect(assertionEvent.payload.contains("validation-evidence"))
        let state = try #require(TaskContextStateManager.load(taskFolder: taskFolder))
        let assertion = try #require(state.validationContract?.assertions.first { $0.id == "browser-visible" })
        #expect(assertion.sourcePointers.contains { $0.kind == "validation_evidence" && $0.path?.contains("browser-visible-behavior.json") == true })
    }

    @Test("browser behavior assertion failure blocks required contract")
    func browserBehaviorAssertionFailureBlocksRequiredContract() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Browser Behavior Failure", primaryPath: root)
        let task = AgentTask(title: "Browser behavior", goal: "Validate rendered artifact", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        let taskFolder = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
        try "<html><body><h1>Still Loading</h1></body></html>".write(
            toFile: (taskFolder as NSString).appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
        let plan = TaskPlanPayload(
            title: "Browser proof",
            goal: "Validate rendered artifact",
            steps: [TaskPlanPayloadStep(id: "browser", title: "Browser")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "browser-missing",
                    description: "Checkout Ready",
                    method: .browserBehavior,
                    path: "index.html",
                    evidenceQuery: "Checkout Ready"
                )
            ])
        )

        let result = await ValidationService.runContract(task: task, plan: plan, run: run, modelContext: context)

        #expect(!result.canComplete)
        #expect(result.failedRequiredAssertionIDs == ["browser-missing"])
        #expect(task.events.contains { $0.type == TaskValidationBehaviorEventTypes.failed && $0.payload.contains("expected_text_missing") })
        #expect(task.events.contains { $0.type == TaskValidationEventTypes.assertionFailed && $0.payload.contains("expected_text_missing") })
        #expect(task.events.contains { $0.type == TaskCorrectiveEventTypes.stepCreated && $0.payload.contains("browser-missing") })
    }

    @Test("verifier assertion pass satisfies required contract")
    func verifierAssertionPassSatisfiesRequiredContract() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fakeCopilot = try fakeCopilotUtility(in: root, output: "PASS\nReviewed assertion verifier-pass.")
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Verifier Pass", primaryPath: root)
        let task = AgentTask(title: "Verifier", goal: "Review independently", workspace: workspace)
        let run = TaskRun(task: task)
        run.output = "Worker says the change is complete."
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        let plan = TaskPlanPayload(
            title: "Verifier plan",
            goal: "Review independently",
            steps: [TaskPlanPayloadStep(id: "review", title: "Review")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "verifier-pass",
                    description: "Independent verifier approves the work",
                    method: .verifier
                )
            ])
        )

        let result = await ValidationService.runContract(
            task: task,
            plan: plan,
            run: run,
            modelContext: context,
            verifierRuntime: AgentUtilityRuntimeConfiguration(
                runtime: .copilotCLI,
                model: "gpt-5",
                copilotPath: fakeCopilot.path,
                copilotHome: (root as NSString).appendingPathComponent("copilot-home")
            )
        )

        #expect(result.canComplete)
        #expect(task.events.contains { $0.type == TaskVerifierEventTypes.started })
        #expect(task.events.contains { $0.type == TaskVerifierEventTypes.completed && $0.payload.contains("\"result\":\"pass\"") })
        #expect(task.events.contains { $0.type == TaskValidationEventTypes.assertionReviewed })
        #expect(task.events.contains { $0.type == TaskValidationEventTypes.assertionPassed && $0.payload.contains("verifier-pass") })
    }

    @Test("verifier assertion failure blocks required contract")
    func verifierAssertionFailureBlocksRequiredContract() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fakeCopilot = try fakeCopilotUtility(in: root, output: "FAIL\nMissing expected behavior evidence.")
        let container = try makeValidationServiceContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Verifier Fail", primaryPath: root)
        let task = AgentTask(title: "Verifier", goal: "Review independently", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        let plan = TaskPlanPayload(
            title: "Verifier plan",
            goal: "Review independently",
            steps: [TaskPlanPayloadStep(id: "review", title: "Review")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "verifier-fail",
                    description: "Independent verifier approves the work",
                    method: .verifier
                )
            ])
        )

        let result = await ValidationService.runContract(
            task: task,
            plan: plan,
            run: run,
            modelContext: context,
            verifierRuntime: AgentUtilityRuntimeConfiguration(
                runtime: .copilotCLI,
                model: "gpt-5",
                copilotPath: fakeCopilot.path,
                copilotHome: (root as NSString).appendingPathComponent("copilot-home")
            )
        )

        #expect(!result.canComplete)
        #expect(result.failedRequiredAssertionIDs == ["verifier-fail"])
        #expect(task.events.contains { $0.type == TaskVerifierEventTypes.completed && $0.payload.contains("\"result\":\"fail\"") })
        #expect(task.events.contains { $0.type == TaskValidationEventTypes.assertionReviewed })
        #expect(task.events.contains { $0.type == TaskValidationEventTypes.assertionFailed && $0.payload.contains("verifier_failed_assertion") })
        #expect(task.events.contains { $0.type == TaskCorrectiveEventTypes.stepCreated && $0.payload.contains("verifier-fail") })
    }

    private func temporaryRoot() throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-validation-service-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func fakeCopilotUtility(in root: String, output: String) throws -> URL {
        let fakeCopilot = URL(fileURLWithPath: root).appendingPathComponent("copilot")
        let escaped = output
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let script = """
        #!/bin/sh
        if [ "$1" = "help" ]; then
          cat <<'HELP'
        --output-format=FORMAT --stream=MODE --no-ask-user --secret-env-vars=VAR
        --allow-all-tools required for non-interactive mode
        HELP
          exit 0
        fi
        printf '%s\\n' '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"\(escaped)"}}'
        exit 0
        """
        try script.write(to: fakeCopilot, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCopilot.path)
        return fakeCopilot
    }
}

import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

private func makeValidationExecutionAuthorityContainer() throws -> ModelContainer {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(
        for: ASTRASchema.current,
        migrationPlan: ASTRAMigrationPlan.self,
        configurations: [config]
    )
}

@Suite("Validation execution authority")
struct ValidationExecutionAuthorityTests {
    @Test("shell validation runner honors an admission-time Off snapshot", arguments: [false, true])
    nonisolated func shellValidationRunnerHonorsOffAdmissionSnapshot(scoped: Bool) async throws {
        guard FileManager.default.isExecutableFile(atPath: ExecutionSandbox.sandboxExecPath) else { return }

        let root = URL(fileURLWithPath: "/var/tmp")
            .appendingPathComponent("astra-validation-off-snapshot-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let outsideWorkspace = root.appendingPathComponent("outside.txt").path

        let result = await ShellValidationCommandRunner(
            sandboxEnforcementSnapshot: .off,
            sandboxSettingsProvider: {
                ExecutionSandboxSettings(enforcement: .strict)
            }
        ).run(
            command: "printf admitted-off > '\(outsideWorkspace)'",
            workingDirectory: workspace.path,
            environment: ProcessInfo.processInfo.environment,
            additionalWritablePaths: [],
            resourceScope: scoped ? TaskExecutionResourceScope(workingDirectory: workspace.path, workspacePath: workspace.path,
                resources: [.init(path: workspace.path, access: .exclusive, role: .execution)]) : nil
        )

        #expect(result.exitCode == 0)
        #expect(FileManager.default.fileExists(atPath: outsideWorkspace))
    }

    @Test("Accepted copy scope confines test and contract commands after live edits")
    @MainActor
    func scopedCopyValidationLifecycle() async throws {
        let source = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: source) }
        let container = try makeValidationExecutionAuthorityContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Copy validation", primaryPath: source)
        let task = AgentTask(title: "Validate copy", goal: "Run tests", workspace: workspace)
        task.isolationStrategy = .copy
        task.validationStrategy = .runTests
        task.testCommand = "make test"
        context.insert(workspace)
        context.insert(task)
        let submitted = try ExecutionRequestSubmissionService.submitInitial(for: task, into: context).get()
        let request = try #require(try TaskTurnRequestRepository.request(id: submitted.requestID, in: context))
        let snapshot = try #require(TaskExecutionLaunchSnapshotApplicator.snapshot(request: request, from: task))
        let scope = try #require(snapshot.resourceScope)
        let copy = scope.workingDirectory
        defer { try? FileManager.default.removeItem(atPath: copy) }
        try FileManager.default.createDirectory(atPath: copy, withIntermediateDirectories: true)
        try "original".write(toFile: source + "/marker", atomically: true, encoding: .utf8)
        try """
        test:
        \t@touch allowed
        \t@if printf changed > '\(source)/marker' 2>/dev/null; then exit 19; fi
        """.write(toFile: copy + "/Makefile", atomically: true, encoding: .utf8)
        task.executionRootPath = source
        task.testCommand = "swift test"
        workspace.additionalPaths = [source]
        let frozen = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: task)
        let runner = ShellValidationCommandRunner(sandboxEnforcementSnapshot: .strict)
        let result = await ValidationService.runTests(task: frozen, commandRunner: runner)
        guard case .passed = result else { Issue.record("Scoped copy validation failed: \(result)"); return }
        #expect(try String(contentsOfFile: source + "/marker", encoding: .utf8) == "original")
        #expect(FileManager.default.fileExists(atPath: copy + "/allowed"))

        let plan = TaskPlanPayload(title: "Proof", goal: "Run scoped tests",
            steps: [TaskPlanPayloadStep(id: "verify", title: "Verify")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(id: "tests", description: "Tests pass", method: .command, command: "make test")
            ]))
        let contract = await ValidationService.runContract(task: task, plan: plan, run: nil,
            modelContext: context, workspacePath: copy, commandRunner: runner, resourceScope: scope)
        #expect(contract.canComplete)
        #expect(try String(contentsOfFile: source + "/marker", encoding: .utf8) == "original")
    }

    @Test("Scoped validation blocks self-sandboxing bypasses and container-to-host fallback")
    @MainActor
    func unsupportedScopedValidationFailsClosed() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "test:\n\t@swift test\n".write(toFile: root + "/Makefile", atomically: true, encoding: .utf8)
        let scope = TaskExecutionResourceScope(workingDirectory: root, workspacePath: root,
            resources: [.init(path: root, access: .exclusive, role: .execution)])
        for enforcement in [ExecutionSandboxEnforcement.strict, .bestEffort] {
            let runner = ShellValidationCommandRunner(sandboxEnforcementSnapshot: enforcement)
            for command in ["swift test", "xcodebuild test", "make test"] {
                let result = await runner.run(command: command, workingDirectory: root,
                    environment: ProcessInfo.processInfo.environment, additionalWritablePaths: [], resourceScope: scope)
                #expect(result.exitCode == -1)
                #expect(result.launchError?.contains("self_sandboxing_toolchain") == true)
            }
        }
        let containerScope = TaskExecutionResourceScope(workingDirectory: root, workspacePath: root,
            resources: scope.resources, executionEnvironment: .init(id: "docker", kind: .dockerImage,
                displayName: "Docker", image: "test:latest"))
        let result = await ShellValidationCommandRunner().run(command: "touch escaped", workingDirectory: root,
            environment: ProcessInfo.processInfo.environment, additionalWritablePaths: [], resourceScope: containerScope)
        #expect(result.launchError?.contains("container_validation_not_supported") == true)
        #expect(!FileManager.default.fileExists(atPath: root + "/escaped"))
        let invalidRoot = TaskExecutionResourceScope(workingDirectory: "/", workspacePath: "/",
            resources: [.init(path: "/", access: .exclusive, role: .execution)])
        let decision = ExecutionSandbox.decideForCommand(executablePath: "/bin/sh", arguments: ["-c", "true"],
            currentDirectory: "/", environment: [:], homeWritableRelativePaths: [], resourceScope: invalidRoot,
            settings: .init(enforcement: .bestEffort))
        guard case .failClosed = decision else { Issue.record("Scoped validation fell back without confinement"); return }
    }

    @Test("validation contract resolves artifacts against the admitted execution root")
    @MainActor
    func validationContractArtifactUsesExecutionRootOverride() async throws {
        let originalRoot = try temporaryRoot()
        let executionRoot = try temporaryRoot()
        defer {
            try? FileManager.default.removeItem(atPath: originalRoot)
            try? FileManager.default.removeItem(atPath: executionRoot)
        }
        try "isolated report".write(
            toFile: (executionRoot as NSString).appendingPathComponent("report.md"),
            atomically: true,
            encoding: .utf8
        )
        let container = try makeValidationExecutionAuthorityContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Isolated Artifact", primaryPath: originalRoot)
        let task = AgentTask(title: "Validate isolated artifact", goal: "Require report.md", workspace: workspace)
        let run = TaskRun(task: task)
        context.insert(workspace)
        context.insert(task)
        context.insert(run)
        let plan = TaskPlanPayload(
            title: "Proof",
            goal: "Require an isolated artifact",
            steps: [TaskPlanPayloadStep(id: "verify", title: "Verify")],
            validationContract: TaskValidationContract(assertions: [
                TaskValidationAssertion(
                    id: "isolated-report",
                    description: "Report exists in the execution root",
                    method: .artifact,
                    path: "report.md"
                )
            ])
        )

        let result = await ValidationService.runContract(
            task: task,
            plan: plan,
            run: run,
            modelContext: context,
            workspacePath: executionRoot
        )

        #expect(result.canComplete)
        let event = try #require(task.events.first {
            $0.type == TaskValidationEventTypes.assertionPassed
        })
        let payload = try JSONDecoder().decode(
            TaskValidationAssertionEventPayload.self,
            from: Data(event.payload.utf8)
        )
        #expect(payload.path == (executionRoot as NSString).appendingPathComponent("report.md"))
    }

    private func temporaryRoot() throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astra-validation-authority-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.path
    }
}

import Foundation
import SwiftData
import Testing
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
    @Test("shell validation runner honors an admission-time Off snapshot")
    nonisolated func shellValidationRunnerHonorsOffAdmissionSnapshot() async throws {
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
            additionalWritablePaths: []
        )

        #expect(result.exitCode == 0)
        #expect(FileManager.default.fileExists(atPath: outsideWorkspace))
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

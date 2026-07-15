import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

private func makeLegacyRuntimeContainer() throws -> ModelContainer {
    let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(
        for: ASTRASchema.current,
        migrationPlan: ASTRAMigrationPlan.self,
        configurations: [configuration]
    )
}

@Suite("Legacy runtime compatibility")
@MainActor
struct AgentRuntimeLegacyCompatibilityTests {
    @Test("Continuation falls back from a removed persisted runtime without crashing")
    func continuationFallsBackFromRemovedPersistedRuntime() async throws {
        let testDir = "/tmp/legacy_runtime_continuation_\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: testDir) }

        let container = try makeLegacyRuntimeContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Legacy Runtime Workspace", primaryPath: testDir)
        let legacyRuntime = try #require(AgentRuntimeID(rawValue: "local_mlx"))
        let task = AgentTask(
            title: "Continue a legacy local-model task",
            goal: "Complete the follow-up with a registered provider",
            workspace: workspace,
            model: "Qwen/Qwen3-4B-MLX-4bit",
            runtime: legacyRuntime
        )
        task.status = .completed
        context.insert(workspace)
        context.insert(task)
        try context.save()

        let fakeRunner = FakeAgentProcessRunner()
        let worker = AgentRuntimeWorker(
            processRunner: fakeRunner,
            providerSettingsSnapshotProvider: { .headlessScenario }
        )
        worker.runtimeReadinessService = RuntimeReadinessService(runner: InstantSuccessBinaryRunner())
        worker.skipPermissions = true
        worker.permissionPolicy = .autonomous
        worker.defaultAgentPolicyLevelRaw = AgentPolicyLevel.autonomous.rawValue
        worker.defaultRuntimeID = .codexCLI
        worker.setExecutablePath("/bin/sh", for: .codexCLI)

        DirectWorkerLaunchAdmission.admitContinuation(task, modelContext: context)
        await worker.continueSession(
            task: task,
            message: "Continue with the available provider.",
            modelContext: context
        ) { _ in }

        #expect(fakeRunner.receivedTaskIDs == [task.id])
        #expect(task.runtimeID == AgentRuntimeID.codexCLI.rawValue)
        #expect(task.runs.last?.runtimeID == AgentRuntimeID.codexCLI.rawValue)
        #expect(task.status == .pendingUser)
    }
}

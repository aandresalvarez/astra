import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Runtime cancellation diagnostics")
@MainActor
struct RuntimeCancellationDiagnosticTests {
    @Test("A user-cancelled process is never recorded as a provider failure", arguments: [false, true], [false, true])
    func userCancellationDoesNotInventProviderError(durableStatusOnly: Bool, beforeLaunch: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-cancel-diagnostic-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let workspace = Workspace(name: "Cancel fixture", primaryPath: root.path)
        let task = AgentTask(title: "Cancel fixture", goal: "Return a short response", workspace: workspace)
        task.status = .queued
        context.insert(workspace)
        context.insert(task)
        try context.save()
        let runner = FakeAgentProcessRunner()
        runner.result = AgentProcessResult(exitCode: 143)
        let worker = AgentRuntimeWorker(processRunner: runner, providerSettingsSnapshotProvider: { .headlessScenario })
        worker.runtimeReadinessService = RuntimeReadinessService(runner: InstantSuccessBinaryRunner())
        worker.skipPermissions = true
        worker.permissionPolicy = .autonomous
        worker.defaultAgentPolicyLevelRaw = AgentPolicyLevel.autonomous.rawValue
        worker.claudePath = "/bin/sh"
        if !beforeLaunch {
            runner.onLaunch = { _, _ in
                if !durableStatusOnly { worker.cancel() }
                task.status = .cancelled
            }
        }
        DirectWorkerLaunchAdmission.admitInitialRun(task, modelContext: context)
        let execution = Task { await worker.execute(task: task, modelContext: context) { _ in } }
        if beforeLaunch {
            for _ in 0..<1_000 {
                if worker.isRunning { break }
                await Task.yield()
            }
            #expect(worker.isRunning)
            if !durableStatusOnly { worker.cancel() }
            task.status = .cancelled
        }
        await execution.value
        if beforeLaunch { #expect(runner.receivedTaskIDs.isEmpty) }
        AppLogger.flushForTesting()
        let messages = AppLogger.entries.filter { $0.taskID == task.id }.map(\.message)
        #expect(task.status == .cancelled)
        #expect(!messages.contains { $0.contains("runtime.failure_diagnostic") })
    }
}

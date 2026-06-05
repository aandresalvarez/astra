import Foundation
import SwiftData
import Testing
@testable import ASTRA
import ASTRACore

/// Covers `TaskLifecycleCoordinator.resumeTask`, the UI "continue where you left
/// off" path. The continuation is driven through a zero-size `TaskQueue` pool so
/// no real provider process is launched: `TaskQueue.continueSession` finds no
/// available worker and returns immediately, leaving only the deterministic,
/// synchronous resume bookkeeping to assert.
@Suite("Task resume continuation (HITL)")
@MainActor
struct TaskLifecycleResumeTests {

    private struct Environment {
        let coordinator: TaskLifecycleCoordinator
        let context: ModelContext
        let container: ModelContainer
        let root: String
    }

    private func makeEnvironment() throws -> Environment {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-resume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let queue = TaskQueue(poolSize: 0)
        let coordinator = TaskLifecycleCoordinator(modelContext: context, taskQueue: queue)
        return Environment(coordinator: coordinator, context: context, container: container, root: url.path)
    }

    @Test("Resume without a session id does not start a continuation")
    func resumeWithoutSessionIDDoesNotStart() throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(atPath: env.root) }

        let workspace = Workspace(name: "Resume Guard", primaryPath: env.root)
        let task = AgentTask(title: "Guard", goal: "Finish later", workspace: workspace)
        task.status = .completed
        task.sessionId = nil
        env.context.insert(workspace)
        env.context.insert(task)

        env.coordinator.resumeTask(task)

        #expect(task.status == .completed)
        #expect(task.events.contains { $0.type == "task.resumed" } == false)
    }

    @Test("Resume with a session id marks running and records a resume event")
    func resumeWithSessionIDMarksRunningAndRecordsEvent() async throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(atPath: env.root) }

        let workspace = Workspace(name: "Resume", primaryPath: env.root)
        let task = AgentTask(title: "Resume", goal: "Complete the original goal", workspace: workspace)
        task.status = .pendingUser
        task.sessionId = "sess-resume-123"
        env.context.insert(workspace)
        env.context.insert(task)

        env.coordinator.resumeTask(task)

        // resumeTask performs these mutations synchronously, before the
        // continuation Task is scheduled, so they are deterministic to assert.
        #expect(task.status == .running)
        let resumeEvents = task.events.filter { $0.type == "task.resumed" }
        #expect(resumeEvents.count == 1)
        #expect(resumeEvents.first?.payload.contains("Resuming previous session") == true)

        // Let the scheduled continuation run; with a zero-size pool it returns
        // without launching a provider. Keeps the container alive until drained.
        await Task.yield()
        _ = env.container
    }

    @Test("Resume continuation uses the canonical continue message")
    func resumeContinuationMessageIsStable() {
        #expect(
            TaskLifecycleCoordinator.resumeContinuationMessage
                == "Continue where you left off. Complete the original goal."
        )
    }
}

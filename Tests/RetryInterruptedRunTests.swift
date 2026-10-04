import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA
import ASTRACore

/// Retry on a run the user (or an ASTRA restart) cut short should pick the
/// provider session back up. The queue has no workers, so only the durable
/// launch decision is asserted: which mode and message the retry submitted.
@Suite("Retry of an interrupted run")
@MainActor
struct RetryInterruptedRunTests {
    private struct Environment {
        let coordinator: TaskLifecycleCoordinator
        let queue: TaskQueue
        let context: ModelContext
        let container: ModelContainer
        let root: String
    }

    private func makeEnvironment() throws -> Environment {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-retry-interrupted-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let queue = TaskQueue(poolSize: 0)
        return Environment(
            coordinator: TaskLifecycleCoordinator(modelContext: context, taskQueue: queue),
            queue: queue, context: context, container: container, root: url.path
        )
    }

    private struct Submitted {
        let mode: TaskExecutionLaunchMode
        let message: String?
        let task: AgentTask
    }

    /// Builds a task whose only run ended with `stopReason`, retries it, and
    /// reports what the retry submitted.
    private func retry(
        runtime: AgentRuntimeID = .claudeCode,
        sessionID: String? = "claude-session-1",
        stopReason: String,
        followUp: String? = nil
    ) async throws -> Submitted {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(atPath: env.root) }
        let workspace = Workspace(name: "Retry Interrupted", primaryPath: env.root)
        let task = AgentTask(title: "Interrupted", goal: "Build the report", workspace: workspace, runtime: runtime)
        task.status = .cancelled
        task.sessionId = sessionID
        task.tokensUsed = 500
        env.context.insert(workspace)
        env.context.insert(task)
        let run = TaskRun(task: task)
        run.status = .cancelled
        run.stopReason = stopReason
        run.completedAt = Date()
        env.context.insert(run)
        if let followUp {
            env.context.insert(TaskEvent(
                task: task, eventType: TaskEventTypes.Conversation.userMessage, payload: followUp, run: run
            ))
        }
        try env.context.save()

        let handle = env.coordinator.retryTask(task)
        await Task.yield()
        let request = try #require(try TaskTurnRequestRepository.requests(for: task, in: env.context).last)
        let sourceEvent = try #require(task.events.first { $0.id == request.sourceEventID })
        let source = try #require(ExecutionRequestSubmissionService.decodeSourcePayload(sourceEvent))
        env.queue.cancelTurnRequest(id: request.id, workspace: workspace, modelContext: env.context)
        await handle?.value
        return Submitted(mode: source.launchMode, message: source.message, task: task)
    }

    @Test("A user-cancelled first run is retried as a continuation of its session")
    func cancelledRunResumes() async throws {
        let submitted = try await retry(stopReason: "cancelled")
        #expect(submitted.mode == .continuation)
        #expect(submitted.message?.hasPrefix("Continue where you left off") == true)
        // A continuation keeps the budget the interrupted run already spent.
        #expect(submitted.task.tokensUsed == 500)
        #expect(submitted.task.events.contains {
            $0.type == "task.retried" && $0.payload.contains("resuming the previous session")
        })
    }

    @Test("A run interrupted by an ASTRA restart or a queue stop resumes too")
    func restartAndQueueStopResume() async throws {
        for reason in ["app_restarted", "queue_cancelled"] {
            let submitted = try await retry(stopReason: reason)
            #expect(submitted.mode == .continuation, "\(reason)")
        }
    }

    @Test("Without a provider session Retry still relaunches from scratch")
    func noSessionRelaunches() async throws {
        let submitted = try await retry(sessionID: nil, stopReason: "cancelled")
        #expect(submitted.mode == .initial)
        #expect(submitted.message == nil)
        #expect(submitted.task.tokensUsed == 0)
    }

    @Test("A failed run keeps its from-scratch Retry; Resume is the continuation action")
    func failedRunStillRelaunches() async throws {
        let submitted = try await retry(stopReason: "failed")
        #expect(submitted.mode == .initial)
    }

    @Test("A runtime with no native resume keeps its from-scratch Retry")
    func runtimeWithoutNativeResumeRelaunches() async throws {
        let submitted = try await retry(runtime: .openCodeCLI, sessionID: "oc-1", stopReason: "cancelled")
        #expect(submitted.mode == .initial)
    }

    @Test("A pending user follow-up still wins over the generic resume message")
    func followUpTakesPrecedence() async throws {
        let submitted = try await retry(stopReason: "cancelled", followUp: "now also add a chart")
        #expect(submitted.mode == .continuation)
        #expect(submitted.message == "now also add a chart")
    }
}

import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Claimless execution request admission", .serialized)
@MainActor
struct TaskExecutionResourceAdmissionQueueTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    /// A workspace-less task resolves to no resource claims at all. Admission
    /// policy accepts that empty set, so the queue's lease path has to let the
    /// request through to runtime preflight: rejecting it there left the
    /// request active forever while the scheduler redispatched it every pass.
    @Test("A claimless request passes the lease path and reaches a terminal state")
    func claimlessRequestReachesRuntimeAdmission() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let task = AgentTask(title: "No workspace", goal: "Summarize the current state.")
        // Runtime admission rejects a task that is no longer queued, which
        // terminalizes the request before any worker starts provider work —
        // keeping this a queue-path assertion rather than a runtime launch.
        task.status = .completed
        context.insert(task)
        let request = TaskTurnRequest(
            task: task,
            messageEventID: UUID(),
            sequence: 1,
            kind: .initial
        )
        context.insert(request)
        try context.save()

        #expect(TaskExecutionResourceClaimResolver.claims(for: task).isEmpty)
        #expect(TaskExecutionResourceClaimResolver.admissionClaims(for: request, task: task).isEmpty)

        let queue = TaskQueue(poolSize: 1)
        let projection = try ExecutionRequestAdmissionScheduler.projection(in: context)
        let candidate = try #require(projection.ordered.first)
        #expect(queue.canAdmitResourceClaims(
            for: candidate,
            in: projection,
            dispatchedRequestIDs: [],
            activeTaskIDs: []
        ))

        await queue.executeTask(task, modelContext: context, executionRequestID: request.id)

        #expect(!request.state.isActive)
        #expect(request.state == .failed)
        #expect(request.terminalReason == "task_not_queued")
        #expect(queue.activeTasks.isEmpty)
        #expect(queue.worker(for: task) == nil)
        #expect(queue.activeResourceLocks.isEmpty)
    }
}

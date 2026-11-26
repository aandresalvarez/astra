import Foundation
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
import SwiftData
@testable import ASTRA

/// A full ownership read asks the release rule for every saved reservation and
/// then reads every journal and every ownership event in the store, on the main
/// actor. Its cost grows with the store's history, so a queue entry point does
/// not repeat a read made a moment earlier in the same main-actor job. Sending
/// a new task used to read three times before it returned, a follow-up twice,
/// and an admission pass twice.
@Suite("Ownership reads per queue entry", .serialized)
@MainActor
struct TaskQueueOwnershipReadTests {
    private func queuedTask() throws -> (container: ModelContainer, context: ModelContext, task: AgentTask, requestID: UUID) {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Ownership reads", primaryPath: "/tmp")
        let task = AgentTask(title: "Queued", goal: "Send me", workspace: workspace)
        task.status = .queued
        context.insert(workspace)
        context.insert(task)
        let submission = try #require(
            try? ExecutionRequestSubmissionService.submitInitial(for: task, into: context).get()
        )
        return (container, context, task, submission.requestID)
    }

    @Test("Sending a task reads ownership once before it returns, not once per entry point it passes")
    func sendingATaskReadsOwnershipOnce() async throws {
        let fixture = try queuedTask()
        defer { _ = fixture.container }
        // No workers: nothing dispatches, so every read counted here is one a
        // queue entry point made on its own account.
        let queue = TaskQueue(poolSize: 0)

        // The first bind reads, whoever makes it: the queue has no ownership yet.
        _ = queue.registerLifecycleTask(modelContext: fixture.context) { _ in }
        #expect(queue.observedOwnershipReadCount == 1)

        // One press of Send, as `TaskLifecycleCoordinator.runSingleTask` makes
        // it: the signal, then the lifecycle work that waits for the run.
        _ = queue.signalExecutionRequest(id: fixture.requestID, task: fixture.task, modelContext: fixture.context)
        // The signal went all the way: it started the loop, without a second read.
        #expect(queue.hasProcessingLoop)
        #expect(queue.observedOwnershipReadCount == 2)
        _ = queue.registerLifecycleTask(modelContext: fixture.context) { _ in }
        #expect(queue.observedOwnershipReadCount == 2,
                "the signal reads; the loop it starts and the lifecycle registration that follows do not read again")

        #expect(await queue.cancelAllAndWait())
    }

    @Test("An entry point that dispatches or admits on its own still reads ownership every time")
    func dispatchingAndAdmittingEntryPointsStillRead() async throws {
        let fixture = try queuedTask()
        defer { _ = fixture.container }
        let queue = TaskQueue(poolSize: 0)
        _ = queue.processQueueIfIdle(modelContext: fixture.context)
        let bound = queue.observedOwnershipReadCount
        #expect(bound == 1)

        _ = queue.processQueueIfIdle(modelContext: fixture.context)
        #expect(queue.observedOwnershipReadCount == bound + 1)

        // The read an admission pass relies on: the acquire makes it itself,
        // whatever it then decides.
        _ = queue.acquireResourceLocksIfAvailable([], task: fixture.task, modelContext: fixture.context)
        #expect(queue.observedOwnershipReadCount == bound + 2)

        #expect(await queue.cancelAllAndWait())
    }

    @Test("A bind that would skip the read still reads when the last read failed")
    func aFailedReadIsAskedAgainByTheNextBind() async throws {
        let fixture = try queuedTask()
        defer { _ = fixture.container }
        let queue = TaskQueue(poolSize: 0)
        _ = queue.registerLifecycleTask(modelContext: fixture.context) { _ in }
        let bound = queue.observedOwnershipReadCount
        // A read that failed leaves the last known holds in place and admits
        // nothing. The entry point that follows it used to read again, which
        // is what cleared a failure that did not last.
        queue.resourceOwnershipReadFailed = true

        _ = queue.registerLifecycleTask(modelContext: fixture.context) { _ in }

        #expect(queue.observedOwnershipReadCount == bound + 1)
        #expect(!queue.resourceOwnershipReadFailed)
        #expect(await queue.cancelAllAndWait())
    }

    @Test("Source check: an admission pass leaves the ownership read to the acquire it calls")
    func admissionPassDoesNotReadTwice() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Astra/Services/Tasks/TaskQueue.swift"), encoding: .utf8)
        let start = try #require(source.range(of: "    private func waitForResourceLocks("))
        let end = try #require(source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex))
        let pass = source[start.upperBound..<end.lowerBound]
        #expect(pass.contains("if let acquired = acquireResourceLocksIfAvailable("))
        #expect(!pass.contains("refreshResourceOwnership("))
    }
}

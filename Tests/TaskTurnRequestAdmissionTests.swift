import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Durable task-turn admission")
@MainActor
struct TaskTurnRequestAdmissionTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    private func makeWorkspaceRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-turn-admission-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func waitUntil(
        _ predicate: @escaping () -> Bool
    ) async -> Bool {
        for _ in 0..<100 where !predicate() {
            await Task.yield()
        }
        return predicate()
    }

    @Test("same-task turn requests wait FIFO before competing for a workspace lock")
    func sameTaskRequestsWaitFIFO() async throws {
        let root = try makeWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try makeContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "FIFO", primaryPath: root.path)
        let task = AgentTask(title: "Task", goal: "Continue", workspace: workspace)
        let holder = AgentTask(title: "Holder", goal: "Hold lock", workspace: workspace)
        context.insert(workspace)
        context.insert(task)
        context.insert(holder)

        let firstSubmission = try #require(TaskTurnSubmissionService.submit(
            message: "First follow-up",
            for: task,
            into: context
        ).successValue)
        let secondSubmission = try #require(TaskTurnSubmissionService.submit(
            message: "Second follow-up",
            for: task,
            into: context
        ).successValue)
        let requests = try TaskTurnRequestRepository.requests(for: task, in: context)
        let first = try #require(requests.first { $0.id == firstSubmission.requestID })
        let second = try #require(requests.first { $0.id == secondSubmission.requestID })

        let queue = TaskQueue(poolSize: 1)
        let lock = try #require(queue.acquireResourceLockIfAvailable(
            task: holder,
            accessMode: .write,
            runMode: "test"
        ))
        let firstAdmission = Task { @MainActor in
            await queue.continueSession(
                task: task,
                message: "First follow-up",
                existingMessageEventID: firstSubmission.eventID,
                turnRequestID: firstSubmission.requestID,
                modelContext: context
            )
        }
        let firstIsWaitingForResource = await waitUntil { first.state == .waitingForResource }
        #expect(firstIsWaitingForResource)

        let secondAdmission = Task { @MainActor in
            await queue.continueSession(
                task: task,
                message: "Second follow-up",
                existingMessageEventID: secondSubmission.eventID,
                turnRequestID: secondSubmission.requestID,
                modelContext: context
            )
        }
        let secondIsWaitingForFirst = await waitUntil {
            second.state == .waitingForWorker
                && second.blockerSummary == "Waiting for an earlier message in this task."
        }
        #expect(secondIsWaitingForFirst)

        queue.cancel(task: task, modelContext: context)
        queue.releaseResourceLock(lock, task: holder, modelContext: context)
        _ = await firstAdmission.value
        _ = await secondAdmission.value

        #expect(first.state == .cancelled)
        #expect(second.state == .cancelled)
    }

    @Test("startup recovery turns stale admission state into replayable or terminal state")
    func startupRecoveryReconcilesActiveRequests() throws {
        let root = try makeWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try makeContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Recovery", primaryPath: root.path)
        let task = AgentTask(title: "Task", goal: "Continue", workspace: workspace)
        context.insert(workspace)
        context.insert(task)

        let waiting = try #require(TaskTurnSubmissionService.submit(
            message: "Wait for worker",
            for: task,
            into: context
        ).successValue)
        let running = try #require(TaskTurnSubmissionService.submit(
            message: "Interrupted run",
            for: task,
            into: context
        ).successValue)
        let requests = try TaskTurnRequestRepository.requests(for: task, in: context)
        let waitingRequest = try #require(requests.first { $0.id == waiting.requestID })
        let runningRequest = try #require(requests.first { $0.id == running.requestID })
        _ = TaskTurnRequestStateMachine.transition(waitingRequest, to: .waitingForResource)
        _ = TaskTurnRequestStateMachine.transition(runningRequest, to: .admitted)
        _ = TaskTurnRequestStateMachine.transition(runningRequest, to: .running)

        let summary = TaskTurnRequestRecoveryService.recoverInterruptedRequests(
            modelContext: context,
            at: Date(timeIntervalSince1970: 123)
        )

        #expect(summary.returnedToWaiting == 1)
        #expect(summary.terminalized == 1)
        #expect(waitingRequest.state == .waitingForWorker)
        #expect(runningRequest.state == .failed)
        #expect(runningRequest.terminalReason == "app_restarted")
    }
}

private extension Result where Failure == TaskTurnSubmissionService.SubmissionError {
    var successValue: Success? {
        guard case let .success(value) = self else { return nil }
        return value
    }
}

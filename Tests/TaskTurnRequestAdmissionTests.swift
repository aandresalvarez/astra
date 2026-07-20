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

    @Test("Cancelling one waiting turn request leaves the task's status untouched")
    func cancelTurnRequestPreservesTaskStatus() async throws {
        let root = try makeWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try makeContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Cancel", primaryPath: root.path)
        let task = AgentTask(title: "Task", goal: "Continue", workspace: workspace)
        task.status = .completed
        context.insert(workspace)
        context.insert(task)

        let submission = try #require(TaskTurnSubmissionService.submit(
            message: "Queued follow-up",
            for: task,
            into: context
        ).successValue)
        let request = try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: context))

        let queue = TaskQueue(poolSize: 0)
        let admission = Task { @MainActor in
            await queue.continueSession(
                task: task,
                message: "Queued follow-up",
                existingMessageEventID: submission.eventID,
                turnRequestID: submission.requestID,
                modelContext: context
            )
        }
        let isWaitingForWorker = await waitUntil {
            request.blockerSummary == "Waiting for an available worker."
        }
        #expect(isWaitingForWorker)

        queue.cancelTurnRequest(id: submission.requestID, workspace: workspace, modelContext: context)
        let started = await admission.value

        #expect(!started)
        #expect(request.state == .cancelled)
        #expect(request.terminalReason == "cancelled_by_user")
        #expect(task.status == .completed)
    }

    @Test("A follow-up parks while the same task's current run holds its worker")
    func followUpWaitsWhileSameTaskRunIsActive() async throws {
        let root = try makeWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try makeContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "BusyWorker", primaryPath: root.path)
        let task = AgentTask(title: "Task", goal: "Continue", workspace: workspace)
        task.status = .running
        context.insert(workspace)
        context.insert(task)

        let submission = try #require(TaskTurnSubmissionService.submit(
            message: "Follow-up while running",
            for: task,
            into: context
        ).successValue)
        let request = try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: context))

        // Two workers: an idle one keeps `hasAvailableWorker` true, exactly
        // the shape where admission used to select the task's busy mapped
        // worker and fail the saved turn as `runtime_not_started`.
        let queue = TaskQueue(poolSize: 2)
        queue.activeTasks.insert(task.id)

        let admission = Task { @MainActor in
            await queue.continueSession(
                task: task,
                message: "Follow-up while running",
                existingMessageEventID: submission.eventID,
                turnRequestID: submission.requestID,
                modelContext: context
            )
        }
        let parkedBehindOwnRun = await waitUntil {
            request.blockerSummary == "Waiting for the current run in this task to finish."
        }
        #expect(parkedBehindOwnRun)
        #expect(request.state == .waitingForWorker)

        queue.cancelTurnRequest(id: submission.requestID, workspace: workspace, modelContext: context)
        let started = await admission.value

        #expect(!started)
        #expect(request.state == .cancelled)
        queue.activeTasks.remove(task.id)
    }

    @Test("Queue-owned task deletion cancels and removes the task's turn requests")
    func queueTaskDeletionCleansUpTurnRequests() async throws {
        let root = try makeWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try makeContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "ScheduleMerge", primaryPath: root.path)
        let task = AgentTask(title: "Scheduled", goal: "Run on schedule", workspace: workspace)
        context.insert(workspace)
        context.insert(task)

        let submission = try #require(TaskTurnSubmissionService.submit(
            message: "Follow-up to a scheduled task",
            for: task,
            into: context
        ).successValue)
        let request = try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: context))
        #expect(request.state.isActive)

        let queue = TaskQueue(poolSize: 1)
        queue.cancelAndRemoveTurnRequests(for: task, modelContext: context)

        let remaining = try TaskTurnRequestRepository.requests(for: task, in: context)
        #expect(remaining.isEmpty)
    }

    @Test("Presentation fetches stay bounded to active plus visible-window requests")
    func presentationRequestsAreBounded() throws {
        let root = try makeWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try makeContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Bounded", primaryPath: root.path)
        let task = AgentTask(title: "Task", goal: "Continue", workspace: workspace)
        context.insert(workspace)
        context.insert(task)

        let offWindowTerminal = try #require(TaskTurnSubmissionService.submit(
            message: "Old completed turn", for: task, into: context
        ).successValue)
        let inWindowTerminal = try #require(TaskTurnSubmissionService.submit(
            message: "Visible failed turn", for: task, into: context
        ).successValue)
        let active = try #require(TaskTurnSubmissionService.submit(
            message: "Still waiting", for: task, into: context
        ).successValue)
        let requests = try TaskTurnRequestRepository.requests(for: task, in: context)
        let first = try #require(requests.first { $0.id == offWindowTerminal.requestID })
        let second = try #require(requests.first { $0.id == inWindowTerminal.requestID })
        _ = TaskTurnRequestStateMachine.transition(first, to: .admitted)
        _ = TaskTurnRequestStateMachine.transition(first, to: .running)
        _ = TaskTurnRequestStateMachine.transition(first, to: .completed)
        _ = TaskTurnRequestStateMachine.transition(second, to: .failed)

        let bounded = try TaskTurnRequestRepository.presentationRequests(
            for: task,
            visibleMessageEventIDs: [inWindowTerminal.eventID],
            in: context
        )
        #expect(bounded.map(\.id) == [inWindowTerminal.requestID, active.requestID])

        let activeOnly = try TaskTurnRequestRepository.activeRequests(for: task, in: context)
        #expect(activeOnly.map(\.id) == [active.requestID])
    }

    @Test("Stopping the queue terminalizes parked durable admissions")
    func cancelAllStopsParkedAdmissions() async throws {
        let root = try makeWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try makeContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "StopQueue", primaryPath: root.path)
        let task = AgentTask(title: "Task", goal: "Continue", workspace: workspace)
        task.status = .completed
        context.insert(workspace)
        context.insert(task)

        let submission = try #require(TaskTurnSubmissionService.submit(
            message: "Parked follow-up",
            for: task,
            into: context
        ).successValue)
        let request = try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: context))

        let queue = TaskQueue(poolSize: 0)
        let admission = Task { @MainActor in
            await queue.continueSession(
                task: task,
                message: "Parked follow-up",
                existingMessageEventID: submission.eventID,
                turnRequestID: submission.requestID,
                modelContext: context
            )
        }
        let isParked = await waitUntil {
            request.blockerSummary == "Waiting for an available worker."
        }
        #expect(isParked)

        queue.cancelAll()
        let started = await admission.value

        #expect(!started)
        #expect(request.state == .cancelled)
        #expect(request.terminalReason == "admission_cancelled")
    }

    @Test("Pending turn messages stay invisible to objective resolution until admitted")
    func pendingTurnMessagesStayInvisibleUntilAdmitted() throws {
        let root = try makeWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try makeContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Visibility", primaryPath: root.path)
        let task = AgentTask(title: "Task", goal: "Summarize the report", workspace: workspace)
        context.insert(workspace)
        context.insert(task)
        // Seed message so both durable turns are follow-ups, not the pinned
        // starting request.
        context.insert(TaskEvent(
            task: task,
            eventType: TaskEventTypes.Conversation.userMessage,
            payload: "Summarize the report"
        ))

        let firstTurn = try #require(TaskTurnSubmissionService.submit(
            message: "Add an executive summary", for: task, into: context
        ).successValue)
        let secondTurn = try #require(TaskTurnSubmissionService.submit(
            message: "new goal is to translate the report to French", for: task, into: context
        ).successValue)
        let requests = try TaskTurnRequestRepository.requests(for: task, in: context)
        let first = try #require(requests.first { $0.id == firstTurn.requestID })
        let second = try #require(requests.first { $0.id == secondTurn.requestID })

        // Turn 1 is being prompted; turn 2 is durable but not yet admitted.
        _ = TaskTurnRequestStateMachine.transition(first, to: .admitted)
        #expect(TaskPendingTurnMessageVisibility.pendingMessageEventIDs(for: task) == [secondTurn.eventID])

        let whilePending = TaskContextStateManager.activeObjectiveResolution(
            for: task,
            planState: .empty,
            startingRequest: task.goal,
            approvedGoal: nil
        )
        #expect(whilePending.hasExplicitOverride == false)
        #expect(!whilePending.objective.localizedCaseInsensitiveContains("French"))

        // Once turn 2 is admitted its message becomes visible context.
        _ = TaskTurnRequestStateMachine.transition(first, to: .running)
        _ = TaskTurnRequestStateMachine.transition(first, to: .completed)
        _ = TaskTurnRequestStateMachine.transition(second, to: .admitted)
        #expect(TaskPendingTurnMessageVisibility.pendingMessageEventIDs(for: task).isEmpty)

        let afterAdmission = TaskContextStateManager.activeObjectiveResolution(
            for: task,
            planState: .empty,
            startingRequest: task.goal,
            approvedGoal: nil
        )
        #expect(afterAdmission.hasExplicitOverride)
        #expect(afterAdmission.objective.localizedCaseInsensitiveContains("French"))
    }
}

private extension Result where Failure == TaskTurnSubmissionService.SubmissionError {
    var successValue: Success? {
        guard case let .success(value) = self else { return nil }
        return value
    }
}

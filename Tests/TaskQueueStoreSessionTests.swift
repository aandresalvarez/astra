import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
import WorkspaceToolSupport
@testable import ASTRA

@Suite("Task queue store lifetime")
@MainActor
struct TaskQueueStoreSessionTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    @Test("A batch of durable SSH acknowledgements refreshes and wakes once without losing later changes")
    func remoteAcknowledgementsCoalesce() async throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Synthetic acknowledgements", model: "test")
        task.status = .completed
        try h.context.save()
        let jobs = RemoteWorkspaceJobStore(rootPath: h.rootURL.appendingPathComponent("acknowledged-jobs").path)
        let queue = TaskQueue(poolSize: 0)
        await queue.processQueue(modelContext: h.context)
        let wakes = queue.observedDispatchWakeCount
        var delivered = Set<UUID>()
        var firstJobID: String?
        for _ in 0..<200 {
            let job = RemoteWorkspaceJobRecord(jobID: UUID().uuidString.lowercased(), taskID: task.id.uuidString,
                connection: .init(id: "fixture", name: "Fixture", target: "fixture", arguments: ["fixture"]),
                command: "true", createdAt: Date())
            firstJobID = firstJobID ?? job.jobID
            try jobs.create(job)
            let saved = try jobs.update(jobID: job.jobID) { $0.requestCancellation(at: Date()) }
            delivered.formUnion((saved.pendingTransitions ?? []).map(\.id))
            try RemoteWorkspaceJobEventReconciler.reconcile(saved, task: task, context: h.context, store: jobs)
        }
        #expect(queue.remoteAdmissionRefresh.isPending)
        #expect(queue.remoteAdmissionRefresh.completedRefreshCount == 0)
        #expect(queue.observedDispatchWakeCount == wakes)
        #expect(try jobs.records().allSatisfy { $0.pendingTransitions?.isEmpty == true })
        #expect(delivered.isSubset(of: Set(task.events.map(\.id))))
        for _ in 0..<100 where queue.remoteAdmissionRefresh.isPending { await Task.yield() }
        #expect(!queue.remoteAdmissionRefresh.isPending)
        #expect(queue.remoteAdmissionRefresh.completedRefreshCount == 1)
        #expect(queue.observedDispatchWakeCount == wakes + 1)
        #expect(queue.ownedCoroutineCount == 0)

        // A later committed transition receives its own refresh; the prior
        // batch's pending identity cannot suppress it.
        let jobID = try #require(firstJobID)
        let later = try jobs.update(jobID: jobID) { $0.status = .cancelled }
        try RemoteWorkspaceJobEventReconciler.reconcile(later, task: task, context: h.context, store: jobs)
        #expect(queue.remoteAdmissionRefresh.isPending)
        for _ in 0..<100 where queue.remoteAdmissionRefresh.isPending { await Task.yield() }
        #expect(queue.remoteAdmissionRefresh.completedRefreshCount == 2)
        #expect(queue.observedDispatchWakeCount == wakes + 2)
        #expect(try jobs.load(jobID: jobID).pendingTransitions?.isEmpty == true)
        #expect(await queue.cancelAllAndWait())
    }

    @Test("Shutdown drains a pending SSH refresh and releases its borrowed context before rebinding")
    func shutdownDrainsRemoteRefresh() async throws {
        let container = try makeContainer()
        let queue = TaskQueue(poolSize: 0)
        weak var borrowed: ModelContext?
        autoreleasepool {
            let context = ModelContext(container)
            borrowed = context
            _ = queue.processQueueIfIdle(modelContext: context)
            NotificationCenter.default.post(name: RemoteWorkspaceJobEventReconciler.admissionDidChange, object: context)
        }
        #expect(queue.remoteAdmissionRefresh.isPending && borrowed != nil)
        #expect(queue.ownedCoroutineCount == 2) // processing plus the coalesced lifecycle task
        #expect(await queue.cancelAllAndWait())
        #expect(!queue.remoteAdmissionRefresh.isPending && !queue.hasBoundStoreSession)
        #expect(queue.remoteAdmissionRefresh.completedRefreshCount == 0 && queue.ownedCoroutineCount == 0)
        #expect(borrowed == nil)

        let replacement = ModelContext(container)
        await queue.processQueue(modelContext: replacement)
        NotificationCenter.default.post(name: RemoteWorkspaceJobEventReconciler.admissionDidChange, object: replacement)
        for _ in 0..<100 where queue.remoteAdmissionRefresh.isPending { await Task.yield() }
        #expect(queue.remoteAdmissionRefresh.completedRefreshCount == 1)
        #expect(await queue.cancelAllAndWait())
    }

    @Test("Legacy request repair runs once per bound store session")
    func legacyRepairRunsOncePerSession() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let root = "/tmp/legacy-repair-\(UUID())"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let workspace = Workspace(name: "Legacy repair", primaryPath: root)
        let first = AgentTask(title: "First legacy", goal: "First", workspace: workspace)
        first.status = .queued
        context.insert(workspace)
        context.insert(first)
        try context.save()

        let session = TaskQueueStoreSession(modelContext: context)
        let firstReport = try #require(session.repairLegacyRequestsIfNeeded())
        #expect(firstReport.failedRequestCount == 0, "\(firstReport.failureReasons)")
        #expect(session.didRepairLegacyRequests)
        #expect(try TaskTurnRequestRepository.activeRequests(for: first, in: context).count == 1)

        let second = AgentTask(title: "Later modern task", goal: "Second", workspace: workspace)
        second.status = .queued
        context.insert(second)
        try context.save()

        session.repairLegacyRequestsIfNeeded()
        #expect(try TaskTurnRequestRepository.activeRequests(for: second, in: context).isEmpty)

        // Re-opening a queue/store session is the explicit compatibility
        // boundary at which imported legacy state may be repaired again.
        TaskQueueStoreSession(modelContext: context).repairLegacyRequestsIfNeeded()
        #expect(try TaskTurnRequestRepository.activeRequests(for: second, in: context).count == 1)
    }

    @Test("Failed legacy repair is not retried within the bound store session")
    func failedLegacyRepairRunsOncePerSession() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-repair-file-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let workspace = Workspace(name: "Broken legacy repair", primaryPath: fileURL.path)
        let task = AgentTask(title: "Legacy task", goal: "Repair once", workspace: workspace)
        task.status = .queued
        context.insert(workspace)
        context.insert(task)
        try context.save()

        let session = TaskQueueStoreSession(modelContext: context)
        let firstReport = try #require(session.repairLegacyRequestsIfNeeded())
        #expect(firstReport.isComplete == false)
        #expect(firstReport.failedRequestCount == 1)
        #expect(session.didAttemptLegacyRequestsRepair)
        #expect(!session.didRepairLegacyRequests)

        #expect(session.repairLegacyRequestsIfNeeded() == nil)
        #expect(try TaskTurnRequestRepository.requests(for: task, in: context).isEmpty)
    }

    @Test("Rebinding never resurrects a cancelled modern request")
    func cancelledRequestIsNotLegacyAfterRebind() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let root = "/tmp/cancelled-request-repair-\(UUID())"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let workspace = Workspace(name: "Cancelled modern", primaryPath: root)
        let task = AgentTask(title: "Cancelled modern", goal: "Do not resurrect", workspace: workspace)
        task.status = .queued
        context.insert(workspace)
        context.insert(task)
        try context.save()

        TaskQueueStoreSession(modelContext: context).repairLegacyRequestsIfNeeded()
        let request = try #require(try TaskTurnRequestRepository.requests(for: task, in: context).first)
        _ = TaskTurnRequestStateMachine.transition(request, to: .cancelled, terminalReason: "queue_cancelled")
        try context.save()

        TaskQueueStoreSession(modelContext: context).repairLegacyRequestsIfNeeded()
        #expect(try TaskTurnRequestRepository.requests(for: task, in: context).count == 1)
        #expect(try TaskTurnRequestRepository.activeRequests(for: task, in: context).isEmpty)
    }

    @Test("Awaited shutdown releases the store only after the processing task drains")
    func shutdownDrainsBeforeReleasingStore() async throws {
        for _ in 0..<25 {
            let container = try makeContainer()
            let context = container.mainContext
            let queue = TaskQueue(poolSize: 1)

            #expect(queue.processQueueIfIdle(modelContext: context))
            #expect(queue.hasBoundStoreSession)
            await queue.cancelAllAndWait()
            #expect(!queue.hasProcessingLoop)
            #expect(!queue.hasBoundStoreSession)
        }
    }

    @Test("Runtime shutdown is the explicit store replacement boundary")
    func runtimeShutdownAllowsBindingAReplacementStore() async throws {
        let queue = TaskQueue(poolSize: 1)
        let runtime = AppRuntimeController(taskQueue: queue)
        let firstContainer = try makeContainer()
        #expect(queue.processQueueIfIdle(modelContext: firstContainer.mainContext))
        await runtime.shutdown()
        #expect(!queue.hasBoundStoreSession)

        let secondContainer = try makeContainer()
        #expect(queue.processQueueIfIdle(modelContext: secondContainer.mainContext))
        await runtime.shutdown()
        #expect(!queue.hasBoundStoreSession)
    }

    @Test("Failed runtime shutdown keeps the scheduler alive for a retry")
    func failedRuntimeShutdownKeepsSchedulerAlive() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Scheduler retry", primaryPath: "/tmp")
        let task = AgentTask(title: "Queued", goal: "Remain durable", workspace: workspace)
        task.status = .queued
        context.insert(workspace)
        context.insert(task)
        let submission = try #require(
            try? ExecutionRequestSubmissionService.submitInitial(for: task, into: context).get()
        )
        var persistenceAvailable = false
        let queue = TaskQueue(poolSize: 0, persistQueueCancellation: { modelContext in
            guard persistenceAvailable else { return false }
            try? modelContext.save()
            return true
        })
        _ = queue.signalExecutionRequest(id: submission.requestID, task: task, modelContext: context)
        let scheduler = TaskScheduler()
        let runtime = AppRuntimeController(taskQueue: queue, taskScheduler: scheduler)
        scheduler.start(modelContext: context, taskQueue: queue)

        #expect(await runtime.shutdown() == false)
        #expect(scheduler.isRunning)

        persistenceAvailable = true
        #expect(await runtime.shutdown())
        #expect(!scheduler.isRunning)
    }

    @Test("Termination drain includes lifecycle coroutines after workers finish")
    func terminationDrainIncludesLifecycleCoroutines() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let queue = TaskQueue(poolSize: 0)
        #expect(!ASTRAAppDelegate.requiresTerminationDrain(for: queue))
        _ = queue.registerLifecycleTask(modelContext: context) { _ in
            await Task.yield()
        }
        #expect(ASTRAAppDelegate.requiresTerminationDrain(for: queue))
    }

    @Test("Signals arriving during shutdown cannot create orphan completion handles")
    func signalDuringShutdownIsRejectedBeforePromiseRegistration() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let queue = TaskQueue(poolSize: 1)
        _ = queue.processQueueIfIdle(modelContext: context)
        while queue.hasProcessingLoop { await Task.yield() }

        let root = "/tmp/shutdown-signal-\(UUID())"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let workspace = Workspace(name: "Shutdown signal", primaryPath: root)
        let task = AgentTask(title: "Shutdown signal", goal: "Must stay queued", workspace: workspace)
        task.status = .queued
        context.insert(workspace)
        context.insert(task)
        try context.save()
        let submissionResult = ExecutionRequestSubmissionService.submitInitial(for: task, into: context)
        let submission: ExecutionRequestSubmissionService.Submission?
        if case .success(let value) = submissionResult {
            submission = value
        } else {
            submission = nil
        }
        let accepted = try #require(submission)

        _ = queue.registerLifecycleTask(modelContext: context) { _ in
            while !Task.isCancelled { await Task.yield() }
        }
        queue.cancelAll()
        #expect(queue.isStopping)

        let rejected = queue.signalExecutionRequest(
            id: accepted.requestID,
            task: task,
            modelContext: context
        )
        await rejected.value
        #expect(queue.pendingCompletionHandleCount == 0)

        await queue.cancelAllAndWait()
        #expect(queue.ownedCoroutineCount == 0)
    }

    @Test("A busy queue still returns a completion handle for accepted durable work")
    func busyQueueReturnsCompletionHandle() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let root = "/tmp/busy-signal-\(UUID())"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let workspace = Workspace(name: "Busy signal", primaryPath: root)
        let task = AgentTask(title: "Queued", goal: "Wait for a worker", workspace: workspace)
        task.status = .queued
        context.insert(workspace)
        context.insert(task)
        let submissionResult = ExecutionRequestSubmissionService.submitInitial(
            for: task,
            into: context
        )
        let submission: ExecutionRequestSubmissionService.Submission?
        if case .success(let value) = submissionResult { submission = value } else { submission = nil }
        let accepted = try #require(submission)

        let queue = TaskQueue(poolSize: 0)
        let completion = queue.signalExecutionRequest(
            id: accepted.requestID,
            task: task,
            modelContext: context
        )

        #expect(queue.pendingCompletionHandleCount == 1)
        queue.cancelTurnRequest(id: accepted.requestID, workspace: workspace, modelContext: context)
        await completion.value
        #expect(queue.pendingCompletionHandleCount == 0)
        await queue.cancelAllAndWait()
    }

    @Test("Failed cancellation persistence preserves durable queue authority and blocks shutdown")
    func failedCancellationPersistenceBlocksShutdown() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Cancellation", primaryPath: "/tmp")
        let task = AgentTask(title: "Queued", goal: "Stay durable", workspace: workspace)
        task.status = .queued
        context.insert(workspace)
        context.insert(task)
        let submissionResult = ExecutionRequestSubmissionService.submitInitial(for: task, into: context)
        let submission: ExecutionRequestSubmissionService.Submission?
        if case let .success(value) = submissionResult { submission = value } else { submission = nil }
        let accepted = try #require(submission)
        let request = try #require(
            try TaskTurnRequestRepository.request(id: accepted.requestID, in: context)
        )
        var persistenceIsAvailable = false
        let queue = TaskQueue(poolSize: 0, persistQueueCancellation: { modelContext in
            guard persistenceIsAvailable else { return false }
            do {
                try modelContext.save()
                return true
            } catch {
                return false
            }
        })
        _ = queue.signalExecutionRequest(
            id: accepted.requestID,
            task: task,
            modelContext: context
        )

        #expect(!queue.cancelAll())
        #expect(request.state.isActive)
        #expect(request.terminalAt == nil)
        #expect(queue.hasBoundStoreSession)
        #expect(!queue.isStopping)

        persistenceIsAvailable = true
        #expect(await queue.cancelAllAndWait())
        #expect(request.state == .cancelled)
        #expect(request.terminalReason == "queue_cancelled")
        #expect(!queue.hasBoundStoreSession)
    }

    @Test("Cancellation retains every owned task handle until its completion defer")
    func registryCancellationRetainsDrainHandles() async {
        let registry = ExecutionRequestTaskRegistry()
        let processingID = UUID()
        let dispatchID = UUID()
        let lifecycleID = UUID()

        let processing = Task { @MainActor in
            while !Task.isCancelled { await Task.yield() }
            registry.finishProcessing(id: processingID)
        }
        let dispatched = Task { @MainActor in
            while !Task.isCancelled { await Task.yield() }
            registry.finishDispatch(requestID: dispatchID)
        }
        let lifecycle = Task { @MainActor in
            while !Task.isCancelled { await Task.yield() }
            registry.finishLifecycle(id: lifecycleID)
        }
        registry.registerProcessing(processing, id: processingID)
        registry.registerDispatch(dispatched, requestID: dispatchID)
        registry.registerLifecycle(lifecycle, id: lifecycleID)

        registry.cancelOwnedTasks()
        #expect(registry.ownedTaskCount == 3)
        let drain = registry.drainSnapshot()
        await drain.wait()
        #expect(registry.ownedTaskCount == 0)
    }

    @Test("Dispatch completion without a promised waiter is not buffered forever")
    func unobservedCompletionIsNotBuffered() async {
        let registry = ExecutionRequestTaskRegistry()
        for _ in 0..<1_000 {
            registry.complete(requestID: UUID())
        }
        #expect(registry.bufferedCompletionSignalCount == 0)

        let promisedID = UUID()
        let handle = registry.completionHandle(requestID: promisedID)
        registry.complete(requestID: promisedID)
        await handle.value
        #expect(registry.promisedCompletionCount == 0)
        #expect(registry.bufferedCompletionSignalCount == 0)
    }
}

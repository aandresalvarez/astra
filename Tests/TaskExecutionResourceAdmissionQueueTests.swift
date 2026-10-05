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

    @Test("Workspace changes during a resource wait fail without exporting or migrating storage",
          arguments: ["initial", "continuation", "plan", "worker", "legacy"])
    func workspaceDriftDuringAdmission(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scope-admission-\(UUID())")
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original")
        let moved = root.appendingPathComponent("unaccepted")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let container = try makeContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Accepted", primaryPath: original.path)
        let task = AgentTask(title: "Inspect", goal: "Explain the code", workspace: workspace)
        task.status = .queued
        context.insert(workspace)
        context.insert(task)
        let plan = TaskPlanPayload(title: "Inspect", goal: task.goal, steps: [.init(id: "inspect", title: "Read the code")])
        let submission: ExecutionRequestSubmissionService.Submission
        switch mode {
        case "plan":
            submission = try ExecutionRequestSubmissionService.submitPlan(plan: plan, mode: .nextStep,
                mutation: .existingTask, for: task, into: context).get()
        case "continuation", "worker":
            submission = try ExecutionRequestSubmissionService.submitFollowUp(message: "Explain the code",
                for: task, into: context).get()
        default:
            submission = try ExecutionRequestSubmissionService.submitInitial(for: task, into: context).get()
        }
        let request = try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: context))
        let snapshot = try #require(TaskExecutionLaunchSnapshotApplicator.snapshot(request: request, from: task))
        if mode == "legacy" { task.status = .failed }
        let folder = try TaskExecutionResourcePreparation.ensureTaskFolder(task: task)
        try "retained".write(toFile: folder + "/sentinel", atomically: true, encoding: .utf8)
        let queue = TaskQueue(poolSize: mode == "worker" ? 0 : 1)
        let blocker = AgentTask(title: "Blocker", goal: "Hold the original workspace")
        let lease = try #require(queue.acquireResourceLockIfAvailable(task: blocker,
            resourceKey: original.path, accessMode: .write, runMode: "test"))
        let execution = Task { @MainActor in
            let policy = AgentRuntimeExecutionPolicy(launchSnapshot: snapshot)
            switch mode {
            case "plan":
                await queue.executeApprovedPlan(task: task, plan: plan, mode: .nextStep, modelContext: context,
                    executionRequestID: request.id, executionPolicy: policy)
            case "continuation", "worker":
                _ = await queue.continueSession(task: task, message: "Explain the code",
                    turnRequestID: request.id, modelContext: context, executionPolicy: policy)
            case "legacy":
                _ = await queue.continueSession(task: task, message: "Explain the code",
                    modelContext: context, executionPolicy: policy)
            default:
                await queue.executeTask(task, modelContext: context, executionRequestID: request.id, executionPolicy: policy)
            }
        }
        defer { execution.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        func isWaiting() -> Bool {
            mode == "worker" ? request.blockerSummary == "Waiting for an available worker."
                : queue.waitingResourceLocks[task.id] != nil
        }
        while !isWaiting() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(isWaiting())
        workspace.primaryPath = moved.path
        if mode == "worker" { queue.resizePool(to: 1) }
        queue.releaseResourceLock(lease, task: blocker)
        await execution.value

        if mode != "legacy" {
            #expect(request.state == .failed)
            #expect(request.terminalReason == "execution_resource_scope_requires_resubmission")
        }
        #expect(task.status == .failed)
        #expect(task.runs.isEmpty)
        #expect(queue.activeResourceLocks.isEmpty)
        #expect(queue.waitingResourceLocks[task.id] == nil)
        #expect(queue.activeTasks.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: moved.path))
        #expect(try String(contentsOfFile: folder + "/sentinel") == "retained")
        #expect(task.events.contains { $0.type == "error" && $0.payload.contains("Submit a new turn") })
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

    @Test("Sandbox Off upgrades a legacy shared request to an exclusive lease")
    func sandboxOffSerializesLegacySharedRequest() throws {
        let workspace = Workspace(name: "Legacy shared", primaryPath: "/tmp/astra-legacy-shared")
        let task = AgentTask(title: "Explain", goal: "Summarize the task.", workspace: workspace)
        let request = TaskTurnRequest(
            task: task,
            messageEventID: UUID(),
            sequence: 1,
            resourceClaims: [
                TaskExecutionResourceClaim(
                    kind: .workspace,
                    key: workspace.primaryPath,
                    access: .shared
                )
            ]
        )

        let sandboxed = TaskExecutionResourceAdmissionPolicy.lockClaims(
            for: request,
            task: task,
            runMode: "test",
            sandboxEnforcement: .bestEffort
        )
        let unconfined = TaskExecutionResourceAdmissionPolicy.lockClaims(
            for: request,
            task: task,
            runMode: "test",
            sandboxEnforcement: .off
        )

        #expect(sandboxed.first?.accessMode == .readOnly)
        #expect(unconfined.first?.accessMode == .write)
        #expect(TaskExecutionResourceAdmissionPolicy.workspaceAccess(from: unconfined) == .exclusive)

        let queue = TaskQueue(
            poolSize: 1,
            sandboxEnforcementProvider: { .off }
        )
        #expect(queue.resourceAccess(for: request, task: task) == .write)
        #expect(queue.resourceLockClaims(
            for: request,
            task: task,
            runMode: "test"
        ).first?.accessMode == .write)
    }
}

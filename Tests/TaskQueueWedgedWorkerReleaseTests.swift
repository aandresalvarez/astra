import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

/// A provider process whose run never returns, even after cancel — the shape
/// of the 0.1.30 hang, where an escaped descendant held stdout open and the
/// worker's `continueSession` waited for an EOF that never came.
private final class WedgedProcessRunner: AgentRuntimeProcessRunning {
    private(set) var launchedTaskIDs: [UUID] = []
    private var pending: [UUID: CheckedContinuation<AgentProcessResult, Never>] = [:]
    private var draining = false
    @MainActor private var owner: RuntimeExecutionOwner?
    var toolsStopped = true
    @MainActor func configureExecutionOwner(_ owner: RuntimeExecutionOwner?) { self.owner = owner }
    private var lateLines: [UUID: (String, Bool) -> Void] = [:]

    func cancel() {}

    func isHostControlBrokerAvailable() -> Bool { true }

    @MainActor
    func runRuntimeProcess(
        adapter: any AgentRuntimeProcessLaunchPlanning & AgentRuntimeProcessEventParsing,
        prompt: String,
        task: AgentTask,
        workspacePath: String,
        executablePath: String,
        homeDirectory: String,
        permissionPolicy: PermissionPolicy,
        executionPolicy: AgentRuntimeExecutionPolicy,
        permissionManifest: RunPermissionManifest?,
        budgetEnforcementMode: BudgetEnforcementMode,
        timeoutSeconds: TimeInterval,
        phase: RunPhase,
        contextText: String,
        nativeContinuationSessionID: String?,
        runID: UUID?,
        launchResourcePlan: TaskLaunchResourcePlan?,
        capabilityResolutionSnapshot: TaskCapabilityResolutionSnapshot?,
        runtimeRequirements: TaskRuntimeRequirementSet?,
        liveApprovalsEnabled: Bool,
        noSemanticProgressTimeoutSeconds: TimeInterval?,
        maxRunSeconds: TimeInterval?,
        onInteractiveAsk: ((AgentInteractiveAskRequest) async -> InteractiveAskOutcome)?,
        onLine: @escaping (String, Bool) -> Void
    ) async -> AgentProcessResult {
        guard !draining else { return Self.lateResult }
        guard let owner else { return AgentProcessResult(exitCode: -1, error: "test owner missing") }
        do {
            try owner.prepareLaunch()
            let child = AgentExecutionScopedProcess(executablePath: "/bin/sh", arguments: ["-c", "exit 0"],
                currentDirectory: workspacePath, environment: ProcessInfo.processInfo.environment)
            try child.run()
            try owner.launched(child)
            for _ in 0..<200 where child.isRunning { try? await Task.sleep(for: .milliseconds(5)) }
            let proof = child.stopProof(executionID: owner.record.executionID,
                toolsStopped: toolsStopped, remoteWorkExcluded: true)
            owner.stopped(proof: proof, turns: 1, tokens: 100, seconds: 1)
        } catch { return AgentProcessResult(exitCode: -1, error: "test process failed: \(error)") }
        launchedTaskIDs.append(task.id)
        lateLines[task.id] = onLine
        let taskID = task.id
        return await withCheckedContinuation { pending[taskID] = $0 }
    }

    private static let lateResult = AgentProcessResult(exitCode: -1, error: "late return")

    /// The wedged run finally returns.
    @MainActor
    func finish(_ taskID: UUID) {
        lateLines.removeValue(forKey: taskID)?("{\"type\":\"result\",\"result\":\"STALE_RESULT_MUST_NOT_APPEAR\"}", true)
        pending.removeValue(forKey: taskID)?.resume(returning: Self.lateResult)
    }

    /// Teardown: every run returns now and later ones return at once, so a
    /// failing assertion cannot leave an admission hanging the suite.
    @MainActor
    func drain() {
        draining = true
        pending.values.forEach { $0.resume(returning: Self.lateResult) }
        pending.removeAll()
    }
}

@Suite("Cancel releases a wedged worker's resource lease", .serialized)
@MainActor
struct TaskQueueWedgedWorkerReleaseTests {
    @MainActor
    private struct Fixture {
        let root: URL
        let container: ModelContainer
        let context: ModelContext
        let wedged: AgentTask
        let next: AgentTask
        let runner = WedgedProcessRunner()
        let queue: TaskQueue

        init(grace: Duration = .milliseconds(50)) throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("astra-wedged-worker-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
                configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
            context = container.mainContext
            let workspace = Workspace(name: "Shared", primaryPath: root.path)
            wedged = AgentTask(title: "Wedged run", goal: "Hang", workspace: workspace, runtime: .claudeCode)
            next = AgentTask(title: "Next task", goal: "Run after", workspace: workspace, runtime: .claudeCode)
            // Follow-ups to finished tasks: the durable-turn path the queue admits.
            wedged.status = .completed
            next.status = .completed
            context.insert(workspace)
            context.insert(wedged)
            context.insert(next)
            try context.save()
            let runner = runner
            queue = TaskQueue(poolSize: 2, workerFactory: {
                let worker = AgentRuntimeWorker(processRunner: runner, providerSettingsSnapshotProvider: { .headlessScenario })
                worker.runtimeReadinessService = RuntimeReadinessService(runner: InstantSuccessBinaryRunner())
                return worker
            }, sandboxEnforcementProvider: { .off }, wedgedWorkerReleaseGrace: grace)
            queue.applySettings(claudePath: "/bin/sh", defaultRuntimeID: .claudeCode, timeoutSeconds: 10,
                validationModel: "claude-sonnet-4-6", defaultPolicyLevelRaw: AgentPolicyLevel.review.rawValue)
        }

        func submitTurn(_ task: AgentTask) throws -> (request: TaskTurnRequest, admission: Task<Bool, Never>) {
            let submission = try #require(TaskTurnSubmissionService.submit(
                message: "Follow up on \(task.title)", for: task, into: context
            ).successValue)
            let request = try #require(try TaskTurnRequestRepository.request(id: submission.requestID, in: context))
            let queue = queue, context = context
            let admission = Task { @MainActor in
                await queue.continueSession(task: task, message: "Follow up on \(task.title)",
                    existingMessageEventID: submission.eventID, turnRequestID: submission.requestID,
                    modelContext: context)
            }
            return (request, admission)
        }

        func releasedEvents(for task: AgentTask) -> [TaskResourceLockPayload] {
            task.events
                .filter { $0.type == TaskResourceLockEventTypes.released }
                .compactMap { try? JSONDecoder().decode(TaskResourceLockPayload.self, from: Data($0.payload.utf8)) }
        }

        func cleanup() {
            _ = TestWorkspaceStoreCleanup.schedule(context: context,
                roots: [root, RuntimeExecutionOwner.store(in: context).root])
        }
    }

    /// Polls rather than timing out on wall clock: a loaded suite stretches
    /// seconds, not iteration counts.
    private func eventually(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<1_000 where !predicate() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }

    /// Drives the 0.1.30 shape: the first task's worker hangs in
    /// `continueSession`, a second task on the same workspace waits for it,
    /// and the user cancels the first.
    private func wedgeThenCancel(_ fixture: Fixture) async throws -> (
        wedged: Task<Bool, Never>, next: Task<Bool, Never>, nextRequest: TaskTurnRequest
    ) {
        let first = try fixture.submitTurn(fixture.wedged)
        #expect(await eventually { fixture.runner.launchedTaskIDs.contains(fixture.wedged.id) },
            "turn \(first.request.state) \(first.request.terminalReason ?? "-"), task \(fixture.wedged.status)")
        #expect(fixture.queue.activeResourceLocks.contains { $0.taskID == fixture.wedged.id })

        let second = try fixture.submitTurn(fixture.next)
        #expect(await eventually { second.request.state == .waitingForResource })
        #expect(second.request.blockingTaskID == fixture.wedged.id)
        let summary = second.request.blockerSummary ?? ""
        #expect(summary.contains("\u{201C}Wedged run\u{201D}"), "\(summary)")
        #expect(summary.contains(String(fixture.wedged.id.uuidString.prefix(8))), "\(summary)")

        fixture.queue.cancel(task: fixture.wedged, modelContext: fixture.context)
        return (first.admission, second.admission, second.request)
    }

    @Test("Cancel on a worker that never returns admits the next task waiting on the same workspace")
    func cancelReleasesWedgedLeaseAndAdmitsWaiter() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let run = try await wedgeThenCancel(fixture)

        #expect(await eventually { fixture.runner.launchedTaskIDs.contains(fixture.next.id) })
        #expect(!fixture.queue.activeResourceLocks.contains { $0.taskID == fixture.wedged.id })
        #expect(fixture.queue.activeResourceLocks.contains { $0.taskID == fixture.next.id })
        #expect(fixture.queue.wedgedLeaseReclaimer.pendingCount == 0)
        let released = fixture.releasedEvents(for: fixture.wedged)
        #expect(!released.isEmpty)
        #expect(released.allSatisfy { $0.reason == "cancelled_cleanup_verified" })
        #expect(fixture.queue.hasAvailableWorker)
        #expect(fixture.wedged.runs.allSatisfy { !$0.output.contains("STALE_RESULT_MUST_NOT_APPEAR") })

        fixture.runner.drain()
        _ = await run.wedged.value
        _ = await run.next.value
        fixture.queue.cancelAll()
    }

    @Test("The wedged worker's late return does not release the lock the next task now holds")
    func lateReturnDoesNotReleaseSuccessorLock() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let run = try await wedgeThenCancel(fixture)
        #expect(await eventually { fixture.runner.launchedTaskIDs.contains(fixture.next.id) })
        let successorClaims = fixture.queue.activeResourceLocks.filter { $0.taskID == fixture.next.id }
        #expect(!successorClaims.isEmpty)
        let releasedBeforeReturn = fixture.releasedEvents(for: fixture.wedged).count

        fixture.runner.finish(fixture.wedged.id)
        _ = await run.wedged.value

        #expect(fixture.queue.activeResourceLocks.filter { $0.taskID == fixture.next.id } == successorClaims)
        #expect(fixture.releasedEvents(for: fixture.wedged).count == releasedBeforeReturn)
        #expect(fixture.wedged.runs.allSatisfy { !$0.output.contains("STALE_RESULT_MUST_NOT_APPEAR") })
        #expect(!fixture.queue.canAcquireResourceLock(for: fixture.wedged, accessMode: .write))

        fixture.runner.drain()
        _ = await run.next.value
        #expect(fixture.queue.activeResourceLocks.isEmpty)
        fixture.queue.cancelAll()
    }

    @Test("A worker that honors cancel within the grace releases its own lease and the deadline does nothing")
    func promptReturnMakesDeadlineNoOp() async throws {
        // A grace no loaded suite can outrun; the deadline is then fired by hand.
        let fixture = try Fixture(grace: .seconds(600))
        defer { fixture.cleanup() }
        let first = try fixture.submitTurn(fixture.wedged)
        #expect(await eventually { fixture.runner.launchedTaskIDs.contains(fixture.wedged.id) })
        let leaseIDs = Set(fixture.queue.activeResourceLocks.compactMap(\.leaseID))
        #expect(!leaseIDs.isEmpty)
        fixture.queue.cancel(task: fixture.wedged, modelContext: fixture.context)
        #expect(fixture.queue.wedgedLeaseReclaimer.pendingCount == 1)
        fixture.runner.drain()
        _ = await first.admission.value
        #expect(fixture.queue.activeResourceLocks.isEmpty)
        let released = fixture.releasedEvents(for: fixture.wedged)
        #expect(!released.isEmpty)

        fixture.queue.releaseWedgedLeases(leaseIDs, taskID: fixture.wedged.id, modelContext: fixture.context)

        #expect(fixture.releasedEvents(for: fixture.wedged).count == released.count)
        #expect(released.allSatisfy { $0.reason == "cancelled_cleanup_verified" })
        fixture.queue.cancelAll()
    }

    @Test("Cancelled work with uncertain tools keeps its resource fence after return and Stop Queue")
    func uncertainToolsKeepFence() async throws {
        let fixture = try Fixture(grace: .seconds(600))
        defer { fixture.cleanup() }
        fixture.runner.toolsStopped = false
        let run = try await wedgeThenCancel(fixture)
        let leases = Set(fixture.queue.activeResourceLocks.filter { $0.taskID == fixture.wedged.id }.compactMap(\.leaseID))
        fixture.queue.releaseWedgedLeases(leases, taskID: fixture.wedged.id, modelContext: fixture.context)
        #expect(!fixture.runner.launchedTaskIDs.contains(fixture.next.id))
        fixture.runner.finish(fixture.wedged.id)
        _ = await run.wedged.value
        #expect(fixture.queue.hasAvailableWorker)
        #expect(fixture.queue.activeResourceLocks.contains { $0.taskID == fixture.wedged.id })
        #expect(fixture.wedged.events.contains { $0.payload.contains("shared resources remain reserved") })
        fixture.queue.cancelAll()
        #expect(fixture.queue.activeResourceLocks.contains { $0.taskID == fixture.wedged.id })
        let restarted = TaskQueue(poolSize: 1)
        restarted.refreshResourceOwnership(in: fixture.context)
        #expect(!restarted.canAcquireResourceLock(for: fixture.next, accessMode: .write))
        fixture.runner.drain()
        _ = await run.next.value
    }

    @Test("Releasing a lease twice frees only that lease, never a later identical claim of the same task")
    func releaseIsIdempotentPerLease() throws {
        let queue = TaskQueue(poolSize: 1)
        let taskID = UUID()
        let claim = TaskResourceLockClaim(taskID: taskID, resourceKey: "/tmp/astra-lease", accessMode: .write, runMode: "continue")
        let first = try #require(queue.acquireResourceLocksIfAvailable([claim.leased(UUID())], task: nil))
        queue.releaseResourceLocks(first, task: nil)
        let second = try #require(queue.acquireResourceLocksIfAvailable([claim.leased(UUID())], task: nil))

        queue.releaseResourceLocks(first, task: nil)

        #expect(queue.activeResourceLocks == second)
        queue.releaseResourceLocks(second, task: nil)
        #expect(queue.activeResourceLocks.isEmpty)
    }

    @Test("The waiting summary names the holder and both paths when the workspaces overlap by ancestry")
    func blockerSummaryNamesHolderAndOverlap() {
        let holderID = UUID()
        let shortID = String(holderID.uuidString.prefix(8))
        let parent = TaskResourceLockClaim(taskID: holderID, resourceKey: "/tmp/astra-repo", accessMode: .write, runMode: "task")
        let child = TaskResourceLockClaim(taskID: UUID(), resourceKey: "/tmp/astra-repo/app", accessMode: .write, runMode: "task")
        let parentPath = TaskExecutionResourceBroker.canonicalKey(kind: .workspace, key: parent.resourceKey)
        let childPath = TaskExecutionResourceBroker.canonicalKey(kind: .workspace, key: child.resourceKey)

        let nested = TaskExecutionResourceBroker.blockerSummary(requested: [child], active: [parent]) { _ in "Refactor login" }
        #expect(nested == "Waiting for workspace resource held by task \u{201C}Refactor login\u{201D} (\(shortID)): it holds \(parentPath), which contains \(childPath).")

        let enclosing = TaskExecutionResourceBroker.blockerSummary(requested: [parent], active: [child])
        #expect(enclosing.hasSuffix(": it holds \(childPath), which is inside \(parentPath)."))
        #expect(enclosing.contains("held by task \(String(child.taskID.uuidString.prefix(8)))"))

        let samePath = TaskExecutionResourceBroker.blockerSummary(
            requested: [TaskResourceLockClaim(taskID: UUID(), resourceKey: "/tmp/astra-repo", accessMode: .write, runMode: "task")],
            active: [parent]
        ) { _ in "Refactor login" }
        #expect(samePath == "Waiting for workspace resource held by task \u{201C}Refactor login\u{201D} (\(shortID)).")
    }
}

private extension Result where Failure == TaskTurnSubmissionService.SubmissionError {
    var successValue: Success? {
        guard case let .success(value) = self else { return nil }
        return value
    }
}

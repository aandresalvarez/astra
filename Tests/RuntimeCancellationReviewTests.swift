import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

@Suite("Cancellation review regressions", .serialized)
@MainActor
struct RuntimeCancellationReviewTests {
    @Test("A foreign provider journal and a missing journal remain fenced without any registered root")
    func foreignReferenceSurvivesRestart() async throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .antigravityCLI, goal: "Foreign owner", model: "test")
        let store = RuntimeExecutionOwner.store(in: h.context)
        var record = try RuntimeRecoveryTestReceipt.install(task: task, run: nil, context: h.context, toolsStopped: false)
        let key = AgentRuntimeSharedStateKey(runtime: .antigravityCLI, identifier: UUID().uuidString)
        record.providerSharedStateKey = key.rawValue
        record.providerSharedStateReleased = false
        do { let lease = try store.acquire(taskID: task.id); try lease.save(record) }
        let root = h.rootURL.appendingPathComponent("provider-leases")
        let reference = RuntimeProviderOwnershipReference(journalRoot: store.root.path, taskID: task.id, ownerID: record.ownerID)
        do {
            let lease = try await ProviderSharedStateProcessLock.acquire(key, root: root)
            try lease.handoff(key, reference: reference, prepare: {})
        }
        // Direct kernel acquisition has no knowledge of a process-local registry.
        let next = try await ProviderSharedStateProcessLock.acquire(key, root: root)
        #expect(throws: (any Error).self) { try next.handoff(key, reference: nil, prepare: {}) }
        let receiptURL = store.root.appendingPathComponent(task.id.uuidString + ".json")
        try FileManager.default.removeItem(at: receiptURL)
        #expect(throws: (any Error).self) { try next.handoff(key, reference: nil, prepare: {}) }
        record.providerSharedStateReleased = true
        do { let lease = try store.acquire(taskID: task.id); try lease.save(record) }
        try next.handoff(key, reference: nil, prepare: {})
    }

    @Test("A retired scan root is empty while missing referenced authority still blocks")
    func absentScanRootIsEmpty() async throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let store = RuntimeExecutionOwnerStore(root: h.rootURL.appendingPathComponent("retired-owners"))
        #expect(try store.records().isEmpty)
        let key = AgentRuntimeSharedStateKey(runtime: .antigravityCLI, identifier: UUID().uuidString)
        let reference = RuntimeProviderOwnershipReference(journalRoot: store.root.path, taskID: UUID(), ownerID: UUID())
        let lease = try await ProviderSharedStateProcessLock.acquire(key, root: h.rootURL.appendingPathComponent("leases"))
        #expect(throws: (any Error).self) { try lease.handoff(key, reference: reference, prepare: {}) }
    }

    @Test("Retiring an isolated store removes its scan hint before destructive fixture cleanup")
    func retiringStoreRemovesScanHint() throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let store = RuntimeExecutionOwner.store(in: h.context)
        let taskID = UUID()
        do { let lease = try store.acquire(taskID: taskID); withExtendedLifetime(lease) {} }
        try Data("malformed".utf8).write(to: store.root.appendingPathComponent(taskID.uuidString + ".json"))
        let key = AgentRuntimeSharedStateKey(runtime: .antigravityCLI, identifier: UUID().uuidString)
        #expect(throws: (any Error).self) { try RuntimeProviderResourceRegistry.assertAvailable(key, ownerID: nil) }
        RuntimeProviderResourceRegistry.unregister(store.root)
        try RuntimeProviderResourceRegistry.assertAvailable(key, ownerID: nil)
        #expect(FileManager.default.fileExists(atPath: store.root.path))
    }

    @Test("Cancelled provider-gate waiters never bind a key they did not acquire")
    func cancelledWaiterDoesNotClaimSettings() async throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Waiting utility", model: "test")
        let acquired = RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60)
        let owner = try #require(acquired)
        defer { owner.finish() }
        let key = AgentRuntimeSharedStateKey(runtime: .antigravityCLI, identifier: UUID().uuidString)
        let gate = AgentRuntimeSharedStateGate(processLockRoot: h.rootURL.appendingPathComponent("provider-leases"),
            registeredStoreRoots: [RuntimeExecutionOwner.store(in: h.context).root])
        let first = try await gate.acquire(key)
        let waiter = Task { try await gate.acquire(key, owner: owner) }
        try await Task.sleep(for: .milliseconds(80))
        #expect(owner.record.providerSharedStateKey == nil)
        owner.requestCancellation()
        await gate.release(first)
        do { _ = try await waiter.value; Issue.record("Cancelled owner acquired provider settings") }
        catch { #expect(owner.record.providerSharedStateKey == nil) }
    }

    @Test("A later utility rebinds the key after the previous utility releases it")
    func utilityHandoffRebindsClaim() async throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Two utilities", model: "test")
        let acquired = RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60)
        let owner = try #require(acquired)
        defer { owner.finish() }
        let gate = AgentRuntimeSharedStateGate(processLockRoot: h.rootURL.appendingPathComponent("provider-leases"),
            registeredStoreRoots: [RuntimeExecutionOwner.store(in: h.context).root])
        let key = AgentRuntimeSharedStateKey(runtime: .antigravityCLI, identifier: UUID().uuidString)
        let first = try await gate.acquire(key, owner: owner)
        let waiting = Task { try await gate.acquire(key, owner: owner) }
        try await Task.sleep(for: .milliseconds(80))
        #expect(owner.releaseProviderSharedState())
        await gate.release(first)
        let second = try await waiting.value
        #expect(owner.record.providerSharedStateReleased == false)
        #expect(try RuntimeExecutionOwner.store(in: h.context).read(taskID: task.id)?.providerSharedStateReleased == false)
        #expect(owner.releaseProviderSharedState())
        await gate.release(second)
    }

    @Test("Missing legacy ownership authority blocks competing work even without captured claims")
    func missingLegacyJournalBlocksAdmission() throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Legacy", model: "test")
        var record = try RuntimeRecoveryTestReceipt.install(task: task, run: nil, context: h.context, toolsStopped: false)
        record.resourceClaims = nil
        h.context.insert(TaskEvent(task: task, eventType: TaskEventTypes.System.runtimeExecutionOwnership,
            payload: TaskEvent.payloadString(record, fallback: "{}")))
        let store = RuntimeExecutionOwner.store(in: h.context)
        try FileManager.default.removeItem(at: store.root.appendingPathComponent(task.id.uuidString + ".json"))
        #expect(throws: (any Error).self) { try RuntimeResourceOwnership.claims(in: store, context: h.context) }
    }

    @Test("Legacy final validation does not conflict with its own task lease")
    func legacySettlementDoesNotSelfConflict() throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Legacy validation", model: "test")
        let run = TaskRun(task: task); h.context.insert(run)
        var record = try RuntimeRecoveryTestReceipt.install(task: task, run: run, context: h.context, toolsStopped: true)
        record.resourceClaims = nil
        let store = RuntimeExecutionOwner.store(in: h.context)
        do { let lease = try store.acquire(taskID: task.id); try lease.save(record) }
        let admission = RuntimeExecutionOwner.acquireSettlement(task: task, run: run, context: h.context)
        let owner = try #require(admission.owner)
        #expect(owner.record.resourceClaims?.isEmpty == false)
        owner.finish()
    }

    @Test("A permission callback invalidated while draining cannot create a late approval card")
    func latePermissionDoesNotMutateTask() async throws {
        let h = try HeadlessChatHarness()
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Permission", model: "test")
        let run = TaskRun(task: task); h.context.insert(run)
        var current = true
        let pending = OrderedMainActorTaskQueue()
        pending.add { current = false }
        let handler = AgentRuntimeWorker.interactiveAskHandler(runtime: .claudeCode, task: task, run: run,
            permissionPolicy: .restricted, manifest: nil, modelContext: h.context, pendingEvents: pending,
            isCurrent: { current })
        let before = task.events.count
        let outcome = await handler(.init(requestID: "cancelled-ask", toolName: "Bash", inputSummary: "sleep 10"))
        await pending.drainAll()
        if case .allow = outcome { Issue.record("Invalidated permission callback allowed work") }
        #expect(task.events.count == before)
        #expect(InFlightPermissionCenter.shared.pendingAsks(taskID: task.id).isEmpty)
    }

    @Test("Cancelling final plan validation preserves cancellation and emits no false failure or completion")
    func finalPlanCancellationHasNoLateVerdict() async throws {
        let h = try HeadlessChatHarness()
        defer { h.cleanup() }
        let marker = h.workspaceURL.appendingPathComponent("validation-started")
        try "test:\n\t@touch validation-started\n\t@sleep 10\n".write(to: h.workspaceURL.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
        let task = h.makeTask(runtime: .claudeCode, goal: "Final validation", model: "test")
        task.status = .running
        let plan = TaskPlanPayload(title: "Finished steps", goal: task.goal,
            steps: [TaskPlanPayloadStep(id: "done", title: "Done", status: .done)],
            validationContract: .init(assertions: [.init(id: "check", description: "Check", method: .command, command: "make test")]))
        let worker = h.makeWorker(runtime: .claudeCode, executablePath: "/bin/false")
        let execution = Task { @MainActor in
            await worker.executeApprovedPlan(task: task, plan: plan, mode: .nextStep, modelContext: h.context, onEvent: { _ in })
        }
        for _ in 0..<500 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(worker.isRunning)
        worker.cancel()
        _ = TaskRunLifecycleService.cancelTask(task, modelContext: h.context, source: .userAction)
        await execution.value
        #expect(task.status == .cancelled)
        #expect(!task.events.contains { [TaskPlanEventTypes.executionCompleted, TaskValidationEventTypes.assertionFailed,
            TaskValidationEventTypes.contractFailed].contains($0.type) })
        #expect(!worker.isRunning)
    }
}

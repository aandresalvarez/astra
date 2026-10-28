import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

@Suite("Cancellation keeps durable resource ownership", .serialized)
@MainActor
struct RuntimeCancellationResourceTests {
    @Test("Resource projection preserves acquisition order while merging durable duplicates")
    func resourceProjectionPreservesOrder() {
        let queue = TaskQueue(poolSize: 1)
        let first = TaskResourceLockClaim(taskID: UUID(), resourceKey: "/first", accessMode: .write, runMode: "test")
        let second = TaskResourceLockClaim(taskID: UUID(), resourceKey: "/second", accessMode: .readOnly, runMode: "test")
        let persisted = TaskResourceLockClaim(taskID: UUID(), resourceKey: "/persisted", accessMode: .write, runMode: "test")
        queue.localResourceLocks = [first, second]
        queue.persistedResourceLocks = [second, persisted, first]
        #expect(queue.activeResourceLocks == [first, second, persisted])
    }

    private func saved(_ h: HeadlessChatHarness, task: AgentTask, toolsStopped: Bool = false) throws -> RuntimeExecutionOwnerRecord {
        var record = try RuntimeRecoveryTestReceipt.install(task: task, run: nil, context: h.context, toolsStopped: toolsStopped)
        record.resourceClaims = [.init(taskID: task.id, resourceKey: h.workspaceURL.path, accessMode: .write,
            runMode: "task", leaseID: UUID())]
        record.cancellationRequested = true
        record.resourcesReleased = false
        let lease = try RuntimeExecutionOwner.store(in: h.context).acquire(taskID: task.id, taskOwnerID: task.persistentModelID)
        try lease.save(record)
        return record
    }

    @Test("A second queue and a reopened disk store retain the exact cancelled resource claims", arguments: AgentRuntimeAdapterRegistry.runtimeIDs)
    func diskRestartRetainsClaims(runtime: AgentRuntimeID) throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let task = h.makeTask(runtime: runtime, goal: "Owner", model: "test")
        var record = try saved(h, task: task)
        record.resourceClaims?.append(.init(taskID: task.id, resourceKey: h.workspaceURL.appendingPathComponent("other").path,
            accessMode: .readOnly, runMode: "task", leaseID: UUID()))
        do { let lease = try RuntimeExecutionOwner.store(in: h.context).acquire(taskID: task.id, taskOwnerID: task.persistentModelID); try lease.save(record) }
        try h.context.save()
        let reopened = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: Array(h.container.configurations))
        let queue = TaskQueue(poolSize: 1)
        queue.refreshResourceOwnership(in: reopened.mainContext)
        #expect(queue.activeResourceLocks == record.resourceClaims)
        let contender = TaskResourceLockClaim(taskID: UUID(), resourceKey: h.workspaceURL.path, accessMode: .write, runMode: "next")
        #expect(!queue.canAcquireResourceLocks([contender]))
        #expect(queue.resourceBlockerSummary([contender], modelContext: reopened.mainContext).contains("cleanup is not yet confirmed"))
    }

    @Test("A live resource owner is not described as unconfirmed cancellation cleanup")
    func liveOwnerStatusIsClear() throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Working owner", model: "test")
        let acquired = RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60)
        let owner = try #require(acquired)
        defer { owner.finish() }
        let queue = TaskQueue(poolSize: 1)
        queue.refreshResourceOwnership(in: h.context)
        let contender = TaskResourceLockClaim(taskID: UUID(), resourceKey: h.workspaceURL.path, accessMode: .write, runMode: "next")
        #expect(!queue.canAcquireResourceLocks([contender]))
        #expect(!queue.resourceBlockerSummary([contender], modelContext: h.context).contains("cleanup"))
        owner.requestCancellation()
        queue.refreshResourceOwnership(in: h.context)
        #expect(queue.resourceBlockerSummary([contender], modelContext: h.context).contains("cleanup is not yet confirmed"))
        // The first displayed holder is local; another persisted holder's
        // cancellation must not be attributed to that live owner.
        queue.localResourceLocks = [.init(taskID: UUID(), resourceKey: h.workspaceURL.path,
            accessMode: .readOnly, runMode: "live")]
        #expect(!queue.resourceBlockerSummary([contender], modelContext: h.context).contains("cleanup"))
    }

    @Test("An explicit follow-up cannot erase cancelled tools or move their resource fence")
    func userTurnCannotEraseQuarantine() throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Owner", model: "claude-sonnet-4-6")
        let record = try saved(h, task: task)
        task.executionRootPath = h.workspaceURL.appendingPathComponent("different").path
        let owner = RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60, newUserTurn: true)
        #expect(owner == nil)
        #expect(try RuntimeExecutionOwner.store(in: h.context).read(taskID: task.id, taskOwnerID: task.persistentModelID) == record)
    }

    @Test("A missing bound journal cannot release a live queue's claims or admit a competing task")
    func missingReceiptRetainsFence() throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Owner", model: "claude-sonnet-4-6")
        let claims = [TaskResourceLockClaim(taskID: task.id, resourceKey: h.workspaceURL.path, accessMode: .write,
            runMode: "task", leaseID: UUID())]
        let queue = TaskQueue(poolSize: 1)
        _ = queue.acquireResourceLocksIfAvailable(claims, task: task, modelContext: h.context)
        let acquired = RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60, resourceClaims: claims)
        let owner = try #require(acquired)
        let run = TaskRun(task: task); h.context.insert(run); try owner.bind(run: run)
        try FileManager.default.removeItem(at: try #require(owner.receiptURL))
        queue.releaseResourceLocks(claims, task: task, modelContext: h.context)
        #expect(queue.activeResourceLocks.contains(claims[0]))
        owner.finish()
    }

    @Test("Legacy unresolved receipts block; verified legacy completion remains usable")
    func legacyReceiptsRequireProof() throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Legacy", model: "claude-sonnet-4-6")
        var record = try saved(h, task: task)
        record.resourceClaims = nil
        record.cancellationRequested = nil
        let store = RuntimeExecutionOwner.store(in: h.context)
        do { let lease = try store.acquire(taskID: task.id, taskOwnerID: task.persistentModelID); try lease.save(record) }
        #expect(throws: (any Error).self) { try RuntimeResourceOwnership.claims(in: store) }
        record.state = .finished
        do { let lease = try store.acquire(taskID: task.id, taskOwnerID: task.persistentModelID); try lease.save(record) }
        #expect(throws: (any Error).self) { try RuntimeResourceOwnership.claims(in: store) }
        let prior = try #require(record.stopProof)
        record.stopProof = .init(executionID: prior.executionID, process: prior.process, reaped: true,
            processGroupEmpty: true, toolsStopped: true, remoteWorkExcluded: true, capturedAt: Date())
        do { let lease = try store.acquire(taskID: task.id, taskOwnerID: task.persistentModelID); try lease.save(record) }
        #expect(try RuntimeResourceOwnership.claims(in: store).isEmpty)
    }

    @Test("The store-wide admission lease prevents another owner from entering before publication")
    func globalAdmissionIsExclusive() throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Owner", model: "claude-sonnet-4-6")
        let store = RuntimeExecutionOwner.store(in: h.context)
        var admission: RuntimeExecutionOwnerStore.Lease? = try store.acquireAdmission()
        #expect(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60) == nil)
        withExtendedLifetime(admission) {}
        admission = nil
        let acquired = RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60)
        let owner = try #require(acquired)
        owner.finish()
    }

    @Test("A previously released run reacquires its admitted resources before final validation")
    func finalValidationReacquiresResources() throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Validate", model: "claude-sonnet-4-6")
        let run = TaskRun(task: task); h.context.insert(run)
        var record = try saved(h, task: task, toolsStopped: true)
        record.runID = run.id; record.resourcesReleased = true
        record.cancellationRequested = false
        let store = RuntimeExecutionOwner.store(in: h.context)
        do { let lease = try store.acquire(taskID: task.id, taskOwnerID: task.persistentModelID); try lease.save(record) }
        let admission = RuntimeExecutionOwner.acquireSettlement(task: task, run: run, context: h.context,
            resourceClaims: record.resourceClaims)
        let owner = try #require(admission.owner)
        try owner.beginSettlement()
        #expect(try RuntimeResourceOwnership.claims(in: store) == record.resourceClaims)
        #expect(owner.record.resourcesReleased == false)
        owner.requestCancellation()
        owner.finish()
        #expect(try RuntimeResourceOwnership.claims(in: store) == record.resourceClaims)
    }

    @Test("Provider utilities cannot bypass a retained task's shared-state journal")
    func providerUtilitySeesFence() async throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .antigravityCLI, goal: "Owner", model: "test")
        var record = try saved(h, task: task)
        let key = AgentRuntimeSharedStateKey(runtime: .antigravityCLI, identifier: UUID().uuidString)
        record.providerSharedStateKey = key.rawValue
        let store = RuntimeExecutionOwner.store(in: h.context)
        do { let lease = try store.acquire(taskID: task.id, taskOwnerID: task.persistentModelID); try lease.save(record) }
        let gate = AgentRuntimeSharedStateGate(processLockRoot: h.rootURL.appendingPathComponent("provider-leases"),
            registeredStoreRoots: [store.root])
        await #expect(throws: (any Error).self) { try await gate.acquire(key) }
        record.resourcesReleased = true
        do { let lease = try store.acquire(taskID: task.id, taskOwnerID: task.persistentModelID); try lease.save(record) }
        let lease = try await gate.acquire(key)
        await gate.release(lease)
    }

    @Test("Failed release persistence never grants in-memory release authority")
    func failedReleaseStaysFenced() throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Owner", model: "claude-sonnet-4-6")
        let acquired = RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60)
        let owner = try #require(acquired)
        owner.didNotLaunch()
        owner.requestCancellation()
        let root = RuntimeExecutionOwner.store(in: h.context).root
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
        owner.finish()
        #expect(!owner.persistedResourceRelease)
        #expect(try RuntimeExecutionOwner.store(in: h.context).read(taskID: task.id, taskOwnerID: task.persistentModelID)?.resourcesReleased == false)
    }
    @Test("Separate gate instances serialize provider settings and cancel parked acquisitions")
    func providerProcessLockSerializesGates() async throws {
        let key = AgentRuntimeSharedStateKey(runtime: .antigravityCLI, identifier: UUID().uuidString)
        let h = try HeadlessChatHarness()
        defer { h.cleanup() }
        let root = h.rootURL.appendingPathComponent("provider-leases")
        let firstGate = AgentRuntimeSharedStateGate(processLockRoot: root, registeredStoreRoots: [])
        let secondGate = AgentRuntimeSharedStateGate(processLockRoot: root, registeredStoreRoots: [])
        let first = try await firstGate.acquire(key)
        var admitted = false
        let waiting = Task { @MainActor in
            let lease = try await secondGate.acquire(key)
            admitted = true
            return lease
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!admitted)
        waiting.cancel()
        do { _ = try await waiting.value; Issue.record("Cancelled acquisition unexpectedly succeeded") }
        catch { #expect(error is CancellationError) }
        await firstGate.release(first)
        let next = try await secondGate.acquire(key)
        #expect(await secondGate.isHeld(next))
        await firstGate.release(first)
        #expect(await secondGate.isHeld(next))
        await secondGate.release(next)
    }

    @Test("A settlement utility journals its actual provider key and retains it on cancellation")
    func settlementUtilityPersistsClaim() async throws {
        let h = try HeadlessChatHarness(persistentStore: true)
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .claudeCode, goal: "Validate", model: "test")
        let acquired = RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60)
        let owner = try #require(acquired)
        defer { owner.finish() }
        try owner.beginSettlement()
        let scope = RuntimeSettlementExecutionScope(mayLaunch: true)
        scope.executionOwner = owner
        owner.settlementScope = scope
        let key = AgentRuntimeSharedStateKey(runtime: .antigravityCLI, identifier: UUID().uuidString)
        let store = RuntimeExecutionOwner.store(in: h.context)
        let gate = AgentRuntimeSharedStateGate(processLockRoot: h.rootURL.appendingPathComponent("provider-leases"),
            registeredStoreRoots: [store.root])
        let utility = try await RuntimeSettlementExecutionScope.$current.withValue(scope) {
            try await RuntimeUtilitySharedStateLease.acquire(key, gate: gate)
        }
        #expect(try store.read(taskID: task.id, taskOwnerID: task.persistentModelID)?.providerSharedStateKey == key.rawValue)
        owner.requestCancellation()
        await utility.release()
        #expect(try store.read(taskID: task.id, taskOwnerID: task.persistentModelID)?.providerSharedStateReleased == false)
        await #expect(throws: (any Error).self) { try await gate.acquire(key) }
        await #expect(throws: (any Error).self) {
            try await RuntimeSettlementExecutionScope.$current.withValue(scope) {
                try await RuntimeUtilitySharedStateLease.acquire(key, gate: gate)
            }
        }
    }

    @Test("Cancelling settlement terminates registered children and rejects later launches")
    func cancellationClosesSettlementScope() throws {
        let scope = RuntimeSettlementExecutionScope(mayLaunch: true)
        let didCancel = LockedFlag()
        try scope.begin(UUID(), cancel: { didCancel.set() })
        scope.cancel()
        #expect(didCancel.value)
        #expect(throws: (any Error).self) { try scope.begin(UUID()) }
        #expect(!scope.localWorkStopped)
        #expect(!scope.toolsStopped)
    }

}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.withLock { stored } }
    func set() { lock.withLock { stored = true } }
}

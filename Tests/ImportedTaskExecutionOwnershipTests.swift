import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
@testable import ASTRA

@Suite("Imported task execution ownership", .serialized)
@MainActor
struct ImportedTaskExecutionOwnershipTests {
    private func fixture() throws -> (ModelContainer, AgentTask, AgentTask) {
        let container = try ModelContainer(for: AgentTask.self, TaskTurnRequest.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let a = AgentTask(title: "A", goal: "A"), b = AgentTask(title: "B", goal: "B")
        b.id = a.id
        for task in [a, b] { container.mainContext.insert(task) }
        try container.mainContext.save()
        return (container, a, b)
    }

    private func receipt(_ task: AgentTask, spent: Int) throws -> RuntimeExecutionOwnerRecord {
        .init(taskID: task.id, ownerID: UUID(), executionID: UUID(),
            appProcess: try #require(RuntimeProcessIdentity.read(ProcessInfo.processInfo.processIdentifier)),
            runtime: "codex_cli", sessionID: task.title + "-session", state: .notStarted,
            limits: .init(tokenCeiling: 1000, turnsRemaining: 2, secondsRemaining: 30, tokensSpent: spent, costSpent: 0),
            resourceClaims: [], resourcesReleased: true, updatedAt: Date())
    }

    @Test("A copy keeps its own session and remaining allowance after reloading")
    func scopedJournalsKeepContext() throws {
        let (container, a, b) = try fixture()
        let context = container.mainContext
        let store = RuntimeExecutionOwner.store(in: context)
        defer { try? FileManager.default.removeItem(at: store.root) }
        for (task, spent) in [(a, 700), (b, 200)] {
            let lease = try store.acquire(taskID: task.id, taskOwnerID: task.persistentModelID)
            try lease.save(receipt(task, spent: spent))
        }
        let reloaded = ModelContext(container)
        let copy = try #require(try reloaded.fetch(FetchDescriptor<AgentTask>()).first { $0.persistentModelID == b.persistentModelID })
        let saved = try #require(try RuntimeExecutionOwner.existing(task: copy, context: reloaded))
        #expect(saved.sessionID == "B-session" && saved.limits.tokensRemaining == 800)
        let owner = try #require(RuntimeExecutionOwner.acquire(task: copy, context: reloaded, maxRunSeconds: 600))
        defer { owner.finish() }
        #expect(owner.isRecovery && owner.record.sessionID == "B-session")
        #expect(owner.record.limits.tokensRemaining == 800 && owner.record.limits.secondsRemaining == 30)
        #expect(try RuntimeExecutionOwner.existing(task: a, context: context)?.limits.tokensRemaining == 300)
        #expect(try store.records().count == 2)
        // Deliberately preserve the old kernel fence across both copies.
        #expect(throws: (any Error).self) { try store.acquire(taskID: a.id, taskOwnerID: a.persistentModelID) }
    }

    @Test("Unattributed legacy receipts cannot be borrowed even after the original is deleted")
    func legacyReceiptNeedsNativeProof() throws {
        let (container, a, b) = try fixture()
        let context = container.mainContext
        let store = RuntimeExecutionOwner.store(in: context)
        defer { try? FileManager.default.removeItem(at: store.root) }
        let saved = try receipt(a, spent: 700)
        do { let lease = try store.acquire(taskID: a.id); try lease.save(saved) }
        context.insert(TaskEvent(task: b, type: "imported.runtime.execution_ownership", payload: TaskEvent.payloadString(saved)))
        context.delete(a); try context.save()
        #expect(throws: (any Error).self) { try RuntimeExecutionOwner.existing(task: b, context: context) }
        if case .blocked = RuntimeExecutionOwner.retryDecision(task: b, context: context) {} else {
            Issue.record("Imported receipt authorized Retry")
        }
        #expect(try store.read(taskID: b.id) == saved)
    }

    @Test("A native audit binds the existing receipt in place and leaves the imported copy unbound")
    func migratesOnlyProvedLegacyOwner() throws {
        let (container, a, b) = try fixture()
        let context = container.mainContext
        let store = RuntimeExecutionOwner.store(in: context)
        defer { try? FileManager.default.removeItem(at: store.root) }
        let saved = try receipt(a, spent: 700)
        do { let lease = try store.acquire(taskID: a.id); try lease.save(saved) }
        context.insert(TaskEvent(task: a, eventType: TaskEventTypes.System.runtimeExecutionOwnership, payload: TaskEvent.payloadString(saved)))
        context.insert(TaskEvent(task: b, type: "imported.runtime.execution_ownership", payload: TaskEvent.payloadString(saved)))
        try context.save()
        do {
            let lease = try RuntimeTaskOwnerJournal.acquire(task: a, context: context)
            #expect(try lease.read()?.taskOwnerID == a.persistentModelID)
            #expect(try lease.read()?.limits == saved.limits)
        }
        #expect(try store.read(taskID: a.id)?.taskOwnerID == a.persistentModelID)
        #expect(try RuntimeExecutionOwner.existing(task: b, context: context) == nil)
        #expect(try store.records().count == 1)
    }

    @Test("A retained lineage cannot switch to an imported copy with the same portable identity")
    func retainedLineageRejectsForeignOwner() throws {
        let (container, a, b) = try fixture()
        let store = RuntimeExecutionOwner.store(in: container.mainContext)
        defer { try? FileManager.default.removeItem(at: store.root) }
        var previous = try receipt(a, spent: 700)
        previous.taskOwnerID = a.persistentModelID
        do {
            let lease = try store.acquire(taskID: a.id, taskOwnerID: a.persistentModelID)
            try lease.save(previous)
            try store.retain(previous)
        }
        var successor = previous
        successor.executionID = UUID(); successor.retainedExecutionHead = previous.executionID
        successor.taskOwnerID = b.persistentModelID
        #expect(throws: (any Error).self) { try store.retainedExecutions(of: successor) }
        #expect(throws: (any Error).self) {
            var foreign = previous; foreign.taskOwnerID = b.persistentModelID
            try store.retain(foreign)
        }
    }

    @Test("A rejected temporary owner does not leak its kernel lock")
    func invalidOwnerReleasesLock() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RuntimeExecutionOwnerStore(root: root), task = AgentTask(title: "Unsaved", goal: "")
        #expect(throws: (any Error).self) { try store.acquire(taskID: task.id, taskOwnerID: task.persistentModelID) }
        let lease = try store.acquire(taskID: task.id)
        withExtendedLifetime(lease) {}
    }

    @Test("Resource projection excludes only the selected local owner")
    func sameUUIDDoesNotHideForeignResources() throws {
        let (container, a, b) = try fixture()
        let context = container.mainContext
        let store = RuntimeExecutionOwner.store(in: context)
        defer { try? FileManager.default.removeItem(at: store.root) }
        let claim = TaskResourceLockClaim(taskID: a.id, resourceKey: "/synthetic/shared", accessMode: .write, runMode: "test")
        var saved = try receipt(a, spent: 700)
        saved.state = .unverified; saved.resourcesReleased = false; saved.resourceClaims = [claim]
        do { let lease = try store.acquire(taskID: a.id, taskOwnerID: a.persistentModelID); try lease.save(saved) }
        #expect(try RuntimeResourceOwnership.claims(in: store, context: context, excluding: b.id,
            excludingOwner: b.persistentModelID) == [claim])
        #expect(try RuntimeResourceOwnership.claims(in: store, context: context, excluding: a.id,
            excludingOwner: a.persistentModelID).isEmpty)
    }

    @Test("Legacy attribution precedes resource inspection so the owner cannot block itself")
    func legacyOwnerDoesNotCompeteWithItself() throws {
        let (container, a, b) = try fixture()
        let context = container.mainContext, store = RuntimeExecutionOwner.store(in: container.mainContext)
        defer { try? FileManager.default.removeItem(at: store.root) }
        let claim = TaskResourceLockClaim(taskID: a.id, resourceKey: "/synthetic/shared", accessMode: .write, runMode: "test")
        var saved = try receipt(a, spent: 700)
        saved.resourcesReleased = false; saved.resourceClaims = [claim]
        do { let lease = try store.acquire(taskID: a.id); try lease.save(saved) }
        context.insert(TaskEvent(task: a, eventType: TaskEventTypes.System.runtimeExecutionOwnership, payload: TaskEvent.payloadString(saved)))
        try context.save()
        #expect(RuntimeExecutionOwner.acquire(task: b, context: context, maxRunSeconds: 60, resourceClaims: [claim]) == nil)
        let owner = try #require(RuntimeExecutionOwner.acquire(task: a, context: context, maxRunSeconds: 60, resourceClaims: [claim]))
        defer { owner.finish() }
        #expect(owner.record.limits.tokensRemaining == 300)
        #expect(owner.receiptURL?.lastPathComponent == a.id.uuidString + ".json")
    }

    @Test("Provider references follow several generations of an attributed legacy file")
    func providerReferenceKeepsTheSameLocalOwner() async throws {
        let (container, a, _) = try fixture()
        let store = RuntimeExecutionOwner.store(in: container.mainContext)
        defer { try? FileManager.default.removeItem(at: store.root) }
        let key = AgentRuntimeSharedStateKey(runtime: .antigravityCLI, identifier: store.root.path)
        var value = try receipt(a, spent: 700)
        let legacyOwner = value.ownerID
        value.taskOwnerID = a.persistentModelID
        value.providerSharedStateKey = key.rawValue
        do { let receipt = try store.acquire(taskID: a.id); try receipt.save(value) }
        let gate = try await ProviderSharedStateProcessLock.acquire(key, root: store.root.appendingPathComponent("provider-gates"))
        try gate.handoff(key, reference: .init(journalRoot: store.root.path, taskID: a.id, ownerID: legacyOwner), prepare: {})
        for _ in 0..<3 {
            var next = try receipt(a, spent: 700)
            next.taskOwnerID = a.persistentModelID; next.legacyReferenceOwnerID = legacyOwner
            next.providerSharedStateKey = key.rawValue; next.resourcesReleased = false
            do { let receipt = try store.acquire(taskID: a.id); try receipt.save(next) }
            try gate.handoff(key, reference: .init(journalRoot: store.root.path, taskID: a.id,
                ownerID: next.ownerID, taskOwnerID: a.persistentModelID), prepare: {})
        }
        withExtendedLifetime(gate) {}
    }
}

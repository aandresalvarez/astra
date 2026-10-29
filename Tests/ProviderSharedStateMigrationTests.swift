import Foundation
import Testing
import ASTRACore
@testable import ASTRA

@Suite("Provider reservation migration preserves authority", .serialized)
@MainActor
struct ProviderSharedStateMigrationTests {
    @Test("Legacy current and retained claims block a new identity without rewriting the journal", arguments: [false, true])
    func oldClaims(retained: Bool) async throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let task = h.makeTask(runtime: .antigravityCLI, goal: "Legacy", model: "test")
        let store = RuntimeExecutionOwner.store(in: h.context)
        RuntimeProviderResourceRegistry.unregister(store.root)
        var record = try RuntimeRecoveryTestReceipt.install(task: task, run: nil, context: h.context, toolsStopped: false)
        RuntimeProviderResourceRegistry.unregister(store.root)
        let old = AgentRuntimeSharedStateKey(runtime: .antigravityCLI, identifier: h.rootURL.path + "/old-alias/settings.json")
        let key = try AgentRuntimeSharedStateKey(runtime: .antigravityCLI, fileURL: h.rootURL.appendingPathComponent("profile/settings.json"))
        record.providerSharedStateKey = retained ? "antigravity_cli:file-v1:/another/profile" : old.rawValue
        record.retainedProviderSharedStateKeys = retained ? [old.rawValue] : nil
        record.providerSharedStateReleased = false
        record.resourcesReleased = false
        do { let lease = try store.acquire(taskID: task.id, taskOwnerID: task.persistentModelID); try lease.save(record) }
        #expect(throws: RuntimeProviderResourceRegistry.Block.self) {
            try RuntimeProviderResourceRegistry.assertAvailable(key, ownerID: nil, in: [store.root])
        }
        #expect(try store.read(taskID: task.id, taskOwnerID: task.persistentModelID) == record)
    }

    @Test("Foreign legacy receipts survive a cold gate and require durable release")
    func coldLegacyReference() async throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let task = h.makeTask(runtime: .antigravityCLI, goal: "Foreign", model: "test")
        let store = RuntimeExecutionOwner.store(in: h.context)
        var record = try RuntimeRecoveryTestReceipt.install(task: task, run: nil, context: h.context, toolsStopped: false)
        RuntimeProviderResourceRegistry.unregister(store.root)
        let old = AgentRuntimeSharedStateKey(runtime: .antigravityCLI, identifier: "old-unresolved-alias")
        record.providerSharedStateKey = old.rawValue; record.providerSharedStateReleased = false; record.resourcesReleased = false
        func save() throws { let lease = try store.acquire(taskID: task.id, taskOwnerID: task.persistentModelID); try lease.save(record) }
        try save()
        let root = h.rootURL.appendingPathComponent("locks")
        do {
            let lease = try await ProviderSharedStateProcessLock.acquire(old, root: root)
            try lease.handoff(old, reference: .init(journalRoot: store.root.path, taskID: task.id, ownerID: record.ownerID)) {}
        }
        let pointers = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        let pointer = try #require(pointers.first)
        let bytes = try Data(contentsOf: pointer)
        let key = try AgentRuntimeSharedStateKey(runtime: .antigravityCLI, fileURL: h.rootURL.appendingPathComponent("profile/settings.json"))
        let cold = AgentRuntimeSharedStateGate(processLockRoot: root, registeredStoreRoots: [])
        do { _ = try await cold.acquire(key); Issue.record("Lost foreign legacy reservation") }
        catch let block as RuntimeProviderResourceRegistry.Block { #expect(block.legacyIdentity) }
        #expect(try store.read(taskID: task.id, taskOwnerID: task.persistentModelID) == record)
        #expect(try Data(contentsOf: pointer) == bytes)
        do { let lease = try store.acquire(taskID: task.id, taskOwnerID: task.persistentModelID); try FileManager.default.removeItem(at: lease.recordURL) }
        do { _ = try await cold.acquire(key); Issue.record("Missing legacy journal was treated as release") }
        catch let failure as ProviderSharedStateCompatibility.UnreadableReservation {
            #expect(failure.localizedDescription.contains("missing record is not proof"))
        }
        #expect(try Data(contentsOf: pointer) == bytes)
        record.providerSharedStateReleased = true
        try save()
        let successor = try await cold.acquire(key)
        await cold.release(successor)
        #expect(try Data(contentsOf: pointer) == bytes)
    }

    @Test("A missing v1 journal fences its own profile but leaves independent profiles available")
    func missingModernJournal() async throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let task = h.makeTask(runtime: .antigravityCLI, goal: "Modern", model: "test")
        let store = RuntimeExecutionOwner.store(in: h.context)
        var record = try RuntimeRecoveryTestReceipt.install(task: task, run: nil, context: h.context, toolsStopped: false)
        RuntimeProviderResourceRegistry.unregister(store.root)
        let key = try AgentRuntimeSharedStateKey(runtime: .antigravityCLI, fileURL: h.rootURL.appendingPathComponent("profile/settings.json"))
        record.providerSharedStateKey = key.rawValue; record.providerSharedStateReleased = false; record.resourcesReleased = false
        let root = h.rootURL.appendingPathComponent("locks")
        do { let lease = try store.acquire(taskID: task.id, taskOwnerID: task.persistentModelID); try lease.save(record) }
        do {
            let lease = try await ProviderSharedStateProcessLock.acquire(key, root: root)
            try lease.handoff(key, reference: .init(journalRoot: store.root.path, taskID: task.id, ownerID: record.ownerID)) {}
        }
        do { let lease = try store.acquire(taskID: task.id, taskOwnerID: task.persistentModelID); try FileManager.default.removeItem(at: lease.recordURL) }
        let gate = AgentRuntimeSharedStateGate(processLockRoot: root, registeredStoreRoots: [])
        do { _ = try await gate.acquire(key); Issue.record("Missing receipt admitted its profile") } catch {}
        let independent = try AgentRuntimeSharedStateKey(runtime: .antigravityCLI, fileURL: h.rootURL.appendingPathComponent("independent/settings.json"))
        let next = try await gate.acquire(independent)
        await gate.release(next)
    }
}

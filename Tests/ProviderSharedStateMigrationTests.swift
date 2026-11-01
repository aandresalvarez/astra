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
        let root = h.providerLockRoot
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
        await #expect(throws: RuntimeProviderResourceRegistry.Block.self) { try await cold.waitForPreviousWriter(key) }
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
        try await cold.waitForPreviousWriter(key)
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
        let root = h.providerLockRoot
        do { let lease = try store.acquire(taskID: task.id, taskOwnerID: task.persistentModelID); try lease.save(record) }
        do {
            let lease = try await ProviderSharedStateProcessLock.acquire(key, root: root)
            try lease.handoff(key, reference: .init(journalRoot: store.root.path, taskID: task.id, ownerID: record.ownerID)) {}
        }
        let pointers = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        let pointer = try #require(pointers.first)
        let bytes = try Data(contentsOf: pointer)
        let gate = AgentRuntimeSharedStateGate(processLockRoot: root, registeredStoreRoots: [])
        await #expect(throws: RuntimeProviderResourceRegistry.Block.self) { try await gate.waitForPreviousWriter(key) }
        do { let lease = try store.acquire(taskID: task.id, taskOwnerID: task.persistentModelID); try FileManager.default.removeItem(at: lease.recordURL) }
        await #expect(throws: ProviderSharedStateCompatibility.UnreadableReservation.self) { try await gate.waitForPreviousWriter(key) }
        do { _ = try await gate.acquire(key); Issue.record("Missing receipt admitted its profile") }
        catch let failure as ProviderSharedStateCompatibility.UnreadableReservation {
            #expect(URL(fileURLWithPath: failure.path).resolvingSymlinksInPath().path == pointer.resolvingSymlinksInPath().path)
            #expect(failure.localizedDescription.contains(failure.path))
        }
        #expect(try Data(contentsOf: pointer) == bytes)
        let independent = try AgentRuntimeSharedStateKey(runtime: .antigravityCLI, fileURL: h.rootURL.appendingPathComponent("independent/settings.json"))
        let next = try await gate.acquire(independent)
        await gate.release(next)
        // Readers never retire the pointer, even after its original writer can release.
        record.providerSharedStateReleased = true
        do { let lease = try store.acquire(taskID: task.id, taskOwnerID: task.persistentModelID); try lease.save(record) }
        try await gate.waitForPreviousWriter(key)
        #expect(try Data(contentsOf: pointer) == bytes)
    }

    @Test("A malformed modern pointer reports its exact path and remains untouched")
    func malformedModernPointer() async throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let root = h.providerLockRoot
        let key = try AgentRuntimeSharedStateKey(runtime: .antigravityCLI,
            fileURL: h.rootURL.appendingPathComponent("profile/settings.json"))
        let lock = try await ProviderSharedStateProcessLock.acquire(key, root: root)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let pointer = try #require(files.first).appendingPathExtension("json")
        let bytes = Data("{invalid ownership reference".utf8)
        try bytes.write(to: pointer)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pointer.path)
        var prepared = false
        do { try lock.handoff(key, reference: nil) { prepared = true }; Issue.record("Malformed pointer admitted its profile") }
        catch let failure as ProviderSharedStateCompatibility.UnreadableReservation {
            #expect(URL(fileURLWithPath: failure.path).resolvingSymlinksInPath().path == pointer.resolvingSymlinksInPath().path)
            #expect(failure.localizedDescription.contains(failure.path))
        }
        #expect(!prepared)
        #expect(try Data(contentsOf: pointer) == bytes)
    }

    @Test("A pre-upgrade continuation can discount only the proven prior writer of this file",
          arguments: ["stopped", "uncertain", "missing-history", "unknown-origin", "inconsistent-current", "inconsistent-archived"])
    func readerChecksArchivedWriter(evidence: String) async throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let task = h.makeTask(runtime: .antigravityCLI, goal: "Archived writer", model: "test")
        let store = RuntimeExecutionOwner.store(in: h.context)
        var writer = try RuntimeRecoveryTestReceipt.install(task: task, run: nil, context: h.context, toolsStopped: evidence != "uncertain")
        RuntimeProviderResourceRegistry.unregister(store.root)
        let key = try AgentRuntimeSharedStateKey(runtime: .antigravityCLI, fileURL: h.rootURL.appendingPathComponent("profile/settings.json"))
        writer.providerSharedStateKey = key.rawValue; writer.providerSharedStateReleased = false
        func save(_ record: RuntimeExecutionOwnerRecord) throws {
            let lease = try store.acquire(taskID: task.id, taskOwnerID: task.persistentModelID)
            try lease.save(record)
        }
        try save(writer)
        do {
            let lock = try await ProviderSharedStateProcessLock.acquire(key, root: h.providerLockRoot)
            try lock.handoff(key, reference: .init(journalRoot: store.root.path, taskID: task.id, ownerID: writer.ownerID,
                taskOwnerID: task.persistentModelID)) {}
        }
        if evidence == "unknown-origin" { writer.providerSharedStateKey = nil }
        if evidence != "missing-history" { try store.retain(writer) }
        // Older ASTRA copied the writer's key even when this Codex turn never used it.
        var continuation = writer
        continuation.runtime = "codex_cli"; continuation.executionID = UUID(); continuation.state = .unverified
        continuation.stopProof = nil; continuation.inheritedToolUncertainty = true; continuation.resourcesReleased = false
        continuation.retainedExecutionHead = writer.executionID; continuation.retainedProviderSharedStateKeys = [key.rawValue]
        continuation.providerSharedStateKey = nil
        continuation.providerSharedStateReleased = evidence == "inconsistent-current" ? false : nil
        if evidence == "inconsistent-archived" {
            // A later writer lost its direct key without ever proving that it stopped.
            continuation.runtime = "antigravity_cli"
            continuation.providerSharedStateReleased = false
            try store.retain(continuation)
            continuation.retainedExecutionHead = continuation.executionID
            continuation.executionID = UUID()
            continuation.runtime = "codex_cli"
            continuation.providerSharedStateReleased = nil
        }
        try save(continuation)
        for roots in [[], [store.root]] {
            let gate = AgentRuntimeSharedStateGate(processLockRoot: h.providerLockRoot, registeredStoreRoots: roots)
            if evidence == "stopped" {
                try await gate.waitForPreviousWriter(key)
            } else {
                await #expect(throws: RuntimeProviderResourceRegistry.Block.self) { try await gate.waitForPreviousWriter(key) }
            }
            await #expect(throws: RuntimeProviderResourceRegistry.Block.self) { try await gate.acquire(key) }
        }
        #expect(try store.read(taskID: task.id, taskOwnerID: task.persistentModelID) == continuation)
    }

    @Test("A reader needs stop proof for the current writer and any inherited writer", arguments: [true, false], [false, true])
    func readerChecksCurrentWriter(toolsStopped: Bool, inheritsUnprovenWriter: Bool) async throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let task = h.makeTask(runtime: .antigravityCLI, goal: "Current writer", model: "test")
        let store = RuntimeExecutionOwner.store(in: h.context)
        let key = try AgentRuntimeSharedStateKey(runtime: .antigravityCLI, fileURL: h.rootURL.appendingPathComponent("profile/settings.json"))
        var writer = try RuntimeRecoveryTestReceipt.install(task: task, run: nil, context: h.context, toolsStopped: toolsStopped)
        RuntimeProviderResourceRegistry.unregister(store.root)
        writer.providerSharedStateKey = key.rawValue
        writer.providerSharedStateReleased = false
        writer.resourcesReleased = false
        if inheritsUnprovenWriter {
            var prior = writer
            prior.executionID = UUID()
            prior.state = .unverified
            prior.stopProof = nil
            try store.retain(prior)
            writer.retainedExecutionHead = prior.executionID
            writer.retainedProviderSharedStateKeys = [key.rawValue]
        }
        #expect(writer.canReplace == toolsStopped)
        do { let lease = try store.acquire(taskID: task.id, taskOwnerID: task.persistentModelID); try lease.save(writer) }
        do {
            let lock = try await ProviderSharedStateProcessLock.acquire(key, root: h.providerLockRoot)
            try lock.handoff(key, reference: .init(journalRoot: store.root.path, taskID: task.id, ownerID: writer.ownerID,
                taskOwnerID: task.persistentModelID)) {}
        }
        let pointer = try #require(try FileManager.default.contentsOfDirectory(at: h.providerLockRoot, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "json" })
        let bytes = try Data(contentsOf: pointer)
        let cold = AgentRuntimeSharedStateGate(processLockRoot: h.providerLockRoot, registeredStoreRoots: [])
        if toolsStopped && !inheritsUnprovenWriter {
            try RuntimeProviderResourceRegistry.assertAvailable(key, ownerID: nil, in: [store.root], reading: true)
            try await cold.waitForPreviousWriter(key)
        } else {
            #expect(throws: RuntimeProviderResourceRegistry.Block.self) {
                try RuntimeProviderResourceRegistry.assertAvailable(key, ownerID: nil, in: [store.root], reading: true)
            }
            await #expect(throws: RuntimeProviderResourceRegistry.Block.self) { try await cold.waitForPreviousWriter(key) }
        }
        #expect(throws: RuntimeProviderResourceRegistry.Block.self) {
            try RuntimeProviderResourceRegistry.assertAvailable(key, ownerID: nil, in: [store.root])
        }
        await #expect(throws: RuntimeProviderResourceRegistry.Block.self) { try await cold.acquire(key) }
        #expect(try store.read(taskID: task.id, taskOwnerID: task.persistentModelID) == writer)
        #expect(try Data(contentsOf: pointer) == bytes)
    }

    @Test("A proven writer's pointer does not turn its reader Retry into a writer after restart", arguments: [false, true])
    func retryOfReleasedWriter(scopedPointer: Bool) async throws {
        let h = try HeadlessChatHarness(persistentStore: true); defer { h.cleanup() }
        let task = h.makeTask(runtime: .antigravityCLI, goal: "Retry on the same account", model: "test")
        let store = RuntimeExecutionOwner.store(in: h.context)
        let key = try AgentRuntimeSharedStateKey(runtime: .antigravityCLI, fileURL: h.rootURL.appendingPathComponent("profile/settings.json"))
        var previous = try RuntimeRecoveryTestReceipt.install(task: task, run: nil, context: h.context)
        previous.providerSharedStateKey = key.rawValue
        previous.providerSharedStateReleased = false // Crash after stop proof, before releasing the writer.
        do { let lease = try store.acquire(taskID: task.id, taskOwnerID: task.persistentModelID); try lease.save(previous) }
        let root = h.providerLockRoot
        do {
            let old = try await ProviderSharedStateProcessLock.acquire(key, root: root)
            try old.handoff(key, reference: .init(journalRoot: store.root.path, taskID: task.id, ownerID: previous.ownerID,
                taskOwnerID: scopedPointer ? task.persistentModelID : nil)) {}
        }
        let pointer = try #require(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "json" })
        let bytes = try Data(contentsOf: pointer)
        let retry = try #require(RuntimeExecutionOwner.acquire(task: task, context: h.context, maxRunSeconds: 60))
        defer { retry.finish() }
        let cold = AgentRuntimeSharedStateGate(processLockRoot: root, registeredStoreRoots: [])
        try await cold.waitForPreviousWriter(key, owner: retry)
        try retry.prepareLaunch(sessionID: "new-session")
        try await cold.waitForPreviousWriter(key)
        #expect(retry.record.providerSharedStateKey == nil && retry.record.resourcesReleased == false)
        #expect(retry.record.limits == previous.limits)
        #expect(try Data(contentsOf: pointer) == bytes)
    }

    @Test("Handoff preserves cancellation and unrelated owner failures", arguments: ["cancel", "busy", "writeFailed"])
    func preservesHandoffFailure(kind: String) async throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let key = try AgentRuntimeSharedStateKey(runtime: .antigravityCLI,
            fileURL: h.rootURL.appendingPathComponent("profile/settings.json"))
        let lock = try await ProviderSharedStateProcessLock.acquire(key, root: h.providerLockRoot)
        do {
            try lock.handoff(key, reference: nil) {
                if kind == "cancel" { throw CancellationError() }
                if kind == "busy" { throw RuntimeExecutionOwnerStore.Failure.busy }
                throw RuntimeExecutionOwnerStore.Failure.writeFailed
            }
            Issue.record("Handoff swallowed a preparation failure")
        } catch is CancellationError { #expect(kind == "cancel") }
        catch RuntimeExecutionOwnerStore.Failure.busy { #expect(kind == "busy") }
        catch RuntimeExecutionOwnerStore.Failure.writeFailed { #expect(kind == "writeFailed") }
    }
}

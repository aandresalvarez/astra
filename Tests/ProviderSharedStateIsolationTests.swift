import Darwin
import Foundation
import Testing
import ASTRACore
@testable import ASTRA

@Suite("Provider test coordination is explicit", .serialized)
@MainActor
struct ProviderSharedStateIsolationTests {
    @Test("Bundle bootstrap installs isolation before suites, including direct SwiftPM runs")
    func bootstrap() throws {
        let id = try #require(ProcessInfo.processInfo.environment[ProviderSharedStateNamespace.environmentKey])
        let uuid = try #require(UUID(uuidString: id))
        #expect(try ProviderSharedStateNamespace.resolve() == ProviderSharedStateNamespace.isolatedRoot(uuid))
        #expect(try ProviderSharedStateNamespace.resolve() != ProviderSharedStateNamespace.sharedRoot)
    }

    @Test("Inherited UUID chooses the same namespace without runner-name or XCTest heuristics")
    func inheritedIdentity() throws {
        let id = UUID()
        let environment = [ProviderSharedStateNamespace.environmentKey: id.uuidString]
        #expect(try ProviderSharedStateNamespace.resolve(override: nil, environment: environment, testBundleLoaded: false)
            == ProviderSharedStateNamespace.isolatedRoot(id))
        #expect(try ProviderSharedStateNamespace.resolve(override: nil, environment: environment, testBundleLoaded: true)
            == ProviderSharedStateNamespace.isolatedRoot(id))
        #expect(try ProviderSharedStateNamespace.resolve(override: nil, environment: [:], testBundleLoaded: false)
            == ProviderSharedStateNamespace.sharedRoot)
    }

    @Test("Lost/malformed inheritance and non-temporary overrides fail closed")
    func unsafeRoots() throws {
        for value in ["", "../provider-state", "/private/tmp/fixture"] {
            #expect(throws: RuntimeExecutionOwnerStore.Failure.self) {
                try ProviderSharedStateNamespace.resolve(override: nil,
                    environment: [ProviderSharedStateNamespace.environmentKey: value], testBundleLoaded: false)
            }
        }
        #expect(throws: RuntimeExecutionOwnerStore.Failure.self) {
            try ProviderSharedStateNamespace.resolve(override: nil, environment: [:], testBundleLoaded: true)
        }
        #expect(throws: RuntimeExecutionOwnerStore.Failure.self) {
            try ProviderSharedStateNamespace.resolve(override: ProviderSharedStateNamespace.sharedRoot)
        }
        let alias = FileManager.default.temporaryDirectory.appendingPathComponent("astra-coordination-alias-\(UUID())")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: ProviderSharedStateNamespace.sharedRoot)
        defer { try? FileManager.default.removeItem(at: alias) }
        #expect(throws: RuntimeExecutionOwnerStore.Failure.self) {
            try ProviderSharedStateNamespace.resolve(override: alias)
        }
        // Identity construction only resolves the path; no settings are read.
        let outside = try AgentRuntimeSharedStateKey(runtime: .antigravityCLI,
            fileURL: URL(fileURLWithPath: "/Users/synthetic-no-access/profile/settings.json"))
        #expect(throws: RuntimeExecutionOwnerStore.Failure.self) {
            try ProviderSharedStateNamespace.validateResource(outside)
        }
    }

    @Test("Default acquisitions and handoffs stay isolated through errors and cancellation")
    func failedAndCancelledPublication() async throws {
        let h = try HeadlessChatHarness(); defer { h.cleanup() }
        let task = h.makeTask(runtime: .antigravityCLI, goal: "Synthetic", model: "test")
        var record = try RuntimeRecoveryTestReceipt.install(task: task, run: nil, context: h.context, toolsStopped: false)
        let key = try AgentRuntimeSharedStateKey(runtime: .antigravityCLI,
            fileURL: h.rootURL.appendingPathComponent("profile/settings.json"))
        record.providerSharedStateKey = key.rawValue
        let store = RuntimeExecutionOwner.store(in: h.context)
        do { let journal = try store.acquire(taskID: task.id, taskOwnerID: task.persistentModelID); try journal.save(record) }
        let reference = RuntimeProviderOwnershipReference(journalRoot: store.root.path, taskID: task.id,
            ownerID: record.ownerID, taskOwnerID: task.persistentModelID)
        let root = try ProviderSharedStateNamespace.resolve()
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
        do {
            let lock = try await ProviderSharedStateProcessLock.acquire(key)
            #expect(throws: CancellationError.self) { try lock.handoff(key, reference: reference) { throw CancellationError() } }
            try lock.handoff(key, reference: reference) {}
        }
        let added = Set(try FileManager.default.contentsOfDirectory(atPath: root.path)).subtracting(before)
        #expect(try added.filter { $0.hasSuffix(".json") }.contains {
            try JSONDecoder().decode(RuntimeProviderOwnershipReference.self,
                from: Data(contentsOf: root.appendingPathComponent($0))) == reference
        })
        let gate = AgentRuntimeSharedStateGate(registeredStoreRoots: [])
        do { _ = try await gate.acquire(key); Issue.record("Unverified fixture admitted") }
        catch is RuntimeProviderResourceRegistry.Block {}
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await ProviderSharedStateProcessLock.acquire(key)
        }
        do { try await cancelled.value; Issue.record("Cancellation admitted") } catch is CancellationError {}
        #expect(try store.read(taskID: task.id, taskOwnerID: task.persistentModelID) == record)
    }

    @Test("An explicitly selected renamed helper still publishes only in test scope",
          .enabled(if: ProcessInfo.processInfo.environment["ASTRA_NAMESPACE_RENAMED_HELPER_PROBE"] == "1"))
    func renamedHelper() async throws {
        // Run alone in a separate raw SwiftPM invocation. This changes the
        // exact property the old process-name heuristic consulted.
        let original = ProcessInfo.processInfo.processName
        ProcessInfo.processInfo.processName = "inc10-renamed-provider-helper"
        defer { ProcessInfo.processInfo.processName = original }
        try await failedAndCancelledPublication()
    }
}

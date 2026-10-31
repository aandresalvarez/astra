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
        let ordinary = try ProviderSharedStateNamespace.resolve(override: nil, environment: [:], testBundleLoaded: false)
        #expect(try ProviderSharedStateIdentity.canonicalPath(ordinary.path) ==
            ProviderSharedStateIdentity.canonicalPath(ProviderSharedStateNamespace.sharedRoot.path))
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
            _ = try ProviderSharedStateNamespace.resolve(key: outside)
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
        let root = h.providerLockRoot
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

    @Test("A test run cannot reserve another run's physical profile or an ordinary temporary app profile")
    func physicalProfileBelongsToTestRun() throws {
        let fixture = try ProviderCoordinationFixture()
        let own = fixture.data
        defer { try? FileManager.default.removeItem(at: own) }
        let other = ProviderSharedStateNamespace.isolatedRoot(UUID())
        let app = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = "profile/settings.json"
        let ownKey = try AgentRuntimeSharedStateKey(runtime: .antigravityCLI, fileURL: own.appendingPathComponent(file))
        #expect(try ProviderSharedStateNamespace.resolve(key: ownKey) == fixture.coordination)
        #expect(try ProviderSharedStateNamespace.resolve(override: fixture.coordination, key: ownKey) == fixture.coordination)
        #expect(throws: RuntimeExecutionOwnerStore.Failure.self) {
            try ProviderSharedStateNamespace.resolve(override: own.appendingPathComponent("another-lock"), key: ownKey)
        }
        let foreignEnvironment = [ProviderSharedStateNamespace.environmentKey: UUID().uuidString]
        for environment in [[:], foreignEnvironment, ["TMPDIR": own.path]] {
            #expect(throws: RuntimeExecutionOwnerStore.Failure.self) {
                try ProviderSharedStateNamespace.resolve(override: nil, environment: environment, testBundleLoaded: false, key: ownKey)
            }
        }
        if FileManager.default.fileExists(atPath: "/System/Volumes/Data/private/tmp") {
            let physical = try ProviderSharedStateIdentity.canonicalPath(own.path)
            let aliasHome = URL(fileURLWithPath: "/System/Volumes/Data" + physical)
            try #require(FileManager.default.fileExists(atPath: aliasHome.path))
            let dataAlias = aliasHome.appendingPathComponent(file)
            let aliasKey = try AgentRuntimeSharedStateKey(runtime: .antigravityCLI, fileURL: dataAlias)
            #expect(throws: RuntimeExecutionOwnerStore.Failure.self) {
                try ProviderSharedStateNamespace.resolve(override: nil, environment: [:], testBundleLoaded: false, key: aliasKey)
            }
        }
        for foreign in [other, app] {
            let key = try AgentRuntimeSharedStateKey(runtime: .antigravityCLI, fileURL: foreign.appendingPathComponent(file))
            #expect(throws: RuntimeExecutionOwnerStore.Failure.self) { _ = try ProviderSharedStateNamespace.resolve(key: key) }
            #expect(throws: RuntimeExecutionOwnerStore.Failure.self) { try ProviderSharedStateNamespace.resolve(override: foreign) }
        }
    }

    @Test("Discarding a workspace preserves its uncertain legacy reservation within that fixture")
    func discardedWorkspaceKeepsFixtureReservation() async throws {
        let h = try HeadlessChatHarness()
        defer { h.cleanup() }
        let task = h.makeTask(runtime: .antigravityCLI, goal: "Synthetic legacy owner", model: "test")
        let legacy = AgentRuntimeSharedStateKey(runtime: .antigravityCLI, identifier: "unresolved-fixture-alias")
        let settings = try AgentRuntimeSharedStateKey(runtime: .antigravityCLI, fileURL: h.rootURL.appendingPathComponent("settings.json"))
        let store = RuntimeExecutionOwner.store(in: h.context)
        var record = try RuntimeRecoveryTestReceipt.install(task: task, run: nil, context: h.context, toolsStopped: false)
        record.providerSharedStateKey = legacy.rawValue
        record.providerSharedStateReleased = false
        record.resourcesReleased = false
        let ref = RuntimeProviderOwnershipReference(journalRoot: store.root.path, taskID: task.id, ownerID: record.ownerID,
            taskOwnerID: task.persistentModelID)
        do {
            let journal = try store.acquire(taskID: task.id, taskOwnerID: task.persistentModelID)
            try journal.save(record)
            let lock = try await ProviderSharedStateProcessLock.acquire(legacy, root: h.providerLockRoot)
            try lock.handoff(legacy, reference: ref) {}
        }
        await h.cleanup().value
        #expect(!FileManager.default.fileExists(atPath: h.rootURL.path))
        let gate = AgentRuntimeSharedStateGate(registeredStoreRoots: [])
        do { _ = try await gate.acquire(settings); Issue.record("Discarding test data released an uncertain legacy owner") }
        catch let block as RuntimeProviderResourceRegistry.Block { #expect(block.ownerID == ref.ownerID && block.legacyIdentity) }
        let independent = try ProviderCoordinationFixture()
        defer { try? FileManager.default.removeItem(at: independent.data) }
        let lease = try await gate.acquire(.init(runtime: .antigravityCLI, fileURL: independent.data.appendingPathComponent("settings.json")))
        await gate.release(lease)
    }

    @Test("Live probes use the physical QA home and its own fixture's settings")
    func liveProfileAndSettingsStayTogether() throws {
        let fm = FileManager.default
        let good = try ProviderCoordinationFixture().data
        let second = try ProviderCoordinationFixture().data
        let outside = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { for dir in [good, second, outside] { try? fm.removeItem(at: dir) } }
        let settings = AntigravityCLIRuntime.settingsURL(providerHomeDirectory: good.path)
        try fm.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: settings)
        for home in [second, outside] {
            let foreign = AntigravityCLIRuntime.settingsURL(providerHomeDirectory: home.path)
            try fm.createDirectory(at: foreign.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: foreign, withDestinationURL: settings)
            #expect(throws: LiveProviderReadiness.Failure.self) { try ProviderCoordinationFixture.liveAntigravityHome(home.path) }
        }
        let alias = outside.appendingPathComponent("qa-home")
        try fm.createSymbolicLink(at: alias, withDestinationURL: good)
        #expect(try ProviderCoordinationFixture.liveAntigravityHome(alias.path) == ProviderSharedStateIdentity.canonicalPath(good.path))
    }

    @Test("Changing a directory during handoff cannot remove a different owner's pointer", arguments: [false, true])
    func pointerStaysWithAcquiredDirectory(replaceDirectory: Bool) async throws {
        let fixture = try ProviderSharedStateNamespace.resolve().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let fm = FileManager.default
        let original = fixture.appendingPathComponent("original/locks")
        let other = fixture.appendingPathComponent("other/locks")
        for dir in [original, other] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let alias = fixture.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: original.deletingLastPathComponent())
        let key = AgentRuntimeSharedStateKey(runtime: .antigravityCLI, identifier: "fixture-local-lock")
        let lock = try await ProviderSharedStateProcessLock.acquire(key, root: alias.appendingPathComponent("locks"))
        let name = try #require(try fm.contentsOfDirectory(atPath: original.path).first)
        let neighbor = other.appendingPathComponent(name + ".json")
        let sentinel = Data("neighbor's protected pointer".utf8)
        try sentinel.write(to: neighbor)
        var prepared = false
        do {
            try lock.handoff(key, reference: nil) {
                if replaceDirectory {
                    try fm.moveItem(at: original, to: fixture.appendingPathComponent("moved"))
                    try fm.createSymbolicLink(at: original, withDestinationURL: other)
                } else {
                    try fm.removeItem(at: alias)
                    try fm.createSymbolicLink(at: alias, withDestinationURL: other.deletingLastPathComponent())
                }
                prepared = true
            }
        } catch is ProviderSharedStateCompatibility.UnreadableReservation { /* A changed lock directory may fail closed. */ }
        #expect(prepared)
        #expect(try Data(contentsOf: neighbor) == sentinel)
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

import Foundation
import Testing
import ASTRACore
@testable import ASTRA

@Suite("Fixture reservation recovery rehearsal", .serialized)
@MainActor
struct ProviderFixtureRecoveryTests {
    private func fixture(_ service: ProviderFixtureRecoveryService, fault: String = "safe") async throws
        -> (AgentRuntimeSharedStateKey, RuntimeExecutionOwnerRecord, RuntimeProviderOwnershipReference) {
        let dead = RuntimeProcessIdentity(pid: Int32.max, startedSeconds: 1, startedMicroseconds: 1)
        let live = try #require(RuntimeProcessIdentity.read(ProcessInfo.processInfo.processIdentifier))
        let execution = UUID()
        let key = AgentRuntimeSharedStateKey(runtime: .antigravityCLI, identifier: service.root.path + "/\(UUID())/settings.json")
        var record = RuntimeExecutionOwnerRecord(taskID: UUID(), ownerID: UUID(), executionID: execution,
            appProcess: fault == "app" ? live : dead, providerProcess: fault == "provider" ? live : dead,
            runtime: "antigravity_cli", state: fault == "tools" ? .unverified : .stopped,
            limits: .init(tokenCeiling: 1000, turnsRemaining: 3, secondsRemaining: 60, tokensSpent: 400, costSpent: 0.1),
            stopProof: .init(executionID: execution, process: fault == "provider" ? live : dead,
                reaped: fault != "unreaped", processGroupEmpty: fault != "group", toolsStopped: fault != "tools",
                remoteWorkExcluded: fault != "remote", capturedAt: Date()), updatedAt: Date())
        record.providerSharedStateKey = key.rawValue
        if fault == "notStartedWithoutProof" { record.state = .notStarted; record.stopProof = nil }
        record.providerSharedStateReleased = false; record.resourcesReleased = false
        record.settlementInProgress = fault == "settling"
        record.settlementLocalWorkStopped = fault != "children"
        record.settlementToolsStopped = fault != "settlementTools"
        if fault == "retained" { record.retainedExecutionHead = UUID() }
        let store = RuntimeExecutionOwnerStore(root: service.root.appendingPathComponent("journals"))
        do { let journal = try store.acquire(taskID: record.taskID); try journal.save(record) }
        let reference = RuntimeProviderOwnershipReference(journalRoot: store.root.path, taskID: record.taskID, ownerID: record.ownerID)
        do {
            let lock = try await ProviderSharedStateProcessLock.acquire(key, root: service.root)
            try lock.handoff(key, reference: reference) {}
        }
        return (key, record, reference)
    }

    @Test("A verified synthetic legacy pointer is archived and retired idempotently; its journal never changes")
    func verified() async throws {
        let service = try ProviderFixtureRecoveryService()
        defer { try? FileManager.default.removeItem(at: service.root) }
        let (key, record, reference) = try await fixture(service)
        let ticket = try service.capture(key: key, reference: reference)
        let modern = try AgentRuntimeSharedStateKey(runtime: .antigravityCLI,
            fileURL: service.profile.appendingPathComponent("independent/settings.json"))
        let gate = AgentRuntimeSharedStateGate(processLockRoot: service.root, registeredStoreRoots: [])
        do { _ = try await gate.acquire(modern); Issue.record("Legacy reservation lost") }
        catch is RuntimeProviderResourceRegistry.Block {}
        #expect(try await service.retire(ticket) == .retired)
        #expect(try await service.retire(ticket) == .alreadyRetired)
        let journal = try RuntimeExecutionOwnerStore(root: URL(fileURLWithPath: reference.journalRoot)).read(taskID: record.taskID)
        #expect(journal == record)
        let audit = try FileManager.default.contentsOfDirectory(at: service.root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "retired" }
        #expect(audit.count == 1)
        let auditURL = try #require(audit.first)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: auditURL)) as? [String: Any])
        #expect(object["executionID"] as? String == record.executionID.uuidString)
        #expect(object["pointer"] != nil && object["journal"] != nil)
        let lease = try await gate.acquire(modern)
        await gate.release(lease)
        let pointer = auditURL.deletingPathExtension().appendingPathExtension("json")
        try FileManager.default.createSymbolicLink(at: pointer, withDestinationURL: service.root.appendingPathComponent("missing"))
        await #expect(throws: ProviderFixtureRecoveryService.Failure.self) { try await service.retire(ticket) }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: pointer.path).hasSuffix("/missing"))
    }

    @Test("Absent PIDs and completed local settlement cannot replace tool proof", arguments:
        ["app", "provider", "tools", "unreaped", "group", "remote", "settling", "children", "settlementTools", "retained", "notStartedWithoutProof"])
    func preservesUnverified(fault: String) async throws {
        let service = try ProviderFixtureRecoveryService()
        defer { try? FileManager.default.removeItem(at: service.root) }
        let (key, record, reference) = try await fixture(service, fault: fault)
        let ticket = try service.capture(key: key, reference: reference)
        let before = try snapshot(service.root)
        do { _ = try await service.retire(ticket); Issue.record("Unsafe fixture retired: \(fault)") }
        catch is ProviderFixtureRecoveryService.Failure {}
        #expect(try snapshot(service.root) == before)
        #expect(try RuntimeExecutionOwnerStore(root: URL(fileURLWithPath: reference.journalRoot)).read(taskID: record.taskID) == record)
    }

    @Test("Changed owners, missing journals, busy workers and audit failures cannot retire a captured fixture", arguments:
        ["owner", "missing", "busy", "audit", "provenance"])
    func changedEvidence(fault: String) async throws {
        let service = try ProviderFixtureRecoveryService()
        defer { try? FileManager.default.removeItem(at: service.root) }
        let (key, record, reference) = try await fixture(service)
        let ticket = try service.capture(key: key, reference: reference)
        let store = RuntimeExecutionOwnerStore(root: URL(fileURLWithPath: reference.journalRoot))
        var held: RuntimeExecutionOwnerStore.Lease? = try store.acquire(taskID: record.taskID)
        if fault == "missing" { try FileManager.default.removeItem(at: #require(held).recordURL) }
        if fault != "busy" { held = nil }
        let pointer = try #require(FileManager.default.contentsOfDirectory(at: service.root, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "json" })
        if fault == "owner" {
            let foreign = RuntimeProviderOwnershipReference(journalRoot: reference.journalRoot, taskID: reference.taskID, ownerID: UUID())
            try JSONEncoder().encode(foreign).write(to: pointer)
        }
        if fault == "audit" { try Data("unrelated audit".utf8).write(to: pointer.deletingPathExtension().appendingPathExtension("retired")) }
        if fault == "provenance" { try FileManager.default.removeItem(at: pointer.deletingPathExtension().appendingPathExtension("fixture")) }
        let before = try snapshot(service.root)
        do { _ = try await service.retire(ticket); Issue.record("Changed fixture retired") }
        catch {}
        #expect(try snapshot(service.root) == before)
        withExtendedLifetime(held) {}
    }

    @Test("A non-verifiable neighbor stays blocked after another fixture is retired")
    func foreignReservation() async throws {
        let service = try ProviderFixtureRecoveryService()
        defer { try? FileManager.default.removeItem(at: service.root) }
        let (key, _, reference) = try await fixture(service)
        let ticket = try service.capture(key: key, reference: reference)
        _ = try await fixture(service, fault: "tools") // No provenance ticket for this owner.
        let before = try snapshot(service.root)
        #expect(try await service.retire(ticket) == .retired)
        let after = try snapshot(service.root)
        var removed: [String] = []
        for (path, bytes) in before {
            if let remaining = after[path] { #expect(remaining == bytes) }
            else { removed.append(path) }
        }
        #expect(removed.count == 1)
        let removedPath = try #require(removed.first)
        let removedReference = try JSONDecoder().decode(RuntimeProviderOwnershipReference.self,
            from: #require(before[removedPath]))
        #expect(removedReference == reference)
        let modern = try AgentRuntimeSharedStateKey(runtime: .antigravityCLI, fileURL: service.profile.appendingPathComponent("profile/settings.json"))
        let gate = AgentRuntimeSharedStateGate(processLockRoot: service.root, registeredStoreRoots: [])
        do { _ = try await gate.acquire(modern); Issue.record("Foreign reservation bypassed") }
        catch is RuntimeProviderResourceRegistry.Block {}
        #expect(throws: ProviderFixtureRecoveryService.Failure.self) {
            try service.capture(key: key, reference: .init(journalRoot: ProviderSharedStateNamespace.sharedRoot.path,
                taskID: reference.taskID, ownerID: reference.ownerID))
        }
    }

    private func snapshot(_ root: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let url as URL in enumerator where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[String(url.path.dropFirst(root.path.count))] = try Data(contentsOf: url)
        }
        return result
    }

    @Test("An identical replacement cannot substitute a busy task lease during recovery",
          arguments: ["root", "journals", "lock"])
    func swappedRehearsal(replaced: String) async throws {
        let service = try ProviderFixtureRecoveryService()
        let moved = service.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { for dir in [service.root, moved] { try? FileManager.default.removeItem(at: dir) } }
        let (key, _, reference) = try await fixture(service)
        let ticket = try service.capture(key: key, reference: reference)
        let before = try snapshot(service.root)
        let store = RuntimeExecutionOwnerStore(root: URL(fileURLWithPath: reference.journalRoot))
        let source = replaced == "root" ? service.root : (replaced == "journals" ? store.root :
            store.root.appendingPathComponent(reference.taskID.uuidString + ".lock"))
        let original = replaced == "lock" ? nil : try snapshot(source)
        let originalLock = replaced == "lock" ? try Data(contentsOf: source) : nil
        let busy = try store.acquire(taskID: reference.taskID, taskOwnerID: reference.taskOwnerID)
        defer { withExtendedLifetime(busy) {} }
        await #expect(throws: RuntimeExecutionOwnerStore.Failure.self) {
            try await service.retire(ticket) {
                try FileManager.default.moveItem(at: source, to: moved)
                try FileManager.default.copyItem(at: moved, to: source)
            }
        }
        if let original { #expect(try snapshot(moved) == original) }
        if let originalLock { #expect(try Data(contentsOf: moved) == originalLock) }
        #expect(try snapshot(service.root) == before)
    }

    @Test("Cancellation while a fixture's provider gate is held preserves its provenance and pointer")
    func cancelledRecovery() async throws {
        let service = try ProviderFixtureRecoveryService()
        defer { try? FileManager.default.removeItem(at: service.root) }
        let (key, _, reference) = try await fixture(service)
        let ticket = try service.capture(key: key, reference: reference)
        let held = try await ProviderSharedStateProcessLock.acquire(key, root: service.root)
        let before = try snapshot(service.root)
        let retirement = Task { try await service.retire(ticket) }
        try await Task.sleep(for: .milliseconds(100))
        retirement.cancel()
        do { _ = try await retirement.value; Issue.record("Cancelled recovery retired the fixture") }
        catch is CancellationError {}
        #expect(try snapshot(service.root) == before)
        withExtendedLifetime(held) {}
    }
}

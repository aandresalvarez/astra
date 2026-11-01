import Darwin
import Foundation
import Testing
import ASTRACore
@testable import ASTRA

@Suite("Fixture reservation recovery rehearsal", .serialized)
@MainActor
struct ProviderFixtureRecoveryTests {
    private func publish(_ service: ProviderFixtureRecoveryService, fault: String) async throws
        -> (AgentRuntimeSharedStateKey, RuntimeProviderOwnershipReference, ProviderSharedStateProcessLock) {
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
        let lock = try await ProviderSharedStateProcessLock.acquire(key, root: service.root)
        try lock.handoff(key, reference: reference) {}
        return (key, reference, lock)
    }

    private func fixture(_ service: ProviderFixtureRecoveryService, fault: String = "safe") async throws
        -> ProviderFixtureRecoveryService.Ticket {
        let (key, reference, lock) = try await publish(service, fault: fault)
        return try service.capture(key: key, reference: reference, holding: lock)
    }

    @Test("A verified synthetic legacy pointer is archived and retired idempotently; its journal never changes")
    func verified() async throws {
        let service = try ProviderFixtureRecoveryService()
        defer { try? FileManager.default.removeItem(at: service.root) }
        let ticket = try await fixture(service)
        let record = ticket.record
        let reference = ticket.reference
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
        #expect(object["providerLock"] != nil && object["taskLock"] != nil)
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
        let ticket = try await fixture(service, fault: fault)
        let record = ticket.record
        let reference = ticket.reference
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
        let ticket = try await fixture(service)
        let record = ticket.record
        let reference = ticket.reference
        let store = RuntimeExecutionOwnerStore(root: URL(fileURLWithPath: reference.journalRoot))
        var held: RuntimeExecutionOwnerStore.Lease? = try store.acquire(taskID: record.taskID)
        if fault == "missing" { try FileManager.default.removeItem(at: #require(held).recordURL) }
        if fault != "busy" { held = nil }
        let pointer = try #require(FileManager.default.contentsOfDirectory(at: service.root, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "json" })
        if fault == "lockPermissions" {
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: pointer.deletingPathExtension().path)
        }
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
        let ticket = try await fixture(service)
        let key = ticket.key
        let reference = ticket.reference
        _ = try await publish(service, fault: "tools") // No provenance ticket for this owner.
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
        let provider = try await ProviderSharedStateProcessLock.acquire(key, root: service.root)
        #expect(throws: ProviderFixtureRecoveryService.Failure.self) {
            try service.capture(key: key, reference: .init(journalRoot: ProviderSharedStateNamespace.sharedRoot.path,
                taskID: reference.taskID, ownerID: reference.ownerID), holding: provider)
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
        let ticket = try await fixture(service)
        let reference = ticket.reference
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

    @Test("Replacing the provider lock cannot authorize retirement", arguments: [false, true])
    func providerLockReplacement(duringRetirement: Bool) async throws {
        let service = try ProviderFixtureRecoveryService()
        defer { try? FileManager.default.removeItem(at: service.root) }
        let ticket = try await fixture(service)
        let key = ticket.key
        let pointer = try #require(FileManager.default.contentsOfDirectory(at: service.root, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "json" })
        let original = pointer.deletingPathExtension()
        let moved = service.root.appendingPathComponent("original-lock")
        let before = try snapshot(service.root)
        func replaceLock() throws {
            try FileManager.default.moveItem(at: original, to: moved)
            try FileManager.default.copyItem(at: moved, to: original)
        }
        let held = duringRetirement ? nil : try await ProviderSharedStateProcessLock.acquire(key, root: service.root)
        defer { withExtendedLifetime(held) {} }
        if !duringRetirement { try replaceLock() }
        await #expect(throws: RuntimeExecutionOwnerStore.Failure.self) {
            try await service.retire(ticket) { if duringRetirement { try replaceLock() } }
        }
        var after = try snapshot(service.root)
        #expect(after.removeValue(forKey: "/original-lock") != nil)
        #expect(after == before)
    }

    @Test("Retirement preserves missing locks and journals, including after a verified retirement",
          arguments: ["provider", "task", "journals"], [false, true])
    func missingLocks(resource: String, alreadyRetired: Bool) async throws {
        let service = try ProviderFixtureRecoveryService()
        defer { try? FileManager.default.removeItem(at: service.root) }
        let ticket = try await fixture(service)
        let reference = ticket.reference
        let pointer = try #require(FileManager.default.contentsOfDirectory(at: service.root, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "json" })
        if alreadyRetired { #expect(try await service.retire(ticket) == .retired) }
        let journals = URL(fileURLWithPath: reference.journalRoot)
        let missing: URL
        switch resource {
        case "task": missing = journals.appendingPathComponent(reference.taskID.uuidString + ".lock")
        case "journals": missing = journals
        default: missing = pointer.deletingPathExtension()
        }
        try FileManager.default.removeItem(at: missing)
        let before = try snapshot(service.root)
        await #expect(throws: RuntimeExecutionOwnerStore.Failure.self) { try await service.retire(ticket) }
        #expect(try snapshot(service.root) == before)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test("Recovery refuses a FIFO without waiting for a writer or consuming the reservation",
          arguments: ["fixture", "retired", "journal", "providerPointer"])
    func refusesFIFO(artifact: String) async throws {
        let service = try ProviderFixtureRecoveryService()
        defer { try? FileManager.default.removeItem(at: service.root) }
        let ticket = try await fixture(service)
        let key = ticket.key
        let reference = ticket.reference
        let pointer = try #require(FileManager.default.contentsOfDirectory(at: service.root, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "json" })
        let fifo: URL
        switch artifact {
        case "journal": fifo = URL(fileURLWithPath: reference.journalRoot).appendingPathComponent(reference.taskID.uuidString + ".json")
        case "providerPointer": fifo = pointer
        default: fifo = pointer.deletingPathExtension().appendingPathExtension(artifact)
        }
        let original = try? Data(contentsOf: fifo)
        if original != nil { try FileManager.default.removeItem(at: fifo) }
        try #require(mkfifo(fifo.path, 0o600) == 0)
        // If a blocking open regresses, release that reader and fail the test instead of hanging the suite.
        let finished = DispatchSemaphore(value: 0)
        let rescued = AsyncStream<Bool> { result in
            DispatchQueue.global().async {
                defer { result.finish() }
                while finished.wait(timeout: .now() + .milliseconds(100)) == .timedOut {
                    let writer = open(fifo.path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
                    if writer >= 0 { close(writer); result.yield(true); return }
                }
                result.yield(false)
            }
        }
        defer { finished.signal() }
        if artifact == "providerPointer" {
            let lease = try await ProviderSharedStateProcessLock.acquire(key, root: service.root)
            #expect(throws: ProviderSharedStateCompatibility.UnreadableReservation.self) { try lease.handoff(key, reference: nil) {} }
        } else {
            await #expect(throws: (any Error).self) { try await service.retire(ticket) }
        }
        finished.signal()
        #expect(await rescued.first(where: { _ in true }) == false, "The protected read waited for a FIFO writer")
        var info = stat()
        #expect(lstat(fifo.path, &info) == 0 && info.st_mode & S_IFMT == S_IFIFO)
        try FileManager.default.removeItem(at: fifo)
        if let original {
            try original.write(to: fifo, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fifo.path)
        }
        #expect(try await service.retire(ticket) == .retired)
    }

    @Test("Cancellation while a fixture's provider gate is held preserves its provenance and pointer")
    func cancelledRecovery() async throws {
        let service = try ProviderFixtureRecoveryService()
        defer { try? FileManager.default.removeItem(at: service.root) }
        let ticket = try await fixture(service)
        let key = ticket.key
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

import ASTRACore
import ASTRARunLedger
import Darwin
import Foundation
import RunBrokerKit
import RunSupervisorSupport
import Testing
@testable import RunBrokerService

@Suite("RunBroker durability and dormant app seams", .serialized)
struct RunBrokerDurabilityAndStartupTests {
    @Test("supervisor spawn sources are duplicated above reserved bootstrap targets")
    func supervisorSpawnSourcesAvoidReservedTargets() throws {
        let descriptor = open("/dev/null", O_RDONLY | O_CLOEXEC)
        #expect(descriptor >= 0)
        defer { close(descriptor) }
        let reserved = try DarwinRunBrokerSupervisorSpawner.reserveSourceDescriptor(descriptor)
        defer { close(reserved) }
        #expect(reserved >= 5)
        #expect(fcntl(reserved, F_GETFD) & FD_CLOEXEC != 0)
    }

    @Test("supervisor children are reaped after normal exit and forced termination")
    func supervisorChildrenAreAlwaysReaped() throws {
        for signal in [Int32(0), SIGKILL] {
            let pid = try spawnReaperFixture(shouldWait: signal != 0)
            DarwinRunBrokerSupervisorSpawner.startReaping(pid)
            if signal != 0 { #expect(kill(pid, signal) == 0) }
            #expect(waitUntilProcessGone(pid, timeout: 5))
            var status: Int32 = 0
            #expect(waitpid(pid, &status, WNOHANG) == -1)
            #expect(errno == ECHILD)
        }
    }

    @Test("capability vault writes a private fsynced identity record and refuses replacement")
    func capabilityVaultDurability() throws {
        let root = try temporaryDirectory("vault")
        defer { try? FileManager.default.removeItem(at: root) }
        let vaultURL = root.appendingPathComponent("capabilities", isDirectory: true)
        let vault = DarwinRunBrokerCapabilityVault(directoryURL: vaultURL)
        let fixture = try BrokerFixture()
        let record = RunBrokerCapabilityRecord(
            identity: .init(manifest: fixture.manifest),
            manifestSHA256: try RunSupervisorDigests.manifest(fixture.manifest),
            capability: try .init(bytes: Data(repeating: 5, count: 32))
        )
        try vault.persistAndSynchronize(record)
        let loaded = try #require(try vault.load(executionID: fixture.manifest.executionID))
        #expect(loaded.identity == record.identity)
        #expect(loaded.manifestSHA256 == record.manifestSHA256)
        #expect(loaded.capability == record.capability)

        let file = try #require(FileManager.default.contentsOfDirectory(at: vaultURL, includingPropertiesForKeys: nil).first)
        #expect(permissions(vaultURL) == 0o700)
        #expect(permissions(file) == 0o600)
        #expect(!String(describing: record).contains(record.capability.base64))

        let conflict = RunBrokerCapabilityRecord(
            identity: record.identity,
            manifestSHA256: record.manifestSHA256,
            capability: try .init(bytes: Data(repeating: 6, count: 32))
        )
        #expect(throws: RunBrokerServiceError.capabilityIdentityMismatch) {
            try vault.persistAndSynchronize(conflict)
        }
    }

    @Test("capability vault synchronizes an identical existing publication before succeeding")
    func capabilityVaultSynchronizesExistingPublication() throws {
        let root = try temporaryDirectory("vault-existing")
        defer { try? FileManager.default.removeItem(at: root) }
        let vaultURL = root.appendingPathComponent("capabilities", isDirectory: true)
        let synchronizations = DirectorySynchronizationRecorder()
        let vault = DarwinRunBrokerCapabilityVault(
            directoryURL: vaultURL,
            directorySynchronizer: { url in synchronizations.record(url) }
        )
        let fixture = try BrokerFixture()
        let record = RunBrokerCapabilityRecord(
            identity: .init(manifest: fixture.manifest),
            manifestSHA256: try RunSupervisorDigests.manifest(fixture.manifest),
            capability: try .init(bytes: Data(repeating: 7, count: 32))
        )

        try vault.persistAndSynchronize(record)
        try vault.persistAndSynchronize(record)

        #expect(synchronizations.urls == [vaultURL, vaultURL])
    }

    @Test("projection remains pending across broker instances until exact app acknowledgement")
    func projectionPullBeforeExactAcknowledgement() throws {
        let fixture = try BrokerFixture()
        try fixture.admitOnly()
        let firstBroker = RunBrokerProjectionOutbox(ledger: fixture.ledger)
        let first = try #require(try firstBroker.next())
        let restartedBroker = RunBrokerProjectionOutbox(ledger: fixture.ledger)
        #expect(try restartedBroker.next() == first)

        _ = try restartedBroker.acknowledge(.init(
            sequence: first.sequence,
            messageID: first.messageID
        ))
        #expect(try restartedBroker.next() == nil)
        #expect(try fixture.ledger.outbox().first?.isAcknowledged == true)
    }

    @Test("wrong projection acknowledgement cannot advance the ledger outbox")
    func wrongProjectionAcknowledgementDoesNotAck() throws {
        let fixture = try BrokerFixture()
        try fixture.admitOnly()
        let outbox = RunBrokerProjectionOutbox(ledger: fixture.ledger)
        let next = try #require(try outbox.next())
        #expect(throws: (any Error).self) {
            _ = try outbox.acknowledge(.init(
                sequence: next.sequence,
                messageID: brokerUUID(99)
            ))
        }
        #expect(try fixture.ledger.outbox().first?.isAcknowledged == false)
        #expect(try outbox.next() == next)
    }

    @Test("concurrent app bootstraps coalesce broker reconciliation before orphan recovery and queue drain")
    func concurrentBootstrapCoalescing() async throws {
        let recorder = AsyncStageRecorder()
        let ordering = RunBrokerStartupOrdering()
        async let first: Void = ordering.perform(
            rollout: .enabled,
            reconcileBroker: {
                await recorder.append("broker")
                try await Task.sleep(for: .milliseconds(50))
            },
            recoverLegacyOrphans: { await recorder.append("orphans") },
            drainTaskQueue: { await recorder.append("queue") }
        )
        async let second: Void = ordering.perform(
            rollout: .enabled,
            reconcileBroker: { await recorder.append("broker") },
            recoverLegacyOrphans: { await recorder.append("orphans") },
            drainTaskQueue: { await recorder.append("queue") }
        )
        _ = try await (first, second)
        let values = await recorder.values
        #expect(values.filter { $0 == "broker" }.count == 1)
        #expect(values.filter { $0 == "orphans" }.count == 2)
        #expect(values.filter { $0 == "queue" }.count == 2)
        let firstBroker = try #require(values.firstIndex(of: "broker"))
        #expect(values.firstIndex(of: "orphans")! > firstBroker)
        #expect(values.firstIndex(of: "queue")! > firstBroker)
    }

    @Test("dormant startup skips broker work but preserves legacy orphan recovery and queue drain")
    func dormantStartupHasNoSideEffects() async throws {
        let recorder = AsyncStageRecorder()
        try await RunBrokerStartupOrdering().perform(
            rollout: .dormant,
            reconcileBroker: { await recorder.append("broker") },
            recoverLegacyOrphans: { await recorder.append("orphans") },
            drainTaskQueue: { await recorder.append("queue") }
        )
        #expect(await recorder.values == ["orphans", "queue"])
    }

    @Test("installed sibling cohort survives deletion of an unrelated app bundle")
    func installedCohortDoesNotDependOnAppBundle() throws {
        let root = try temporaryDirectory("cohort")
        defer { try? FileManager.default.removeItem(at: root) }
        let cohort = root.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: cohort, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cohort.path)
        let broker = cohort.appendingPathComponent(RunBrokerCohort.brokerExecutableName)
        let supervisor = cohort.appendingPathComponent(RunBrokerCohort.supervisorExecutableName)
        #expect(FileManager.default.createFile(atPath: broker.path, contents: Data("broker".utf8), attributes: [.posixPermissions: 0o700]))
        #expect(FileManager.default.createFile(atPath: supervisor.path, contents: Data("supervisor".utf8), attributes: [.posixPermissions: 0o700]))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: broker.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: supervisor.path)

        let app = root.appendingPathComponent("ASTRA.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
        try FileManager.default.removeItem(at: app)

        let resolved = try RunBrokerCohortResolver.resolve(brokerExecutableURL: broker)
        #expect(resolved.brokerExecutableURL == broker.resolvingSymlinksInPath().standardizedFileURL)
        #expect(resolved.supervisorExecutableURL == supervisor.resolvingSymlinksInPath().standardizedFileURL)
    }
}

private final class DirectorySynchronizationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedURLs: [URL] = []

    var urls: [URL] { lock.withLock { recordedURLs } }

    func record(_ url: URL) {
        lock.withLock { recordedURLs.append(url) }
    }
}

actor AsyncStageRecorder {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private func temporaryDirectory(_ suffix: String) throws -> URL {
    let url = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        .appendingPathComponent("astra-run-broker-\(suffix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
}

private func permissions(_ url: URL) -> Int {
    let attributes = try! FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

private func spawnReaperFixture(shouldWait: Bool) throws -> pid_t {
    let arguments = shouldWait ? ["/bin/sleep", "10"] : ["/usr/bin/true"]
    var argv = arguments.map { strdup($0) } + [nil]
    defer { argv.forEach { if let value = $0 { free(value) } } }
    var pid: pid_t = 0
    let result = arguments[0].withCString { executable in
        argv.withUnsafeMutableBufferPointer {
            posix_spawn(&pid, executable, nil, nil, $0.baseAddress, environ)
        }
    }
    guard result == 0 else {
        throw NSError(domain: "ReaperFixture", code: Int(result))
    }
    return pid
}

private func waitUntilProcessGone(_ pid: pid_t, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if kill(pid, 0) == -1, errno == ESRCH { return true }
        usleep(20_000)
    }
    return kill(pid, 0) == -1 && errno == ESRCH
}

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

    @Test("app outbox acknowledgement waits for durable projection and exact dedupe replay")
    func projectionBeforeAppAcknowledgement() throws {
        let fixture = try BrokerFixture()
        try fixture.admitOnly()
        let projector = CrashAfterProjectionProjector()
        let delivery = RunBrokerProjectionDeliveryService(
            ledger: fixture.ledger,
            projection: projector
        )
        #expect(throws: ProjectionCrash.self) {
            _ = try delivery.deliver(limit: 1)
        }
        let before = try #require(fixture.ledger.outbox().first)
        #expect(!before.isAcknowledged)
        #expect(projector.messageIDs == [before.messageID])

        #expect(try delivery.deliver(limit: 1) == 1)
        let after = try #require(fixture.ledger.outbox().first)
        #expect(after.isAcknowledged)
        #expect(projector.messageIDs == [before.messageID, before.messageID])
    }

    @Test("a non-durable app projection cannot advance the ledger outbox")
    func nonDurableProjectionDoesNotAck() throws {
        let fixture = try BrokerFixture()
        try fixture.admitOnly()
        let delivery = RunBrokerProjectionDeliveryService(
            ledger: fixture.ledger,
            projection: NeverDurableProjector()
        )
        #expect(throws: RunBrokerServiceError.projectionDidNotBecomeDurable) {
            _ = try delivery.deliver(limit: 1)
        }
        #expect(try fixture.ledger.outbox().first?.isAcknowledged == false)
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

enum ProjectionCrash: Error { case afterDurableWrite }

final class CrashAfterProjectionProjector: RunBrokerProjectionApplying, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var messageIDs: [RunLedgerEventID] = []

    func durablyApply(_ message: RunLedgerOutboxMessage) throws -> RunBrokerProjectionApplyDisposition {
        lock.lock()
        messageIDs.append(message.messageID)
        let isFirst = messageIDs.count == 1
        lock.unlock()
        if isFirst { throw ProjectionCrash.afterDurableWrite }
        return .exactReplayDurable
    }
}

struct NeverDurableProjector: RunBrokerProjectionApplying {
    func durablyApply(_ message: RunLedgerOutboxMessage) throws -> RunBrokerProjectionApplyDisposition {
        .notDurable
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

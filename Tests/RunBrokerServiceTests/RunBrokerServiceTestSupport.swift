import ASTRACore
import ASTRARunLedger
import Foundation
import RunSupervisorSupport
@_spi(RunBrokerServiceTesting) @testable import RunBrokerService

let brokerTestDate = Date(timeIntervalSince1970: 2_100_000_000)

func brokerUUID(_ value: UInt8) -> UUID {
    UUID(uuid: (value, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
}

final class BrokerFixture {
    let root: URL
    let ledger: RunLedger
    let vault = MemoryCapabilityVault()
    let spawner = RecordingSpawner()
    let transport = RecordingTransport()
    let logger = RecordingLogger()
    let manifest: ExecutionLaunchManifest

    init(
        maximumOutputEventBytes: UInt64 = 32_768,
        maximumPersistedOutputBytes: UInt64 = 1_048_576
    ) throws {
        root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("astra-run-broker-service-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let installation = RunBrokerInstallationID(rawValue: brokerUUID(1))
        ledger = try RunLedger(configuration: .init(
            ledgerDirectoryURL: root.appendingPathComponent("ledger", isDirectory: true),
            installationID: installation
        ))
        manifest = .init(
            installationID: installation,
            storeID: ledger.identity.storeID,
            executionID: .init(rawValue: brokerUUID(2)),
            taskID: brokerUUID(3),
            authority: .init(
                id: .init(rawValue: brokerUUID(4)),
                epoch: .initial
            ),
            configuration: .init(
                runtimeID: .codexCLI,
                executablePath: "/usr/bin/true",
                workingDirectory: "/tmp",
                configurationRevision: "test-revision"
            ),
            declaredEffects: [.computeOnly],
            supervisionPolicy: try .init(
                hardTimeoutSeconds: 3_600,
                idleProgressTimeoutSeconds: 300,
                maximumOutputEventBytes: maximumOutputEventBytes,
                maximumPersistedOutputBytes: maximumPersistedOutputBytes
            ),
            createdAt: brokerTestDate
        )
    }

    deinit {
        try? ledger.close()
        try? FileManager.default.removeItem(at: root)
    }

    func request() -> RunBrokerStartRequest {
        .init(
            authorityMode: .durableBroker,
            manifest: manifest,
            primaryOperationID: .init(rawValue: brokerUUID(5)),
            admissionID: brokerUUID(6),
            arguments: [],
            environment: [:]
        )
    }

    func orchestrator(
        fault: any RunBrokerStartFaultInjecting = NoOpRunBrokerStartFaultInjector(),
        authorizer: (any RunBrokerImmediateTerminationAuthorizing)? = nil
    ) -> RunBrokerOrchestrator {
        if let authorizer {
            return .init(
                ledger: ledger,
                vault: vault,
                spawner: spawner,
                transport: transport,
                installedBrokerExecutableURL: root.appendingPathComponent("installed/astra-run-broker"),
                faultInjector: fault,
                terminationAuthorizer: authorizer,
                logger: logger
            )
        }
        return .init(
            ledger: ledger,
            vault: vault,
            spawner: spawner,
            transport: transport,
            installedBrokerExecutableURL: root.appendingPathComponent("installed/astra-run-broker"),
            faultInjector: fault,
            logger: logger
        )
    }

    func admitOnly() throws {
        _ = try ledger.admitExecution(
            manifest: manifest,
            primaryOperationID: request().primaryOperationID,
            admittedAt: manifest.createdAt,
            idempotencyKey: request().admissionID
        )
    }

    func event(
        _ sequence: UInt64,
        _ kind: RunSupervisorEventKind,
        output: Data? = nil,
        exitCode: Int32? = nil,
        cancellationIntent: ExecutionCancellationIntent? = nil
    ) -> RunSupervisorEvent {
        .init(
            sequence: sequence,
            id: brokerUUID(UInt8(20 + sequence)),
            timestamp: brokerTestDate.addingTimeInterval(TimeInterval(sequence)),
            kind: kind,
            payload: .init(
                data: output,
                exitCode: exitCode,
                cancellationIntent: cancellationIntent,
                terminationReason: kind == .providerExited ? .exited : nil
            )
        )
    }
}

final class MemoryCapabilityVault: RunBrokerCapabilityVaulting, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [RunBrokerExecutionID: RunBrokerCapabilityRecord] = [:]
    private(set) var persistCount = 0

    func persistAndSynchronize(_ record: RunBrokerCapabilityRecord) throws {
        lock.lock()
        defer { lock.unlock() }
        records[record.identity.executionID] = record
        persistCount += 1
    }

    func load(executionID: RunBrokerExecutionID) throws -> RunBrokerCapabilityRecord? {
        lock.lock()
        defer { lock.unlock() }
        return records[executionID]
    }

    func replace(_ record: RunBrokerCapabilityRecord) {
        lock.lock()
        records[record.identity.executionID] = record
        lock.unlock()
    }
}

final class RecordingSpawner: RunBrokerSupervisorSpawning, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var payloads: [RunSupervisorBootstrapPayload] = []
    private(set) var brokerURLs: [URL] = []

    func spawn(payload: RunSupervisorBootstrapPayload, installedBrokerExecutableURL: URL) throws {
        lock.lock()
        payloads.append(payload)
        brokerURLs.append(installedBrokerExecutableURL)
        lock.unlock()
    }
}

final class RecordingTransport: RunBrokerSupervisorTransporting, @unchecked Sendable {
    private let lock = NSLock()
    var events: [RunSupervisorEvent] = []
    var source: RunBrokerSupervisorReplaySource = .liveAuthenticated
    var identityOverride: RunSupervisorIdentity?
    var replayError: Error?
    var onImmediateTermination: (() -> Void)?
    private(set) var acknowledgements: [UInt64] = []
    private(set) var replayCursors: [UInt64] = []
    private(set) var immediateTerminationCount = 0

    func presence(
        identity: RunSupervisorIdentity,
        capability: RunSupervisorCapability
    ) throws -> RunBrokerSupervisorPresence {
        lock.lock()
        defer { lock.unlock() }
        if let replayError { throw replayError }
        return events.isEmpty ? .absent : .authenticated
    }

    func replay(
        identity: RunSupervisorIdentity,
        capability: RunSupervisorCapability,
        after sequence: UInt64
    ) throws -> RunBrokerSupervisorReplayBatch {
        lock.lock()
        defer { lock.unlock() }
        if let replayError { throw replayError }
        replayCursors.append(sequence)
        let batch = Array(events.filter { $0.sequence > sequence }.prefix(4))
        return .init(
            identity: identityOverride ?? identity,
            source: source,
            events: batch,
            lastSequence: events.last?.sequence ?? sequence
        )
    }

    func acknowledge(
        identity: RunSupervisorIdentity,
        capability: RunSupervisorCapability,
        source: RunBrokerSupervisorReplaySource,
        through sequence: UInt64
    ) throws {
        lock.lock()
        acknowledgements.append(sequence)
        lock.unlock()
    }

    func requestImmediateTermination(
        identity: RunSupervisorIdentity,
        capability: RunSupervisorCapability
    ) throws {
        onImmediateTermination?()
        lock.lock()
        immediateTerminationCount += 1
        lock.unlock()
    }
}

enum InjectedStartCrash: Error { case crash }

struct PointFaultInjector: RunBrokerStartFaultInjecting {
    let point: RunBrokerStartCrashPoint
    func checkpoint(_ point: RunBrokerStartCrashPoint) throws {
        if self.point == point { throw InjectedStartCrash.crash }
    }
}

final class RecordingLogger: RunBrokerServiceLogging, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var records: [(String, [String: String])] = []
    func record(event: String, fields: [String: String]) {
        lock.lock()
        records.append((event, fields))
        lock.unlock()
    }
    var rendered: String {
        lock.lock()
        defer { lock.unlock() }
        return records.map { "\($0.0) \($0.1)" }.joined(separator: "\n")
    }
}

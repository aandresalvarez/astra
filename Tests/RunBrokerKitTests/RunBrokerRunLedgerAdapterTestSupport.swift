import ASTRACore
@testable import ASTRARunLedger
import Foundation
import Testing
@testable import RunBrokerKit

struct AdapterActiveOperation {
    let executionID: RunBrokerExecutionID
    let operationID: RunBrokerOperationID
    let authority: RunBrokerAuthority
}

final class AdapterLedgerFixture {
    let root: URL
    let installationID = RunBrokerInstallationID(rawValue: adapterUUID(1))
    let configuration: RunLedgerConfiguration
    private let base = Date(timeIntervalSince1970: 1_720_000_000)

    init() throws {
        root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("astra-run-broker-adapter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        configuration = .init(
            ledgerDirectoryURL: root.appendingPathComponent("ledger", isDirectory: true),
            installationID: installationID,
            busyTimeoutMilliseconds: 10_000
        )
    }

    func open(expectedStoreID: RunBrokerStoreID? = nil) throws -> RunLedger {
        try RunLedger(configuration: .init(
            ledgerDirectoryURL: configuration.ledgerDirectoryURL,
            installationID: installationID,
            expectedStoreID: expectedStoreID,
            busyTimeoutMilliseconds: 10_000
        ))
    }

    func createActiveOperation(in ledger: RunLedger, seed: Int) throws -> AdapterActiveOperation {
        let authority = RunBrokerAuthority(
            id: .init(rawValue: adapterUUID(seed + 1)),
            epoch: .initial
        )
        let executionID = RunBrokerExecutionID(rawValue: adapterUUID(seed + 2))
        let operationID = RunBrokerOperationID(rawValue: adapterUUID(seed + 3))
        let manifest = ExecutionLaunchManifest(
            installationID: installationID,
            storeID: ledger.identity.storeID,
            executionID: executionID,
            taskID: adapterUUID(seed + 4),
            authority: authority,
            configuration: .init(
                runtimeID: .codexCLI,
                executablePath: "/usr/local/bin/codex",
                workingDirectory: "/workspace/repository",
                configurationRevision: "sha256:adapter-test"
            ),
            declaredEffects: [.computeOnly],
            createdAt: date(0)
        )
        try ledger.admitExecution(
            manifest: manifest,
            primaryOperationID: operationID,
            admittedAt: date(2),
            idempotencyKey: adapterUUID(seed + 5)
        )
        return .init(executionID: executionID, operationID: operationID, authority: authority)
    }

    func deadline(
        operation: AdapterActiveOperation,
        dueOffset: TimeInterval,
        recordedOffset: TimeInterval,
        attempt: UInt64,
        generation: UUID
    ) -> RunBrokerMonitorDeadline {
        .init(
            operationID: operation.operationID,
            authority: operation.authority,
            dueAt: date(dueOffset),
            recordedAt: date(recordedOffset),
            attempt: attempt,
            generation: generation
        )
    }

    func date(_ offset: TimeInterval) -> Date { base.addingTimeInterval(offset) }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

final class AdapterTimer: RunBrokerOneShotTimer, @unchecked Sendable {
    func schedule(
        at deadline: Date,
        _ action: @escaping @Sendable () -> Void
    ) -> any RunBrokerScheduledDeadline {
        AdapterTimerToken()
    }
}

final class AdapterTimerToken: RunBrokerScheduledDeadline, @unchecked Sendable {
    func cancel() {}
}

final class AdapterMonitor: RunBrokerExternalOperationMonitoring, @unchecked Sendable {
    private(set) var operations: [RunBrokerOperationID] = []
    func monitor(operationID: RunBrokerOperationID) throws -> RunBrokerMonitorAttemptResult {
        operations.append(operationID)
        return .init(disposition: .completed)
    }
}

struct AdapterClock: RunBrokerSchedulerClock {
    let now: Date
}

final class AdapterRandom: RunBrokerRandomGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt8 = 0
    func randomBytes(count: Int) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        value &+= 1
        return Data(repeating: value, count: count)
    }
}

func adapterAuditCount(_ ledger: RunLedger) throws -> Int64 {
    try ledger.connection.withLock { database in
        let count = try ledger.connection.scalarInt64(
            "SELECT COUNT(*) FROM monitor_attempts",
            database: database
        )
        guard let count else { throw AdapterTestError.missingAuditCount }
        return count
    }
}

private enum AdapterTestError: Error {
    case missingAuditCount
}

func adapterLedgerError(_ body: () throws -> Void) -> RunLedgerError? {
    do {
        try body()
        return nil
    } catch let error as RunLedgerError {
        return error
    } catch {
        Issue.record("Unexpected non-ledger error: \(error)")
        return nil
    }
}

func canonicalAdapterDate(_ date: Date) -> Date {
    let milliseconds = Int64((date.timeIntervalSince1970 * 1_000).rounded(.towardZero))
    return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
}

func adapterUUID(_ suffix: Int) -> UUID {
    UUID(uuidString: String(format: "20000000-0000-0000-0000-%012d", suffix))!
}

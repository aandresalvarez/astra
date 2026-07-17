import ASTRACore
@testable import ASTRARunLedger
import Foundation
import Testing

let monitorTestDate = Date(timeIntervalSince1970: 1_710_000_000)
let monitorWorkspaceEffect = ExecutionEffectClaim(
    scope: .workspaceRepository(workspaceID: "monitor-workspace", repositoryID: "repository"),
    access: .exclusive
)

struct ActiveMonitorOperation {
    let executionID: RunBrokerExecutionID
    let operationID: RunBrokerOperationID
    let authority: RunBrokerAuthority
}

final class MonitorLedgerFixture {
    let root: URL
    let configuration: RunLedgerConfiguration

    init(precreateDirectory: Bool = false) throws {
        root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(
            "astra-monitor-ledger-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let directory = root.appendingPathComponent("ledger", isDirectory: true)
        if precreateDirectory {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        }
        configuration = .init(
            ledgerDirectoryURL: directory,
            installationID: .init(rawValue: monitorUUID(1)),
            busyTimeoutMilliseconds: 10_000
        )
    }

    func open(expectedStoreID: RunBrokerStoreID? = nil) throws -> RunLedger {
        try RunLedger(configuration: .init(
            ledgerDirectoryURL: configuration.ledgerDirectoryURL,
            installationID: configuration.installationID,
            expectedStoreID: expectedStoreID,
            busyTimeoutMilliseconds: 10_000
        ))
    }

    func createActiveOperation(
        in ledger: RunLedger,
        seed: Int,
        authority: RunBrokerAuthority? = nil,
        effect: ExecutionEffectClaim = monitorWorkspaceEffect
    ) throws -> ActiveMonitorOperation {
        let authority = authority ?? RunBrokerAuthority(
            id: .init(rawValue: monitorUUID(seed + 1)),
            epoch: .init(rawValue: 1)
        )
        let executionID = RunBrokerExecutionID(rawValue: monitorUUID(seed + 2))
        let operationID = RunBrokerOperationID(rawValue: monitorUUID(seed + 3))
        let manifest = ExecutionLaunchManifest(
            installationID: configuration.installationID,
            storeID: ledger.identity.storeID,
            executionID: executionID,
            taskID: monitorUUID(seed + 4),
            authority: authority,
            configuration: .init(
                runtimeID: .codexCLI,
                executablePath: "/usr/local/bin/codex",
                workingDirectory: "/workspace/repo",
                configurationRevision: "sha256:monitor-test"
            ),
            declaredEffects: [effect],
            createdAt: date(0)
        )
        try ledger.admitExecution(
            manifest: manifest,
            primaryOperationID: operationID,
            admittedAt: date(2),
            idempotencyKey: monitorUUID(seed + 5)
        )
        return .init(
            executionID: executionID,
            operationID: operationID,
            authority: authority
        )
    }

    func date(_ offset: TimeInterval) -> Date {
        monitorTestDate.addingTimeInterval(offset)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

final class AdvancedLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func withValue(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&storage)
    }
}

func monitorUUID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", value))!
}

func monitorLedgerError(_ body: () throws -> Void) -> RunLedgerError? {
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

func canonicalMilliseconds(_ date: Date) -> Date {
    let milliseconds = Int64((date.timeIntervalSince1970 * 1_000).rounded(.towardZero))
    return Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
}

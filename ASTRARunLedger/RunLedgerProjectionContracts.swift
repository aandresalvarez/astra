import ASTRACore
import Foundation

public struct RunLedgerExecutionProjection: Equatable, Sendable {
    public let manifest: ExecutionLaunchManifest
    public let authority: RunBrokerAuthority
    public let control: ExecutionControlState
    public let updatedAt: Date
    public let createdSequence: Int64
    public let updatedSequence: Int64

    public init(
        manifest: ExecutionLaunchManifest,
        authority: RunBrokerAuthority,
        control: ExecutionControlState,
        updatedAt: Date,
        createdSequence: Int64,
        updatedSequence: Int64
    ) {
        self.manifest = manifest
        self.authority = authority
        self.control = control
        self.updatedAt = updatedAt
        self.createdSequence = createdSequence
        self.updatedSequence = updatedSequence
    }
}

public struct RunLedgerOperationProjection: Equatable, Sendable {
    public let record: DurableExecutionClaimRecord
    public let createdSequence: Int64
    public let updatedSequence: Int64

    public init(
        record: DurableExecutionClaimRecord,
        createdSequence: Int64,
        updatedSequence: Int64
    ) {
        self.record = record
        self.createdSequence = createdSequence
        self.updatedSequence = updatedSequence
    }
}

public struct RunLedgerProjection: Equatable, Sendable {
    public let executions: [RunBrokerExecutionID: RunLedgerExecutionProjection]
    public let operations: [RunBrokerOperationID: RunLedgerOperationProjection]
    public let monitorDeadlines: [RunBrokerOperationID: RunLedgerMonitorDeadline]

    public init(
        executions: [RunBrokerExecutionID: RunLedgerExecutionProjection] = [:],
        operations: [RunBrokerOperationID: RunLedgerOperationProjection] = [:],
        monitorDeadlines: [RunBrokerOperationID: RunLedgerMonitorDeadline] = [:]
    ) {
        self.executions = executions
        self.operations = operations
        self.monitorDeadlines = monitorDeadlines
    }
}

import ASTRACore
import Foundation

public enum RunLedgerHealthStatus: String, Codable, Equatable, Sendable {
    case healthy
    case missing
    case incompatibleSchema = "incompatible_schema"
    case identityMismatch = "identity_mismatch"
    case corrupt
    case projectionDrift = "projection_drift"
    case unsafeStorage = "unsafe_storage"
    case unavailable
}

public struct RunLedgerHealthReport: Equatable, Sendable {
    public let status: RunLedgerHealthStatus
    public let identity: RunLedgerIdentity?
    public let lastEventSequence: Int64?
    public let detail: String?

    public init(
        status: RunLedgerHealthStatus,
        identity: RunLedgerIdentity? = nil,
        lastEventSequence: Int64? = nil,
        detail: String? = nil
    ) {
        self.status = status
        self.identity = identity
        self.lastEventSequence = lastEventSequence
        self.detail = detail
    }
}

public enum RunLedgerError: Error, Equatable, Sendable {
    case missingLedger
    case closed
    case unsafeStorage(String)
    case corrupt(String)
    case incompatibleSchema(expected: Int, found: Int)
    case applicationIdentityMismatch(expected: Int32, found: Int32)
    case storeIdentityMismatch(expected: RunBrokerStoreID, found: RunBrokerStoreID)
    case installationIdentityMismatch(expected: RunBrokerInstallationID, found: RunBrokerInstallationID)
    case sqlite(operation: String, code: Int32, message: String)
    case invalidEvent(String)
    case eventIDReuse(RunLedgerEventID)
    case aggregateKeyReuse(kind: String, id: String)
    case missingExecution(RunBrokerExecutionID)
    case missingOperation(RunBrokerOperationID)
    case admissionDenied([ExecutionAdmissionDenial])
    case claimTransitionRejected(DurableExecutionClaimDisposition)
    case controlTransitionRejected
    case monitorScheduleConflict(operationID: RunBrokerOperationID)
    case projectionDrift(String)
    case invalidConsumerID
    case checkpointWouldRegress(current: Int64, requested: Int64)
    case checkpointWouldSkip(current: Int64, requested: Int64, next: Int64?)
    case outboxAcknowledgementWouldRegress(current: Int64, requested: Int64)
    case outboxAcknowledgementWouldSkip(current: Int64, requested: Int64, next: Int64?)
    case outboxMessageIdentityMismatch(
        sequence: Int64,
        expected: RunLedgerEventID,
        requested: RunLedgerEventID
    )
}

import Foundation

public enum ExecutionSupervisionPolicyError: Error, Equatable, Sendable {
    case invalidTimeout
    case invalidOutputLimit
}

/// Immutable, secret-free limits captured at admission. A later settings
/// change cannot silently alter the watchdog or backpressure contract of an
/// already-running execution.
public struct ExecutionSupervisionPolicySnapshot: Codable, Equatable, Hashable, Sendable {
    public let hardTimeoutSeconds: UInt64
    public let idleProgressTimeoutSeconds: UInt64
    public let maximumOutputEventBytes: UInt64
    public let maximumPersistedOutputBytes: UInt64

    public init(
        hardTimeoutSeconds: UInt64,
        idleProgressTimeoutSeconds: UInt64,
        maximumOutputEventBytes: UInt64 = 32_768,
        maximumPersistedOutputBytes: UInt64 = 64 * 1_024 * 1_024
    ) throws {
        guard hardTimeoutSeconds > 0,
              idleProgressTimeoutSeconds > 0,
              idleProgressTimeoutSeconds <= hardTimeoutSeconds else {
            throw ExecutionSupervisionPolicyError.invalidTimeout
        }
        guard maximumOutputEventBytes > 0,
              maximumOutputEventBytes <= 32_768,
              maximumPersistedOutputBytes >= maximumOutputEventBytes,
              maximumPersistedOutputBytes <= 1_073_741_824 else {
            throw ExecutionSupervisionPolicyError.invalidOutputLimit
        }
        self.hardTimeoutSeconds = hardTimeoutSeconds
        self.idleProgressTimeoutSeconds = idleProgressTimeoutSeconds
        self.maximumOutputEventBytes = maximumOutputEventBytes
        self.maximumPersistedOutputBytes = maximumPersistedOutputBytes
    }
}

/// Provider-neutral durable evidence copied from the authenticated supervisor
/// spool. Provider PIDs are intentionally excluded: they are diagnostics, not
/// authority or recovery identity.
public struct RunBrokerSupervisorObservation: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case supervisorReady = "supervisor_ready"
        case providerStarted = "provider_started"
        case standardOutput = "stdout"
        case standardError = "stderr"
        case standardInputAccepted = "stdin_accepted"
        case standardInputClosed = "stdin_closed"
        case cancellationRequested = "cancellation_requested"
        case cancellationUnsupported = "cancellation_unsupported"
        case terminationStarted = "termination_started"
        case cancellationConfirmed = "cancellation_confirmed"
        case providerExited = "provider_exited"
        case providerLaunchFailed = "provider_launch_failed"
        case outputBackpressureStarted = "output_backpressure_started"
        case outputBackpressureReleased = "output_backpressure_released"
        case recoveryTailQuarantined = "recovery_tail_quarantined"
    }

    public let executionID: RunBrokerExecutionID
    public let authority: RunBrokerAuthority
    public let supervisorSequence: UInt64
    public let supervisorEventID: UUID
    public let occurredAt: Date
    public let kind: Kind
    public let output: Data?
    public let exitCode: Int32?
    public let cancellationIntent: ExecutionCancellationIntent?
    public let quarantinedByteCount: UInt64?

    public init(
        executionID: RunBrokerExecutionID,
        authority: RunBrokerAuthority,
        supervisorSequence: UInt64,
        supervisorEventID: UUID,
        occurredAt: Date,
        kind: Kind,
        output: Data? = nil,
        exitCode: Int32? = nil,
        cancellationIntent: ExecutionCancellationIntent? = nil,
        quarantinedByteCount: UInt64? = nil
    ) {
        self.executionID = executionID
        self.authority = authority
        self.supervisorSequence = supervisorSequence
        self.supervisorEventID = supervisorEventID
        self.occurredAt = occurredAt
        self.kind = kind
        self.output = output
        self.exitCode = exitCode
        self.cancellationIntent = cancellationIntent
        self.quarantinedByteCount = quarantinedByteCount
    }
}

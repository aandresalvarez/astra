import Foundation
import ASTRACore

public struct RunBrokerMonitorDeadline: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let operationID: RunBrokerOperationID
    public let authority: RunBrokerAuthority
    public let dueAt: Date
    public let recordedAt: Date
    public let attempt: UInt64
    public let generation: UUID

    public init(
        operationID: RunBrokerOperationID,
        authority: RunBrokerAuthority,
        dueAt: Date,
        recordedAt: Date,
        attempt: UInt64,
        generation: UUID
    ) {
        self.operationID = operationID
        self.authority = authority
        self.dueAt = Self.canonicalMilliseconds(dueAt)
        self.recordedAt = Self.canonicalMilliseconds(recordedAt)
        self.attempt = attempt
        self.generation = generation
    }

    public var id: RunBrokerOperationID { operationID }

    private enum CodingKeys: String, CodingKey {
        case operationID, authority, dueAt, recordedAt, attempt, generation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let dueAt = try container.decode(Date.self, forKey: .dueAt)
        let recordedAt = try container.decode(Date.self, forKey: .recordedAt)
        guard Self.isRepresentableAsCanonicalMilliseconds(dueAt) else {
            throw DecodingError.dataCorruptedError(
                forKey: .dueAt,
                in: container,
                debugDescription: "Monitor dueAt is outside the canonical millisecond range"
            )
        }
        guard Self.isRepresentableAsCanonicalMilliseconds(recordedAt) else {
            throw DecodingError.dataCorruptedError(
                forKey: .recordedAt,
                in: container,
                debugDescription: "Monitor recordedAt is outside the canonical millisecond range"
            )
        }
        self.init(
            operationID: try container.decode(RunBrokerOperationID.self, forKey: .operationID),
            authority: try container.decode(RunBrokerAuthority.self, forKey: .authority),
            dueAt: dueAt,
            recordedAt: recordedAt,
            attempt: try container.decode(UInt64.self, forKey: .attempt),
            generation: try container.decode(UUID.self, forKey: .generation)
        )
    }

    private static func isRepresentableAsCanonicalMilliseconds(_ date: Date) -> Bool {
        let milliseconds = date.timeIntervalSince1970 * 1_000
        return milliseconds.isFinite
            && milliseconds >= Double(Int64.min)
            // Double(Int64.max) rounds up to 2^63; that exact value traps when
            // converted to Int64, so the upper bound must remain exclusive.
            && milliseconds < Double(Int64.max)
    }

    private static func canonicalMilliseconds(_ date: Date) -> Date {
        let milliseconds = Int64(
            (date.timeIntervalSince1970 * 1_000).rounded(.towardZero)
        )
        return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
    }
}

/// A schedule mutation is an exact compare-and-set. `replacing == nil` means
/// that no schedule may currently exist; it is not an unconditional upsert.
public struct RunBrokerMonitorUpsert: Codable, Equatable, Sendable {
    public let deadline: RunBrokerMonitorDeadline
    public let replacing: RunBrokerMonitorDeadline?

    public init(
        deadline: RunBrokerMonitorDeadline,
        replacing: RunBrokerMonitorDeadline?
    ) {
        self.deadline = deadline
        self.replacing = replacing
    }
}

/// Removal carries the complete expected projection and its causal event time.
/// Operation identity alone cannot fence ABA reschedules or authority changes.
public struct RunBrokerMonitorRemoval: Codable, Equatable, Sendable {
    public let expected: RunBrokerMonitorDeadline
    public let occurredAt: Date

    public init(expected: RunBrokerMonitorDeadline, occurredAt: Date) {
        self.expected = expected
        self.occurredAt = Self.canonicalMilliseconds(occurredAt)
    }

    private enum CodingKeys: String, CodingKey {
        case expected, occurredAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let occurredAt = try container.decode(Date.self, forKey: .occurredAt)
        let milliseconds = occurredAt.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite,
              milliseconds >= Double(Int64.min),
              milliseconds < Double(Int64.max) else {
            throw DecodingError.dataCorruptedError(
                forKey: .occurredAt,
                in: container,
                debugDescription: "Monitor removal occurredAt is outside the canonical millisecond range"
            )
        }
        self.init(
            expected: try container.decode(RunBrokerMonitorDeadline.self, forKey: .expected),
            occurredAt: occurredAt
        )
    }

    private static func canonicalMilliseconds(_ date: Date) -> Date {
        let milliseconds = Int64(
            (date.timeIntervalSince1970 * 1_000).rounded(.towardZero)
        )
        return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
    }
}

public enum RunBrokerSchedulerCommand: Codable, Equatable, Sendable {
    case recover
    case upsert(RunBrokerMonitorUpsert)
    case remove(RunBrokerMonitorRemoval)
    case wake
    case status
}

public enum RunBrokerCommand:
    Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible
{
    /// The only pre-MAC command. It carries no caller-controlled authority;
    /// the broker resolves and verifies the live peer and its signed bundle.
    case authorizeSignedSuccessor
    case negotiate(RunBrokerNegotiationRequest)
    case health
    case capabilities
    case scheduler(RunBrokerSchedulerCommand)
    case application(RunBrokerApplicationCommand)

    public var isSafeForEphemeralReplay: Bool {
        switch self {
        case .negotiate, .health, .capabilities:
            true
        case .authorizeSignedSuccessor:
            false
        case .scheduler, .application:
            false
        }
    }

    public var description: String {
        switch self {
        case .authorizeSignedSuccessor: "authorizeSignedSuccessor"
        case .negotiate: "negotiate"
        case .health: "health"
        case .capabilities: "capabilities"
        case .scheduler: "scheduler"
        case .application(let command): "application(\(command.description))"
        }
    }

    public var debugDescription: String { description }
}

public struct RunBrokerRequestAuthentication: Codable, Equatable, Sendable {
    public let issuedAtMilliseconds: Int64
    public let nonce: Data
    public let mac: Data

    public init(issuedAtMilliseconds: Int64, nonce: Data, mac: Data) throws {
        guard nonce.count == RunBrokerAuthenticationPolicy.nonceByteCount else {
            throw RunBrokerContractError.invalidNonce
        }
        guard mac.count == RunBrokerAuthenticationPolicy.macByteCount else {
            throw RunBrokerContractError.invalidAuthentication
        }
        self.issuedAtMilliseconds = issuedAtMilliseconds
        self.nonce = nonce
        self.mac = mac
    }

    private enum CodingKeys: String, CodingKey { case issuedAtMilliseconds, nonce, mac }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            issuedAtMilliseconds: container.decode(Int64.self, forKey: .issuedAtMilliseconds),
            nonce: container.decode(Data.self, forKey: .nonce),
            mac: container.decode(Data.self, forKey: .mac)
        )
    }
}

public struct RunBrokerRequestEnvelope: Codable, Equatable, Sendable {
    public let protocolVersion: RunBrokerProtocolVersion
    public let requestID: UUID
    public let idempotencyKey: UUID
    public let channel: RunBrokerChannel
    public let installationID: RunBrokerInstallationID
    public let command: RunBrokerCommand
    public let authentication: RunBrokerRequestAuthentication

    public init(
        protocolVersion: RunBrokerProtocolVersion,
        requestID: UUID,
        idempotencyKey: UUID,
        channel: RunBrokerChannel,
        installationID: RunBrokerInstallationID,
        command: RunBrokerCommand,
        authentication: RunBrokerRequestAuthentication
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.idempotencyKey = idempotencyKey
        self.channel = channel
        self.installationID = installationID
        self.command = command
        self.authentication = authentication
    }
}

public enum RunBrokerErrorCode: String, Codable, Sendable {
    case incompatibleProtocol = "incompatible_protocol"
    case updateRequired = "update_required"
    case insecureDowngrade = "insecure_downgrade"
    case authenticationFailed = "authentication_failed"
    case replayDetected = "replay_detected"
    case replayProtectionSaturated = "replay_protection_saturated"
    case wrongChannel = "wrong_channel"
    case wrongInstallation = "wrong_installation"
    case peerIdentityRejected = "peer_identity_rejected"
    case invalidRequest = "invalid_request"
    case frameTooLarge = "frame_too_large"
    case ledgerUnavailable = "ledger_unavailable"
    case monitorUnavailable = "monitor_unavailable"
    case monitorScheduleConflict = "monitor_schedule_conflict"
    case applicationUnavailable = "application_unavailable"
    case applicationRequestRejected = "application_request_rejected"
    case executionNotFound = "execution_not_found"
    case projectionAcknowledgementConflict = "projection_acknowledgement_conflict"
    case externalOperationBlocked = "external_operation_blocked"
    case internalFailure = "internal_failure"
}

public struct RunBrokerErrorResponse: Codable, Equatable, Sendable {
    public let code: RunBrokerErrorCode
    public let message: String
    public let retryable: Bool

    public init(code: RunBrokerErrorCode, message: String, retryable: Bool = false) {
        self.code = code
        self.message = message
        self.retryable = retryable
    }
}

public enum RunBrokerResponsePayload: Codable, Equatable, Sendable {
    case negotiation(RunBrokerNegotiationResponse)
    case health(RunBrokerHealth)
    case capabilities(RunBrokerCapabilities)
    case schedulerStatus([RunBrokerMonitorDeadline])
    case application(RunBrokerApplicationResponse)
    case accepted
}

public struct RunBrokerResponseEnvelope: Codable, Equatable, Sendable {
    public let protocolVersion: RunBrokerProtocolVersion
    public let requestID: UUID
    public let result: RunBrokerResponsePayload?
    public let error: RunBrokerErrorResponse?

    public init(
        protocolVersion: RunBrokerProtocolVersion,
        requestID: UUID,
        result: RunBrokerResponsePayload
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.result = result
        self.error = nil
    }

    public init(
        protocolVersion: RunBrokerProtocolVersion,
        requestID: UUID,
        error: RunBrokerErrorResponse
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.result = nil
        self.error = error
    }

    public func validate() throws {
        guard (result == nil) != (error == nil) else {
            throw RunBrokerContractError.invalidEnvelope
        }
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, requestID, result, error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.protocolVersion = try container.decode(
            RunBrokerProtocolVersion.self,
            forKey: .protocolVersion
        )
        self.requestID = try container.decode(UUID.self, forKey: .requestID)
        self.result = try container.decodeIfPresent(RunBrokerResponsePayload.self, forKey: .result)
        self.error = try container.decodeIfPresent(RunBrokerErrorResponse.self, forKey: .error)
        try validate()
    }
}

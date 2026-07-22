import ASTRACore
import Foundation

public protocol RunSupervisorClock: Sendable {
    func now() -> Date
}

public struct SystemRunSupervisorClock: RunSupervisorClock {
    public init() {}
    public func now() -> Date { Date() }
}

package extension RunSupervisorClock {
    func persistedNow() -> Date {
        let milliseconds = (now().timeIntervalSince1970 * 1_000).rounded(.down)
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }
}

public enum RunSupervisorEventKind: String, Codable, Sendable {
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
    case outputQuotaExceeded = "output_quota_exceeded"
    case recoveryTailQuarantined = "recovery_tail_quarantined"

    public var isOutput: Bool { self == .standardOutput || self == .standardError }
    public var isTerminalTruth: Bool {
        self == .providerExited || self == .cancellationConfirmed || self == .providerLaunchFailed
    }
}

public struct RunSupervisorEventPayload: Codable, Equatable, Sendable {
    public let data: Data?
    public let exitCode: Int32?
    public let cancellationIntent: ExecutionCancellationIntent?
    public let quarantinedByteCount: UInt64?
    public let providerPID: Int32?
    public let terminationSignal: Int32?
    public let terminationReason: RunSupervisorTerminationReason?

    public init(
        data: Data? = nil,
        exitCode: Int32? = nil,
        cancellationIntent: ExecutionCancellationIntent? = nil,
        quarantinedByteCount: UInt64? = nil,
        providerPID: Int32? = nil,
        terminationSignal: Int32? = nil,
        terminationReason: RunSupervisorTerminationReason? = nil
    ) {
        self.data = data
        self.exitCode = exitCode
        self.cancellationIntent = cancellationIntent
        self.quarantinedByteCount = quarantinedByteCount
        self.providerPID = providerPID
        self.terminationSignal = terminationSignal
        self.terminationReason = terminationReason
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case data, exitCode, cancellationIntent, quarantinedByteCount
        case providerPID, terminationSignal, terminationReason
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeyNames(Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = try container.decodeIfPresent(Data.self, forKey: .data)
        exitCode = try container.decodeIfPresent(Int32.self, forKey: .exitCode)
        cancellationIntent = try container.decodeIfPresent(
            ExecutionCancellationIntent.self,
            forKey: .cancellationIntent
        )
        quarantinedByteCount = try container.decodeIfPresent(UInt64.self, forKey: .quarantinedByteCount)
        providerPID = try container.decodeIfPresent(Int32.self, forKey: .providerPID)
        terminationSignal = try container.decodeIfPresent(Int32.self, forKey: .terminationSignal)
        terminationReason = try container.decodeIfPresent(
            RunSupervisorTerminationReason.self,
            forKey: .terminationReason
        )
    }

    package func validate(for kind: RunSupervisorEventKind) throws {
        let empty = data == nil && exitCode == nil && cancellationIntent == nil
            && quarantinedByteCount == nil
            && providerPID == nil && terminationSignal == nil && terminationReason == nil
        switch kind {
        case .standardOutput, .standardError:
            guard let data, !data.isEmpty, data.count <= 32_768,
                  exitCode == nil, cancellationIntent == nil,
                  quarantinedByteCount == nil, providerPID == nil,
                  terminationSignal == nil, terminationReason == nil else {
                throw RunSupervisorError.invalidSchema
            }
        case .providerStarted:
            guard data == nil, exitCode == nil, cancellationIntent == nil,
                  quarantinedByteCount == nil,
                  providerPID.map({ $0 > 0 }) ?? true,
                  terminationSignal == nil, terminationReason == nil else {
                throw RunSupervisorError.invalidSchema
            }
        case .cancellationRequested, .cancellationUnsupported:
            guard let cancellationIntent, cancellationIntent != .none,
                  data == nil, exitCode == nil,
                  quarantinedByteCount == nil, providerPID == nil,
                  terminationSignal == nil, terminationReason == nil else {
                throw RunSupervisorError.invalidSchema
            }
        case .terminationStarted, .cancellationConfirmed:
            guard cancellationIntent == .immediate,
                  data == nil, exitCode == nil,
                  quarantinedByteCount == nil, providerPID == nil,
                  terminationSignal == nil, terminationReason == nil else {
                throw RunSupervisorError.invalidSchema
            }
        case .providerExited:
            guard let exitCode, let terminationReason,
                  data == nil, cancellationIntent == nil,
                  quarantinedByteCount == nil, providerPID == nil else {
                throw RunSupervisorError.invalidSchema
            }
            switch terminationReason {
            case .exited:
                guard exitCode >= 0, terminationSignal == nil else {
                    throw RunSupervisorError.invalidSchema
                }
            case .signaled:
                guard let terminationSignal, terminationSignal > 0 else {
                    throw RunSupervisorError.invalidSchema
                }
            case .waitFailed:
                guard exitCode < 0, terminationSignal == nil else {
                    throw RunSupervisorError.invalidSchema
                }
            }
        case .recoveryTailQuarantined, .outputQuotaExceeded:
            guard let quarantinedByteCount, quarantinedByteCount > 0,
                  data == nil, exitCode == nil, cancellationIntent == nil,
                  providerPID == nil,
                  terminationSignal == nil, terminationReason == nil else {
                throw RunSupervisorError.invalidSchema
            }
        case .supervisorReady, .standardInputAccepted, .standardInputClosed,
             .providerLaunchFailed, .outputBackpressureStarted, .outputBackpressureReleased:
            guard empty else { throw RunSupervisorError.invalidSchema }
        }
    }
}

public enum RunSupervisorTerminationReason: String, Codable, Equatable, Sendable {
    case exited
    case signaled
    case waitFailed = "wait_failed"
}

public struct RunSupervisorEvent: Codable, Equatable, Sendable, Identifiable {
    public let sequence: UInt64
    public let id: UUID
    public let timestamp: Date
    public let kind: RunSupervisorEventKind
    public let payload: RunSupervisorEventPayload

    public init(
        sequence: UInt64,
        id: UUID,
        timestamp: Date,
        kind: RunSupervisorEventKind,
        payload: RunSupervisorEventPayload
    ) {
        self.sequence = sequence
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case sequence, id, timestamp, kind, payload
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeyNames(Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sequence = try container.decode(UInt64.self, forKey: .sequence)
        id = try container.decode(UUID.self, forKey: .id)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        kind = try container.decode(RunSupervisorEventKind.self, forKey: .kind)
        payload = try container.decode(RunSupervisorEventPayload.self, forKey: .payload)
        guard sequence > 0 else { throw RunSupervisorError.invalidSchema }
        try payload.validate(for: kind)
    }
}

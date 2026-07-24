import ASTRACore
import Foundation

public enum RunLedgerExecutionControlEvent: Codable, Equatable, Sendable {
    case executionStarted
    case executionCompleted
    case executionFailed
    case requestCancellation(ExecutionCancellationIntent)
    case backendAcceptedCancellation
    case terminationStarted
    case cancellationConfirmed
    case backendRejectedCancellation
    case observationBecameIndeterminate

    var coreEvent: ExecutionControlEvent {
        switch self {
        case .executionStarted: .executionStarted
        case .executionCompleted: .executionCompleted
        case .executionFailed: .executionFailed
        case .requestCancellation(let intent): .requestCancellation(intent)
        case .backendAcceptedCancellation: .backendAcceptedCancellation
        case .terminationStarted: .terminationStarted
        case .cancellationConfirmed: .cancellationConfirmed
        case .backendRejectedCancellation: .backendRejectedCancellation
        case .observationBecameIndeterminate: .observationBecameIndeterminate
        }
    }
}

extension RunLedgerExecutionControlEvent {
    private static let schemaVersion = 1

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case kind
        case intent
    }

    private enum Kind: String, Codable {
        case executionStarted = "execution_started"
        case executionCompleted = "execution_completed"
        case executionFailed = "execution_failed"
        case requestCancellation = "request_cancellation"
        case backendAcceptedCancellation = "backend_accepted_cancellation"
        case terminationStarted = "termination_started"
        case cancellationConfirmed = "cancellation_confirmed"
        case backendRejectedCancellation = "backend_rejected_cancellation"
        case observationBecameIndeterminate = "observation_became_indeterminate"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported execution-control event schema: \(version)"
            )
        }
        let kind = try container.decode(Kind.self, forKey: .kind)
        let expected: Set<String> = switch kind {
        case .requestCancellation:
            [CodingKeys.schemaVersion.rawValue, CodingKeys.kind.rawValue, CodingKeys.intent.rawValue]
        default:
            [CodingKeys.schemaVersion.rawValue, CodingKeys.kind.rawValue]
        }
        try RunLedgerStrictCoding.requireExactKeys(
            decoder,
            expected: expected,
            typeName: "RunLedgerExecutionControlEvent"
        )
        switch kind {
        case .executionStarted:
            self = .executionStarted
        case .executionCompleted:
            self = .executionCompleted
        case .executionFailed:
            self = .executionFailed
        case .requestCancellation:
            self = .requestCancellation(
                try container.decode(ExecutionCancellationIntent.self, forKey: .intent)
            )
        case .backendAcceptedCancellation:
            self = .backendAcceptedCancellation
        case .terminationStarted:
            self = .terminationStarted
        case .cancellationConfirmed:
            self = .cancellationConfirmed
        case .backendRejectedCancellation:
            self = .backendRejectedCancellation
        case .observationBecameIndeterminate:
            self = .observationBecameIndeterminate
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schemaVersion, forKey: .schemaVersion)
        switch self {
        case .executionStarted:
            try container.encode(Kind.executionStarted, forKey: .kind)
        case .executionCompleted:
            try container.encode(Kind.executionCompleted, forKey: .kind)
        case .executionFailed:
            try container.encode(Kind.executionFailed, forKey: .kind)
        case .requestCancellation(let intent):
            try container.encode(Kind.requestCancellation, forKey: .kind)
            try container.encode(intent, forKey: .intent)
        case .backendAcceptedCancellation:
            try container.encode(Kind.backendAcceptedCancellation, forKey: .kind)
        case .terminationStarted:
            try container.encode(Kind.terminationStarted, forKey: .kind)
        case .cancellationConfirmed:
            try container.encode(Kind.cancellationConfirmed, forKey: .kind)
        case .backendRejectedCancellation:
            try container.encode(Kind.backendRejectedCancellation, forKey: .kind)
        case .observationBecameIndeterminate:
            try container.encode(Kind.observationBecameIndeterminate, forKey: .kind)
        }
    }
}

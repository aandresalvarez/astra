import Foundation

public enum RuntimeSwitchContractError: Error, Equatable, Sendable {
    case emptyCheckpointID
    case emptyForceReasonCode
}

public struct RuntimeSwitchRequestID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        self.init(rawValue: UUID())
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(UUID.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct RuntimeSwitchCheckpointID: Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) throws {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw RuntimeSwitchContractError.emptyCheckpointID }
        self.rawValue = normalized
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let encoded = try container.decode(String.self)
        do {
            try self.init(rawValue: encoded)
            guard rawValue == encoded else { throw RuntimeSwitchContractError.emptyCheckpointID }
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Runtime switch checkpoint ID must be nonempty and canonically trimmed"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Capability must be affirmatively declared by both the provider adapter and
/// detached supervisor. Absence is not treated as support.
public enum RuntimeContinuationCapabilityDeclaration: String, Codable, Equatable, Sendable {
    case notDeclared = "not_declared"
    case unsupported
    case supported
}

public enum RuntimeSwitchExecutionLifecycle: String, Codable, Equatable, Sendable {
    case active
    case terminal
}

public struct RuntimeSwitchCheckpointEvidence: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let checkpointID: RuntimeSwitchCheckpointID?
    public let inFlightEffectCount: UInt
    public let inFlightToolOperationCount: UInt
    public let providerContinuation: RuntimeContinuationCapabilityDeclaration
    public let supervisorContinuation: RuntimeContinuationCapabilityDeclaration

    public init(
        checkpointID: RuntimeSwitchCheckpointID?,
        inFlightEffectCount: UInt,
        inFlightToolOperationCount: UInt,
        providerContinuation: RuntimeContinuationCapabilityDeclaration,
        supervisorContinuation: RuntimeContinuationCapabilityDeclaration
    ) {
        self.checkpointID = checkpointID
        self.inFlightEffectCount = inFlightEffectCount
        self.inFlightToolOperationCount = inFlightToolOperationCount
        self.providerContinuation = providerContinuation
        self.supervisorContinuation = supervisorContinuation
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case checkpointID
        case inFlightEffectCount
        case inFlightToolOperationCount
        case providerContinuation
        case supervisorContinuation
    }

    public init(from decoder: Decoder) throws {
        try RuntimeSwitchStrictCoding.rejectUnknownKeys(
            in: decoder,
            allowed: Set(CodingKeys.allCases.map(\.rawValue)),
            typeName: "runtime switch checkpoint evidence"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try RuntimeSwitchStrictCoding.requireSchemaVersion(
            Self.currentSchemaVersion,
            in: container,
            key: .schemaVersion,
            typeName: "runtime switch checkpoint evidence"
        )
        self.init(
            checkpointID: try container.decodeIfPresent(RuntimeSwitchCheckpointID.self, forKey: .checkpointID),
            inFlightEffectCount: try container.decode(UInt.self, forKey: .inFlightEffectCount),
            inFlightToolOperationCount: try container.decode(UInt.self, forKey: .inFlightToolOperationCount),
            providerContinuation: try container.decode(
                RuntimeContinuationCapabilityDeclaration.self,
                forKey: .providerContinuation
            ),
            supervisorContinuation: try container.decode(
                RuntimeContinuationCapabilityDeclaration.self,
                forKey: .supervisorContinuation
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encodeIfPresent(checkpointID, forKey: .checkpointID)
        try container.encode(inFlightEffectCount, forKey: .inFlightEffectCount)
        try container.encode(inFlightToolOperationCount, forKey: .inFlightToolOperationCount)
        try container.encode(providerContinuation, forKey: .providerContinuation)
        try container.encode(supervisorContinuation, forKey: .supervisorContinuation)
    }
}

/// Current broker-owned facts used by the pure switch policy. PIDs and local
/// process handles are deliberately absent from this authority boundary.
public struct ActiveRuntimeSwitchContext: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let identity: ActiveRuntimeConfigurationIdentity
    public let lifecycle: RuntimeSwitchExecutionLifecycle
    public let checkpoint: RuntimeSwitchCheckpointEvidence

    public init(
        identity: ActiveRuntimeConfigurationIdentity,
        lifecycle: RuntimeSwitchExecutionLifecycle = .active,
        checkpoint: RuntimeSwitchCheckpointEvidence
    ) {
        self.identity = identity
        self.lifecycle = lifecycle
        self.checkpoint = checkpoint
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case identity
        case lifecycle
        case checkpoint
    }

    public init(from decoder: Decoder) throws {
        try RuntimeSwitchStrictCoding.rejectUnknownKeys(
            in: decoder,
            allowed: Set(CodingKeys.allCases.map(\.rawValue)),
            typeName: "active runtime switch context"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try RuntimeSwitchStrictCoding.requireSchemaVersion(
            Self.currentSchemaVersion,
            in: container,
            key: .schemaVersion,
            typeName: "active runtime switch context"
        )
        self.init(
            identity: try container.decode(ActiveRuntimeConfigurationIdentity.self, forKey: .identity),
            lifecycle: try container.decode(RuntimeSwitchExecutionLifecycle.self, forKey: .lifecycle),
            checkpoint: try container.decode(RuntimeSwitchCheckpointEvidence.self, forKey: .checkpoint)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(identity, forKey: .identity)
        try container.encode(lifecycle, forKey: .lifecycle)
        try container.encode(checkpoint, forKey: .checkpoint)
    }
}

import Foundation

public struct RuntimeSwitchCheckpointID: Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) throws {
        self.rawValue = try RuntimeSwitchBounds.canonical(rawValue, field: "checkpoint ID", limit: 256)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        do {
            try self.init(rawValue: value)
            guard rawValue == value else { throw RuntimeSwitchContractError.emptyValue("checkpoint ID") }
        } catch {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Checkpoint ID must be bounded and canonical")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct RuntimeSwitchEffectID: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

public struct RuntimeSwitchEvidenceID: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

public enum RuntimeSwitchExecutionLifecycle: String, Codable, Equatable, Hashable, Sendable {
    case registered
    case starting
    case running
    case cancellationPending = "cancellation_pending"
    case terminating
    case offline
    case inDoubt = "in_doubt"
    case terminal

    public var acceptsNewControlIntent: Bool {
        self == .registered || self == .starting || self == .running
    }
}

public struct RuntimeSwitchProtocolIdentity: Codable, Equatable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let adapterID: String
    public let protocolVersion: UInt32

    public init(adapterID: String, protocolVersion: UInt32) throws {
        self.adapterID = try RuntimeSwitchBounds.canonical(adapterID, field: "adapter ID", limit: 128)
        guard protocolVersion > 0 else { throw RuntimeSwitchContractError.emptyValue("adapter protocol version") }
        self.protocolVersion = protocolVersion
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case schemaVersion, adapterID, protocolVersion }

    public init(from decoder: Decoder) throws {
        try RuntimeSwitchStrictCoding.rejectUnknownKeys(
            in: decoder,
            allowed: Set(CodingKeys.allCases.map(\.rawValue)),
            typeName: "runtime switch protocol identity"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try RuntimeSwitchStrictCoding.requireSchemaVersion(
            Self.currentSchemaVersion,
            in: container,
            key: .schemaVersion,
            typeName: "runtime switch protocol identity"
        )
        try self.init(
            adapterID: container.decode(String.self, forKey: .adapterID),
            protocolVersion: container.decode(UInt32.self, forKey: .protocolVersion)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(adapterID, forKey: .adapterID)
        try container.encode(protocolVersion, forKey: .protocolVersion)
    }
}

public struct RuntimeSwitchSupervisorFence: Codable, Equatable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let installationID: RunBrokerInstallationID
    public let storeID: RunBrokerStoreID
    public let executionID: RunBrokerExecutionID
    public let authority: RunBrokerAuthority
    public let cohortID: String
    public let protocolIdentity: RuntimeSwitchProtocolIdentity

    public init(
        installationID: RunBrokerInstallationID,
        storeID: RunBrokerStoreID,
        executionID: RunBrokerExecutionID,
        authority: RunBrokerAuthority,
        cohortID: String,
        protocolIdentity: RuntimeSwitchProtocolIdentity
    ) throws {
        self.installationID = installationID
        self.storeID = storeID
        self.executionID = executionID
        self.authority = authority
        self.cohortID = try RuntimeSwitchBounds.canonical(cohortID, field: "supervisor cohort ID", limit: 256)
        self.protocolIdentity = protocolIdentity
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, installationID, storeID, executionID, authority, cohortID, protocolIdentity
    }

    public init(from decoder: Decoder) throws {
        try RuntimeSwitchStrictCoding.rejectUnknownKeys(
            in: decoder,
            allowed: Set(CodingKeys.allCases.map(\.rawValue)),
            typeName: "runtime switch supervisor fence"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try RuntimeSwitchStrictCoding.requireSchemaVersion(
            Self.currentSchemaVersion,
            in: container,
            key: .schemaVersion,
            typeName: "runtime switch supervisor fence"
        )
        try self.init(
            installationID: container.decode(RunBrokerInstallationID.self, forKey: .installationID),
            storeID: container.decode(RunBrokerStoreID.self, forKey: .storeID),
            executionID: container.decode(RunBrokerExecutionID.self, forKey: .executionID),
            authority: container.decode(RunBrokerAuthority.self, forKey: .authority),
            cohortID: container.decode(String.self, forKey: .cohortID),
            protocolIdentity: container.decode(RuntimeSwitchProtocolIdentity.self, forKey: .protocolIdentity)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(installationID, forKey: .installationID)
        try container.encode(storeID, forKey: .storeID)
        try container.encode(executionID, forKey: .executionID)
        try container.encode(authority, forKey: .authority)
        try container.encode(cohortID, forKey: .cohortID)
        try container.encode(protocolIdentity, forKey: .protocolIdentity)
    }
}

/// Exact fence captured at the authenticated safe checkpoint. Counts are not
/// persisted because only zero is valid; the watermarks and generation make a
/// later dispatch-time zero-count observation comparable without ambiguity.
public struct RuntimeSwitchCheckpointFence: Codable, Equatable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let checkpointID: RuntimeSwitchCheckpointID
    public let checkpointGeneration: UInt64
    public let ledgerSequence: UInt64
    public let effectWatermark: UInt64
    public let toolOperationWatermark: UInt64
    public let source: RuntimeSwitchSourceFence
    public let targetManifestSHA256: ExecutionLaunchArgumentsSHA256
    public let providerContinuation: RuntimeSwitchProtocolIdentity
    public let supervisor: RuntimeSwitchSupervisorFence

    package init(
        checkpointID: RuntimeSwitchCheckpointID,
        checkpointGeneration: UInt64,
        ledgerSequence: UInt64,
        effectWatermark: UInt64,
        toolOperationWatermark: UInt64,
        source: RuntimeSwitchSourceFence,
        targetManifestSHA256: ExecutionLaunchArgumentsSHA256,
        providerContinuation: RuntimeSwitchProtocolIdentity,
        supervisor: RuntimeSwitchSupervisorFence
    ) {
        self.checkpointID = checkpointID
        self.checkpointGeneration = checkpointGeneration
        self.ledgerSequence = ledgerSequence
        self.effectWatermark = effectWatermark
        self.toolOperationWatermark = toolOperationWatermark
        self.source = source
        self.targetManifestSHA256 = targetManifestSHA256
        self.providerContinuation = providerContinuation
        self.supervisor = supervisor
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, checkpointID, checkpointGeneration, ledgerSequence, effectWatermark
        case toolOperationWatermark, source, targetManifestSHA256, providerContinuation, supervisor
    }

    public init(from decoder: Decoder) throws {
        try RuntimeSwitchStrictCoding.rejectUnknownKeys(
            in: decoder,
            allowed: Set(CodingKeys.allCases.map(\.rawValue)),
            typeName: "runtime switch checkpoint fence"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try RuntimeSwitchStrictCoding.requireSchemaVersion(
            Self.currentSchemaVersion,
            in: container,
            key: .schemaVersion,
            typeName: "runtime switch checkpoint fence"
        )
        self.init(
            checkpointID: try container.decode(RuntimeSwitchCheckpointID.self, forKey: .checkpointID),
            checkpointGeneration: try container.decode(UInt64.self, forKey: .checkpointGeneration),
            ledgerSequence: try container.decode(UInt64.self, forKey: .ledgerSequence),
            effectWatermark: try container.decode(UInt64.self, forKey: .effectWatermark),
            toolOperationWatermark: try container.decode(UInt64.self, forKey: .toolOperationWatermark),
            source: try container.decode(RuntimeSwitchSourceFence.self, forKey: .source),
            targetManifestSHA256: try container.decode(ExecutionLaunchArgumentsSHA256.self, forKey: .targetManifestSHA256),
            providerContinuation: try container.decode(RuntimeSwitchProtocolIdentity.self, forKey: .providerContinuation),
            supervisor: try container.decode(RuntimeSwitchSupervisorFence.self, forKey: .supervisor)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(checkpointID, forKey: .checkpointID)
        try container.encode(checkpointGeneration, forKey: .checkpointGeneration)
        try container.encode(ledgerSequence, forKey: .ledgerSequence)
        try container.encode(effectWatermark, forKey: .effectWatermark)
        try container.encode(toolOperationWatermark, forKey: .toolOperationWatermark)
        try container.encode(source, forKey: .source)
        try container.encode(targetManifestSHA256, forKey: .targetManifestSHA256)
        try container.encode(providerContinuation, forKey: .providerContinuation)
        try container.encode(supervisor, forKey: .supervisor)
    }
}

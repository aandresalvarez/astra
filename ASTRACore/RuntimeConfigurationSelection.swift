import Foundation

public enum RuntimeConfigurationContractError: Error, Equatable, Sendable {
    case emptyConfigurationRevision
}

/// A stable revision of the complete launch configuration, not a process ID.
/// The broker compares this value exactly before accepting active-run control.
public struct RuntimeConfigurationRevision: Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) throws {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw RuntimeConfigurationContractError.emptyConfigurationRevision
        }
        self.rawValue = normalized
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let encoded = try container.decode(String.self)
        do {
            try self.init(rawValue: encoded)
            guard rawValue == encoded else {
                throw RuntimeConfigurationContractError.emptyConfigurationRevision
            }
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Runtime configuration revision must be nonempty and canonically trimmed"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Provider-neutral runtime and model configuration for one future launch.
/// It names exactly one target and intentionally has no fallback runtime.
public struct RuntimeExecutionConfiguration: Codable, Equatable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let runtimeID: AgentRuntimeID
    public let modelID: String?
    public let revision: RuntimeConfigurationRevision

    public init(
        runtimeID: AgentRuntimeID,
        modelID: String? = nil,
        revision: RuntimeConfigurationRevision
    ) {
        self.runtimeID = runtimeID
        self.modelID = modelID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        self.revision = revision
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case runtimeID
        case modelID
        case revision
    }

    public init(from decoder: Decoder) throws {
        try RuntimeSwitchStrictCoding.rejectUnknownKeys(
            in: decoder,
            allowed: Set(CodingKeys.allCases.map(\.rawValue)),
            typeName: "runtime configuration"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try RuntimeSwitchStrictCoding.requireSchemaVersion(
            Self.currentSchemaVersion,
            in: container,
            key: .schemaVersion,
            typeName: "runtime configuration"
        )
        let runtimeValue = try container.decode(String.self, forKey: .runtimeID)
        guard let runtimeID = AgentRuntimeID(rawValue: runtimeValue),
              runtimeID.rawValue == runtimeValue else {
            throw DecodingError.dataCorruptedError(
                forKey: .runtimeID,
                in: container,
                debugDescription: "Runtime ID must be nonempty and canonically trimmed"
            )
        }
        let modelID = try container.decodeIfPresent(String.self, forKey: .modelID)
        if let modelID {
            let canonical = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !canonical.isEmpty, canonical == modelID else {
                throw DecodingError.dataCorruptedError(
                    forKey: .modelID,
                    in: container,
                    debugDescription: "Model ID must be nonempty and canonically trimmed when present"
                )
            }
        }
        self.init(
            runtimeID: runtimeID,
            modelID: modelID,
            revision: try container.decode(RuntimeConfigurationRevision.self, forKey: .revision)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(runtimeID.rawValue, forKey: .runtimeID)
        try container.encodeIfPresent(modelID, forKey: .modelID)
        try container.encode(revision, forKey: .revision)
    }
}

/// Immutable identity of the active execution configuration. There is no PID:
/// only broker-issued execution identity and fenced authority can control it.
public struct ActiveRuntimeConfigurationIdentity: Codable, Equatable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let executionID: RunBrokerExecutionID
    public let authority: RunBrokerAuthority
    public let configuration: RuntimeExecutionConfiguration

    public init(
        executionID: RunBrokerExecutionID,
        authority: RunBrokerAuthority,
        configuration: RuntimeExecutionConfiguration
    ) {
        self.executionID = executionID
        self.authority = authority
        self.configuration = configuration
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case executionID
        case authorityID
        case authorityEpoch
        case configuration
    }

    public init(from decoder: Decoder) throws {
        try RuntimeSwitchStrictCoding.rejectUnknownKeys(
            in: decoder,
            allowed: Set(CodingKeys.allCases.map(\.rawValue)),
            typeName: "active runtime identity"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try RuntimeSwitchStrictCoding.requireSchemaVersion(
            Self.currentSchemaVersion,
            in: container,
            key: .schemaVersion,
            typeName: "active runtime identity"
        )
        self.init(
            executionID: .init(rawValue: try container.decode(UUID.self, forKey: .executionID)),
            authority: .init(
                id: .init(rawValue: try container.decode(UUID.self, forKey: .authorityID)),
                epoch: .init(rawValue: try container.decode(UInt64.self, forKey: .authorityEpoch))
            ),
            configuration: try container.decode(RuntimeExecutionConfiguration.self, forKey: .configuration)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(executionID.rawValue, forKey: .executionID)
        try container.encode(authority.id.rawValue, forKey: .authorityID)
        try container.encode(authority.epoch.rawValue, forKey: .authorityEpoch)
        try container.encode(configuration, forKey: .configuration)
    }
}

/// Runtime-picker state. The active identity is observation-only; selection can
/// replace only `next`, so this reducer cannot emit cancellation or process I/O.
public struct NextExecutionRuntimeSelectionState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let active: ActiveRuntimeConfigurationIdentity?
    public let next: RuntimeExecutionConfiguration

    public init(
        active: ActiveRuntimeConfigurationIdentity? = nil,
        next: RuntimeExecutionConfiguration
    ) {
        self.active = active
        self.next = next
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case active
        case next
    }

    public init(from decoder: Decoder) throws {
        try RuntimeSwitchStrictCoding.rejectUnknownKeys(
            in: decoder,
            allowed: Set(CodingKeys.allCases.map(\.rawValue)),
            typeName: "next execution selection state"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try RuntimeSwitchStrictCoding.requireSchemaVersion(
            Self.currentSchemaVersion,
            in: container,
            key: .schemaVersion,
            typeName: "next execution selection state"
        )
        self.init(
            active: try container.decodeIfPresent(ActiveRuntimeConfigurationIdentity.self, forKey: .active),
            next: try container.decode(RuntimeExecutionConfiguration.self, forKey: .next)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encodeIfPresent(active, forKey: .active)
        try container.encode(next, forKey: .next)
    }
}

public enum NextExecutionRuntimeSelectionDisposition: String, Codable, Equatable, Sendable {
    case applied
    case idempotent
}

public struct NextExecutionRuntimeSelectionReduction: Equatable, Sendable {
    public let state: NextExecutionRuntimeSelectionState
    public let disposition: NextExecutionRuntimeSelectionDisposition

    public init(
        state: NextExecutionRuntimeSelectionState,
        disposition: NextExecutionRuntimeSelectionDisposition
    ) {
        self.state = state
        self.disposition = disposition
    }
}

public enum NextExecutionRuntimeSelectionReducer {
    public static func select(
        _ configuration: RuntimeExecutionConfiguration,
        in state: NextExecutionRuntimeSelectionState
    ) -> NextExecutionRuntimeSelectionReduction {
        guard configuration != state.next else {
            return .init(state: state, disposition: .idempotent)
        }
        return .init(
            state: .init(active: state.active, next: configuration),
            disposition: .applied
        )
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

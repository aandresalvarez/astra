import Foundation

public enum RuntimeSwitchRequestSource: String, Codable, Equatable, Sendable {
    case runtimePicker = "runtime_picker"
    case taskChat = "task_chat"
    case diagnostics
    case automation
}

/// Force-only audit fields. They never appear on ordinary selection or the
/// default graceful request path.
public struct RuntimeForceSwitchAudit: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let source: RuntimeSwitchRequestSource
    public let reasonCode: String

    public init(source: RuntimeSwitchRequestSource, reasonCode: String) throws {
        let normalized = reasonCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw RuntimeSwitchContractError.emptyForceReasonCode }
        self.source = source
        self.reasonCode = normalized
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case source
        case reasonCode
    }

    public init(from decoder: Decoder) throws {
        try RuntimeSwitchStrictCoding.rejectUnknownKeys(
            in: decoder,
            allowed: Set(CodingKeys.allCases.map(\.rawValue)),
            typeName: "runtime force-switch audit"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try RuntimeSwitchStrictCoding.requireSchemaVersion(
            Self.currentSchemaVersion,
            in: container,
            key: .schemaVersion,
            typeName: "runtime force-switch audit"
        )
        let reasonCode = try container.decode(String.self, forKey: .reasonCode)
        do {
            try self.init(
                source: container.decode(RuntimeSwitchRequestSource.self, forKey: .source),
                reasonCode: reasonCode
            )
            guard self.reasonCode == reasonCode else {
                throw RuntimeSwitchContractError.emptyForceReasonCode
            }
        } catch let error as RuntimeSwitchContractError {
            throw DecodingError.dataCorruptedError(
                forKey: .reasonCode,
                in: container,
                debugDescription: String(describing: error)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(source, forKey: .source)
        try container.encode(reasonCode, forKey: .reasonCode)
    }
}

public enum RuntimeForceSwitchAffirmation: String, Codable, Equatable, Sendable {
    case terminateActiveExecutionImmediately = "terminate_active_execution_immediately"
}

public struct RuntimeForceSwitchConfirmation: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let confirmationID: UUID
    public let affirmedRequestID: RuntimeSwitchRequestID
    public let affirmedExecutionID: RunBrokerExecutionID
    public let affirmedTarget: RuntimeExecutionConfiguration
    public let affirmation: RuntimeForceSwitchAffirmation
    public let confirmedAt: Date

    public init(
        confirmationID: UUID,
        affirmedRequestID: RuntimeSwitchRequestID,
        affirmedExecutionID: RunBrokerExecutionID,
        affirmedTarget: RuntimeExecutionConfiguration,
        affirmation: RuntimeForceSwitchAffirmation,
        confirmedAt: Date
    ) {
        self.confirmationID = confirmationID
        self.affirmedRequestID = affirmedRequestID
        self.affirmedExecutionID = affirmedExecutionID
        self.affirmedTarget = affirmedTarget
        self.affirmation = affirmation
        self.confirmedAt = confirmedAt
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case confirmationID
        case affirmedRequestID
        case affirmedExecutionID
        case affirmedTarget
        case affirmation
        case confirmedAt
    }

    public init(from decoder: Decoder) throws {
        try RuntimeSwitchStrictCoding.rejectUnknownKeys(
            in: decoder,
            allowed: Set(CodingKeys.allCases.map(\.rawValue)),
            typeName: "runtime force-switch confirmation"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try RuntimeSwitchStrictCoding.requireSchemaVersion(
            Self.currentSchemaVersion,
            in: container,
            key: .schemaVersion,
            typeName: "runtime force-switch confirmation"
        )
        self.init(
            confirmationID: try container.decode(UUID.self, forKey: .confirmationID),
            affirmedRequestID: try container.decode(RuntimeSwitchRequestID.self, forKey: .affirmedRequestID),
            affirmedExecutionID: .init(
                rawValue: try container.decode(UUID.self, forKey: .affirmedExecutionID)
            ),
            affirmedTarget: try container.decode(RuntimeExecutionConfiguration.self, forKey: .affirmedTarget),
            affirmation: try container.decode(RuntimeForceSwitchAffirmation.self, forKey: .affirmation),
            confirmedAt: try container.decode(Date.self, forKey: .confirmedAt)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(confirmationID, forKey: .confirmationID)
        try container.encode(affirmedRequestID, forKey: .affirmedRequestID)
        try container.encode(affirmedExecutionID.rawValue, forKey: .affirmedExecutionID)
        try container.encode(affirmedTarget, forKey: .affirmedTarget)
        try container.encode(affirmation, forKey: .affirmation)
        try container.encode(confirmedAt, forKey: .confirmedAt)
    }
}

public struct ForceRuntimeSwitchRequest: Codable, Equatable, Sendable {
    public let intent: RuntimeSwitchIntent
    public let audit: RuntimeForceSwitchAudit
    public let confirmation: RuntimeForceSwitchConfirmation?

    public init(
        intent: RuntimeSwitchIntent,
        audit: RuntimeForceSwitchAudit,
        confirmation: RuntimeForceSwitchConfirmation?
    ) {
        self.intent = intent
        self.audit = audit
        self.confirmation = confirmation
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case intent
        case audit
        case confirmation
    }

    public init(from decoder: Decoder) throws {
        try RuntimeSwitchStrictCoding.rejectUnknownKeys(
            in: decoder,
            allowed: Set(CodingKeys.allCases.map(\.rawValue)),
            typeName: "force runtime switch request"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            intent: try container.decode(RuntimeSwitchIntent.self, forKey: .intent),
            audit: try container.decode(RuntimeForceSwitchAudit.self, forKey: .audit),
            confirmation: try container.decodeIfPresent(
                RuntimeForceSwitchConfirmation.self,
                forKey: .confirmation
            )
        )
    }
}

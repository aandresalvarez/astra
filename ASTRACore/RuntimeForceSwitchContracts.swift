import Foundation

public enum RuntimeSwitchRequestSource: String, Codable, Equatable, Hashable, Sendable {
    case runtimePicker = "runtime_picker"
    case taskChat = "task_chat"
    case diagnostics
    case automation
}

public enum RuntimeForceSwitchReasonCode: String, Codable, Equatable, Hashable, Sendable {
    case providerUnresponsive = "provider_unresponsive"
    case supervisorRecovery = "supervisor_recovery"
    case operatorEmergencyStop = "operator_emergency_stop"
    case diagnosticsEscalation = "diagnostics_escalation"
}

public struct RuntimeSwitchAuditID: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { self.init(rawValue: UUID()) }
}

/// Caller-supplied audit intent. It is durable but not sufficient authority to
/// terminate anything; the broker requires a separate verified challenge
/// confirmation before creating an immediate cancellation effect.
public struct RuntimeForceSwitchAudit: Codable, Equatable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let auditID: RuntimeSwitchAuditID
    public let source: RuntimeSwitchRequestSource
    public let reasonCode: RuntimeForceSwitchReasonCode

    public init(
        auditID: RuntimeSwitchAuditID,
        source: RuntimeSwitchRequestSource,
        reasonCode: RuntimeForceSwitchReasonCode
    ) {
        self.auditID = auditID
        self.source = source
        self.reasonCode = reasonCode
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case schemaVersion, auditID, source, reasonCode }

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
        self.init(
            auditID: try container.decode(RuntimeSwitchAuditID.self, forKey: .auditID),
            source: try container.decode(RuntimeSwitchRequestSource.self, forKey: .source),
            reasonCode: try container.decode(RuntimeForceSwitchReasonCode.self, forKey: .reasonCode)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(auditID, forKey: .auditID)
        try container.encode(source, forKey: .source)
        try container.encode(reasonCode, forKey: .reasonCode)
    }
}

public struct RuntimeForceChallengeID: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

public struct RuntimeSwitchActorID: Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) throws {
        self.rawValue = try RuntimeSwitchBounds.canonical(rawValue, field: "authenticated actor ID", limit: 256)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        do {
            try self.init(rawValue: value)
            guard rawValue == value else { throw RuntimeSwitchContractError.emptyValue("authenticated actor ID") }
        } catch {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Actor ID must be bounded and canonical")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Broker-issued, ledger-stored challenge. Its package-only initializer and
/// architecture boundary prevent UI/callers from manufacturing confirmation
/// authority. Decoding exists only for durable broker recovery.
public struct RuntimeForceSwitchChallenge: Codable, Equatable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let challengeID: RuntimeForceChallengeID
    public let requestID: RuntimeSwitchRequestID
    public let requestDigest: RuntimeSwitchRequestDigest
    public let actorID: RuntimeSwitchActorID
    public let sessionID: UUID
    public let issuedAt: Date
    public let expiresAt: Date

    package init(
        challengeID: RuntimeForceChallengeID,
        requestID: RuntimeSwitchRequestID,
        requestDigest: RuntimeSwitchRequestDigest,
        actorID: RuntimeSwitchActorID,
        sessionID: UUID,
        issuedAt: Date,
        expiresAt: Date
    ) throws {
        try Self.validate(issuedAt: issuedAt, expiresAt: expiresAt)
        self.challengeID = challengeID
        self.requestID = requestID
        self.requestDigest = requestDigest
        self.actorID = actorID
        self.sessionID = sessionID
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, challengeID, requestID, requestDigest, actorID, sessionID, issuedAt, expiresAt
    }

    public init(from decoder: Decoder) throws {
        try RuntimeSwitchStrictCoding.rejectUnknownKeys(
            in: decoder,
            allowed: Set(CodingKeys.allCases.map(\.rawValue)),
            typeName: "runtime force-switch challenge"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try RuntimeSwitchStrictCoding.requireSchemaVersion(
            Self.currentSchemaVersion,
            in: container,
            key: .schemaVersion,
            typeName: "runtime force-switch challenge"
        )
        try self.init(
            challengeID: container.decode(RuntimeForceChallengeID.self, forKey: .challengeID),
            requestID: container.decode(RuntimeSwitchRequestID.self, forKey: .requestID),
            requestDigest: container.decode(RuntimeSwitchRequestDigest.self, forKey: .requestDigest),
            actorID: container.decode(RuntimeSwitchActorID.self, forKey: .actorID),
            sessionID: container.decode(UUID.self, forKey: .sessionID),
            issuedAt: container.decode(Date.self, forKey: .issuedAt),
            expiresAt: container.decode(Date.self, forKey: .expiresAt)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(challengeID, forKey: .challengeID)
        try container.encode(requestID, forKey: .requestID)
        try container.encode(requestDigest, forKey: .requestDigest)
        try container.encode(actorID, forKey: .actorID)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(issuedAt, forKey: .issuedAt)
        try container.encode(expiresAt, forKey: .expiresAt)
    }

    private static func validate(issuedAt: Date, expiresAt: Date) throws {
        guard issuedAt.timeIntervalSince1970.isFinite,
              expiresAt.timeIntervalSince1970.isFinite,
              expiresAt > issuedAt,
              expiresAt.timeIntervalSince(issuedAt) <= 300 else {
            throw RuntimeSwitchContractError.invalidTimestamp("force challenge")
        }
    }
}

public struct ForceRuntimeSwitchRequest: Codable, Equatable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let intent: RuntimeSwitchIntent
    public let audit: RuntimeForceSwitchAudit

    public init(intent: RuntimeSwitchIntent, audit: RuntimeForceSwitchAudit) throws {
        guard intent.mode == .immediate else { throw RuntimeSwitchContractError.invalidMode }
        self.intent = intent
        self.audit = audit
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case schemaVersion, intent, audit }

    public init(from decoder: Decoder) throws {
        try RuntimeSwitchStrictCoding.rejectUnknownKeys(
            in: decoder,
            allowed: Set(CodingKeys.allCases.map(\.rawValue)),
            typeName: "force runtime switch request"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try RuntimeSwitchStrictCoding.requireSchemaVersion(
            Self.currentSchemaVersion,
            in: container,
            key: .schemaVersion,
            typeName: "force runtime switch request"
        )
        try self.init(
            intent: container.decode(RuntimeSwitchIntent.self, forKey: .intent),
            audit: container.decode(RuntimeForceSwitchAudit.self, forKey: .audit)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(intent, forKey: .intent)
        try container.encode(audit, forKey: .audit)
    }
}

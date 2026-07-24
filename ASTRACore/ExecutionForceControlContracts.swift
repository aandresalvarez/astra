import Foundation

public struct ExecutionForceRequestDigest: Codable, Equatable, Hashable, Sendable {
    public let value: ExecutionLaunchArgumentsSHA256
    public init(value: ExecutionLaunchArgumentsSHA256) { self.value = value }
}

public struct ExecutionForceChallenge: Codable, Equatable, Hashable, Sendable {
    public let challengeID: RuntimeForceChallengeID
    public let requestDigest: ExecutionForceRequestDigest
    public let requestID: UUID
    public let executionID: RunBrokerExecutionID
    public let authority: RunBrokerAuthority
    public let expectedSupervisorSequence: UInt64
    public let actorID: RuntimeSwitchActorID
    public let sessionID: UUID
    public let audit: RuntimeForceSwitchAudit
    public let issuedAt: Date
    public let expiresAt: Date

    package init(
        challengeID: RuntimeForceChallengeID,
        requestDigest: ExecutionForceRequestDigest,
        requestID: UUID,
        executionID: RunBrokerExecutionID,
        authority: RunBrokerAuthority,
        expectedSupervisorSequence: UInt64,
        actorID: RuntimeSwitchActorID,
        sessionID: UUID,
        audit: RuntimeForceSwitchAudit,
        issuedAt: Date,
        expiresAt: Date
    ) throws {
        guard Self.canonical(issuedAt), Self.canonical(expiresAt),
              expiresAt > issuedAt,
              expiresAt.timeIntervalSince(issuedAt) <= 10 * 60,
              authority.epoch.rawValue > 0 else {
            throw RuntimeSwitchContractError.invalidTimestamp("execution force challenge")
        }
        self.challengeID = challengeID
        self.requestDigest = requestDigest
        self.requestID = requestID
        self.executionID = executionID
        self.authority = authority
        self.expectedSupervisorSequence = expectedSupervisorSequence
        self.actorID = actorID
        self.sessionID = sessionID
        self.audit = audit
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case challengeID, requestDigest, requestID, executionID, authority
        case expectedSupervisorSequence, actorID, sessionID, audit, issuedAt, expiresAt
    }

    public init(from decoder: Decoder) throws {
        try RuntimeSwitchStrictCoding.rejectUnknownKeys(
            in: decoder,
            allowed: Set(CodingKeys.allCases.map(\.rawValue)),
            typeName: "execution force challenge"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            challengeID: container.decode(RuntimeForceChallengeID.self, forKey: .challengeID),
            requestDigest: container.decode(ExecutionForceRequestDigest.self, forKey: .requestDigest),
            requestID: container.decode(UUID.self, forKey: .requestID),
            executionID: container.decode(RunBrokerExecutionID.self, forKey: .executionID),
            authority: container.decode(RunBrokerAuthority.self, forKey: .authority),
            expectedSupervisorSequence: container.decode(UInt64.self, forKey: .expectedSupervisorSequence),
            actorID: container.decode(RuntimeSwitchActorID.self, forKey: .actorID),
            sessionID: container.decode(UUID.self, forKey: .sessionID),
            audit: container.decode(RuntimeForceSwitchAudit.self, forKey: .audit),
            issuedAt: container.decode(Date.self, forKey: .issuedAt),
            expiresAt: container.decode(Date.self, forKey: .expiresAt)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(challengeID, forKey: .challengeID)
        try container.encode(requestDigest, forKey: .requestDigest)
        try container.encode(requestID, forKey: .requestID)
        try container.encode(executionID, forKey: .executionID)
        try container.encode(authority, forKey: .authority)
        try container.encode(expectedSupervisorSequence, forKey: .expectedSupervisorSequence)
        try container.encode(actorID, forKey: .actorID)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(audit, forKey: .audit)
        try container.encode(issuedAt, forKey: .issuedAt)
        try container.encode(expiresAt, forKey: .expiresAt)
    }

    private static func canonical(_ date: Date) -> Bool {
        let milliseconds = date.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite,
              milliseconds >= Double(Int64.min), milliseconds <= Double(Int64.max) else {
            return false
        }
        return date == Date(
            timeIntervalSince1970: Double(Int64(milliseconds.rounded(.towardZero))) / 1_000
        )
    }
}

public struct ExecutionForceChallengeConsumption: Codable, Equatable, Hashable, Sendable {
    public let challenge: ExecutionForceChallenge
    public let effectID: RuntimeSwitchEffectID
    public let confirmedAt: Date

    package init(
        challenge: ExecutionForceChallenge,
        effectID: RuntimeSwitchEffectID,
        confirmedAt: Date
    ) throws {
        guard confirmedAt >= challenge.issuedAt, confirmedAt <= challenge.expiresAt else {
            throw RuntimeSwitchContractError.invalidTimestamp("execution force confirmation")
        }
        self.challenge = challenge
        self.effectID = effectID
        self.confirmedAt = confirmedAt
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case challenge, effectID, confirmedAt
    }

    public init(from decoder: Decoder) throws {
        try RuntimeSwitchStrictCoding.rejectUnknownKeys(
            in: decoder,
            allowed: Set(CodingKeys.allCases.map(\.rawValue)),
            typeName: "execution force challenge consumption"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            challenge: container.decode(ExecutionForceChallenge.self, forKey: .challenge),
            effectID: container.decode(RuntimeSwitchEffectID.self, forKey: .effectID),
            confirmedAt: container.decode(Date.self, forKey: .confirmedAt)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(challenge, forKey: .challenge)
        try container.encode(effectID, forKey: .effectID)
        try container.encode(confirmedAt, forKey: .confirmedAt)
    }
}

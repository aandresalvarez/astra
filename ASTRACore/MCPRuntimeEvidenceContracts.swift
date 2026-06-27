public enum MCPRuntimeDeliveryEvidenceKind: String, Codable, Equatable, Sendable, CaseIterable {
    case manifestDeclared
    case runtimeConfigRendered
    case gatewayProjection
    case providerAccepted
    case healthProbe
}

public enum MCPRuntimeEvidenceStatus: String, Codable, Equatable, Sendable, CaseIterable {
    case pending
    case delivered
    case warning
    case failed
    case stale
}

public struct MCPRuntimeEvidenceFingerprint: Codable, Equatable, Sendable {
    public var subject: String
    public var algorithm: String
    public var digest: String

    public init(subject: String, algorithm: String, digest: String) {
        self.subject = subject
        self.algorithm = algorithm
        self.digest = digest
    }
}

public struct MCPRuntimeDeliveryEvidence: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var serverID: String
    public var kind: MCPRuntimeDeliveryEvidenceKind
    public var status: MCPRuntimeEvidenceStatus
    public var observedAt: String?
    public var fingerprints: [MCPRuntimeEvidenceFingerprint]
    public var diagnosticRefIDs: [String]

    public init(
        id: String,
        serverID: String,
        kind: MCPRuntimeDeliveryEvidenceKind,
        status: MCPRuntimeEvidenceStatus,
        observedAt: String? = nil,
        fingerprints: [MCPRuntimeEvidenceFingerprint] = [],
        diagnosticRefIDs: [String] = []
    ) {
        self.id = id
        self.serverID = serverID
        self.kind = kind
        self.status = status
        self.observedAt = observedAt
        self.fingerprints = fingerprints
        self.diagnosticRefIDs = diagnosticRefIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        serverID = try container.decode(String.self, forKey: .serverID)
        kind = try container.decode(MCPRuntimeDeliveryEvidenceKind.self, forKey: .kind)
        status = try container.decode(MCPRuntimeEvidenceStatus.self, forKey: .status)
        observedAt = try container.decodeIfPresent(String.self, forKey: .observedAt)
        fingerprints = try container.decodeIfPresent(
            [MCPRuntimeEvidenceFingerprint].self,
            forKey: .fingerprints
        ) ?? []
        diagnosticRefIDs = try container.decodeIfPresent([String].self, forKey: .diagnosticRefIDs) ?? []
    }
}

public enum MCPValidationDriftKind: String, Codable, Equatable, Sendable, CaseIterable {
    case authProfileMismatch
    case deliveryEvidenceStale
    case manifestShapeMismatch
    case missingServer
    case providerCapabilityMismatch
    case runtimeBindingMismatch
    case runtimeCapabilityMismatch
    case scopeMismatch
    case toolSchemaMismatch
}

public enum MCPValidationDriftSeverity: String, Codable, Equatable, Sendable, CaseIterable {
    case info
    case warning
    case blocking
}

public struct MCPValidationDriftEvidence: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var serverID: String
    public var kind: MCPValidationDriftKind
    public var severity: MCPValidationDriftSeverity
    public var expectedFingerprint: String?
    public var observedFingerprint: String?
    public var evidenceIDs: [String]

    public init(
        id: String,
        serverID: String,
        kind: MCPValidationDriftKind,
        severity: MCPValidationDriftSeverity,
        expectedFingerprint: String? = nil,
        observedFingerprint: String? = nil,
        evidenceIDs: [String] = []
    ) {
        self.id = id
        self.serverID = serverID
        self.kind = kind
        self.severity = severity
        self.expectedFingerprint = expectedFingerprint
        self.observedFingerprint = observedFingerprint
        self.evidenceIDs = evidenceIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        serverID = try container.decode(String.self, forKey: .serverID)
        kind = try container.decode(MCPValidationDriftKind.self, forKey: .kind)
        severity = try container.decode(MCPValidationDriftSeverity.self, forKey: .severity)
        expectedFingerprint = try container.decodeIfPresent(String.self, forKey: .expectedFingerprint)
        observedFingerprint = try container.decodeIfPresent(String.self, forKey: .observedFingerprint)
        evidenceIDs = try container.decodeIfPresent([String].self, forKey: .evidenceIDs) ?? []
    }
}

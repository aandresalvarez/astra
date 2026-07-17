import Foundation

/// Intent shared by graceful and force actions. `expectedActive` provides
/// compare-and-swap fencing over execution, authority, and config revision.
public struct RuntimeSwitchIntent: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let requestID: RuntimeSwitchRequestID
    public let expectedActive: ActiveRuntimeConfigurationIdentity
    public let target: RuntimeExecutionConfiguration
    public let requestedAt: Date

    public init(
        requestID: RuntimeSwitchRequestID,
        expectedActive: ActiveRuntimeConfigurationIdentity,
        target: RuntimeExecutionConfiguration,
        requestedAt: Date
    ) {
        self.requestID = requestID
        self.expectedActive = expectedActive
        self.target = target
        self.requestedAt = requestedAt
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case requestID
        case expectedActive
        case target
        case requestedAt
    }

    public init(from decoder: Decoder) throws {
        try RuntimeSwitchStrictCoding.rejectUnknownKeys(
            in: decoder,
            allowed: Set(CodingKeys.allCases.map(\.rawValue)),
            typeName: "runtime switch intent"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try RuntimeSwitchStrictCoding.requireSchemaVersion(
            Self.currentSchemaVersion,
            in: container,
            key: .schemaVersion,
            typeName: "runtime switch intent"
        )
        self.init(
            requestID: try container.decode(RuntimeSwitchRequestID.self, forKey: .requestID),
            expectedActive: try container.decode(ActiveRuntimeConfigurationIdentity.self, forKey: .expectedActive),
            target: try container.decode(RuntimeExecutionConfiguration.self, forKey: .target),
            requestedAt: try container.decode(Date.self, forKey: .requestedAt)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(requestID, forKey: .requestID)
        try container.encode(expectedActive, forKey: .expectedActive)
        try container.encode(target, forKey: .target)
        try container.encode(requestedAt, forKey: .requestedAt)
    }
}

public struct GracefulRuntimeHandoffRequest: Codable, Equatable, Sendable {
    public let intent: RuntimeSwitchIntent

    public init(intent: RuntimeSwitchIntent) {
        self.intent = intent
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case intent }

    public init(from decoder: Decoder) throws {
        try RuntimeSwitchStrictCoding.rejectUnknownKeys(
            in: decoder,
            allowed: Set(CodingKeys.allCases.map(\.rawValue)),
            typeName: "graceful runtime handoff request"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(intent: try container.decode(RuntimeSwitchIntent.self, forKey: .intent))
    }
}

/// Active-run switching is explicit. Callers that do not choose a force action
/// receive the graceful handoff path through `defaultHandoff`.
public enum ActiveRuntimeSwitchRequest: Codable, Equatable, Sendable {
    case gracefulHandoff(GracefulRuntimeHandoffRequest)
    case forceTermination(ForceRuntimeSwitchRequest)

    public static func defaultHandoff(intent: RuntimeSwitchIntent) -> Self {
        .gracefulHandoff(.init(intent: intent))
    }

    public var intent: RuntimeSwitchIntent {
        switch self {
        case .gracefulHandoff(let request): request.intent
        case .forceTermination(let request): request.intent
        }
    }

    private enum Kind: String, Codable {
        case gracefulHandoff = "graceful_handoff"
        case forceTermination = "force_termination"
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case kind
        case gracefulHandoff
        case forceTermination
    }

    public init(from decoder: Decoder) throws {
        try RuntimeSwitchStrictCoding.rejectUnknownKeys(
            in: decoder,
            allowed: Set(CodingKeys.allCases.map(\.rawValue)),
            typeName: "active runtime switch request"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try RuntimeSwitchStrictCoding.requireSchemaVersion(
            1,
            in: container,
            key: .schemaVersion,
            typeName: "active runtime switch request"
        )
        switch try container.decode(Kind.self, forKey: .kind) {
        case .gracefulHandoff:
            guard !container.contains(.forceTermination) else {
                throw Self.invalidVariant(in: container)
            }
            self = .gracefulHandoff(
                try container.decode(GracefulRuntimeHandoffRequest.self, forKey: .gracefulHandoff)
            )
        case .forceTermination:
            guard !container.contains(.gracefulHandoff) else {
                throw Self.invalidVariant(in: container)
            }
            self = .forceTermination(
                try container.decode(ForceRuntimeSwitchRequest.self, forKey: .forceTermination)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(1, forKey: .schemaVersion)
        switch self {
        case .gracefulHandoff(let request):
            try container.encode(Kind.gracefulHandoff, forKey: .kind)
            try container.encode(request, forKey: .gracefulHandoff)
        case .forceTermination(let request):
            try container.encode(Kind.forceTermination, forKey: .kind)
            try container.encode(request, forKey: .forceTermination)
        }
    }

    private static func invalidVariant(
        in container: KeyedDecodingContainer<CodingKeys>
    ) -> DecodingError {
        .dataCorrupted(.init(
            codingPath: container.codingPath,
            debugDescription: "Runtime switch request must contain exactly one payload matching kind"
        ))
    }
}

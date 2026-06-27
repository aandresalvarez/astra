import Foundation

public enum MCPProviderCapabilityAvailability: String, Codable, Equatable, Sendable, CaseIterable {
    case available
    case preview
    case unavailable
    case deprecated
}

public enum MCPProviderCapabilityInvariantViolation: Equatable, Sendable {
    case contractIDRequired
    case idRequired
    case undeclaredAuthProfileRef(String)
    case undeclaredConfigRef(String)
    case undeclaredSecretRef(String)
}

public struct MCPProviderCapability: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var displayName: String
    public var contractID: RemoteMCPContractID
    public var availability: MCPProviderCapabilityAvailability
    public var requiredAuthProfileRefs: [String]
    public var requiredSecretRefs: [String]
    public var requiredConfigRefs: [String]
    public var requiredScopes: [OAuthScope]
    public var supportedToolEffects: [RemoteMCPToolEffect]

    public init(
        id: String,
        displayName: String,
        contractID: RemoteMCPContractID,
        availability: MCPProviderCapabilityAvailability,
        requiredAuthProfileRefs: [String] = [],
        requiredSecretRefs: [String] = [],
        requiredConfigRefs: [String] = [],
        requiredScopes: [OAuthScope] = [],
        supportedToolEffects: [RemoteMCPToolEffect] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.contractID = contractID
        self.availability = availability
        self.requiredAuthProfileRefs = requiredAuthProfileRefs
        self.requiredSecretRefs = requiredSecretRefs
        self.requiredConfigRefs = requiredConfigRefs
        self.requiredScopes = requiredScopes
        self.supportedToolEffects = supportedToolEffects
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        contractID = try container.decode(RemoteMCPContractID.self, forKey: .contractID)
        availability = try container.decode(MCPProviderCapabilityAvailability.self, forKey: .availability)
        requiredAuthProfileRefs = try container.decodeIfPresent([String].self, forKey: .requiredAuthProfileRefs) ?? []
        requiredSecretRefs = try container.decodeIfPresent([String].self, forKey: .requiredSecretRefs) ?? []
        requiredConfigRefs = try container.decodeIfPresent([String].self, forKey: .requiredConfigRefs) ?? []
        requiredScopes = try container.decodeIfPresent([OAuthScope].self, forKey: .requiredScopes) ?? []
        supportedToolEffects = try container.decodeIfPresent(
            [RemoteMCPToolEffect].self,
            forKey: .supportedToolEffects
        ) ?? []
    }

    public func invariantViolations(
        declaredAuthProfileRefs: Set<String>,
        declaredSecretRefs: Set<String>,
        declaredConfigRefs: Set<String>
    ) -> [MCPProviderCapabilityInvariantViolation] {
        var violations: [MCPProviderCapabilityInvariantViolation] = []
        if id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            violations.append(.idRequired)
        }
        if contractID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            violations.append(.contractIDRequired)
        }
        for ref in requiredAuthProfileRefs.map(Self.trimmedNonEmpty) where !declaredAuthProfileRefs.contains(ref) {
            violations.append(.undeclaredAuthProfileRef(ref))
        }
        for ref in requiredSecretRefs.map(Self.trimmedNonEmpty) where !declaredSecretRefs.contains(ref) {
            violations.append(.undeclaredSecretRef(ref))
        }
        for ref in requiredConfigRefs.map(Self.trimmedNonEmpty) where !declaredConfigRefs.contains(ref) {
            violations.append(.undeclaredConfigRef(ref))
        }
        return violations
    }

    private static func trimmedNonEmpty(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

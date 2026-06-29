import Foundation

public struct MCPAuthProfileRef: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var providerID: String
    public var purpose: String
    public var required: Bool

    public init(
        id: String,
        providerID: String,
        purpose: String,
        required: Bool = true
    ) {
        self.id = id
        self.providerID = providerID
        self.purpose = purpose
        self.required = required
    }
}

public struct MCPSecretRef: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var purpose: String
    public var required: Bool

    public init(id: String, purpose: String, required: Bool = true) {
        self.id = id
        self.purpose = purpose
        self.required = required
    }
}

public struct MCPConfigRef: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var purpose: String
    public var required: Bool

    public init(id: String, purpose: String, required: Bool = true) {
        self.id = id
        self.purpose = purpose
        self.required = required
    }
}

public enum MCPControlPlaneInvariantViolation: Equatable, Sendable {
    case authProfileProviderIDRequired(String)
    case authProfileRefIDRequired
    case configRefIDRequired
    case duplicateAuthProfileRef(String)
    case duplicateConfigRef(String)
    case duplicateProviderCapability(String)
    case duplicateRuntimeBinding(String)
    case duplicateSecretRef(String)
    case providerCapability(String, MCPProviderCapabilityInvariantViolation)
    case runtimeBinding(String, MCPRuntimeBindingInvariantViolation)
    case secretRefIDRequired
}

public struct MCPControlPlaneMetadata: Codable, Equatable, Sendable {
    public var authProfileRefs: [MCPAuthProfileRef]
    public var secretRefs: [MCPSecretRef]
    public var configRefs: [MCPConfigRef]
    public var runtimeBindings: [MCPRuntimeBindingTemplate]
    public var providerCapabilities: [MCPProviderCapability]

    public init(
        authProfileRefs: [MCPAuthProfileRef] = [],
        secretRefs: [MCPSecretRef] = [],
        configRefs: [MCPConfigRef] = [],
        runtimeBindings: [MCPRuntimeBindingTemplate] = [],
        providerCapabilities: [MCPProviderCapability] = []
    ) {
        self.authProfileRefs = authProfileRefs
        self.secretRefs = secretRefs
        self.configRefs = configRefs
        self.runtimeBindings = runtimeBindings
        self.providerCapabilities = providerCapabilities
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        authProfileRefs = try container.decodeIfPresent([MCPAuthProfileRef].self, forKey: .authProfileRefs) ?? []
        secretRefs = try container.decodeIfPresent([MCPSecretRef].self, forKey: .secretRefs) ?? []
        configRefs = try container.decodeIfPresent([MCPConfigRef].self, forKey: .configRefs) ?? []
        runtimeBindings = try container.decodeIfPresent([MCPRuntimeBindingTemplate].self, forKey: .runtimeBindings) ?? []
        providerCapabilities = try container.decodeIfPresent([MCPProviderCapability].self, forKey: .providerCapabilities) ?? []
    }

    public func invariantViolations() -> [MCPControlPlaneInvariantViolation] {
        var violations: [MCPControlPlaneInvariantViolation] = []
        let authProfileIDs = canonicalIDs(authProfileRefs.map(\.id))
        let secretIDs = canonicalIDs(secretRefs.map(\.id))
        let configIDs = canonicalIDs(configRefs.map(\.id))

        for authProfileRef in authProfileRefs {
            let id = canonicalID(authProfileRef.id)
            if id.isEmpty {
                violations.append(.authProfileRefIDRequired)
            }
            if canonicalID(authProfileRef.providerID).isEmpty {
                violations.append(.authProfileProviderIDRequired(id))
            }
        }
        for secretRef in secretRefs where canonicalID(secretRef.id).isEmpty {
            violations.append(.secretRefIDRequired)
        }
        for configRef in configRefs where canonicalID(configRef.id).isEmpty {
            violations.append(.configRefIDRequired)
        }

        violations.append(contentsOf: duplicateIDs(authProfileRefs.map(\.id)).map {
            .duplicateAuthProfileRef($0)
        })
        violations.append(contentsOf: duplicateIDs(secretRefs.map(\.id)).map {
            .duplicateSecretRef($0)
        })
        violations.append(contentsOf: duplicateIDs(configRefs.map(\.id)).map {
            .duplicateConfigRef($0)
        })
        violations.append(contentsOf: duplicateIDs(runtimeBindings.map(\.id)).map {
            .duplicateRuntimeBinding($0)
        })
        violations.append(contentsOf: duplicateIDs(providerCapabilities.map(\.id)).map {
            .duplicateProviderCapability($0)
        })

        for binding in runtimeBindings {
            for violation in binding.invariantViolations(
                declaredSecretRefs: secretIDs,
                declaredConfigRefs: configIDs,
                declaredAuthProfileRefs: authProfileIDs
            ) {
                violations.append(.runtimeBinding(binding.id, violation))
            }
        }
        for capability in providerCapabilities {
            for violation in capability.invariantViolations(
                declaredAuthProfileRefs: authProfileIDs,
                declaredSecretRefs: secretIDs,
                declaredConfigRefs: configIDs
            ) {
                violations.append(.providerCapability(capability.id, violation))
            }
        }
        return violations
    }

    private func duplicateIDs(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        var duplicates: [String] = []
        for id in ids.map(canonicalID) where !id.isEmpty {
            if !seen.insert(id).inserted, !duplicates.contains(id) {
                duplicates.append(id)
            }
        }
        return duplicates
    }

    private func canonicalIDs(_ ids: [String]) -> Set<String> {
        Set(ids.map(canonicalID).filter { !$0.isEmpty })
    }

    private func canonicalID(_ id: String) -> String {
        id.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

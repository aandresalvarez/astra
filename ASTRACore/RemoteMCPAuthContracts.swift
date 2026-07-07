import Foundation

public struct OAuthAccountIdentity: Codable, Equatable, Sendable {
    public var providerSubject: String
    public var email: String?
    public var displayName: String?
    public var hostedDomain: String?

    public init(
        providerSubject: String,
        email: String? = nil,
        displayName: String? = nil,
        hostedDomain: String? = nil
    ) {
        self.providerSubject = providerSubject
        self.email = email
        self.displayName = displayName
        self.hostedDomain = hostedDomain
    }
}

public enum OAuthScopeSensitivity: String, Codable, Equatable, Sendable, CaseIterable {
    case basic
    case sensitive
    case restricted
}

public struct OAuthScope: Codable, Equatable, Sendable {
    public var value: String
    public var purpose: String
    public var sensitivity: OAuthScopeSensitivity
    public var required: Bool

    public init(
        value: String,
        purpose: String,
        sensitivity: OAuthScopeSensitivity = .sensitive,
        required: Bool = true
    ) {
        self.value = value
        self.purpose = purpose
        self.sensitivity = sensitivity
        self.required = required
    }
}

public enum RemoteMCPAuthorizationKind: String, Codable, Equatable, Sendable, CaseIterable {
    case none
    case astraOwnedOAuth
}

public struct RemoteMCPAuthProfile: Codable, Equatable, Sendable {
    public var id: String
    public var providerID: String
    public var authorizationKind: RemoteMCPAuthorizationKind
    public var account: OAuthAccountIdentity?
    public var scopes: [OAuthScope]
    public var consentRequired: Bool
    public var auditEventNamespace: String

    public init(
        id: String,
        providerID: String,
        authorizationKind: RemoteMCPAuthorizationKind,
        account: OAuthAccountIdentity? = nil,
        scopes: [OAuthScope] = [],
        consentRequired: Bool = true,
        auditEventNamespace: String
    ) {
        self.id = id
        self.providerID = providerID
        self.authorizationKind = authorizationKind
        self.account = account
        self.scopes = scopes
        self.consentRequired = consentRequired
        self.auditEventNamespace = auditEventNamespace
    }
}

public struct RemoteMCPContractID: Codable, Equatable, Hashable, Sendable, RawRepresentable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public extension RemoteMCPContractID {
    public static let googleWorkspaceDriveRead = RemoteMCPContractID(rawValue: "googleWorkspace.drive.read")
    public static let googleWorkspaceDocsRead = RemoteMCPContractID(rawValue: "googleWorkspace.docs.read")
    public static let googleWorkspaceGmailRead = RemoteMCPContractID(rawValue: "googleWorkspace.gmail.read")
    public static let googleWorkspaceGmailSend = RemoteMCPContractID(rawValue: "googleWorkspace.gmail.send")
    public static let googleWorkspaceCalendarRead = RemoteMCPContractID(rawValue: "googleWorkspace.calendar.read")
    public static let googleWorkspaceCalendarWrite = RemoteMCPContractID(rawValue: "googleWorkspace.calendar.write")
}

public enum GoogleWorkspaceContractID: String, Codable, Equatable, Sendable, CaseIterable {
    case driveRead = "googleWorkspace.drive.read"
    case docsRead = "googleWorkspace.docs.read"
    case gmailRead = "googleWorkspace.gmail.read"
    case gmailSend = "googleWorkspace.gmail.send"
    case calendarRead = "googleWorkspace.calendar.read"
    case calendarWrite = "googleWorkspace.calendar.write"

    public var contractID: RemoteMCPContractID {
        RemoteMCPContractID(rawValue: rawValue)
    }
}

public enum RemoteMCPToolEffect: String, Codable, Equatable, Sendable, CaseIterable {
    case read
    case write
    case send
    case delete
    case admin

    public var isMutating: Bool {
        switch self {
        case .read:
            return false
        case .write, .send, .delete, .admin:
            return true
        }
    }
}

public enum RemoteMCPToolClassificationViolation: Equatable, Sendable {
    case auditEventNameRequired
    case contractIDRequired
    case mutatingToolRequiresConsent
    case toolNameRequired
}

public struct RemoteMCPToolClassification: Codable, Equatable, Sendable {
    public var toolName: String
    public var contractID: RemoteMCPContractID
    public var effect: RemoteMCPToolEffect
    public var dataAccess: [CapabilityDataAccessKind]
    public var riskLevel: CapabilityRiskLevel
    public var requiresExplicitUserConsent: Bool
    public var auditEventName: String

    public init(
        toolName: String,
        contractID: RemoteMCPContractID,
        effect: RemoteMCPToolEffect,
        dataAccess: [CapabilityDataAccessKind],
        riskLevel: CapabilityRiskLevel,
        requiresExplicitUserConsent: Bool,
        auditEventName: String
    ) {
        self.toolName = toolName
        self.contractID = contractID
        self.effect = effect
        self.dataAccess = dataAccess
        self.riskLevel = riskLevel
        self.requiresExplicitUserConsent = requiresExplicitUserConsent
        self.auditEventName = auditEventName
    }

    public func invariantViolations() -> [RemoteMCPToolClassificationViolation] {
        var violations: [RemoteMCPToolClassificationViolation] = []
        if toolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            violations.append(.toolNameRequired)
        }
        if contractID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            violations.append(.contractIDRequired)
        }
        if auditEventName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            violations.append(.auditEventNameRequired)
        }
        if effect.isMutating && !requiresExplicitUserConsent {
            violations.append(.mutatingToolRequiresConsent)
        }
        return violations
    }
}

public enum RemoteMCPTokenDelivery: String, Codable, Equatable, Sendable, CaseIterable {
    case astraBrokered
}

public enum RemoteMCPRegistryInvariantViolation: Equatable, Sendable {
    case rawProviderToolsHiddenFromGeneratedApps
    case invalidToolClassification(String, RemoteMCPToolClassificationViolation)
}

public struct RemoteMCPServerRegistryMetadata: Codable, Equatable, Sendable {
    public var registryID: String
    public var providerID: String
    public var providerDisplayName: String
    public var endpoint: URL?
    public var authProfile: RemoteMCPAuthProfile?
    public var contractIDs: [RemoteMCPContractID]
    public var toolClassifications: [RemoteMCPToolClassification]
    public var tokenDelivery: RemoteMCPTokenDelivery
    public var exposesRawProviderToolsToGeneratedApps: Bool

    public init(
        registryID: String,
        providerID: String,
        providerDisplayName: String,
        endpoint: URL? = nil,
        authProfile: RemoteMCPAuthProfile? = nil,
        contractIDs: [RemoteMCPContractID] = [],
        toolClassifications: [RemoteMCPToolClassification] = [],
        tokenDelivery: RemoteMCPTokenDelivery = .astraBrokered,
        exposesRawProviderToolsToGeneratedApps: Bool = false
    ) {
        self.registryID = registryID
        self.providerID = providerID
        self.providerDisplayName = providerDisplayName
        self.endpoint = endpoint
        self.authProfile = authProfile
        self.contractIDs = contractIDs
        self.toolClassifications = toolClassifications
        self.tokenDelivery = tokenDelivery
        self.exposesRawProviderToolsToGeneratedApps = exposesRawProviderToolsToGeneratedApps
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        registryID = try container.decode(String.self, forKey: .registryID)
        providerID = try container.decode(String.self, forKey: .providerID)
        providerDisplayName = try container.decode(String.self, forKey: .providerDisplayName)
        endpoint = try container.decodeIfPresent(URL.self, forKey: .endpoint)
        authProfile = try container.decodeIfPresent(RemoteMCPAuthProfile.self, forKey: .authProfile)
        contractIDs = try container.decodeIfPresent([RemoteMCPContractID].self, forKey: .contractIDs) ?? []
        toolClassifications = try container.decodeIfPresent([RemoteMCPToolClassification].self, forKey: .toolClassifications) ?? []
        tokenDelivery = try container.decodeIfPresent(RemoteMCPTokenDelivery.self, forKey: .tokenDelivery) ?? .astraBrokered
        exposesRawProviderToolsToGeneratedApps = try container.decodeIfPresent(
            Bool.self,
            forKey: .exposesRawProviderToolsToGeneratedApps
        ) ?? false
    }

    public func invariantViolations() -> [RemoteMCPRegistryInvariantViolation] {
        var violations: [RemoteMCPRegistryInvariantViolation] = []
        if exposesRawProviderToolsToGeneratedApps {
            violations.append(.rawProviderToolsHiddenFromGeneratedApps)
        }
        for classification in toolClassifications {
            for violation in classification.invariantViolations() {
                violations.append(.invalidToolClassification(classification.toolName, violation))
            }
        }
        return violations
    }
}

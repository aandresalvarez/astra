import Foundation

public struct AstraPackManifest: Codable, Equatable, Sendable, Identifiable {
    public static let supportedFormatVersion = 1

    public var formatVersion: Int
    public var id: String
    public var name: String
    public var version: String
    public var coreAPIVersion: String
    public var description: String
    public var capabilityPackageIDs: [String]
    public var shelfDefaults: [AstraPackShelfDefault]
    public var appTemplates: [AstraPackAppTemplate]
    public var policyRestrictions: [AstraPackPolicyRestriction]
    public var vocabulary: [String: String]
    public var compositionPriority: Int?
    public var branding: AstraPackBranding?

    public init(
        formatVersion: Int = Self.supportedFormatVersion,
        id: String,
        name: String,
        version: String,
        coreAPIVersion: String,
        description: String,
        capabilityPackageIDs: [String] = [],
        shelfDefaults: [AstraPackShelfDefault] = [],
        appTemplates: [AstraPackAppTemplate] = [],
        policyRestrictions: [AstraPackPolicyRestriction] = [],
        vocabulary: [String: String] = [:],
        compositionPriority: Int? = nil,
        branding: AstraPackBranding? = nil
    ) {
        self.formatVersion = formatVersion
        self.id = id
        self.name = name
        self.version = version
        self.coreAPIVersion = coreAPIVersion
        self.description = description
        self.capabilityPackageIDs = capabilityPackageIDs
        self.shelfDefaults = shelfDefaults
        self.appTemplates = appTemplates
        self.policyRestrictions = policyRestrictions
        self.vocabulary = vocabulary
        self.compositionPriority = compositionPriority
        self.branding = branding
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        guard formatVersion == Self.supportedFormatVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .formatVersion,
                in: container,
                debugDescription: "Unsupported ASTRA pack manifest formatVersion \(formatVersion)."
            )
        }

        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decode(String.self, forKey: .version)
        coreAPIVersion = try container.decode(String.self, forKey: .coreAPIVersion)
        description = try container.decode(String.self, forKey: .description)
        capabilityPackageIDs = try container.decodeIfPresent([String].self, forKey: .capabilityPackageIDs) ?? []
        shelfDefaults = try container.decodeIfPresent([AstraPackShelfDefault].self, forKey: .shelfDefaults) ?? []
        appTemplates = try container.decodeIfPresent([AstraPackAppTemplate].self, forKey: .appTemplates) ?? []
        policyRestrictions = try container.decodeIfPresent(
            [AstraPackPolicyRestriction].self,
            forKey: .policyRestrictions
        ) ?? []
        vocabulary = try container.decodeIfPresent([String: String].self, forKey: .vocabulary) ?? [:]
        compositionPriority = try container.decodeIfPresent(Int.self, forKey: .compositionPriority)
        branding = try container.decodeIfPresent(AstraPackBranding.self, forKey: .branding)
    }
}

public struct AstraPackShelfDefault: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var kind: String
    public var capabilityPackageIDs: [String]

    public init(
        id: String,
        title: String,
        kind: String,
        capabilityPackageIDs: [String] = []
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.capabilityPackageIDs = capabilityPackageIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        kind = try container.decode(String.self, forKey: .kind)
        capabilityPackageIDs = try container.decodeIfPresent([String].self, forKey: .capabilityPackageIDs) ?? []
    }
}

public struct AstraPackAppTemplate: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var contributionKind: String
    public var templateID: String
    public var capabilityPackageIDs: [String]

    public init(
        id: String,
        name: String,
        contributionKind: String,
        templateID: String,
        capabilityPackageIDs: [String] = []
    ) {
        self.id = id
        self.name = name
        self.contributionKind = contributionKind
        self.templateID = templateID
        self.capabilityPackageIDs = capabilityPackageIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        contributionKind = try container.decode(String.self, forKey: .contributionKind)
        templateID = try container.decode(String.self, forKey: .templateID)
        capabilityPackageIDs = try container.decodeIfPresent([String].self, forKey: .capabilityPackageIDs) ?? []
    }
}

public struct AstraPackPolicyRestriction: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var contributionKind: String
    public var action: String
    public var effect: String
    public var targetID: String?
    public var targetTag: String?
    public var targetMCPServerID: String?
    public var targetMCPToolName: String?
    public var message: String

    public init(
        id: String,
        contributionKind: String,
        action: String,
        effect: String,
        targetID: String? = nil,
        targetTag: String? = nil,
        targetMCPServerID: String? = nil,
        targetMCPToolName: String? = nil,
        message: String = ""
    ) {
        self.id = id
        self.contributionKind = contributionKind
        self.action = action
        self.effect = effect
        self.targetID = targetID
        self.targetTag = targetTag
        self.targetMCPServerID = targetMCPServerID
        self.targetMCPToolName = targetMCPToolName
        self.message = message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        contributionKind = try container.decode(String.self, forKey: .contributionKind)
        action = try container.decode(String.self, forKey: .action)
        effect = try container.decode(String.self, forKey: .effect)
        targetID = try container.decodeIfPresent(String.self, forKey: .targetID)
        targetTag = try container.decodeIfPresent(String.self, forKey: .targetTag)
        targetMCPServerID = try container.decodeIfPresent(String.self, forKey: .targetMCPServerID)
        targetMCPToolName = try container.decodeIfPresent(String.self, forKey: .targetMCPToolName)
        message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
    }
}

public struct AstraPackBranding: Codable, Equatable, Sendable {
    public var accentColor: String
    public var iconSystemName: String
    public var displayName: String

    public init(
        accentColor: String,
        iconSystemName: String,
        displayName: String
    ) {
        self.accentColor = accentColor
        self.iconSystemName = iconSystemName
        self.displayName = displayName
    }
}

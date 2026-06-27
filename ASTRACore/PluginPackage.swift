import Foundation

public struct CapabilitySourceMetadata: Codable, Sendable, Equatable {
    public var id: String
    public var displayName: String
    public var kind: String
    public var url: URL?
    public var trustLevel: String
    public var lastRefreshedAt: Date?

    public init(
        id: String,
        displayName: String,
        kind: String,
        url: URL? = nil,
        trustLevel: String,
        lastRefreshedAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.url = url
        self.trustLevel = trustLevel
        self.lastRefreshedAt = lastRefreshedAt
    }

    public static func builtIn() -> CapabilitySourceMetadata {
        CapabilitySourceMetadata(
            id: "built-in",
            displayName: "Built-in Capabilities",
            kind: "built-in",
            trustLevel: "built-in"
        )
    }

    public static func builtIn(url: URL?) -> CapabilitySourceMetadata {
        CapabilitySourceMetadata(
            id: "built-in",
            displayName: "Built-in Capabilities",
            kind: "built-in",
            url: url,
            trustLevel: "built-in"
        )
    }

    public static func localLibrary() -> CapabilitySourceMetadata {
        CapabilitySourceMetadata(
            id: "local",
            displayName: "Local Capability Library",
            kind: "local",
            trustLevel: "local"
        )
    }

    public static func localLibrary(url: URL?) -> CapabilitySourceMetadata {
        CapabilitySourceMetadata(
            id: "local",
            displayName: "Local Capability Library",
            kind: "local",
            url: url,
            trustLevel: "local"
        )
    }

    public static func remoteApproved(
        id: String,
        displayName: String,
        url: URL?,
        lastRefreshedAt: Date? = nil
    ) -> CapabilitySourceMetadata {
        CapabilitySourceMetadata(
            id: id,
            displayName: displayName,
            kind: "remote",
            url: url,
            trustLevel: "remote-approved",
            lastRefreshedAt: lastRefreshedAt
        )
    }
}

public enum CapabilityApprovalStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case draft
    case approved
    case deprecated
    case blocked
}

public enum CapabilityRiskLevel: String, Codable, Sendable, Equatable, CaseIterable, Comparable {
    case low
    case medium
    case high
    case restricted

    public static func < (lhs: CapabilityRiskLevel, rhs: CapabilityRiskLevel) -> Bool {
        order(lhs) < order(rhs)
    }

    private static func order(_ value: CapabilityRiskLevel) -> Int {
        switch value {
        case .low: 0
        case .medium: 1
        case .high: 2
        case .restricted: 3
        }
    }
}

public enum CapabilityVisibility: String, Codable, Sendable, Equatable, CaseIterable {
    case everyone
    case roleScoped
    case workspaceScoped
    case adminOnly
    case hidden
}

public enum CapabilityDataAccessKind: String, Codable, Sendable, Equatable, CaseIterable {
    case workspaceFiles
    case appSupport
    case connectorCredentials
    case keychainReference
    case network
    case externalService
    case authenticatedBrowserContent
    case email
    case clinicalData
    case logs
}

public enum CapabilityExternalEffectKind: String, Codable, Sendable, Equatable, CaseIterable {
    case readOnly
    case localFileWrite
    case externalAPIWrite
    case browserNavigation
    case browserEdit
    case messageSend
    case ticketMutation
    case deploy
    case delete
}

public struct CapabilityGovernance: Codable, Sendable, Equatable {
    public var approvalStatus: CapabilityApprovalStatus
    public var riskLevel: CapabilityRiskLevel
    public var visibility: CapabilityVisibility
    public var allowedRoles: [String]
    public var allowedWorkspaceTags: [String]
    public var requiresAdminApproval: Bool
    public var requiresExplicitUserConsent: Bool
    public var dataAccess: [CapabilityDataAccessKind]
    public var externalEffects: [CapabilityExternalEffectKind]
    public var approvedBy: String?
    public var approvedAt: Date?
    public var reviewTicketURL: URL?
    public var policyNotes: String

    public init(
        approvalStatus: CapabilityApprovalStatus = .draft,
        riskLevel: CapabilityRiskLevel = .medium,
        visibility: CapabilityVisibility = .adminOnly,
        allowedRoles: [String] = [],
        allowedWorkspaceTags: [String] = [],
        requiresAdminApproval: Bool = true,
        requiresExplicitUserConsent: Bool = true,
        dataAccess: [CapabilityDataAccessKind] = [],
        externalEffects: [CapabilityExternalEffectKind] = [],
        approvedBy: String? = nil,
        approvedAt: Date? = nil,
        reviewTicketURL: URL? = nil,
        policyNotes: String = ""
    ) {
        self.approvalStatus = approvalStatus
        self.riskLevel = riskLevel
        self.visibility = visibility
        self.allowedRoles = allowedRoles
        self.allowedWorkspaceTags = allowedWorkspaceTags
        self.requiresAdminApproval = requiresAdminApproval
        self.requiresExplicitUserConsent = requiresExplicitUserConsent
        self.dataAccess = dataAccess
        self.externalEffects = externalEffects
        self.approvedBy = approvedBy
        self.approvedAt = approvedAt
        self.reviewTicketURL = reviewTicketURL
        self.policyNotes = policyNotes
    }

    public static func builtInApproved(
        riskLevel: CapabilityRiskLevel = .medium,
        dataAccess: [CapabilityDataAccessKind] = [],
        externalEffects: [CapabilityExternalEffectKind] = [.readOnly],
        allowedRoles: [String] = [],
        allowedWorkspaceTags: [String] = [],
        visibility: CapabilityVisibility = .everyone,
        policyNotes: String = ""
    ) -> CapabilityGovernance {
        CapabilityGovernance(
            approvalStatus: .approved,
            riskLevel: riskLevel,
            visibility: visibility,
            allowedRoles: allowedRoles,
            allowedWorkspaceTags: allowedWorkspaceTags,
            requiresAdminApproval: false,
            requiresExplicitUserConsent: false,
            dataAccess: dataAccess,
            externalEffects: externalEffects,
            approvedBy: "ASTRA",
            reviewTicketURL: nil,
            policyNotes: policyNotes
        )
    }

    public static func localDraft() -> CapabilityGovernance {
        CapabilityGovernance(
            approvalStatus: .draft,
            riskLevel: .medium,
            visibility: .adminOnly,
            allowedRoles: [],
            allowedWorkspaceTags: [],
            requiresAdminApproval: true,
            requiresExplicitUserConsent: true,
            dataAccess: [],
            externalEffects: [],
            approvedBy: nil,
            approvedAt: nil,
            reviewTicketURL: nil,
            policyNotes: "Local capability packages require review before broad workspace use."
        )
    }

    public static func defaultGovernance(for sourceMetadata: CapabilitySourceMetadata?) -> CapabilityGovernance {
        switch sourceMetadata?.kind {
        case "built-in":
            return .builtInApproved()
        case "remote":
            return sourceMetadata?.trustLevel == "remote-approved" ? .builtInApproved() : .localDraft()
        default:
            return .localDraft()
        }
    }
}

public struct CapabilityIconDescriptor: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, Equatable {
        case systemSymbol
        case brand
        case asset
    }

    public var kind: Kind
    public var value: String
    public var fallbackSystemName: String
    public var monochromePreferred: Bool

    public init(
        kind: Kind,
        value: String,
        fallbackSystemName: String,
        monochromePreferred: Bool = true
    ) {
        self.kind = kind
        self.value = value
        self.fallbackSystemName = fallbackSystemName
        self.monochromePreferred = monochromePreferred
    }

    public static func systemSymbol(
        _ name: String,
        fallbackSystemName: String? = nil
    ) -> CapabilityIconDescriptor {
        CapabilityIconDescriptor(
            kind: .systemSymbol,
            value: name,
            fallbackSystemName: fallbackSystemName ?? name
        )
    }

    public static func brand(
        _ id: String,
        fallbackSystemName: String
    ) -> CapabilityIconDescriptor {
        CapabilityIconDescriptor(
            kind: .brand,
            value: id,
            fallbackSystemName: fallbackSystemName
        )
    }

    public static func asset(
        _ relativePath: String,
        fallbackSystemName: String
    ) -> CapabilityIconDescriptor {
        CapabilityIconDescriptor(
            kind: .asset,
            value: relativePath,
            fallbackSystemName: fallbackSystemName
        )
    }
}

public struct PluginPackage: Codable, Identifiable {
    public var formatVersion: Int
    public var id: String
    public var name: String
    public var icon: String
    public var iconDescriptor: CapabilityIconDescriptor
    public var description: String
    public var author: String
    public var category: String
    public var tags: [String]
    public var version: String
    public var setupGuide: String
    public var skills: [PluginSkill]
    public var connectors: [PluginConnector]
    public var localTools: [PluginLocalTool]
    public var mcpServers: [PluginMCPServer]
    public var templates: [PluginTemplate]
    /// Site-specific browser automation adapters this capability enables.
    /// Keep generic browser controls outside this list; these IDs are for
    /// web-app behaviors that are not portable across arbitrary websites.
    public var browserAdapters: [String]
    public var minAppVersion: String?
    public var requires: [String]?
    public var conflicts: [String]?
    public var sourceMetadata: CapabilitySourceMetadata?
    public var governance: CapabilityGovernance
    /// External CLI tools this package needs in order to actually work.
    /// The catalog renders these as preflight badges so users see
    /// "gcloud required ✓ found" before they install.
    ///
    /// Default `[]` for zero-config packages — absence of prerequisites
    /// means "no runtime dependencies beyond the app itself."
    public var prerequisites: [CLIPrerequisite]

    public init(
        formatVersion: Int = 2,
        id: String,
        name: String,
        icon: String,
        iconDescriptor: CapabilityIconDescriptor? = nil,
        description: String,
        author: String,
        category: String,
        tags: [String],
        version: String,
        setupGuide: String = "",
        skills: [PluginSkill],
        connectors: [PluginConnector],
        localTools: [PluginLocalTool],
        mcpServers: [PluginMCPServer] = [],
        templates: [PluginTemplate],
        browserAdapters: [String] = [],
        prerequisites: [CLIPrerequisite] = [],
        sourceMetadata: CapabilitySourceMetadata? = nil,
        governance: CapabilityGovernance? = nil
    ) {
        self.formatVersion = formatVersion
        self.id = id
        self.name = name
        self.icon = icon
        self.iconDescriptor = iconDescriptor ?? .systemSymbol(icon)
        self.description = description
        self.author = author
        self.category = category
        self.tags = tags
        self.version = version
        self.setupGuide = setupGuide
        self.skills = skills
        self.connectors = connectors
        self.localTools = localTools
        self.mcpServers = mcpServers
        self.templates = templates
        self.browserAdapters = browserAdapters
        self.prerequisites = prerequisites
        self.sourceMetadata = sourceMetadata
        self.governance = governance ?? CapabilityGovernance.defaultGovernance(for: sourceMetadata)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        icon = try c.decode(String.self, forKey: .icon)
        iconDescriptor = try c.decodeIfPresent(CapabilityIconDescriptor.self, forKey: .iconDescriptor)
            ?? .systemSymbol(icon)
        description = try c.decode(String.self, forKey: .description)
        author = try c.decode(String.self, forKey: .author)
        category = try c.decode(String.self, forKey: .category)
        tags = try c.decode([String].self, forKey: .tags)
        version = try c.decode(String.self, forKey: .version)
        setupGuide = try c.decodeIfPresent(String.self, forKey: .setupGuide) ?? ""
        skills = try c.decode([PluginSkill].self, forKey: .skills)
        connectors = try c.decode([PluginConnector].self, forKey: .connectors)
        localTools = try c.decode([PluginLocalTool].self, forKey: .localTools)
        mcpServers = try c.decodeIfPresent([PluginMCPServer].self, forKey: .mcpServers) ?? []
        templates = try c.decode([PluginTemplate].self, forKey: .templates)
        browserAdapters = try c.decodeIfPresent([String].self, forKey: .browserAdapters) ?? []
        minAppVersion = try c.decodeIfPresent(String.self, forKey: .minAppVersion)
        requires = try c.decodeIfPresent([String].self, forKey: .requires)
        conflicts = try c.decodeIfPresent([String].self, forKey: .conflicts)
        sourceMetadata = try c.decodeIfPresent(CapabilitySourceMetadata.self, forKey: .sourceMetadata)
        governance = try c.decodeIfPresent(CapabilityGovernance.self, forKey: .governance)
            ?? CapabilityGovernance.defaultGovernance(for: sourceMetadata)
        // Legacy fixtures pre-date `prerequisites`. Default to empty so
        // every pre-existing catalog JSON still decodes cleanly. Older
        // fixtures may also carry retired `signature`/`isTrusted` keys;
        // keyed decoding ignores them.
        prerequisites = try c.decodeIfPresent([CLIPrerequisite].self, forKey: .prerequisites) ?? []
    }

    public var requiresSetup: Bool {
        connectors.contains { !$0.credentialHints.isEmpty || !$0.configHints.isEmpty }
    }

    public var contentSummary: String {
        contentParts.joined(separator: ", ")
    }

    public enum InstallBlocker: Equatable, Sendable {
        case appTooOld(required: String, current: String)
        case missingDependency(String)
        case conflictsWith(String)
    }

    public func installBlockers(
        appVersion: SemanticVersion,
        installedPluginIDs: Set<String>
    ) -> [InstallBlocker] {
        var blockers: [InstallBlocker] = []
        if let minStr = minAppVersion, let minVer = SemanticVersion(string: minStr) {
            if appVersion < minVer {
                blockers.append(.appTooOld(required: minStr, current: appVersion.description))
            }
        }
        for dep in requires ?? [] {
            if !installedPluginIDs.contains(dep) {
                blockers.append(.missingDependency(dep))
            }
        }
        for conflict in conflicts ?? [] {
            if installedPluginIDs.contains(conflict) {
                blockers.append(.conflictsWith(conflict))
            }
        }
        return blockers
    }

    public var contentParts: [String] {
        var parts: [String] = []
        if !skills.isEmpty { parts.append("\(skills.count) skill\(skills.count == 1 ? "" : "s")") }
        if !connectors.isEmpty { parts.append("\(connectors.count) connector\(connectors.count == 1 ? "" : "s")") }
        if !localTools.isEmpty { parts.append("\(localTools.count) tool\(localTools.count == 1 ? "" : "s")") }
        if !mcpServers.isEmpty { parts.append("\(mcpServers.count) MCP server\(mcpServers.count == 1 ? "" : "s")") }
        if !templates.isEmpty { parts.append("\(templates.count) template\(templates.count == 1 ? "" : "s")") }
        if !browserAdapters.isEmpty { parts.append("\(browserAdapters.count) browser adapter\(browserAdapters.count == 1 ? "" : "s")") }
        return parts
    }
}

public struct PluginSkill: Codable {
    public var name: String
    public var icon: String
    public var description: String
    public var allowedTools: [String]
    public var disallowedTools: [String]
    public var customTools: [String]
    public var behaviorInstructions: String
    public var environmentKeys: [String]
    public var environmentValues: [String]

    public init(name: String, icon: String, description: String, allowedTools: [String],
                disallowedTools: [String], customTools: [String], behaviorInstructions: String,
                environmentKeys: [String], environmentValues: [String]) {
        self.name = name
        self.icon = icon
        self.description = description
        self.allowedTools = allowedTools
        self.disallowedTools = disallowedTools
        self.customTools = customTools
        self.behaviorInstructions = behaviorInstructions
        self.environmentKeys = environmentKeys
        self.environmentValues = environmentValues
    }
}

public struct PluginConnector: Codable {
    public var name: String
    public var serviceType: String
    public var icon: String
    public var description: String
    public var baseURL: String
    public var authMethod: String
    public var credentialHints: [CredentialHint]
    public var configHints: [ConfigHint]
    public var notes: String

    public struct CredentialHint: Codable {
        public var key: String
        public var hint: String

        public init(key: String, hint: String) {
            self.key = key
            self.hint = hint
        }
    }

    public struct ConfigHint: Codable {
        public var key: String
        public var hint: String
        public var isList: Bool

        public init(key: String, hint: String, isList: Bool) {
            self.key = key
            self.hint = hint
            self.isList = isList
        }
    }

    public init(name: String, serviceType: String, icon: String, description: String,
                baseURL: String, authMethod: String, credentialHints: [CredentialHint],
                configHints: [ConfigHint], notes: String) {
        self.name = name
        self.serviceType = serviceType
        self.icon = icon
        self.description = description
        self.baseURL = baseURL
        self.authMethod = authMethod
        self.credentialHints = credentialHints
        self.configHints = configHints
        self.notes = notes
    }
}

public struct PluginLocalTool: Codable {
    public var name: String
    public var description: String
    public var icon: String
    public var toolType: String
    public var command: String
    public var arguments: String

    public init(name: String, description: String, icon: String, toolType: String,
                command: String, arguments: String) {
        self.name = name
        self.description = description
        self.icon = icon
        self.toolType = toolType
        self.command = command
        self.arguments = arguments
    }
}

public struct PluginMCPInstallSource: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, Equatable, CaseIterable {
        case npm
        case pypi
        case nuget
        case oci
        case dockerImage
        case mcpb
        case remoteHTTP
        case localBinary
        case unknown
    }

    public enum InstallMode: String, Codable, Sendable, Equatable, CaseIterable {
        case npx
        case uvx
        case pipx
        case dotnetTool
        case dockerGateway
        case dockerRun
        case globalBinary
        case localBinary
        case remote
        case manual
    }

    public var kind: Kind
    public var identifier: String
    public var version: String?
    public var digest: String?
    public var installMode: InstallMode
    public var registryURL: URL?
    public var documentationURL: URL?
    public var packageManagerArguments: [String]
    public var riskNotes: [String]

    public init(
        kind: Kind,
        identifier: String,
        version: String? = nil,
        digest: String? = nil,
        installMode: InstallMode,
        registryURL: URL? = nil,
        documentationURL: URL? = nil,
        packageManagerArguments: [String] = [],
        riskNotes: [String] = []
    ) {
        self.kind = kind
        self.identifier = identifier
        self.version = version
        self.digest = digest
        self.installMode = installMode
        self.registryURL = registryURL
        self.documentationURL = documentationURL
        self.packageManagerArguments = packageManagerArguments
        self.riskNotes = riskNotes
    }
}

public struct PluginMCPServer: Codable, Equatable, Sendable, Identifiable {
    public enum Transport: String, Codable, Sendable, Equatable, CaseIterable {
        case stdio
        case http
        case sse
    }

    public enum TrustLevel: String, Codable, Sendable, Equatable, CaseIterable {
        case low
        case medium
        case high
        case restricted
    }

    public var id: String
    public var displayName: String
    public var transport: Transport
    public var command: String?
    public var arguments: [String]
    public var url: URL?
    public var environmentKeys: [String]
    public var connectorBindings: [String]
    public var allowedTools: [String]
    public var excludedTools: [String]
    public var resourcesEnabled: Bool
    public var promptsEnabled: Bool
    public var trustLevel: TrustLevel
    public var installSource: PluginMCPInstallSource?

    public init(
        id: String,
        displayName: String,
        transport: Transport,
        command: String? = nil,
        arguments: [String] = [],
        url: URL? = nil,
        environmentKeys: [String] = [],
        connectorBindings: [String] = [],
        allowedTools: [String] = [],
        excludedTools: [String] = [],
        resourcesEnabled: Bool = false,
        promptsEnabled: Bool = false,
        trustLevel: TrustLevel = .medium,
        installSource: PluginMCPInstallSource? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.transport = transport
        self.command = command
        self.arguments = arguments
        self.url = url
        self.environmentKeys = environmentKeys
        self.connectorBindings = connectorBindings
        self.allowedTools = allowedTools
        self.excludedTools = excludedTools
        self.resourcesEnabled = resourcesEnabled
        self.promptsEnabled = promptsEnabled
        self.trustLevel = trustLevel
        self.installSource = installSource
    }
}

public struct PluginTemplate: Codable {
    public var name: String
    public var icon: String
    public var description: String
    public var mainGoal: String
    public var beforeGoal: String
    public var afterGoal: String
    public var mainBudget: Int
    public var beforeBudget: Int
    public var afterBudget: Int
    public var variablesJSON: String
    public var passContextToMain: Bool
    public var passContextToAfter: Bool

    public init(name: String, icon: String, description: String, mainGoal: String,
                beforeGoal: String, afterGoal: String, mainBudget: Int, beforeBudget: Int,
                afterBudget: Int, variablesJSON: String, passContextToMain: Bool,
                passContextToAfter: Bool) {
        self.name = name
        self.icon = icon
        self.description = description
        self.mainGoal = mainGoal
        self.beforeGoal = beforeGoal
        self.afterGoal = afterGoal
        self.mainBudget = mainBudget
        self.beforeBudget = beforeBudget
        self.afterBudget = afterBudget
        self.variablesJSON = variablesJSON
        self.passContextToMain = passContextToMain
        self.passContextToAfter = passContextToAfter
    }
}

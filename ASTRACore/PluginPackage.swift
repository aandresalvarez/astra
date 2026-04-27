import Foundation

public struct PluginPackage: Codable, Identifiable {
    public var formatVersion: Int
    public var id: String
    public var name: String
    public var icon: String
    public var description: String
    public var author: String
    public var category: String
    public var tags: [String]
    public var version: String
    public var setupGuide: String
    public var skills: [PluginSkill]
    public var connectors: [PluginConnector]
    public var localTools: [PluginLocalTool]
    public var templates: [PluginTemplate]
    public var minAppVersion: String?
    public var requires: [String]?
    public var conflicts: [String]?
    public var signature: String?
    public var isTrusted: Bool = false
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
        description: String,
        author: String,
        category: String,
        tags: [String],
        version: String,
        setupGuide: String = "",
        skills: [PluginSkill],
        connectors: [PluginConnector],
        localTools: [PluginLocalTool],
        templates: [PluginTemplate],
        prerequisites: [CLIPrerequisite] = []
    ) {
        self.formatVersion = formatVersion
        self.id = id
        self.name = name
        self.icon = icon
        self.description = description
        self.author = author
        self.category = category
        self.tags = tags
        self.version = version
        self.setupGuide = setupGuide
        self.skills = skills
        self.connectors = connectors
        self.localTools = localTools
        self.templates = templates
        self.prerequisites = prerequisites
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        icon = try c.decode(String.self, forKey: .icon)
        description = try c.decode(String.self, forKey: .description)
        author = try c.decode(String.self, forKey: .author)
        category = try c.decode(String.self, forKey: .category)
        tags = try c.decode([String].self, forKey: .tags)
        version = try c.decode(String.self, forKey: .version)
        setupGuide = try c.decodeIfPresent(String.self, forKey: .setupGuide) ?? ""
        skills = try c.decode([PluginSkill].self, forKey: .skills)
        connectors = try c.decode([PluginConnector].self, forKey: .connectors)
        localTools = try c.decode([PluginLocalTool].self, forKey: .localTools)
        templates = try c.decode([PluginTemplate].self, forKey: .templates)
        minAppVersion = try c.decodeIfPresent(String.self, forKey: .minAppVersion)
        requires = try c.decodeIfPresent([String].self, forKey: .requires)
        conflicts = try c.decodeIfPresent([String].self, forKey: .conflicts)
        signature = try c.decodeIfPresent(String.self, forKey: .signature)
        // Legacy fixtures pre-date `prerequisites`. Default to empty so
        // every pre-existing catalog JSON still decodes cleanly.
        prerequisites = try c.decodeIfPresent([CLIPrerequisite].self, forKey: .prerequisites) ?? []
        isTrusted = false
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
        if !templates.isEmpty { parts.append("\(templates.count) template\(templates.count == 1 ? "" : "s")") }
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

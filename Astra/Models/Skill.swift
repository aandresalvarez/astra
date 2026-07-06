import Foundation
import SwiftData
import ASTRACore

@Model
final class Skill {
    var id: UUID
    var name: String
    var skillDescription: String
    var icon: String
    var allowedTools: [String]
    var disallowedTools: [String]
    var customTools: [String]
    var behaviorInstructions: String
    var environmentKeys: [String]
    // Non-secret values remain here. Secret values are migrated to Keychain and
    // their stored placeholders are kept blank for compatibility.
    var environmentValues: [String]
    var originPackageID: String?
    var originPackageVersion: String?
    var originComponentID: String?
    var originComponentKind: String?
    var originSourceKind: String?
    var createdAt: Date
    var updatedAt: Date

    var isGlobal: Bool = false
    var isBuiltIn: Bool = false

    static let builtInNames: Set<String> = [
        "Read-Only",
        "Safe Bash",
        "Test Runner",
        "Read-Only Explorer",
        "Safe Executor"
    ]

    var isSystemBuiltIn: Bool {
        isBuiltIn || Self.isBuiltInName(name)
    }

    static func isBuiltInName(_ name: String) -> Bool {
        builtInNames.contains(name.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var workspace: Workspace?

    @Relationship(inverse: \AgentTask.skills)
    var tasks: [AgentTask] = []

    // Three-layer architecture: skills reference connectors and local tools
    @Relationship(inverse: \Connector.skill)
    var connectors: [Connector] = []

    @Relationship(inverse: \LocalTool.skill)
    var localTools: [LocalTool] = []

    static let secretPatterns = ["KEY", "TOKEN", "SECRET", "PASSWORD", "CREDENTIAL", "AUTH"]

    init(
        name: String = "",
        icon: String = "puzzlepiece.extension",
        skillDescription: String = "",
        allowedTools: [String] = [],
        disallowedTools: [String] = [],
        customTools: [String] = [],
        behaviorInstructions: String = "",
        environmentVariables: [String: String] = [:]
    ) {
        self.id = UUID()
        self.name = name
        self.icon = icon
        self.skillDescription = skillDescription
        self.allowedTools = allowedTools
        self.disallowedTools = disallowedTools
        self.customTools = customTools
        self.behaviorInstructions = behaviorInstructions
        self.environmentKeys = Array(environmentVariables.keys)
        self.environmentValues = Array(environmentVariables.values)
        self.originPackageID = nil
        self.originPackageVersion = nil
        self.originComponentID = nil
        self.originComponentKind = nil
        self.originSourceKind = nil
        self.createdAt = Date()
        self.updatedAt = Date()
        self.migrateSecretsToKeychain()
    }

    /// Environment variables as a dictionary (stored as parallel arrays for SwiftData compatibility)
    var environmentVariables: [String: String] {
        get {
            var merged: [String: String] = [:]
            for (index, key) in environmentKeys.enumerated() {
                guard index < environmentValues.count else { continue }
                let value = valueForEnvironmentKey(at: index)
                if Self.isSecretEnvironmentKey(key) {
                    if !value.isEmpty {
                        merged[key] = value
                    }
                } else {
                    merged[key] = value
                }
            }
            return merged
        }
        set {
            let oldSecretKeys = environmentKeys.enumerated()
                .filter { Self.isSecretEnvironmentKey($0.element) }
                .map { $0.element }

            environmentKeys = []
            environmentValues = []

            for (key, value) in newValue {
                upsertEnvironmentEntry(key: key, value: value)
            }

            let newSecretKeys = Set(environmentKeys.filter(Self.isSecretEnvironmentKey))
            for key in oldSecretKeys where !newSecretKeys.contains(key) {
                let deleted = SkillSecretSeam.required.deleteSecret(key: key, skillID: id)
                ConnectorAuditLoggingSeam.required.audit(.skillSecretRemoved, category: "Keychain", fields: [
                    "skill_id": id.uuidString,
                    "result": deleted ? "removed" : "failed"
                ], level: deleted ? .info : .warning)
            }
        }
    }

    static func isSecretEnvironmentKey(_ key: String) -> Bool {
        let upper = key.uppercased()
        return secretPatterns.contains { upper.contains($0) }
    }

    var exportableEnvironmentValues: [String] {
        normalizedEnvironmentValues().enumerated().map { index, value in
            let key = environmentKeys[index]
            return Self.isSecretEnvironmentKey(key) ? "" : value
        }
    }

    func valueForEnvironmentKey(at index: Int) -> String {
        valueForEnvironmentKey(at: index, store: KeychainSecretStore())
    }

    func valueForEnvironmentKey(at index: Int, store: SecretStore) -> String {
        guard index < environmentKeys.count else { return "" }
        let key = environmentKeys[index]
        let storedValue = normalizedEnvironmentValue(at: index)
        guard Self.isSecretEnvironmentKey(key) else { return storedValue }
        return SkillSecretSeam.required.loadSecretValue(key: key, skillID: id, store: store) ?? storedValue
    }

    func upsertEnvironmentEntry(key rawKey: String, value: String) {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !key.isEmpty else { return }

        if let index = environmentKeys.firstIndex(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) {
            environmentKeys[index] = key
            setEnvironmentValue(value, at: index)
        } else {
            environmentKeys.append(key)
            environmentValues.append("")
            setEnvironmentValue(value, at: environmentKeys.count - 1)
        }
    }

    func setEnvironmentValue(_ value: String, at index: Int) {
        guard index < environmentKeys.count else { return }
        ensureEnvironmentValueCapacity()

        let key = environmentKeys[index]
        if Self.isSecretEnvironmentKey(key) {
            if !value.isEmpty {
                let saved = SkillSecretSeam.required.saveSecretValue(value, key: key, skillID: id, skillName: name)
                ConnectorAuditLoggingSeam.required.audit(.skillSecretAdded, category: "Keychain", fields: [
                    "skill_id": id.uuidString,
                    "result": saved ? "stored" : "failed"
                ], level: saved ? .info : .warning)
                environmentValues[index] = saved ? "" : value
            } else {
                environmentValues[index] = ""
            }
        } else {
            environmentValues[index] = value
        }
        updatedAt = Date()
    }

    func removeEnvironmentEntry(at index: Int) {
        guard index < environmentKeys.count else { return }
        let key = environmentKeys[index]
        if Self.isSecretEnvironmentKey(key) {
            let deleted = SkillSecretSeam.required.deleteSecret(key: key, skillID: id)
            ConnectorAuditLoggingSeam.required.audit(.skillSecretRemoved, category: "Keychain", fields: [
                "skill_id": id.uuidString,
                "result": deleted ? "removed" : "failed"
            ], level: deleted ? .info : .warning)
        }
        environmentKeys.remove(at: index)
        if index < environmentValues.count {
            environmentValues.remove(at: index)
        }
        updatedAt = Date()
    }

    func migrateSecretsToKeychain() {
        ensureEnvironmentValueCapacity()

        for (index, key) in environmentKeys.enumerated() where Self.isSecretEnvironmentKey(key) {
            let legacyValue = environmentValues[index]
            guard !legacyValue.isEmpty else { continue }

            if SkillSecretSeam.required.secretExists(key: key, skillID: id) {
                environmentValues[index] = ""
                continue
            }

            if SkillSecretSeam.required.saveSecretValue(legacyValue, key: key, skillID: id, skillName: name) {
                environmentValues[index] = ""
            }
        }
    }

    func cleanupKeychain() {
        SkillSecretSeam.required.deleteAllSecrets(skillID: id)
        ConnectorAuditLoggingSeam.required.audit(.skillDeleted, category: "Keychain", fields: [
            "skill_id": id.uuidString
        ])
    }

    func normalizedEnvironmentValue(at index: Int) -> String {
        guard index < environmentValues.count else { return "" }
        return environmentValues[index]
    }

    private func normalizedEnvironmentValues() -> [String] {
        if environmentValues.count >= environmentKeys.count {
            return Array(environmentValues.prefix(environmentKeys.count))
        }
        return environmentValues + Array(repeating: "", count: environmentKeys.count - environmentValues.count)
    }

    func ensureEnvironmentValueCapacity() {
        if environmentValues.count < environmentKeys.count {
            environmentValues.append(contentsOf: Array(repeating: "", count: environmentKeys.count - environmentValues.count))
        } else if environmentValues.count > environmentKeys.count {
            environmentValues = Array(environmentValues.prefix(environmentKeys.count))
        }
    }

    /// All environment variables: legacy env vars + connector env vars merged
    var resolvedAllEnvironmentVariables: [String: String] {
        var merged = environmentVariables
        let facts = connectors.map { connector in
            ConnectorEnvironmentFacts(
                id: connector.id,
                name: connector.name,
                serviceType: connector.serviceType,
                baseURL: connector.baseURL,
                authMethod: connector.authMethod,
                credentialKeys: connector.credentialKeys,
                configKeys: connector.configKeys,
                configValues: connector.configValues,
                originPackageID: connector.originPackageID,
                originComponentID: connector.originComponentID
            )
        }
        for (key, value) in ConnectorEnvironmentProjectionSeam.required.environmentVariables(for: facts) {
            merged[key] = value
        }
        return merged
    }

    /// System tools always included — agent can't function without these
    static let systemTools: Set<String> = ["Read", "Glob", "Grep"]

    /// All logical tools the agent can use, including system tools, custom tools and named local tools.
    var allAllowedTools: [String] {
        var tools = allowedTools + customTools
        for tool in localTools where !tool.command.isEmpty {
            tools.append(tool.command)
        }
        // If we have CLI/script local tools, ensure Bash is allowed so agent can run them
        let hasCLITools = localTools.contains { $0.toolType != "mcp" && !$0.command.isEmpty }
        if hasCLITools && !tools.contains("Bash") {
            tools.append("Bash")
        }
        return Array(Set(tools)).sorted()
    }

    /// Summary of attached connectors for display
    var connectorSummary: String {
        connectors.isEmpty ? "" : connectors.map(\.name).joined(separator: ", ")
    }

    /// Summary of attached local tools for display
    var localToolSummary: String {
        localTools.isEmpty ? "" : localTools.map(\.name).joined(separator: ", ")
    }

    static let knownTools = [
        "Read", "Write", "Edit", "Bash", "Glob", "Grep",
        "WebFetch", "WebSearch", "Agent", "NotebookEdit", "TodoWrite"
    ]

    static let defaultAllowed = [
        "Write", "Edit", "Read", "Bash", "Glob", "Grep"
    ]

    static let toolDescriptions: [String: String] = [
        "Read": "Read file contents",
        "Write": "Create new files",
        "Edit": "Modify existing files",
        "Bash": "Run shell commands",
        "Glob": "Search for files by name",
        "Grep": "Search file contents",
        "WebFetch": "Fetch web page content",
        "WebSearch": "Search the web",
        "Agent": "Spawn sub-agents",
        "NotebookEdit": "Edit Jupyter notebooks",
        "TodoWrite": "Manage todo lists"
    ]
}

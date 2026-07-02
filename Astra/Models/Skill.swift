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
                SkillSecretPersistence.deleteRemovedSecret(key: key, from: self)
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
        SkillSecretPersistence.valueForEnvironmentKey(on: self, at: index, store: store)
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
        SkillSecretPersistence.setEnvironmentValue(value, on: self, at: index)
    }

    func removeEnvironmentEntry(at index: Int) {
        SkillSecretPersistence.removeEnvironmentEntry(on: self, at: index)
    }

    func migrateSecretsToKeychain() {
        SkillSecretPersistence.migrateSecretsToKeychain(self)
    }

    func cleanupKeychain() {
        SkillSecretPersistence.cleanupKeychain(for: self)
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
        for (key, value) in ConnectorRuntimeProjection(connectors: connectors).environmentVariables() {
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

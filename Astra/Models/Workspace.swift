import Foundation
import SwiftData

@Model
public final class Workspace: Identifiable {
    public var id: UUID
    public var name: String
    public var primaryPath: String
    public var additionalPaths: [String]
    public var icon: String
    public var instructions: String
    public var lastUsedSkillNames: [String] = []
    public var enabledGlobalSkillIDs: [String] = []
    public var enabledGlobalConnectorIDs: [String] = []
    public var enabledGlobalToolIDs: [String] = []
    /// V19 enablement, read only by `PluginActivationMigration` and cleared
    /// once it has moved onto `pluginActivations`.
    @Attribute(originalName: "enabledCapabilityIDs")
    public var legacyEnabledCapabilityIDs: [String] = []
    public var enabledPackIDs: [String] = []
    public var shelfVisibilityOverrideIDs: [String] = []
    public var shelfVisibilityOverrideValues: [Bool] = []
    public var memories: [String] = []
    @Attribute(originalName: "installedPluginIDs")
    public var legacyInstalledPluginIDs: [String] = []
    @Attribute(originalName: "installedPluginVersions")
    public var legacyInstalledPluginVersions: [String] = []
    public var isStarred: Bool = false
    /// The code location new chats default to. `nil` means the primary path; a
    /// non-nil value is the absolute path of the active configured repository or
    /// a git worktree. Existing threads are never moved by this value: they keep
    /// their own `executionRootPath` snapshot.
    public var activeWorkingPath: String?
    /// JSON-encoded default execution environment for new runs. Nil means host.
    /// Existing threads keep their own task/run snapshot once execution starts.
    public var activeExecutionEnvironmentJSON: String?
    public var createdAt: Date
    public var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \AgentTask.workspace)
    public var tasks: [AgentTask] = []

    @Relationship(deleteRule: .cascade, inverse: \Skill.workspace)
    public var skills: [Skill] = []

    @Relationship(deleteRule: .cascade, inverse: \Connector.workspace)
    public var connectors: [Connector] = []

    @Relationship(deleteRule: .cascade, inverse: \LocalTool.workspace)
    public var localTools: [LocalTool] = []

    @Relationship(deleteRule: .cascade, inverse: \TaskTemplate.workspace)
    public var templates: [TaskTemplate] = []

    @Relationship(deleteRule: .cascade, inverse: \TaskSchedule.workspace)
    public var schedules: [TaskSchedule] = []

    /// Installed plugins and their per-workspace state, owned by
    /// `WorkspaceCapabilityActivation`.
    @Relationship(deleteRule: .cascade, inverse: \PluginActivation.workspace)
    public var pluginActivations: [PluginActivation] = []

    public init(
        name: String,
        primaryPath: String,
        additionalPaths: [String] = [],
        icon: String = "folder.fill",
        instructions: String = ""
    ) {
        self.id = UUID()
        self.name = Self.displayName(name: name, primaryPath: primaryPath)
        self.primaryPath = primaryPath
        self.additionalPaths = additionalPaths
        self.icon = icon
        self.instructions = instructions
        self.lastUsedSkillNames = []
        self.enabledPackIDs = []
        self.shelfVisibilityOverrideIDs = []
        self.shelfVisibilityOverrideValues = []
        self.isStarred = false
        self.activeWorkingPath = nil
        self.activeExecutionEnvironmentJSON = nil
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    public var shelfVisibilityOverrides: [String: Bool] {
        get {
            var overrides: [String: Bool] = [:]
            for (index, shelfID) in shelfVisibilityOverrideIDs.enumerated() {
                let normalizedShelfID = shelfID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalizedShelfID.isEmpty, index < shelfVisibilityOverrideValues.count else { continue }
                overrides[normalizedShelfID] = shelfVisibilityOverrideValues[index]
            }
            return overrides
        }
        set {
            let normalizedOverrides = Self.normalizedShelfVisibilityOverrides(newValue)
            let orderedShelfIDs = normalizedOverrides.keys.sorted()
            shelfVisibilityOverrideIDs = orderedShelfIDs
            shelfVisibilityOverrideValues = orderedShelfIDs.map { normalizedOverrides[$0] ?? false }
        }
    }

    private static func normalizedShelfVisibilityOverrides(_ overrides: [String: Bool]) -> [String: Bool] {
        var normalized: [String: Bool] = [:]
        for rawShelfID in overrides.keys.sorted() {
            let shelfID = rawShelfID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !shelfID.isEmpty else { continue }
            normalized[shelfID] = overrides[rawShelfID] ?? false
        }
        return normalized
    }

    /// The directory new chats and the Repository panel currently operate in:
    /// the active repository/worktree when one is selected, otherwise primary.
    public var resolvedWorkingPath: String {
        if let active = activeWorkingPath,
           !active.isEmpty,
           FileManager.default.fileExists(atPath: active) {
            return active
        }
        return primaryPath
    }

    /// True when the workspace is focused on a non-primary code location.
    public var isUsingWorktree: Bool {
        guard let active = activeWorkingPath, !active.isEmpty else { return false }
        return active != primaryPath
    }

    /// Enabled plugin IDs, derived from `pluginActivations`.
    public var enabledCapabilityIDs: [String] {
        WorkspaceCapabilityActivation.state(of: self).capabilityIDs
    }

    /// Every plugin with an activation here, on or off, and its recorded
    /// version, paired by index.
    public var installedPluginIDs: [String] {
        WorkspaceCapabilityActivation.state(of: self).pluginIDs
    }

    public var installedPluginVersions: [String] {
        WorkspaceCapabilityActivation.state(of: self).pluginVersions
    }

    public func installedVersion(of pluginID: String) -> String? {
        WorkspaceCapabilityActivation.activation(for: pluginID, in: self)?.recordedVersion
    }

    public var installedPluginIDSet: Set<String> {
        Set(installedPluginIDs)
    }

    public var displayPath: String {
        URL(fileURLWithPath: primaryPath).lastPathComponent
    }

    public static func displayName(name: String, primaryPath: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let placeholderNames: Set<String> = ["", "untitled", "untitled workspace", "new workspace", "asdf", "asdfadsf"]
        if !placeholderNames.contains(lower) {
            return trimmed
        }

        let folderName = URL(fileURLWithPath: primaryPath).lastPathComponent
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return folderName.isEmpty ? "Workspace" : folderName.capitalized
    }

    public var totalCost: Double {
        tasks.reduce(0) { $0 + $1.costUSD }
    }

    public var totalTokens: Int {
        tasks.reduce(0) { $0 + $1.tokensUsed }
    }
}

import Foundation
import SwiftData

@Model
final class Workspace: Identifiable {
    var id: UUID
    var name: String
    var primaryPath: String
    var additionalPaths: [String]
    var icon: String
    var instructions: String
    var lastUsedSkillNames: [String] = []
    var enabledGlobalSkillIDs: [String] = []
    var enabledGlobalConnectorIDs: [String] = []
    var enabledGlobalToolIDs: [String] = []
    var enabledCapabilityIDs: [String] = []
    var memories: [String] = []
    var installedPluginIDs: [String] = []
    var installedPluginVersions: [String] = []
    var isStarred: Bool = false
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \AgentTask.workspace)
    var tasks: [AgentTask] = []

    @Relationship(deleteRule: .cascade, inverse: \Skill.workspace)
    var skills: [Skill] = []

    @Relationship(deleteRule: .cascade, inverse: \Connector.workspace)
    var connectors: [Connector] = []

    @Relationship(deleteRule: .cascade, inverse: \LocalTool.workspace)
    var localTools: [LocalTool] = []

    @Relationship(deleteRule: .cascade, inverse: \TaskTemplate.workspace)
    var templates: [TaskTemplate] = []

    @Relationship(deleteRule: .cascade, inverse: \TaskSchedule.workspace)
    var schedules: [TaskSchedule] = []

    init(
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
        self.isStarred = false
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    func installedVersion(of pluginID: String) -> String? {
        guard let idx = installedPluginIDs.firstIndex(of: pluginID),
              idx < installedPluginVersions.count else { return nil }
        return installedPluginVersions[idx]
    }

    func recordInstalledPlugin(id: String, version: String) {
        if let idx = installedPluginIDs.firstIndex(of: id) {
            if idx < installedPluginVersions.count {
                installedPluginVersions[idx] = version
            }
        } else {
            installedPluginIDs.append(id)
            installedPluginVersions.append(version)
        }
        updatedAt = Date()
    }

    var installedPluginIDSet: Set<String> {
        Set(installedPluginIDs)
    }

    var displayPath: String {
        URL(fileURLWithPath: primaryPath).lastPathComponent
    }

    static func displayName(name: String, primaryPath: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let placeholderNames: Set<String> = ["", "untitled", "untitled workspace", "new workspace"]
        if !placeholderNames.contains(lower) {
            return trimmed
        }

        let folderName = URL(fileURLWithPath: primaryPath).lastPathComponent
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return folderName.isEmpty ? "Workspace" : folderName.capitalized
    }

    var totalCost: Double {
        tasks.reduce(0) { $0 + $1.costUSD }
    }

    var totalTokens: Int {
        tasks.reduce(0) { $0 + $1.tokensUsed }
    }
}

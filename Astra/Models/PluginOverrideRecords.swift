import Foundation
import SwiftData

/// The authored rows a workspace's enabled activations name as component
/// overrides, frozen with a queued request (`TaskExecutionPolicySnapshotV1`)
/// so an override edited or deleted while the request waits does not change
/// what it runs with. Never a secret value: a secret setting's value stays in
/// the Keychain under the row's ID, and is captured blank.
public struct PluginOverrideRecords: Codable, Equatable, Sendable {
    public struct SkillRecord: Codable, Equatable, Sendable {
        public let id: UUID
        public let credentialNamespaceID: UUID?
        public let name: String
        public let icon: String
        public let skillDescription: String
        public let allowedTools: [String]
        public let disallowedTools: [String]
        public let customTools: [String]
        public let behaviorInstructions: String
        public let environmentKeys: [String]
        public let environmentValues: [String]
        public let isGlobal: Bool
        public let createdAt: Date
        public let updatedAt: Date
        /// The accounts and tools attached to the row that its workspace
        /// reaches through it, frozen with it: an attachment edited or
        /// deleted while the request waits does not change the run either.
        /// Absent from a request recorded before attachments were frozen.
        public let attachedConnectors: [PluginAccountRecord]?
        public let attachedTools: [ToolRecord]?

        /// `skill`'s contents, with the attachments `workspaceID` reaches:
        /// shared ones, and its own (never another workspace's).
        public init(_ skill: Skill, workspaceID: UUID) {
            id = skill.id
            credentialNamespaceID = skill.credentialNamespaceID
            name = skill.name
            icon = skill.icon
            skillDescription = skill.skillDescription
            allowedTools = skill.allowedTools
            disallowedTools = skill.disallowedTools
            customTools = skill.customTools
            behaviorInstructions = skill.behaviorInstructions
            environmentKeys = skill.environmentKeys
            environmentValues = skill.environmentKeys.enumerated().map { index, key in
                guard !Skill.isSecretEnvironmentKey(key), index < skill.environmentValues.count else { return "" }
                return skill.environmentValues[index]
            }
            isGlobal = skill.isGlobal
            createdAt = skill.createdAt
            updatedAt = skill.updatedAt
            attachedConnectors = skill.connectors
                .filter { !$0.isDeleted && ($0.isGlobal || $0.workspace?.id == workspaceID) }
                .map(PluginAccountRecord.init)
            attachedTools = skill.localTools
                .filter { !$0.isDeleted && ($0.isGlobal || $0.workspace == nil || $0.workspace?.id == workspaceID) }
                .map(ToolRecord.init)
        }

        /// Writes these contents onto `skill`, a launch copy (never a stored
        /// row). Environment is assigned directly: the init's parameter would
        /// move secret-looking values into the Keychain.
        public func apply(to skill: Skill) {
            skill.credentialNamespaceID = credentialNamespaceID
            skill.name = name
            skill.icon = icon
            skill.skillDescription = skillDescription
            skill.allowedTools = allowedTools
            skill.disallowedTools = disallowedTools
            skill.customTools = customTools
            skill.behaviorInstructions = behaviorInstructions
            skill.environmentKeys = environmentKeys
            skill.environmentValues = environmentValues
            skill.isGlobal = isGlobal
            skill.createdAt = createdAt
            skill.updatedAt = updatedAt
        }

        /// A never-inserted skill with these contents, for one deleted since.
        public func makeSkill() -> Skill {
            let skill = Skill(name: name)
            skill.id = id
            apply(to: skill)
            return skill
        }
    }

    public struct ToolRecord: Codable, Equatable, Sendable {
        public let id: UUID
        public let name: String
        public let toolDescription: String
        public let icon: String
        public let toolType: String
        public let command: String
        public let arguments: String
        public let isGlobal: Bool
        /// The skill the row was attached to, if any.
        public let skillID: UUID?
        public let createdAt: Date
        public let updatedAt: Date

        public init(_ tool: LocalTool) {
            id = tool.id
            name = tool.name
            toolDescription = tool.toolDescription
            icon = tool.icon
            toolType = tool.toolType
            command = tool.command
            arguments = tool.arguments
            isGlobal = tool.isGlobal
            skillID = tool.skill.flatMap { $0.isDeleted ? nil : $0.id }
            createdAt = tool.createdAt
            updatedAt = tool.updatedAt
        }

        /// Writes these contents onto `tool`, a launch copy (never a stored
        /// row). The caller wires its skill.
        public func apply(to tool: LocalTool) {
            tool.name = name
            tool.toolDescription = toolDescription
            tool.icon = icon
            tool.toolType = toolType
            tool.command = command
            tool.arguments = arguments
            tool.isGlobal = isGlobal
            tool.createdAt = createdAt
            tool.updatedAt = updatedAt
        }

        /// A never-inserted tool with these contents, for one deleted since.
        public func makeTool() -> LocalTool {
            let tool = LocalTool(name: name, toolDescription: toolDescription, icon: icon, toolType: toolType, command: command, arguments: arguments)
            tool.id = id
            apply(to: tool)
            return tool
        }
    }

    public let skills: [SkillRecord]
    public let localTools: [ToolRecord]

    /// The override rows `workspace`'s enabled activations name: the
    /// workspace's own (or, in a launch copy, its copies), else shared rows
    /// from its store.
    public init(workspace: Workspace) {
        let ids = WorkspaceCapabilityActivation.activations(of: workspace)
            .filter(\.isEnabled)
            .flatMap(\.overridingRowIDs)
            .compactMap(UUID.init(uuidString:))
        var seen = Set<UUID>()
        var skills: [SkillRecord] = []
        var tools: [ToolRecord] = []
        for id in ids where seen.insert(id).inserted {
            if let skill = workspace.skills.first(where: { $0.id == id && !$0.isDeleted }) ?? Self.fetch(Skill.self, id, near: workspace) {
                skills.append(SkillRecord(skill, workspaceID: workspace.id))
            } else if let tool = workspace.localTools.first(where: { $0.id == id && !$0.isDeleted })
                ?? Self.fetch(LocalTool.self, id, near: workspace) {
                tools.append(ToolRecord(tool))
            }
        }
        self.skills = skills
        self.localTools = tools
    }

    /// Every override row ID these records carry (not their attachments).
    public var rowIDs: Set<UUID> {
        Set(skills.map(\.id) + localTools.map(\.id))
    }

    private static func fetch(_: Skill.Type, _ id: UUID, near workspace: Workspace) -> Skill? {
        guard let context = workspace.modelContext else { return nil }
        var descriptor = FetchDescriptor<Skill>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first { !$0.isDeleted }
    }

    private static func fetch(_: LocalTool.Type, _ id: UUID, near workspace: Workspace) -> LocalTool? {
        guard let context = workspace.modelContext else { return nil }
        var descriptor = FetchDescriptor<LocalTool>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first { !$0.isDeleted }
    }
}

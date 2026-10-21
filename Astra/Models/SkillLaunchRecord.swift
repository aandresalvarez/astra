import Foundation
import SwiftData

/// Immutable authored skill settings and credential references, including
/// scoped attachments. Shared by independent selections and plugin overrides;
/// each owning request collection determines which role may reach a launch.
public struct SkillLaunchRecord: Codable, Equatable, Sendable {
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
    public let attachedTools: [PluginOverrideRecords.ToolRecord]?

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
            .map(PluginAccountRecord.forLaunch)
        attachedTools = skill.localTools
            .filter { !$0.isDeleted && ($0.isGlobal || $0.workspace == nil || $0.workspace?.id == workspaceID) }
            .map(PluginOverrideRecords.ToolRecord.init)
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
    /// Actual selections grant restoration authority: authored rows and rows
    /// still owned by explicit pending legacy enablement. Provenance alone
    /// grants nothing, and an activation's override is never independent.
    public static func captureAuthored(for task: AgentTask) -> [Self]? {
        guard let workspace = task.workspace else { return nil }
        let overrides = WorkspaceCapabilityActivation.overridingRowIDs(of: workspace)
        return task.skills.filter {
            !$0.isDeleted && !overrides.contains($0.id)
                && ($0.isGlobal || $0.workspace == nil || $0.workspace?.id == workspace.id)
                && ($0.originPackageID == nil
                    || WorkspaceCapabilityActivation.hasPendingLegacyEnablement($0.originPackageID, in: workspace)
                    || ($0.isGlobal && WorkspaceCapabilityActivation.hasSharedResource(.skill, id: $0.id, in: workspace)))
        }.map { Self($0, workspaceID: workspace.id) }
    }

}

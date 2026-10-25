import Foundation

/// Read-only attachment scope shared by runtime projection and workspace mirrors.
public enum SkillAttachmentVisibility {
    public static func connectors(of skill: Skill, in workspace: Workspace) -> [Connector] {
        let enabled = Set(WorkspaceCapabilityActivation.state(of: workspace).globalConnectorIDs)
        return skill.connectors.filter {
            !$0.isDeleted && ($0.isGlobal ? enabled.contains($0.id.uuidString) : $0.workspace?.id == workspace.id)
        }
    }

    public static func tools(of skill: Skill, in workspace: Workspace) -> [LocalTool] {
        skill.localTools.filter {
            !$0.isDeleted && ($0.isGlobal || $0.workspace == nil || $0.workspace?.id == workspace.id)
        }
    }
}

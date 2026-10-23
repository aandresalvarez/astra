import ASTRAModels

/// Resolve relationship faults before a reversible deletion. Otherwise
/// SwiftData can restore a lazy snapshot future as an array on rollback and
/// abort on the next save (including autosave). This does not change the graph;
/// SwiftData still owns the cascade, rollback, and persisted relationships.
@MainActor
public enum SwiftDataDeletionPreparation {
    public static func prepare(_ workspace: Workspace) {
        let tasks = workspace.tasks
        let connectors = workspace.connectors
        let tools = workspace.localTools
        // Surviving global skills also own inverse arrays modified by this
        // deletion, even though they are outside workspace.skills.
        let skills = workspace.skills + tasks.flatMap(\.skills)
            + connectors.compactMap(\.skill) + tools.compactMap(\.skill)
        for connector in connectors { _ = (connector.id, connector.workspace?.id, connector.skill?.id) }
        for tool in tools { _ = (tool.id, tool.workspace?.id, tool.skill?.id) }
        for template in workspace.templates { _ = (template.id, template.workspace?.id) }
        for schedule in workspace.schedules { _ = (schedule.id, schedule.workspace?.id) }
        // The owning workspace's array is already resolved. Prepare each
        // task's children once; inverse skill owners are handled below.
        for task in tasks { SwiftDataTaskRollbackPreparation.prepare(task) }
        var preparedSkills: Set<ObjectIdentifier> = []
        for skill in skills where preparedSkills.insert(ObjectIdentifier(skill)).inserted {
            _ = (skill.id, skill.workspace?.id)
            for task in skill.tasks { _ = task.id }
            for connector in skill.connectors { _ = connector.id }
            for tool in skill.localTools { _ = tool.id }
        }
    }

    public static func prepare(_ task: AgentTask) {
        // A task-only deletion also mutates its surviving owner's inverse.
        // Resolve the array and its models before SwiftData snapshots it.
        if let workspace = task.workspace {
            for related in workspace.tasks { _ = related.id }
        }
        SwiftDataTaskRollbackPreparation.prepare(task)
        for skill in task.skills {
            _ = skill.id
            for related in skill.tasks { _ = related.id }
        }
    }

}

import ASTRAModels

/// Resolve relationship faults before a reversible deletion. Otherwise
/// SwiftData can restore a lazy snapshot future as an array on rollback and
/// abort on the next save (including autosave). This does not change the graph;
/// SwiftData still owns the cascade, rollback, and persisted relationships.
@MainActor
public enum SwiftDataDeletionPreparation {
    public static func prepare(_ workspace: Workspace) {
        let tasks = workspace.tasks
        let skills = workspace.skills
        for connector in workspace.connectors { _ = (connector.id, connector.workspace?.id, connector.skill?.id) }
        for tool in workspace.localTools { _ = (tool.id, tool.workspace?.id, tool.skill?.id) }
        for template in workspace.templates { _ = (template.id, template.workspace?.id) }
        for schedule in workspace.schedules { _ = (schedule.id, schedule.workspace?.id) }
        for task in tasks { prepare(task) }
        for skill in skills {
            _ = (skill.id, skill.workspace?.id)
            for task in skill.tasks { _ = task.id }
            for connector in skill.connectors { _ = connector.id }
            for tool in skill.localTools { _ = tool.id }
        }
    }

    public static func prepare(_ task: AgentTask) {
        _ = (task.id, task.workspace?.id)
        for run in task.runs { _ = (run.id, run.task?.id) }
        for event in task.events { _ = (event.id, event.task?.id, event.run?.id) }
        for artifact in task.artifacts { _ = (artifact.id, artifact.task?.id) }
        for skill in task.skills { _ = skill.id }
    }
}

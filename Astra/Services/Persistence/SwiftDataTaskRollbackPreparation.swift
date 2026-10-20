import ASTRAModels

/// Resolve a task's own relationships before the first reversible edit.
/// SwiftData can otherwise capture an unresolved array future in the edit's
/// rollback snapshot and abort when the restored relationship is read. This
/// only faults the affected task; it does not export or scan its workspace.
@MainActor
public enum SwiftDataTaskRollbackPreparation {
    public static func prepare(_ task: AgentTask) {
        _ = (task.id, task.workspace?.id)
        for run in task.runs { _ = (run.id, run.task?.id) }
        for event in task.events { _ = (event.id, event.task?.id, event.run?.id) }
        for artifact in task.artifacts { _ = (artifact.id, artifact.task?.id) }
        for skill in task.skills { _ = skill.id }
    }
}

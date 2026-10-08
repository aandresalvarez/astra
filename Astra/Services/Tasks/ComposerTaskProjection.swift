import Foundation
import ASTRACore
import ASTRAModels

/// The task a new-task composer *would* submit, built for read-only questions
/// (runtime eligibility, skill scope) while the user is still typing.
///
/// The projection must stay out of the store. SwiftData adopts an unmanaged
/// model as soon as it joins a managed one through a relationship setter, so
/// `task.skills = selectedSkills` (managed skills, inverse `Skill.tasks`) used
/// to insert every preview and probe into the composer's context. The next
/// autosave then persisted them as phantom `draft` rows — one per preview pass,
/// carrying whatever id the preview had been anchored to, the workspace's or
/// the live draft's. Skills are therefore cloned, and the workspace is only
/// handed to `AgentTask.init`, which sets the to-one without registering the
/// inverse (a post-init `task.workspace = workspace` adopts the task too).
@MainActor
enum ComposerTaskProjection {
    static func detachedTask(
        title: String,
        goal: String,
        workspace: Workspace?,
        skills: [Skill],
        inputs: [String],
        tokenBudget: Int = TaskExecutionDefaults.tokenBudget,
        model: String = TaskExecutionDefaults.model,
        runtime: AgentRuntimeID = TaskExecutionDefaults.runtime
    ) -> AgentTask {
        let task = AgentTask(
            title: title,
            goal: goal,
            workspace: workspace,
            tokenBudget: tokenBudget,
            model: model,
            runtime: runtime
        )
        task.inputs = inputs
        task.skills = TaskExecutionLaunchSnapshotApplicator.detachedSkills(skills)
        return task
    }

    /// The behavior skills `taskText` activates out of `selectedSkills`,
    /// returned as the caller's managed instances so they can be assigned to
    /// the task that is actually submitted.
    static func scopedSkills(
        _ selectedSkills: [Skill],
        forTaskText taskText: String,
        inputs: [String],
        workspace: Workspace?
    ) -> [Skill] {
        let trimmed = taskText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !selectedSkills.isEmpty else { return selectedSkills }

        let probe = detachedTask(
            title: String(trimmed.prefix(60)),
            goal: trimmed,
            workspace: workspace,
            skills: selectedSkills,
            inputs: inputs
        )
        let managedByID = Dictionary(
            selectedSkills.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // Workspace and package skills come back managed; the clones map back
        // to their sources, and a clone with no managed source is dropped
        // rather than inserted as a duplicate Skill.
        return TaskCapabilityResolver(task: probe)
            .activationScope(contextText: trimmed)
            .behaviorSkills
            .compactMap { $0.modelContext == nil ? managedByID[$0.id] : $0 }
    }
}

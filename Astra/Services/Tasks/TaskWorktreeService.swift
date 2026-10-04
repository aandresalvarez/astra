import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

enum TaskWorktreeCreationError: LocalizedError {
    case repositoryUnavailable
    case noCommit(String)
    case persistenceFailed(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .repositoryUnavailable:
            "The selected Git repository is no longer available in this workspace. Choose another repository."
        case .noCommit(let path):
            "Could not read HEAD in \(path). Create an initial commit before starting a task in a worktree."
        case .persistenceFailed(let path, let reason):
            "The worktree was created at \(path), but ASTRA could not save the task. The worktree has been kept; no agent was launched. \(reason)"
        }
    }
}

/// Prepares the checkout before submission freezes the task's launch path and
/// resource claims. The task's existing executionRootPath owns the durable pin.
@MainActor
enum TaskWorktreeService {
    static func branchName(for task: AgentTask) -> String {
        let words = task.title.lowercased()
            .split { !$0.isASCII || (!$0.isLetter && !$0.isNumber) }
        let slug = String(words.joined(separator: "-").prefix(40))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "astra/\(slug.isEmpty ? "task" : slug)-\(task.id.uuidString.lowercased())"
    }

    static func prepare(
        task: AgentTask,
        repositoryPath: String?,
        inheritingFrom draft: AgentTask? = nil,
        modelContext: ModelContext,
        git: any GitRepositoryOperating = GitService.shared,
        worktreesRoot: String = AppChannel.current.defaultWorktreesRoot
    ) async throws {
        try Task.checkCancellation()
        if let draft {
            guard draft !== task else { return }
            task.executionRootPath = draft.executionRootPath
            if let prepared = draft.events
                .filter({ $0.hasType(TaskEventTypes.Task.worktreePrepared) })
                .max(by: { $0.timestamp < $1.timestamp }) {
                modelContext.insert(TaskEvent(
                    task: task,
                    eventType: TaskEventTypes.Task.worktreePrepared,
                    payload: prepared.payload
                ))
            }
            return
        }
        guard let repositoryPath else { return }
        guard let workspace = task.workspace else {
            throw TaskWorktreeCreationError.repositoryUnavailable
        }
        let repositories = await git.scanForGitRepositories(
            primaryPath: workspace.primaryPath,
            additionalPaths: workspace.additionalPaths
        )
        let path = WorkspacePathPresentation.standardizedPath(repositoryPath)
        guard repositories.contains(where: { $0.path == path }) else {
            throw TaskWorktreeCreationError.repositoryUnavailable
        }
        try Task.checkCancellation()
        guard let head = await git.getCommitSHA("HEAD", at: path) else {
            throw TaskWorktreeCreationError.noCommit(path)
        }
        let branch = branchName(for: task)
        let destination = GitService.worktreeLocation(
            repoPath: path, branch: branch, worktreesRoot: worktreesRoot
        )
        let payload = try TaskEvent.encodePayload(TaskWorktreePayload(
            repositoryPath: path, worktreePath: destination, branch: branch
        )).get()
        try Task.checkCancellation()

        let createdPath = try await git.addWorktree(
            repoPath: path,
            branch: branch,
            createBranch: true,
            base: head,
            worktreesRoot: worktreesRoot
        )
        task.executionRootPath = createdPath
        modelContext.insert(task)
        modelContext.insert(TaskEvent(
            task: task,
            eventType: TaskEventTypes.Task.worktreePrepared,
            payload: payload
        ))
        // Keep a recoverable draft even if the composer is dismissed after Git
        // finishes. Cancellation may prevent launch, but must not orphan the pin.
        do {
            try WorkspacePersistenceCoordinator.saveAndAutoExportOrThrow(
                workspace: workspace,
                modelContext: modelContext,
                taskID: task.id,
                auditFields: ["operation": "task_worktree_prepared"]
            )
        } catch {
            throw TaskWorktreeCreationError.persistenceFailed(
                path: createdPath, reason: error.localizedDescription
            )
        }
        AppLogger.breadcrumb(action: "task_worktree_prepared", category: "Git", taskID: task.id, fields: [
            "repository": path,
            "worktree": createdPath,
            "branch": branch
        ])
    }

    static func recoverFailedSubmission(
        task: AgentTask,
        existingDraft: AgentTask?,
        modelContext: ModelContext
    ) -> AgentTask? {
        if existingDraft == nil,
           task.events.contains(where: { $0.hasType(TaskEventTypes.Task.worktreePrepared) }) {
            TaskStateMachine.restoreDraftForEditing(task, modelContext: modelContext)
            WorkspacePersistenceCoordinator.saveAndAutoExport(
                workspace: task.workspace,
                modelContext: modelContext,
                taskID: task.id,
                auditFields: ["operation": "worktree_submission_failed"]
            )
            return task
        }
        modelContext.delete(task)
        return existingDraft
    }
}

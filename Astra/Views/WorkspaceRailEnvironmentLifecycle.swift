import SwiftUI
import SwiftData
import ASTRAModels
import ASTRACore

/// Refresh ownership follows the rail, including its visible collapsed summary.
/// Disclosure only mounts controls; it never detaches the selected context.
struct WorkspaceRailEnvironmentLifecycle: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.newTaskWorktreeIntents) private var worktreeIntents
    @ObservedObject var git: WorkspaceGitViewModel
    @ObservedObject var docker: WorkspaceDockerViewModel
    let workspace: Workspace
    let selectedTask: AgentTask?
    let hasGitRepositories: Bool
    let hasDockerEnvironments: Bool

    private var repositoryTask: AgentTask? {
        Self.repositoryTask(selectedTask: selectedTask, preparedDraft: worktreeIntents?.entry(
            workspaceID: workspace.id, selectedTaskID: selectedTask?.id
        )?.preparedDraft)
    }

    static func repositoryTask(selectedTask: AgentTask?, preparedDraft: AgentTask?) -> AgentTask? {
        if let selectedTask { return selectedTask }
        guard let preparedDraft, preparedDraft.modelContext != nil, !preparedDraft.isDeleted else { return nil }
        return preparedDraft
    }

    static func needsContainerRows(workspaceHasContainers: Bool, task: AgentTask?) -> Bool {
        workspaceHasContainers || ExecutionEnvironmentStore.decode(task?.executionEnvironmentSnapshotJSON).isContainerized
    }

    func body(content: Content) -> some View {
        content
            .task(id: RepositoryContext(workspace: workspace, task: repositoryTask, enabled: hasGitRepositories)) {
                guard await deferViewUpdate() else { return }
                if hasGitRepositories {
                    git.setup(for: workspace, selectedTask: repositoryTask)
                    if scenePhase != .active { git.pauseRefresh() }
                } else {
                    git.pauseRefresh()
                }
            }
            .task(id: ContainerContext(workspace: workspace, task: selectedTask, enabled: hasDockerEnvironments)) {
                guard await deferViewUpdate() else { return }
                // Keep the selected context current even when Host needs no inventory scan.
                docker.setup(for: workspace, selectedTask: selectedTask, refreshInventory: hasDockerEnvironments)
            }
            .onDisappear { git.pauseRefresh() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active, hasGitRepositories { git.resumeRefresh() }
                else { git.pauseRefresh() }
            }
    }

    private func deferViewUpdate() async -> Bool {
        do { try await Task.sleep(for: .milliseconds(1)) }
        catch { return false }
        return !Task.isCancelled
    }

    struct RepositoryContext: Equatable {
        let workspaceOwner: PersistentIdentifier
        let taskOwner: PersistentIdentifier?
        let primaryPath: String
        let additionalPaths: [String]
        let activeWorkingPath: String?
        let executionRootPath: String?
        let enabled: Bool

        init(workspace: Workspace, task: AgentTask?, enabled: Bool) {
            workspaceOwner = workspace.persistentModelID
            taskOwner = task?.persistentModelID
            primaryPath = workspace.primaryPath
            additionalPaths = workspace.additionalPaths
            activeWorkingPath = workspace.activeWorkingPath
            executionRootPath = task?.executionRootPath
            self.enabled = enabled
        }
    }

    struct ContainerContext: Equatable {
        let repository: RepositoryContext
        let taskStatus: String?
        let taskEnvironment: String?
        let workspaceEnvironment: String?

        init(workspace: Workspace, task: AgentTask?, enabled: Bool) {
            repository = RepositoryContext(workspace: workspace, task: task, enabled: enabled)
            taskStatus = task?.status.rawValue
            taskEnvironment = task?.executionEnvironmentSnapshotJSON
            workspaceEnvironment = workspace.activeExecutionEnvironmentJSON
        }
    }
}

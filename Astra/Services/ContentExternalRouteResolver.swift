import Foundation
import SwiftData
import ASTRACore

enum ContentExternalRouteResolution {
    case openWorkspace(Workspace)
    case openTask(AgentTask)
    case createdTask(AgentTask, shouldRun: Bool)
}

@MainActor
struct ContentExternalRouteResolver {
    let modelContext: ModelContext
    let defaultRuntimeID: String
    let defaultModel: String
    let defaultBudget: Int

    func resolve(
        _ route: AstraExternalRoute,
        workspaces: [Workspace]
    ) -> ContentExternalRouteResolution? {
        switch route.destination {
        case .workspace(let workspaceID):
            guard let workspace = workspace(for: workspaceID, in: workspaces) else { return nil }
            return .openWorkspace(workspace)

        case .task(let taskID):
            guard let task = task(for: taskID, in: workspaces) else { return nil }
            return .openTask(task)

        case .createTask(let workspaceID, let goal, let shouldRun):
            guard let task = createTask(
                workspaceID: workspaceID,
                goal: goal,
                shouldRun: shouldRun,
                workspaces: workspaces
            ) else {
                return nil
            }
            return .createdTask(task, shouldRun: shouldRun)

        case .continueLatestUnfinishedTask(let workspaceID):
            guard let workspace = workspace(for: workspaceID, in: workspaces),
                  let task = AstraTaskIntentSupport.latestUnfinishedTask(in: workspace) else {
                return nil
            }
            return .openTask(task)
        }
    }

    private func createTask(
        workspaceID: UUID,
        goal: String,
        shouldRun: Bool,
        workspaces: [Workspace]
    ) -> AgentTask? {
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGoal.isEmpty,
              let workspace = workspace(for: workspaceID, in: workspaces) else {
            return nil
        }

        let runtime = AgentRuntimeID(rawValue: defaultRuntimeID) ?? TaskExecutionDefaults.runtime
        let task = AgentTask(
            title: AstraTaskIntentSupport.title(for: trimmedGoal),
            goal: trimmedGoal,
            workspace: workspace,
            tokenBudget: defaultBudget,
            model: RuntimeModelAvailability.normalizedModel(defaultModel, for: runtime)
        )
        task.runtimeID = runtime.rawValue
        task.status = shouldRun ? .queued : .draft
        modelContext.insert(task)

        if shouldRun {
            modelContext.insert(TaskEvent(task: task, type: "user.message", payload: trimmedGoal))
        } else {
            task.draftMessages = AstraTaskIntentSupport.draftMessagesJSON(for: trimmedGoal)
        }
        TaskCapabilitySnapshotter.capture(for: task)
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)

        AppLogger.audit(.taskCreated, category: "AppIntents", taskID: task.id, fields: [
            "source": shouldRun ? "voice_create_and_run" : "voice_create_draft",
            "workspace_id": workspace.id.uuidString
        ])

        return task
    }

    private func workspace(for id: UUID, in workspaces: [Workspace]) -> Workspace? {
        workspaces.first { $0.id == id }
    }

    private func task(for id: UUID, in workspaces: [Workspace]) -> AgentTask? {
        for workspace in workspaces {
            if let task = workspace.tasks.first(where: { $0.id == id }) {
                return task
            }
        }
        return nil
    }
}

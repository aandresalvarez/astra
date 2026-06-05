import Foundation
import SwiftData
import ASTRACore

enum ContentExternalRouteResolution {
    case openWorkspace(Workspace)
    case openTask(AgentTask)
    case createdTask(AgentTask, shouldRun: Bool)
    case unresolved(String)

    var noticeMessage: String {
        switch self {
        case .unresolved(let message): message
        case .openWorkspace, .openTask, .createdTask: ""
        }
    }
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
    ) -> ContentExternalRouteResolution {
        switch route.destination {
        case .workspace(let workspaceID):
            guard let workspace = workspace(for: workspaceID, in: workspaces) else {
                return .unresolved("Workspace not found: \(workspaceID.uuidString)")
            }
            return .openWorkspace(workspace)

        case .task(let taskID):
            guard let task = task(for: taskID, in: workspaces) else {
                return .unresolved("Task not found: \(taskID.uuidString)")
            }
            return .openTask(task)

        case .createTask(let workspaceID, let goal, let shouldRun):
            guard let task = createTask(
                workspaceID: workspaceID,
                goal: goal,
                shouldRun: shouldRun,
                workspaces: workspaces
            ) else {
                return .unresolved("Could not create task in workspace: \(workspaceID.uuidString)")
            }
            return .createdTask(task, shouldRun: shouldRun)

        case .continueLatestUnfinishedTask(let workspaceID):
            guard let workspace = workspace(for: workspaceID, in: workspaces) else {
                return .unresolved("Workspace not found: \(workspaceID.uuidString)")
            }
            guard let task = AstraTaskIntentSupport.latestUnfinishedTask(in: workspace) else {
                return .unresolved("No unfinished task found in workspace: \(workspace.name)")
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

        let runtime = AgentRuntimeAdapterRegistry.registeredRuntime(rawValue: defaultRuntimeID)
        let task = AgentTask(
            title: AstraTaskIntentSupport.title(for: trimmedGoal),
            goal: trimmedGoal,
            workspace: workspace,
            tokenBudget: defaultBudget,
            model: RuntimeModelAvailability.normalizedModel(defaultModel, for: runtime),
            runtime: runtime
        )
        task.status = shouldRun ? .queued : .draft
        modelContext.insert(task)

        if shouldRun {
            modelContext.insert(TaskEvent(
                task: task,
                eventType: TaskEventTypes.Conversation.userMessage,
                payload: trimmedGoal
            ))
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

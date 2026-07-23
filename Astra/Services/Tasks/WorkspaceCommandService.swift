import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

enum WorkspaceCommandService {
    typealias InitialExecutionSubmitter = @MainActor (
        AgentTask,
        ModelContext
    ) -> Result<ExecutionRequestSubmissionService.Submission, ExecutionRequestSubmissionService.SubmissionError>

    struct TemplateTaskCreation {
        let mainTask: AgentTask
        let beforeTask: AgentTask?
        let initialRequestSubmitted: Bool
    }

    @discardableResult
    @MainActor
    static func createSkill(
        name: String,
        behaviorInstructions: String,
        allowedTools: [String],
        disallowedTools: [String] = [],
        workspace: Workspace,
        modelContext: ModelContext,
        source: String
    ) -> Skill {
        let skill = Skill(
            name: name,
            allowedTools: allowedTools.isEmpty ? Skill.defaultAllowed : allowedTools,
            disallowedTools: disallowedTools,
            behaviorInstructions: behaviorInstructions
        )
        skill.workspace = workspace
        modelContext.insert(skill)
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
        AppLogger.audit(.skillCreated, category: "UI", fields: [
            "source": source,
            "workspace_id": workspace.id.uuidString,
            "allowed_tools_count": String(skill.allowedTools.count)
        ])
        return skill
    }

    @discardableResult
    @MainActor
    static func createTool(
        name: String,
        toolType: String,
        command: String,
        description: String,
        workspace: Workspace,
        modelContext: ModelContext,
        source: String
    ) -> LocalTool {
        let tool = LocalTool(name: name)
        tool.toolType = toolType
        tool.command = command
        tool.toolDescription = description
        tool.icon = LocalTool.iconForType(toolType)
        tool.workspace = workspace
        modelContext.insert(tool)
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
        AppLogger.audit(.localToolCreated, category: "UI", fields: [
            "source": source,
            "workspace_id": workspace.id.uuidString,
            "tool_type": toolType
        ])
        return tool
    }

    @discardableResult
    @MainActor
    static func createConnector(
        name: String,
        serviceType: String,
        baseURL: String,
        authMethod: String,
        credentials: [String: String],
        workspace: Workspace,
        modelContext: ModelContext,
        allowCredentialUserInteraction: Bool = false,
        source: String
    ) -> (connector: Connector, failedCredentialKeys: [String]) {
        let connector = Connector(
            name: name,
            serviceType: serviceType,
            icon: connectorIcon(for: serviceType),
            baseURL: baseURL,
            authMethod: authMethod
        )
        connector.workspace = workspace
        var failedCredentialKeys: [String] = []
        for (key, value) in credentials {
            let saved = connector.saveCredential(
                key: key,
                value: value,
                allowUserInteraction: allowCredentialUserInteraction
            )
            if !saved {
                failedCredentialKeys.append(key)
            }
        }
        modelContext.insert(connector)
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
        AppLogger.audit(.connectorCreated, category: "UI", fields: [
            "source": source,
            "workspace_id": workspace.id.uuidString,
            "service_type": serviceType,
            "credential_count": String(credentials.count),
            "failed_credential_count": String(failedCredentialKeys.count)
        ])
        return (connector, failedCredentialKeys)
    }

    @discardableResult
    @MainActor
    static func createTemplateTasks(
        template: TaskTemplate,
        taskTitle: String,
        variables: [String: String],
        selectedSkills: [Skill],
        defaultModel: String,
        defaultRuntimeID: String,
        workspace: Workspace,
        modelContext: ModelContext,
        source: String,
        submitInitial: InitialExecutionSubmitter = { task, context in
            ExecutionRequestSubmissionService.submitInitial(for: task, into: context)
        }
    ) -> TemplateTaskCreation {
        let runtime = AgentRuntimeAdapterRegistry.registeredRuntime(rawValue: defaultRuntimeID)
        let normalizedDefaultModel = RuntimeModelAvailability.normalizedModel(
            defaultModel,
            for: runtime
        )
        let mainGoal = template.resolveGoal(template.mainGoal, with: variables)
        let mainModel = RuntimeModelAvailability.normalizedModel(
            template.mainModel.isEmpty ? normalizedDefaultModel : template.mainModel,
            for: runtime
        )
        let mainTask = AgentTask(
            title: taskTitle,
            goal: mainGoal,
            workspace: workspace,
            tokenBudget: template.mainBudget,
            model: mainModel,
            runtime: runtime
        )
        let mainTaskInitialState = TaskStateMachine.snapshot(mainTask)
        let mainTaskInitialUpdatedAt = mainTask.updatedAt
        let mainTaskInitialUnreadAt = mainTask.unreadAt
        TaskStateMachine.enqueueFromWorkspaceCommand(mainTask, modelContext: modelContext)
        mainTask.templateID = template.id
        mainTask.templateHooksJSON = template.hooksJSON
        mainTask.skills = skills(for: template, selectedSkills: selectedSkills)
        TaskCapabilitySnapshotter.capture(for: mainTask)

        if template.hasAfterPhase {
            let afterGoal = template.resolveGoal(template.afterGoal, with: variables)
            mainTask.chainedGoal = template.passContextToAfter
                ? "Previous task output will be provided as context.\n\n" + afterGoal
                : afterGoal
        }

        var beforeTask: AgentTask?
        var runnableInitialState = mainTaskInitialState
        var runnableInitialUpdatedAt = mainTaskInitialUpdatedAt
        var runnableInitialUnreadAt = mainTaskInitialUnreadAt
        if template.hasBeforePhase {
            let beforeGoal = template.resolveGoal(template.beforeGoal, with: variables)
            let beforeModel = RuntimeModelAvailability.normalizedModel(
                template.beforeModel.isEmpty ? normalizedDefaultModel : template.beforeModel,
                for: runtime
            )
            let task = AgentTask(
                title: "\(taskTitle) — Before",
                goal: beforeGoal,
                workspace: workspace,
                tokenBudget: template.beforeBudget,
                model: beforeModel,
                runtime: runtime
            )
            runnableInitialState = TaskStateMachine.snapshot(task)
            runnableInitialUpdatedAt = task.updatedAt
            runnableInitialUnreadAt = task.unreadAt
            TaskStateMachine.enqueueFromWorkspaceCommand(task, modelContext: modelContext)
            task.templateID = template.id
            task.templateHooksJSON = template.hooksJSON
            task.skills = mainTask.skills
            TaskCapabilitySnapshotter.capture(for: task)

            let chainedMainGoal = template.passContextToMain
                ? "Previous task output will be provided as context.\n\n" + mainGoal
                : mainGoal
            task.chainedGoal = chainedMainGoal
            modelContext.insert(task)
            mainTask.chainedFromID = task.id
            TaskStateMachine.restoreDraftForEditing(mainTask, modelContext: modelContext)
            beforeTask = task
        }

        modelContext.insert(mainTask)
        let runnableTask = beforeTask ?? mainTask
        guard case .success = submitInitial(runnableTask, modelContext) else {
            TaskStateMachine.restoreExecutionSubmissionFailure(
                runnableTask,
                snapshot: runnableInitialState,
                modelContext: modelContext,
                at: runnableInitialUpdatedAt
            )
            runnableTask.updatedAt = runnableInitialUpdatedAt
            runnableTask.unreadAt = runnableInitialUnreadAt
            AppLogger.audit(.taskFailed, category: "UI", taskID: runnableTask.id, fields: [
                "operation": "template_execution_submission"
            ], level: .error)
            return TemplateTaskCreation(
                mainTask: mainTask,
                beforeTask: beforeTask,
                initialRequestSubmitted: false
            )
        }
        AppLogger.audit(.taskCreated, category: "UI", taskID: mainTask.id, fields: [
            "source": source,
            "workspace_id": workspace.id.uuidString,
            "template_id": template.id.uuidString
        ])
        return TemplateTaskCreation(
            mainTask: mainTask,
            beforeTask: beforeTask,
            initialRequestSubmitted: true
        )
    }

    static func connectorIcon(for serviceType: String) -> String {
        switch serviceType {
        case "jira": "list.bullet.rectangle"
        case "github": "cat"
        case "slack": "number"
        case "database": "cylinder"
        case "rest_api": "arrow.left.arrow.right"
        case "confluence": "book"
        default: "bolt.horizontal.circle"
        }
    }

    private static func skills(for template: TaskTemplate, selectedSkills: [Skill]) -> [Skill] {
        guard !template.defaultSkillIDs.isEmpty else { return selectedSkills }
        let idSet = Set(template.defaultSkillIDs)
        return selectedSkills.filter { idSet.contains($0.id.uuidString) }
    }
}

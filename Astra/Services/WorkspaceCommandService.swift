import Foundation
import SwiftData
import ASTRACore

enum WorkspaceCommandService {
    struct TemplateTaskCreation {
        let mainTask: AgentTask
        let beforeTask: AgentTask?
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
        source: String
    ) -> Connector {
        let connector = Connector(
            name: name,
            serviceType: serviceType,
            icon: connectorIcon(for: serviceType),
            baseURL: baseURL,
            authMethod: authMethod
        )
        connector.workspace = workspace
        for (key, value) in credentials {
            connector.saveCredential(key: key, value: value)
        }
        modelContext.insert(connector)
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
        AppLogger.audit(.connectorCreated, category: "UI", fields: [
            "source": source,
            "workspace_id": workspace.id.uuidString,
            "service_type": serviceType,
            "credential_count": String(credentials.count)
        ])
        return connector
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
        source: String
    ) -> TemplateTaskCreation {
        let mainGoal = template.resolveGoal(template.mainGoal, with: variables)
        let mainTask = AgentTask(
            title: taskTitle,
            goal: mainGoal,
            workspace: workspace,
            tokenBudget: template.mainBudget,
            model: template.mainModel.isEmpty ? defaultModel : template.mainModel
        )
        mainTask.runtimeID = defaultRuntimeID
        mainTask.status = .queued
        mainTask.templateID = template.id
        mainTask.templateHooksJSON = template.hooksJSON
        mainTask.skills = skills(for: template, selectedSkills: selectedSkills)
        mainTask.captureSkillSnapshots()

        if template.hasAfterPhase {
            let afterGoal = template.resolveGoal(template.afterGoal, with: variables)
            mainTask.chainedGoal = template.passContextToAfter
                ? "Previous task output will be provided as context.\n\n" + afterGoal
                : afterGoal
        }

        var beforeTask: AgentTask?
        if template.hasBeforePhase {
            let beforeGoal = template.resolveGoal(template.beforeGoal, with: variables)
            let task = AgentTask(
                title: "\(taskTitle) — Before",
                goal: beforeGoal,
                workspace: workspace,
                tokenBudget: template.beforeBudget,
                model: template.beforeModel.isEmpty ? defaultModel : template.beforeModel
            )
            task.runtimeID = defaultRuntimeID
            task.status = .queued
            task.templateID = template.id
            task.templateHooksJSON = template.hooksJSON
            task.skills = mainTask.skills
            task.captureSkillSnapshots()

            let chainedMainGoal = template.passContextToMain
                ? "Previous task output will be provided as context.\n\n" + mainGoal
                : mainGoal
            task.chainedGoal = chainedMainGoal
            modelContext.insert(task)
            mainTask.chainedFromID = task.id
            mainTask.status = .draft
            beforeTask = task
        }

        modelContext.insert(mainTask)
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: modelContext)
        AppLogger.audit(.taskCreated, category: "UI", taskID: mainTask.id, fields: [
            "source": source,
            "workspace_id": workspace.id.uuidString,
            "template_id": template.id.uuidString
        ])
        return TemplateTaskCreation(mainTask: mainTask, beforeTask: beforeTask)
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

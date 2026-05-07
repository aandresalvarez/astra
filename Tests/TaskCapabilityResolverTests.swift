import Foundation
import SwiftData
import Testing
@testable import ASTRA

private func makeTaskCapabilityResolverContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

@Suite("TaskCapabilityResolver")
@MainActor
struct TaskCapabilityResolverTests {
    @Test("Enabled connector contributes its companion skill instructions")
    func enabledConnectorIncludesCompanionSkillInstructions() throws {
        let container = try makeTaskCapabilityResolverContainer()
        let context = container.mainContext

        let workspace = Workspace(name: "Jira Workspace", primaryPath: "/tmp/jira-workspace")
        context.insert(workspace)

        let jiraSkill = Skill(
            name: "Jira Agent",
            allowedTools: ["Read", "Bash"],
            behaviorInstructions: "Use /rest/api/3/mypermissions before diagnosing Jira auth."
        )
        jiraSkill.isGlobal = true
        context.insert(jiraSkill)

        let jiraConnector = Connector(
            name: "Jira",
            serviceType: "jira",
            connectorDescription: "Jira REST API",
            baseURL: "https://example.atlassian.net",
            authMethod: "basic"
        )
        jiraConnector.isGlobal = true
        jiraConnector.skill = jiraSkill
        jiraConnector.configKeys = ["JIRA_PROJECTS"]
        jiraConnector.configValues = ["STAR"]
        context.insert(jiraConnector)

        workspace.enabledGlobalConnectorIDs = [jiraConnector.id.uuidString]

        let safeSkill = Skill(
            name: "Safe Bash",
            allowedTools: ["Read", "Bash"],
            behaviorInstructions: "Avoid destructive shell commands."
        )
        safeSkill.workspace = workspace
        context.insert(safeSkill)

        let task = AgentTask(title: "Use Jira", goal: "Create STAR ticket", workspace: workspace)
        task.skills = [safeSkill]
        context.insert(task)
        try context.save()

        let instructions = task.resolvedBehaviorInstructions
        #expect(instructions.contains("[Safe Bash]:"))
        #expect(instructions.contains("[Jira Agent]:"))
        #expect(instructions.contains("/rest/api/3/mypermissions"))

        let prompt = AgentPromptBuilder.buildPrompt(for: task)
        #expect(prompt.contains("Behavioral Instructions (from Skills):"))
        #expect(prompt.contains("[Jira Agent]:"))
        #expect(prompt.contains("JIRA_PROJECTS: STAR"))
    }
}

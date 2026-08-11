import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

private func makeTaskCapabilityDuplicateSkillContainer() throws -> ModelContainer {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(
        for: ASTRASchema.current,
        migrationPlan: ASTRAMigrationPlan.self,
        configurations: [config]
    )
}

@Suite("Task capability duplicate skills")
@MainActor
struct TaskCapabilityDuplicateSkillTests {
    @Test("Enabled package resolves only its current package-owned skill")
    func enabledPackageRejectsStaleDuplicateSkillInstructions() throws {
        let container = try makeTaskCapabilityDuplicateSkillContainer()
        let context = container.mainContext
        let package = try #require(
            PluginCatalog.builtInPackages.first { $0.id == "github-workflow" }
        )
        let pluginSkill = try #require(package.skills.first)

        let workspace = Workspace(name: "GitHub Duplicate", primaryPath: "/tmp/github-duplicate")
        workspace.enabledCapabilityIDs = [package.id]
        context.insert(workspace)

        let current = Skill(
            name: pluginSkill.name,
            allowedTools: pluginSkill.allowedTools,
            behaviorInstructions: "CURRENT_GITHUB_INSTRUCTIONS"
        )
        current.isGlobal = true
        current.originPackageID = package.id
        current.originPackageVersion = package.version
        current.originComponentID = CapabilityResourceOrigin.componentID(for: pluginSkill)
        current.originComponentKind = CapabilityResourceComponentKind.skill.rawValue
        context.insert(current)

        let stale = Skill(
            name: pluginSkill.name,
            allowedTools: ["Read", "Bash"],
            behaviorInstructions: "STALE_GITHUB_INSTRUCTIONS"
        )
        stale.isGlobal = true
        stale.originPackageID = package.id
        stale.originPackageVersion = "2.1.2"
        stale.originComponentID = CapabilityResourceOrigin.componentID(for: pluginSkill)
        stale.originComponentKind = CapabilityResourceComponentKind.skill.rawValue
        context.insert(stale)

        let task = AgentTask(
            title: "Inspect GitHub",
            goal: "Use GitHub to list pull requests",
            workspace: workspace
        )
        context.insert(task)
        try context.save()

        let resolver = TaskCapabilityResolver(task: task)
        #expect(resolver.allBehaviorSkills.map(\.id) == [current.id])

        let prompt = AgentPromptBuilder.buildPrompt(for: task)
        #expect(prompt.contains("CURRENT_GITHUB_INSTRUCTIONS"))
        #expect(!prompt.contains("STALE_GITHUB_INSTRUCTIONS"))
    }

    @Test("Task-only package duplicates prefer the newer owned version")
    func taskOnlyDuplicatesPreferNewerVersion() throws {
        let container = try makeTaskCapabilityDuplicateSkillContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Task Duplicate", primaryPath: "/tmp/task-duplicate")
        context.insert(workspace)

        let stale = Skill(name: "GitHub Agent", behaviorInstructions: "STALE")
        stale.originPackageID = "github-workflow"
        stale.originPackageVersion = "2.1.2"
        stale.originComponentID = "skill:github-agent"
        context.insert(stale)

        let current = Skill(name: "GitHub Agent", behaviorInstructions: "CURRENT")
        current.originPackageID = "github-workflow"
        current.originPackageVersion = "2.1.9"
        current.originComponentID = "skill:github-agent"
        context.insert(current)

        let task = AgentTask(title: "GitHub", goal: "Inspect GitHub", workspace: workspace)
        task.skills = [stale, current]
        context.insert(task)
        try context.save()

        #expect(TaskCapabilityResolver(task: task).allBehaviorSkills.map(\.id) == [current.id])
    }

    @Test("A connector survives dedupe of the skill copy that owns it")
    func duplicateSkillDedupeKeepsOwnedConnectorInActivationScope() throws {
        let container = try makeTaskCapabilityDuplicateSkillContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Jira Support Tickets", primaryPath: "/tmp/jira-support-tickets")
        context.insert(workspace)

        // The copy that owns the connector. Installing the package globally and
        // then again into a workspace leaves two rows for one logical skill.
        let owning = Skill(
            name: "Jira Agent",
            skillDescription: "Search and read Jira tickets via typed read-only operations"
        )
        owning.isGlobal = true
        owning.originPackageID = "jira-workflow"
        owning.originPackageVersion = "2.2.0"
        owning.originComponentID = "skill:jira-agent"
        owning.originComponentKind = CapabilityResourceComponentKind.skill.rawValue
        owning.updatedAt = Date(timeIntervalSince1970: 1_000)
        context.insert(owning)

        let connector = Connector(
            name: "Jira-new",
            serviceType: "jira",
            connectorDescription: "Atlassian Jira REST API v3",
            baseURL: "https://example.atlassian.net",
            authMethod: "basic"
        )
        connector.isGlobal = true
        connector.credentialKeys = ["JIRA_EMAIL", "JIRA_API_TOKEN"]
        connector.skill = owning
        context.insert(connector)
        workspace.enabledGlobalConnectorIDs = [connector.id.uuidString]

        // Same logical skill, no connectors, newer — so it wins dedupe.
        let winning = Skill(
            name: "Jira Agent",
            skillDescription: "Search and read Jira tickets via typed read-only operations"
        )
        winning.originPackageID = "jira-workflow"
        winning.originPackageVersion = "2.2.0"
        winning.originComponentID = "skill:jira-agent"
        winning.originComponentKind = CapabilityResourceComponentKind.skill.rawValue
        winning.workspace = workspace
        winning.updatedAt = Date(timeIntervalSince1970: 2_000)
        context.insert(winning)

        let task = AgentTask(
            title: "Answer the ticket",
            goal: "can you see my open tickets in the SS project?",
            workspace: workspace
        )
        task.skills = [owning, winning]
        context.insert(task)
        try context.save()

        let resolver = TaskCapabilityResolver(task: task)
        #expect(resolver.allBehaviorSkills.map(\.id) == [winning.id])
        #expect(resolver.allConnectors.map(\.id) == [connector.id])

        // A follow-up that never says "Jira" reaches the connector only through
        // its owning skill. The skill is in scope, so the connector must be too.
        let scope = resolver.activationScope(
            contextText: "what are the next steps to address and answer the ticket?"
        )
        #expect(scope.behaviorSkills.map(\.id) == [winning.id])
        #expect(scope.connectors.map(\.id) == [connector.id])
    }
}

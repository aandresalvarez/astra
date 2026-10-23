import Foundation
import Testing
import SwiftData
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@MainActor
private func makeLaunchSnapshotContainer() throws -> ModelContainer {
    try ModelContainer(
        for: ASTRASchema.current,
        migrationPlan: ASTRAMigrationPlan.self,
        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
    )
}

@MainActor
@Suite("Task execution launch snapshot applicator")
struct TaskExecutionLaunchSnapshotApplicatorTests {
    @Test("Queued request uses a detached immutable configuration and preserves editable state")
    func buildsDetachedCompleteSnapshot() throws {
        let workspace = Workspace(name: "Queued workspace", primaryPath: "/tmp/queued-workspace")
        let task = AgentTask(title: "Queued", goal: "Run", workspace: workspace)
        let priorRun = TaskRun(task: task)
        priorRun.status = .completed
        let priorEvent = TaskEvent(task: task, type: TaskEventTypes.Conversation.userMessage.rawValue, payload: "prior")
        task.runs = [priorRun]
        task.events = [priorEvent]
        task.runtimeID = "codex_cli"
        task.model = "submitted-model"
        task.tokenBudget = 1_234
        task.runtimeExplicitlySelected = true
        task.maxTurns = 7
        task.isolationStrategy = .gitBranch
        task.validationStrategy = .runTests
        task.testCommand = "swift test"
        task.useAgentTeam = true
        task.teamSize = 4
        task.teamInstructions = "submitted team"
        task.executionRootPath = "/tmp/submitted-root"
        task.executionEnvironmentSnapshotJSON = "{\"submitted\":true}"
        task.templateHooksJSON = "submitted-hooks"
        task.skillSnapshotsJSON = "submitted-skills"
        task.runtimePermissionGrantsJSON = "submitted-grants"
        let request = TaskTurnRequest(task: task, messageEventID: .init(), sequence: 1)

        task.runtimeID = "claude_code"
        task.model = "edited-model"
        task.tokenBudget = 9_999
        task.runtimeExplicitlySelected = false
        task.maxTurns = 2
        task.isolationStrategy = .copy
        task.validationStrategy = .manual
        task.testCommand = ""
        task.useAgentTeam = false
        task.teamSize = 2
        task.teamInstructions = "edited team"
        task.executionRootPath = "/tmp/edited-root"
        task.executionEnvironmentSnapshotJSON = "{\"edited\":true}"
        task.templateHooksJSON = "edited-hooks"
        task.skillSnapshotsJSON = "edited-skills"
        task.runtimePermissionGrantsJSON = "edited-grants"

        let snapshot = try #require(TaskExecutionLaunchSnapshotApplicator.snapshot(request: request, from: task))
        let launchTask = TaskExecutionLaunchSnapshotApplicator.detachedTask(snapshot, from: task)
        #expect(launchTask.runtimeID == "codex_cli")
        #expect(launchTask.model == "submitted-model")
        #expect(launchTask.tokenBudget == 1_234)
        #expect(launchTask.maxTurns == 7)
        #expect(launchTask.isolationStrategy == .gitBranch)
        #expect(launchTask.validationStrategy == .runTests)
        #expect(launchTask.executionRootPath == "/tmp/submitted-root")
        #expect(launchTask.runtimePermissionGrantsJSON == "submitted-grants")
        #expect(launchTask.workspace?.primaryPath == workspace.primaryPath)
        #expect(launchTask.events.contains { $0.id == priorEvent.id })
        #expect(launchTask.runs.contains { $0.id == priorRun.id })
        #expect(task.workspace === workspace)
        #expect(task.events.contains { $0.id == priorEvent.id })
        #expect(task.runs.contains { $0.id == priorRun.id })
        #expect(priorEvent.task === task)
        #expect(priorRun.task === task)

        #expect(task.runtimeID == "claude_code")
        #expect(task.model == "edited-model")
        #expect(task.tokenBudget == 9_999)
        #expect(task.maxTurns == 2)
        #expect(task.isolationStrategy == .copy)
        #expect(task.validationStrategy == .manual)
        #expect(task.executionRootPath == "/tmp/edited-root")
        #expect(task.runtimePermissionGrantsJSON == "edited-grants")
    }

    @Test("Queued retry preserves the complete enabled global capability inventory")
    func queuedRetryPreservesGlobalCapabilityInventory() throws {
        let container = try makeLaunchSnapshotContainer()
        let context = container.mainContext
        let githubPackage = try #require(
            PluginCatalog.builtInPackages.first { $0.id == "github-workflow" }
        )
        let gcloudPackage = try #require(
            PluginCatalog.builtInPackages.first { $0.id == "gcloud-workflow" }
        )

        let workspace = Workspace(
            name: "Production retry",
            primaryPath: "/tmp/production-retry"
        )
        workspace.enabledCapabilityIDs = [githubPackage.id, gcloudPackage.id]
        context.insert(workspace)

        let githubSkill = Skill(
            name: "GitHub Agent",
            skillDescription: "Inspect GitHub through host control.",
            allowedTools: ["Read", "Glob", "Grep"],
            behaviorInstructions: "Use the GitHub host-control tool."
        )
        githubSkill.isGlobal = true
        context.insert(githubSkill)

        let gcloudSkill = Skill(
            name: "GCloud Agent",
            skillDescription: "Inspect Google Cloud.",
            allowedTools: ["Read", "Bash"],
            behaviorInstructions: "Use gcloud for cloud inspection."
        )
        gcloudSkill.isGlobal = true
        context.insert(gcloudSkill)

        let gcloudConnector = Connector(
            name: "Google Cloud",
            serviceType: "gcloud",
            connectorDescription: "Google Cloud runtime configuration",
            baseURL: "https://cloud.google.com",
            authMethod: "none"
        )
        gcloudConnector.isGlobal = true
        gcloudConnector.configKeys = ["GCP_PROJECT"]
        gcloudConnector.configValues = ["astra-test-project"]
        gcloudConnector.skill = gcloudSkill
        context.insert(gcloudConnector)

        let gcloudTools = gcloudPackage.localTools.map { definition in
            let tool = LocalTool(
                name: definition.name,
                toolDescription: definition.description,
                icon: definition.icon,
                toolType: definition.toolType,
                command: definition.command,
                arguments: definition.arguments
            )
            tool.isGlobal = true
            tool.skill = gcloudSkill
            context.insert(tool)
            return tool
        }
        let gcloudTool = try #require(
            gcloudTools.first { $0.command == "gcloud" }
        )

        let unrelatedSkill = Skill(name: "Unrelated Agent")
        unrelatedSkill.isGlobal = true
        context.insert(unrelatedSkill)
        let unrelatedConnector = Connector(
            name: "Unrelated Service",
            serviceType: "unrelated",
            authMethod: "none"
        )
        unrelatedConnector.isGlobal = true
        context.insert(unrelatedConnector)
        let unrelatedTool = LocalTool(name: "unrelated", command: "unrelated")
        unrelatedTool.isGlobal = true
        context.insert(unrelatedTool)

        workspace.enabledGlobalSkillIDs = [
            githubSkill.id.uuidString,
            gcloudSkill.id.uuidString
        ]
        workspace.enabledGlobalConnectorIDs = [gcloudConnector.id.uuidString]
        workspace.enabledGlobalToolIDs = gcloudTools.map { $0.id.uuidString }

        let task = AgentTask(
            title: "Inspect GitHub and Google Cloud",
            goal: "Review GitHub CI and inspect Google Cloud resources",
            workspace: workspace
        )
        context.insert(task)
        let request = TaskTurnRequest(
            task: task,
            messageEventID: UUID(),
            sequence: 2,
            kind: .retry
        )
        context.insert(request)
        try context.save()

        let liveResolver = TaskCapabilityResolver(task: task)
        let liveFullScope = liveResolver.resolvedScope(.fullInventory)
        let liveProviderScope = liveResolver.resolvedScope(
            .providerLaunch(contextText: task.goal)
        )
        let snapshot = try #require(
            TaskExecutionLaunchSnapshotApplicator.snapshot(request: request, from: task)
        )
        let detached = TaskExecutionLaunchSnapshotApplicator.detachedTask(
            snapshot,
            from: task
        )
        let detachedResolver = TaskCapabilityResolver(task: detached)
        let detachedFullScope = detachedResolver.resolvedScope(.fullInventory)
        let detachedProviderScope = detachedResolver.resolvedScope(
            .providerLaunch(contextText: task.goal)
        )
        let liveFullSkillIDs = Set(liveFullScope.behaviorSkills.map { $0.id })
        let detachedFullSkillIDs = Set(detachedFullScope.behaviorSkills.map { $0.id })
        let liveFullConnectorIDs = Set(liveFullScope.connectors.map { $0.id })
        let detachedFullConnectorIDs = Set(detachedFullScope.connectors.map { $0.id })
        let liveFullToolIDs = Set(liveFullScope.localTools.map { $0.id })
        let detachedFullToolIDs = Set(detachedFullScope.localTools.map { $0.id })
        let liveProviderSkillIDs = Set(liveProviderScope.behaviorSkills.map { $0.id })
        let detachedProviderSkillIDs = Set(detachedProviderScope.behaviorSkills.map { $0.id })
        let liveProviderConnectorIDs = Set(liveProviderScope.connectors.map { $0.id })
        let detachedProviderConnectorIDs = Set(detachedProviderScope.connectors.map { $0.id })
        let liveProviderToolIDs = Set(liveProviderScope.localTools.map { $0.id })
        let detachedProviderToolIDs = Set(detachedProviderScope.localTools.map { $0.id })

        #expect(detached.modelContext == nil)
        #expect(liveFullSkillIDs == detachedFullSkillIDs)
        #expect(liveFullConnectorIDs == detachedFullConnectorIDs)
        #expect(liveFullToolIDs == detachedFullToolIDs)
        #expect(liveProviderSkillIDs == detachedProviderSkillIDs)
        #expect(liveProviderConnectorIDs == detachedProviderConnectorIDs)
        #expect(liveProviderToolIDs == detachedProviderToolIDs)
        #expect(
            liveProviderScope.resolver.resolvedEnvironmentVariables ==
                detachedProviderScope.resolver.resolvedEnvironmentVariables
        )

        let detachedWorkspace = try #require(detached.workspace)
        let detachedGitHubSkill = try #require(
            detachedWorkspace.skills.first { $0.id == githubSkill.id }
        )
        let detachedGCloudSkill = try #require(
            detachedWorkspace.skills.first { $0.id == gcloudSkill.id }
        )
        let detachedConnector = try #require(
            detachedWorkspace.connectors.first { $0.id == gcloudConnector.id }
        )
        let detachedTool = try #require(
            detachedWorkspace.localTools.first { $0.id == gcloudTool.id }
        )

        #expect(detachedGitHubSkill !== githubSkill)
        #expect(detachedGCloudSkill !== gcloudSkill)
        #expect(detachedConnector !== gcloudConnector)
        #expect(detachedTool !== gcloudTool)
        #expect(detachedConnector.skill === detachedGCloudSkill)
        #expect(detachedTool.skill === detachedGCloudSkill)
        #expect(detachedConnector.workspace === detachedWorkspace)
        #expect(detachedTool.workspace === detachedWorkspace)
        #expect(
            detachedGCloudSkill.connectors.filter { $0.id == gcloudConnector.id }.count == 1
        )
        #expect(
            detachedGCloudSkill.localTools.filter { $0.id == gcloudTool.id }.count == 1
        )

        #expect(githubSkill.workspace == nil)
        #expect(gcloudSkill.workspace == nil)
        #expect(gcloudConnector.workspace == nil)
        #expect(gcloudTools.allSatisfy { $0.workspace == nil })
        #expect(gcloudConnector.skill === gcloudSkill)
        #expect(gcloudTool.skill === gcloudSkill)
        #expect(!workspace.skills.contains { $0.id == githubSkill.id || $0.id == gcloudSkill.id })
        #expect(!workspace.connectors.contains { $0.id == gcloudConnector.id })
        #expect(!workspace.localTools.contains { $0.id == gcloudTool.id })

        #expect(!detachedWorkspace.skills.contains { $0.id == unrelatedSkill.id })
        #expect(!detachedWorkspace.connectors.contains { $0.id == unrelatedConnector.id })
        #expect(!detachedWorkspace.localTools.contains { $0.id == unrelatedTool.id })

        let issues = CapabilityRuntimeIntegrityService.issues(
            for: detached,
            packages: [githubPackage, gcloudPackage],
            checkExecutables: false,
            scope: .fullInventory
        )
        let missingResourceKinds = issues
            .map { $0.resourceKind.rawValue }
            .filter { ["skill", "connector", "local_tool"].contains($0) }
        #expect(missingResourceKinds.isEmpty)
    }
}

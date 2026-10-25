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
    @Test("Queued request uses a detached immutable configuration and preserves editable state", arguments: [false, true])
    func buildsDetachedCompleteSnapshot(persisted: Bool) throws {
        let container = persisted ? try makeLaunchSnapshotContainer() : nil
        let context = container?.mainContext
        context?.autosaveEnabled = false
        let workspace = Workspace(name: "Queued workspace", primaryPath: "/tmp/queued-workspace")
        let task = AgentTask(title: "Queued", goal: "Run", workspace: workspace)
        let priorRun = TaskRun(task: task)
        priorRun.status = .completed
        let priorEvent = TaskEvent(task: task, type: TaskEventTypes.Conversation.userMessage.rawValue, payload: "prior", run: priorRun)
        priorEvent.agentName = "Researcher"
        priorEvent.agentId = "agent-1"
        priorEvent.teamName = "Research"
        priorEvent.category = "message"
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
        if let context {
            context.insert(workspace)
            context.insert(task)
            context.insert(request)
            try context.save()
        }

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
        let copiedEvent = try #require(launchTask.events.first { $0.id == priorEvent.id })
        #expect(copiedEvent.payload == priorEvent.payload)
        #expect(copiedEvent.timestamp == priorEvent.timestamp)
        #expect(copiedEvent.agentName == priorEvent.agentName)
        #expect(copiedEvent.agentId == priorEvent.agentId)
        #expect(copiedEvent.teamName == priorEvent.teamName)
        #expect(copiedEvent.category == priorEvent.category)
        #expect(copiedEvent.run?.id == priorRun.id)
        #expect(copiedEvent.run?.task === launchTask)
        #expect(launchTask.runs.contains { $0.id == priorRun.id })
        #expect(task.workspace === workspace)
        #expect(task.events.contains { $0.id == priorEvent.id })
        #expect(task.runs.contains { $0.id == priorRun.id })
        #expect(priorEvent.task === task)
        #expect(priorRun.task === task)
        #expect(launchTask.modelContext == nil)
        if let context {
            try context.save()
            #expect(try context.fetchCount(FetchDescriptor<AgentTask>()) == 1)
        }

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
        workspace.testEnabledCapabilityIDs = [githubPackage.id, gcloudPackage.id]
        context.insert(workspace)

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
        context.insert(gcloudConnector)
        let gcloudActivation = try #require(WorkspaceCapabilityActivation.activation(for: gcloudPackage.id, in: workspace))
        WorkspaceCapabilityActivation.bind(
            gcloudConnector,
            toComponent: CapabilityResourceOrigin.componentID(for: gcloudPackage.connectors[0]),
            of: gcloudActivation
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

        #expect(detached.modelContext == nil)
        #expect(Set(liveFullScope.behaviorSkills.map(\.id)) == Set(detachedFullScope.behaviorSkills.map(\.id)))
        #expect(Set(liveFullScope.connectors.map(\.id)) == Set(detachedFullScope.connectors.map(\.id)))
        #expect(Set(liveFullScope.localTools.map(\.id)) == Set(detachedFullScope.localTools.map(\.id)))
        #expect(Set(liveProviderScope.behaviorSkills.map(\.id)) == Set(detachedProviderScope.behaviorSkills.map(\.id)))
        #expect(Set(liveProviderScope.connectors.map(\.id)) == Set(detachedProviderScope.connectors.map(\.id)))
        #expect(Set(liveProviderScope.localTools.map(\.id)) == Set(detachedProviderScope.localTools.map(\.id)))
        #expect(
            liveProviderScope.resolver.resolvedEnvironmentVariables ==
                detachedProviderScope.resolver.resolvedEnvironmentVariables
        )

        // Both plugins' skills are projected, the bound shared account rides
        // along, and the detached copies wire only to each other.
        let liveSkillNames = Set(liveFullScope.behaviorSkills.map(\.name))
        #expect(liveSkillNames.isSuperset(of: Set((githubPackage.skills + gcloudPackage.skills).map(\.name))))
        let detachedConnector = try #require(detachedFullScope.connectors.first { $0.id == gcloudConnector.id })
        #expect(detachedConnector !== gcloudConnector)
        #expect(detachedConnector.config["GCP_PROJECT"] == "astra-test-project")
        let detachedGCloudTool = try #require(detachedFullScope.localTools.first { $0.command == "gcloud" })
        #expect(detachedGCloudTool.skill?.name == gcloudPackage.skills[0].name)
        #expect(detachedGCloudTool.skill?.modelContext == nil)
        #expect(gcloudConnector.skill == nil)
        #expect(gcloudConnector.workspace == nil)
        #expect(!workspace.connectors.contains { $0.id == gcloudConnector.id })

        #expect(!detachedFullScope.behaviorSkills.contains { $0.id == unrelatedSkill.id })
        #expect(!detachedFullScope.connectors.contains { $0.id == unrelatedConnector.id })
        #expect(!detachedFullScope.localTools.contains { $0.id == unrelatedTool.id })

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

    @Test("A row attached to an override after submission stays out of the launch, never as the workspace's own")
    func lateOverrideAttachmentsStayOutOfTheLaunch() throws {
        let fixture = try PluginMigrationFixture(authoredToolOnGCloudSkill: true)
        // Both submission and live resolution use the definitions migrated by
        // this fixture, independent of installed packages or approval records.
        let packs = AstraPackCatalog()
        let inputs = CapabilityResolutionInputs(
            libraryDirectory: CapabilityLibrary().directory.standardizedFileURL,
            packageDefinitions: fixture.packages,
            approvalsDirectory: CapabilityApprovalStore().directory.standardizedFileURL,
            approvalRecords: [],
            packBuiltInDirectory: packs.builtInDirectory?.standardizedFileURL,
            packLocalStorageRoot: packs.localStorageRoot?.standardizedFileURL,
            packCatalog: .init(entries: [], diagnostics: []))
        try CapabilityResolutionInputs.$pinned.withValue(inputs) {
            let context = fixture.context
            try PluginActivationMigration.migrate(modelContext: context, packages: fixture.packages)
            let a = try fixture.workspace(fixture.aID)
            let override = try #require(try context.fetch(FetchDescriptor<Skill>()).first { $0.id == fixture.gcloudSkillID })
            let submittedToolID = try #require(fixture.authoredToolID)
            // A's own connector, in its scope at submission on its own.
            let standalone = Connector(name: "Standalone", serviceType: "standalone_service", authMethod: "none")
            standalone.workspace = a
            context.insert(standalone)
            let acceptedStandaloneTool = LocalTool(name: "Already accepted", toolType: "cli", command: "echo", arguments: "accepted")
            acceptedStandaloneTool.workspace = a
            context.insert(acceptedStandaloneTool)
            let task = AgentTask(title: "A", goal: "Manage GCP resources", workspace: a)
            context.insert(task)
            let request = TaskTurnRequest(task: task, messageEventID: UUID(), sequence: 2, kind: .retry)
            context.insert(request)
            try context.save()

            // Moving an already accepted standalone tool must not erase it.
            acceptedStandaloneTool.skill = override
            // While it waits, new rows are attached to the override.
            let lateConnector = Connector(name: "Late", serviceType: "late_service", authMethod: "none")
            lateConnector.workspace = a
            lateConnector.skill = override
            let lateTool = LocalTool(name: "Late tool", toolDescription: "Attached later", toolType: "cli", command: "echo", arguments: "late")
            lateTool.workspace = a
            lateTool.skill = override
            context.insert(lateConnector)
            context.insert(lateTool)
            try context.save()
            #expect(TaskCapabilityResolver(task: task).allLocalTools.contains { $0.id == lateTool.id })

            let snapshot = try #require(TaskExecutionLaunchSnapshotApplicator.snapshot(request: request, from: task))
            #expect(snapshot.standaloneToolIDs?.contains(acceptedStandaloneTool.id) == true)
            let persisted = try JSONDecoder().decode(AgentTaskLaunchSnapshot.self, from: JSONEncoder().encode(snapshot))
            let detached = TaskExecutionLaunchSnapshotApplicator.detachedTask(persisted, from: task)
            let nested = TaskExecutionLaunchSnapshotApplicator.detachedTask(AgentTaskLaunchSnapshot(task: detached), from: detached)
            #expect(TaskCapabilityResolver(task: nested).allLocalTools.contains { $0.id == acceptedStandaloneTool.id })
            #expect(TaskExecutionPolicySnapshotV1(task: nested).standaloneToolIDs == snapshot.standaloneToolIDs)
            #expect(!TaskCapabilityResolver(task: nested).allLocalTools.contains { $0.id == lateTool.id })
            // Backward decoding must preserve unknown (nil), rather than
            // recapturing live rows as accepted during nested launches.
            let encoded = try JSONEncoder().encode(snapshot)
            var legacyJSON = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            legacyJSON.removeValue(forKey: "standaloneToolIDs")
            let legacy = try JSONDecoder().decode(AgentTaskLaunchSnapshot.self,
                from: JSONSerialization.data(withJSONObject: legacyJSON))
            let legacyTask = TaskExecutionLaunchSnapshotApplicator.detachedTask(legacy, from: task)
            #expect(AgentTaskLaunchSnapshot(task: legacyTask).standaloneToolIDs == nil)
            #expect(TaskExecutionPolicySnapshotV1(task: legacyTask).standaloneToolIDs == nil)
            legacyJSON["standaloneToolIDs"] = [] as [String]
            let empty = try JSONDecoder().decode(AgentTaskLaunchSnapshot.self,
                from: JSONSerialization.data(withJSONObject: legacyJSON))
            let emptyTask = TaskExecutionLaunchSnapshotApplicator.detachedTask(empty, from: task)
            #expect(AgentTaskLaunchSnapshot(task: emptyTask).standaloneToolIDs == [])
            let resolver = TaskCapabilityResolver(task: detached)
            #expect(!resolver.allConnectors.contains { $0.id == lateConnector.id })
            #expect(!resolver.allLocalTools.contains { $0.id == lateTool.id })
            #expect(detached.workspace?.connectors.contains { $0.id == lateConnector.id } == false)
            #expect(detached.workspace?.localTools.contains { $0.id == lateTool.id } == false)
            // What was in scope at submission still is.
            #expect(resolver.allLocalTools.contains { $0.id == acceptedStandaloneTool.id })
            #expect(resolver.allLocalTools.contains { $0.id == submittedToolID })
            #expect(resolver.allConnectors.contains { $0.id == standalone.id })
        }
    }
}

import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA
import ASTRACore

@Suite("Schema Versioning")
struct SchemaVersionTests {
    @Test("SchemaV1 declares all 10 model types")
    func v1ModelCount() {
        #expect(ASTRASchemaV1.models.count == 10)
    }

    @Test("SchemaV2 declares all 10 model types")
    func v2ModelCount() {
        #expect(ASTRASchemaV2.models.count == 10)
    }

    @Test("SchemaV3 declares all 10 model types")
    func v3ModelCount() {
        #expect(ASTRASchemaV3.models.count == 10)
    }

    @Test("SchemaV4 declares all 10 model types")
    func v4ModelCount() {
        #expect(ASTRASchemaV4.models.count == 10)
    }

    @Test("SchemaV5 declares all 10 model types")
    func v5ModelCount() {
        #expect(ASTRASchemaV5.models.count == 10)
    }

    @Test("SchemaV6 declares all 10 model types")
    func v6ModelCount() {
        #expect(ASTRASchemaV6.models.count == 10)
    }

    @Test("SchemaV7 declares all 10 model types")
    func v7ModelCount() {
        #expect(ASTRASchemaV7.models.count == 10)
    }

    @Test("Historical V7 and V8 schemas keep frozen core model identities")
    func historicalV7AndV8SchemasKeepFrozenCoreModelIdentities() {
        #expect(ASTRASchemaV7.models.contains { $0 == ASTRASchemaV7.Workspace.self })
        #expect(ASTRASchemaV7.models.contains { $0 == ASTRASchemaV7.AgentTask.self })
        #expect(!ASTRASchemaV7.models.contains { $0 == Workspace.self })
        #expect(!ASTRASchemaV7.models.contains { $0 == AgentTask.self })
        #expect(ASTRASchemaV8.models.contains { $0 == ASTRASchemaV8.Workspace.self })
        #expect(ASTRASchemaV8.models.contains { $0 == ASTRASchemaV8.AgentTask.self })
        #expect(!ASTRASchemaV8.models.contains { $0 == Workspace.self })
        #expect(!ASTRASchemaV8.models.contains { $0 == AgentTask.self })
        #expect(ASTRASchemaV8.models.contains { $0 == ASTRASchemaV8.WorkspaceApp.self })
        #expect(!ASTRASchemaV8.models.contains { $0 == WorkspaceApp.self })
    }

    @Test("SchemaV1 version identifier is 1.0.0")
    func v1VersionIdentifier() {
        #expect(ASTRASchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
    }

    @Test("SchemaV2 version identifier is 2.0.0")
    func v2VersionIdentifier() {
        #expect(ASTRASchemaV2.versionIdentifier == Schema.Version(2, 0, 0))
    }

    @Test("SchemaV3 version identifier is 3.0.0")
    func v3VersionIdentifier() {
        #expect(ASTRASchemaV3.versionIdentifier == Schema.Version(3, 0, 0))
    }

    @Test("SchemaV4 version identifier is 4.0.0")
    func v4VersionIdentifier() {
        #expect(ASTRASchemaV4.versionIdentifier == Schema.Version(4, 0, 0))
    }

    @Test("SchemaV5 version identifier is 5.0.0")
    func v5VersionIdentifier() {
        #expect(ASTRASchemaV5.versionIdentifier == Schema.Version(5, 0, 0))
    }

    @Test("SchemaV6 version identifier is 6.0.0")
    func v6VersionIdentifier() {
        #expect(ASTRASchemaV6.versionIdentifier == Schema.Version(6, 0, 0))
    }

    @Test("SchemaV7 version identifier is 7.0.0")
    func v7VersionIdentifier() {
        #expect(ASTRASchemaV7.versionIdentifier == Schema.Version(7, 0, 0))
    }

    @Test("SchemaV8 declares 15 model types (10 + 5 Workspace App models)")
    func v8ModelCount() {
        #expect(ASTRASchemaV8.models.count == 15)
    }

    @Test("SchemaV8 version identifier is 8.0.0")
    func v8VersionIdentifier() {
        #expect(ASTRASchemaV8.versionIdentifier == Schema.Version(8, 0, 0))
    }

    @Test("SchemaV9 declares 16 model types (V8 + Google OAuth account profiles)")
    func v9ModelCount() {
        #expect(ASTRASchemaV9.models.count == 16)
        #expect(ASTRASchemaV9.models.contains { $0 == ASTRASchemaV9.GoogleOAuthAccountProfile.self })
        #expect(!ASTRASchemaV9.models.contains { $0 == GoogleOAuthAccountProfile.self })
    }

    @Test("SchemaV9 version identifier is 9.0.0")
    func v9VersionIdentifier() {
        #expect(ASTRASchemaV9.versionIdentifier == Schema.Version(9, 0, 0))
    }

    @Test("SchemaV10 declares 16 model types and keeps pack profile fields on Workspace")
    func v10ModelCountAndPackProfileFields() {
        #expect(ASTRASchemaV10.models.count == 16)
        #expect(ASTRASchemaV10.models.contains { $0 == ASTRASchemaV10.GoogleOAuthAccountProfile.self })
        #expect(!ASTRASchemaV10.models.contains { $0 == AgentTask.self })
    }

    @Test("SchemaV10 version identifier is 10.0.0")
    func v10VersionIdentifier() {
        #expect(ASTRASchemaV10.versionIdentifier == Schema.Version(10, 0, 0))
    }

    @Test("SchemaV11 declares 16 model types and keeps typed runtime state fields")
    func v11ModelCountAndTypedRuntimeStateFields() {
        #expect(ASTRASchemaV11.models.count == 16)
        #expect(ASTRASchemaV11.models.contains { $0 == ASTRASchemaV11.AgentTask.self })
        #expect(ASTRASchemaV11.models.contains { $0 == ASTRASchemaV11.TaskRun.self })
        #expect(!ASTRASchemaV11.models.contains { $0 == AgentTask.self })
        #expect(!ASTRASchemaV11.models.contains { $0 == TaskRun.self })

        let task = ASTRASchemaV11.AgentTask()
        #expect(task.runtimePermissionOpenRequestsJSON == "[]")
        #expect(task.runtimePermissionGrantsJSON == "[]")

        let run = ASTRASchemaV11.TaskRun()
        #expect(run.providerLaunchSignatureJSON == nil)
    }

    @Test("SchemaV11 version identifier is 11.0.0")
    func v11VersionIdentifier() {
        #expect(ASTRASchemaV11.versionIdentifier == Schema.Version(11, 0, 0))
    }

    @MainActor
    @Test("SchemaV12 declares current model types and explicit-runtime-selection field")
    func v12ModelCountAndExplicitRuntimeSelectionField() throws {
        #expect(ASTRASchemaV12.models.count == 16)
        #expect(ASTRASchemaV12.models.contains { $0 == AgentTask.self })
        #expect(ASTRASchemaV12.models.contains { $0 == TaskRun.self })

        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [config]
        )
        let context = container.mainContext
        let task = AgentTask(title: "Typed State", goal: "Verify typed state")
        context.insert(task)
        let run = TaskRun(task: task)
        context.insert(run)
        try context.save()

        #expect(task.runtimeExplicitlySelected == false)
        #expect(task.runtimePermissionOpenRequestsJSON == "[]")
        #expect(task.runtimePermissionGrantsJSON == "[]")
        #expect(run.providerLaunchSignatureJSON == nil)
    }

    @Test("SchemaV12 version identifier is 12.0.0")
    func v12VersionIdentifier() {
        #expect(ASTRASchemaV12.versionIdentifier == Schema.Version(12, 0, 0))
    }

    @Test("Migration plan lists SchemaV1 through SchemaV12")
    func migrationPlanHasVersions() {
        #expect(ASTRAMigrationPlan.schemas.count == 12)
    }

    @Test("Migration plan has V1 to V12 lightweight stages")
    func migrationPlanHasStage() {
        #expect(ASTRAMigrationPlan.stages.count == 11)
    }

    @Test("ModelContainer can be created with versioned schema")
    func containerCreation() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [config]
        )
        #expect(container.schema.entities.count == 16)
    }

    @MainActor
    @Test("Versioned container supports full CRUD cycle")
    func crudCycle() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [config]
        )
        let context = container.mainContext

        let workspace = Workspace(name: "Test", primaryPath: "/tmp/schema-test")
        context.insert(workspace)
        #expect(workspace.enabledGlobalToolIDs.isEmpty)
        #expect(workspace.enabledCapabilityIDs.isEmpty)
        #expect(workspace.isStarred == false)
        #expect(workspace.activeWorkingPath == nil)
        #expect(workspace.activeExecutionEnvironmentJSON == nil)

        let skill = Skill(name: "Reader", allowedTools: ["Read"])
        skill.workspace = workspace
        context.insert(skill)

        let connector = Connector(name: "API", serviceType: "rest_api")
        connector.workspace = workspace
        context.insert(connector)

        let tool = LocalTool(name: "Build", command: "swift build")
        tool.workspace = workspace
        context.insert(tool)

        #expect(skill.originPackageID == nil)
        #expect(connector.originPackageID == nil)
        #expect(tool.originPackageID == nil)

        let task = AgentTask(title: "Test Task", goal: "Do something", workspace: workspace)
        task.skills = [skill]
        #expect(task.executionRootPath == nil)
        #expect(ExecutionEnvironmentStore.decode(task.executionEnvironmentSnapshotJSON).isHost)
        context.insert(task)

        let run = TaskRun(task: task)
        #expect(ExecutionEnvironmentStore.decode(run.executionEnvironmentSnapshotJSON).isHost)
        context.insert(run)

        let event = TaskEvent(task: task, type: "test", run: run)
        context.insert(event)

        let artifact = Artifact(task: task, type: "file", path: "/tmp/out.txt")
        context.insert(artifact)

        let template = TaskTemplate(name: "Build", mainGoal: "Build it", workspace: workspace)
        context.insert(template)
        #expect(template.originPackageID == nil)

        let schedule = TaskSchedule(name: "Hourly", workspace: workspace)
        context.insert(schedule)
        #expect(schedule.resolvedRuntimeID == .claudeCode)

        try context.save()

        let workspaces = try context.fetch(FetchDescriptor<Workspace>())
        #expect(workspaces.count == 1)
        #expect(workspaces[0].tasks.count == 1)
        #expect(workspaces[0].skills.count == 1)
        #expect(workspaces[0].connectors.count == 1)
        #expect(workspaces[0].localTools.count == 1)
        #expect(workspaces[0].templates.count == 1)
        #expect(workspaces[0].schedules.count == 1)

        let tasks = try context.fetch(FetchDescriptor<AgentTask>())
        #expect(tasks[0].runs.count == 1)
        #expect(tasks[0].events.count == 1)
        #expect(tasks[0].artifacts.count == 1)
        #expect(tasks[0].skills.count == 1)
    }

    @MainActor
    @Test("SchemaV1 store migrates to current runtime and unread fields")
    func legacyStoreMigratesToCurrentFields() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-schema-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storeURL = root.appendingPathComponent("store.store")
        var oldContainer: ModelContainer? = try ModelContainer(
            for: Schema(versionedSchema: ASTRASchemaV1.self),
            configurations: [ModelConfiguration(url: storeURL)]
        )

        let oldContext = try #require(oldContainer?.mainContext)
        let oldWorkspace = ASTRASchemaV1.Workspace()
        oldWorkspace.name = "Legacy"
        oldWorkspace.primaryPath = "/tmp/legacy"
        oldContext.insert(oldWorkspace)

        let oldTask = ASTRASchemaV1.AgentTask()
        oldTask.title = "Legacy Task"
        oldTask.goal = "Do work"
        oldTask.workspace = oldWorkspace
        oldContext.insert(oldTask)

        let oldRun = ASTRASchemaV1.TaskRun()
        oldRun.task = oldTask
        oldRun.output = "done"
        oldContext.insert(oldRun)

        let oldSchedule = ASTRASchemaV1.TaskSchedule()
        oldSchedule.name = "Legacy Schedule"
        oldSchedule.goal = "Review"
        oldSchedule.workspace = oldWorkspace
        oldContext.insert(oldSchedule)

        try oldContext.save()
        oldContainer = nil

        let migratedContainer = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(url: storeURL)]
        )
        let context = migratedContainer.mainContext
        let tasks = try context.fetch(FetchDescriptor<AgentTask>())
        let migratedTask = try #require(tasks.first)
        #expect(migratedTask.resolvedRuntimeID == .claudeCode)
        #expect(migratedTask.unreadAt == nil)
        #expect((migratedTask.runtimePermissionOpenRequestsJSON ?? "[]") == "[]")
        #expect((migratedTask.runtimePermissionGrantsJSON ?? "[]") == "[]")
        #expect(migratedTask.runtimeExplicitlySelected == false)

        let runs = try context.fetch(FetchDescriptor<TaskRun>())
        let migratedRun = try #require(runs.first)
        #expect(migratedRun.runtimeID == nil)
        #expect(migratedRun.providerSessionId == nil)
        #expect(migratedRun.providerVersion == nil)
        #expect(migratedRun.providerLaunchSignatureJSON == nil)

        let schedules = try context.fetch(FetchDescriptor<TaskSchedule>())
        let migratedSchedule = try #require(schedules.first)
        #expect(migratedSchedule.resolvedRuntimeID == .claudeCode)
    }

    @MainActor
    @Test("SchemaV2 store migrates to SchemaV3 unread fields")
    func v2StoreMigratesToUnreadFields() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-schema-v2-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storeURL = root.appendingPathComponent("store.store")
        var oldContainer: ModelContainer? = try ModelContainer(
            for: Schema(versionedSchema: ASTRASchemaV2.self),
            configurations: [ModelConfiguration(url: storeURL)]
        )

        let oldContext = try #require(oldContainer?.mainContext)
        let oldWorkspace = ASTRASchemaV2.Workspace()
        oldWorkspace.name = "Legacy V2"
        oldWorkspace.primaryPath = "/tmp/legacy-v2"
        oldContext.insert(oldWorkspace)

        let oldTask = ASTRASchemaV2.AgentTask()
        oldTask.title = "Legacy V2 Task"
        oldTask.goal = "Do work"
        oldTask.workspace = oldWorkspace
        oldContext.insert(oldTask)

        try oldContext.save()
        oldContainer = nil

        let migratedContainer = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(url: storeURL)]
        )
        let context = migratedContainer.mainContext
        let tasks = try context.fetch(FetchDescriptor<AgentTask>())
        let migratedTask = try #require(tasks.first)
        #expect(migratedTask.resolvedRuntimeID == .claudeCode)
        #expect(migratedTask.unreadAt == nil)
    }

    @MainActor
    @Test("SchemaV3 store migrates to SchemaV4 starred workspace field")
    func v3StoreMigratesToStarredWorkspaceField() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-schema-v3-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storeURL = root.appendingPathComponent("store.store")
        var oldContainer: ModelContainer? = try ModelContainer(
            for: Schema(versionedSchema: ASTRASchemaV3.self),
            configurations: [ModelConfiguration(url: storeURL)]
        )

        let oldContext = try #require(oldContainer?.mainContext)
        let oldWorkspace = ASTRASchemaV3.Workspace()
        oldWorkspace.name = "Legacy V3"
        oldWorkspace.primaryPath = "/tmp/legacy-v3"
        oldContext.insert(oldWorkspace)

        try oldContext.save()
        oldContainer = nil

        let migratedContainer = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(url: storeURL)]
        )
        let context = migratedContainer.mainContext
        let workspaces = try context.fetch(FetchDescriptor<Workspace>())
        let migratedWorkspace = try #require(workspaces.first)
        #expect(migratedWorkspace.isStarred == false)
    }

    @MainActor
    @Test("SchemaV4 store migrates to SchemaV5 origin fields")
    func v4StoreMigratesToOriginFields() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-schema-v4-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storeURL = root.appendingPathComponent("store.store")
        var oldContainer: ModelContainer? = try ModelContainer(
            for: Schema(versionedSchema: ASTRASchemaV4.self),
            configurations: [ModelConfiguration(url: storeURL)]
        )

        let oldContext = try #require(oldContainer?.mainContext)
        let oldWorkspace = ASTRASchemaV4.Workspace()
        oldWorkspace.name = "Legacy V4"
        oldWorkspace.primaryPath = "/tmp/legacy-v4"
        oldContext.insert(oldWorkspace)

        let oldSkill = ASTRASchemaV4.Skill()
        oldSkill.name = "Legacy Skill"
        oldSkill.workspace = oldWorkspace
        oldContext.insert(oldSkill)

        let oldConnector = ASTRASchemaV4.Connector()
        oldConnector.name = "Legacy Connector"
        oldConnector.workspace = oldWorkspace
        oldContext.insert(oldConnector)

        let oldTool = ASTRASchemaV4.LocalTool()
        oldTool.name = "legacy-tool"
        oldTool.workspace = oldWorkspace
        oldContext.insert(oldTool)

        let oldTemplate = ASTRASchemaV4.TaskTemplate()
        oldTemplate.name = "Legacy Template"
        oldTemplate.workspace = oldWorkspace
        oldContext.insert(oldTemplate)

        try oldContext.save()
        oldContainer = nil

        let migratedContainer = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(url: storeURL)]
        )
        let context = migratedContainer.mainContext
        #expect(try context.fetch(FetchDescriptor<Skill>()).first?.originPackageID == nil)
        #expect(try context.fetch(FetchDescriptor<Connector>()).first?.originPackageID == nil)
        #expect(try context.fetch(FetchDescriptor<LocalTool>()).first?.originPackageID == nil)
        #expect(try context.fetch(FetchDescriptor<TaskTemplate>()).first?.originPackageID == nil)
    }

    @MainActor
    @Test("SchemaV5 store migrates to SchemaV6 worktree binding fields")
    func v5StoreMigratesToWorktreeFields() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-schema-v5-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storeURL = root.appendingPathComponent("store.store")
        var oldContainer: ModelContainer? = try ModelContainer(
            for: Schema(versionedSchema: ASTRASchemaV5.self),
            configurations: [ModelConfiguration(url: storeURL)]
        )

        let oldContext = try #require(oldContainer?.mainContext)
        let oldWorkspace = ASTRASchemaV5.Workspace()
        oldWorkspace.name = "Legacy V5"
        oldWorkspace.primaryPath = "/tmp/legacy-v5"
        oldContext.insert(oldWorkspace)

        let oldTask = ASTRASchemaV5.AgentTask()
        oldTask.title = "Legacy V5 Task"
        oldTask.goal = "Do work"
        oldTask.workspace = oldWorkspace
        oldContext.insert(oldTask)

        try oldContext.save()
        oldContainer = nil

        let migratedContainer = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(url: storeURL)]
        )
        let context = migratedContainer.mainContext
        let migratedWorkspace = try #require(try context.fetch(FetchDescriptor<Workspace>()).first)
        #expect(migratedWorkspace.activeWorkingPath == nil)
        #expect(migratedWorkspace.activeExecutionEnvironmentJSON == nil)
        #expect(migratedWorkspace.isUsingWorktree == false)

        let migratedTask = try #require(try context.fetch(FetchDescriptor<AgentTask>()).first)
        #expect(migratedTask.executionRootPath == nil)
        #expect(migratedTask.executionEnvironmentSnapshotJSON == nil)

        let migratedRuns = try context.fetch(FetchDescriptor<TaskRun>())
        #expect(migratedRuns.allSatisfy { $0.executionEnvironmentSnapshotJSON == nil })
    }

    @MainActor
    @Test("Previous schema store migrates to empty pack profile workspace fields")
    func previousSchemaStoreMigratesToEmptyPackProfileWorkspaceFields() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-schema-pack-profile-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storeURL = root.appendingPathComponent("store.store")
        var oldContainer: ModelContainer? = try ModelContainer(
            for: Schema(versionedSchema: ASTRASchemaV5.self),
            configurations: [ModelConfiguration(url: storeURL)]
        )

        let oldContext = try #require(oldContainer?.mainContext)
        let oldWorkspace = ASTRASchemaV5.Workspace()
        oldWorkspace.name = "Legacy Profile"
        oldWorkspace.primaryPath = "/tmp/legacy-profile"
        oldContext.insert(oldWorkspace)
        try oldContext.save()
        oldContainer = nil

        let migratedContainer = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(url: storeURL)]
        )
        let context = migratedContainer.mainContext
        let migratedWorkspace = try #require(try context.fetch(FetchDescriptor<Workspace>()).first)
        #expect(migratedWorkspace.enabledPackIDs.isEmpty)
        #expect(migratedWorkspace.shelfVisibilityOverrideIDs.isEmpty)
        #expect(migratedWorkspace.shelfVisibilityOverrideValues.isEmpty)
        #expect(migratedWorkspace.shelfVisibilityOverrides.isEmpty)
    }

    @MainActor
    @Test("SchemaV9 store migrates directly to empty pack profile workspace fields")
    func v9StoreMigratesToEmptyPackProfileWorkspaceFields() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-schema-v9-pack-profile-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storeURL = root.appendingPathComponent("store.store")
        var oldContainer: ModelContainer? = try ModelContainer(
            for: Schema(versionedSchema: ASTRASchemaV9.self),
            configurations: [ModelConfiguration(url: storeURL)]
        )

        let oldContext = try #require(oldContainer?.mainContext)
        let oldWorkspace = ASTRASchemaV9.Workspace()
        oldWorkspace.name = "Legacy V9 Profile"
        oldWorkspace.primaryPath = "/tmp/legacy-v9-profile"
        oldContext.insert(oldWorkspace)
        try oldContext.save()
        oldContainer = nil

        let migratedContainer = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(url: storeURL)]
        )
        let context = migratedContainer.mainContext
        let migratedWorkspace = try #require(try context.fetch(FetchDescriptor<Workspace>()).first)
        #expect(migratedWorkspace.enabledPackIDs.isEmpty)
        #expect(migratedWorkspace.shelfVisibilityOverrideIDs.isEmpty)
        #expect(migratedWorkspace.shelfVisibilityOverrideValues.isEmpty)
        #expect(migratedWorkspace.shelfVisibilityOverrides.isEmpty)
    }

    @MainActor
    @Test("SchemaV7 store (main's released 10-entity schema) migrates to V8 and gains the 5 Workspace App tables")
    func v7StoreMigratesToWorkspaceAppTables() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-schema-v7-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Write a store at main's V7 (10 core entities, NO Workspace App tables).
        let storeURL = root.appendingPathComponent("store.store")
        var oldContainer: ModelContainer? = try ModelContainer(
            for: Schema(versionedSchema: ASTRASchemaV7.self),
            configurations: [ModelConfiguration(url: storeURL)]
        )
        let oldContext = try #require(oldContainer?.mainContext)
        let oldWorkspace = ASTRASchemaV7.Workspace()
        oldWorkspace.name = "Legacy V7"
        oldWorkspace.primaryPath = "/tmp/legacy-v7"
        oldContext.insert(oldWorkspace)
        let oldTask = ASTRASchemaV7.AgentTask()
        oldTask.title = "Legacy V7 Task"
        oldTask.goal = "Do work"
        oldTask.workspace = oldWorkspace
        oldContext.insert(oldTask)
        let oldRun = ASTRASchemaV7.TaskRun()
        oldRun.task = oldTask
        oldContext.insert(oldRun)
        try oldContext.save()
        // Capture the id BEFORE tearing down the old container — the model instance is faulted/destroyed
        // once its container is released, so reading `oldWorkspace.id` afterward would crash.
        let oldWorkspaceID = oldWorkspace.id
        oldContainer = nil

        // Reopen at current through the migration plan: the V7 -> V8 lightweight stage must
        // create the 5 additive Workspace App tables while later stages preserve core rows.
        let migratedContainer = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(url: storeURL)]
        )
        let context = migratedContainer.mainContext

        // Existing core rows survive the migration.
        #expect(try context.fetch(FetchDescriptor<Workspace>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<AgentTask>()).count == 1)

        // The 5 new tables exist (an empty fetch would THROW if the table were missing) and are writable.
        #expect(try context.fetch(FetchDescriptor<WorkspaceApp>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<WorkspaceAppRun>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<WorkspaceAppRunEvent>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<WorkspaceAppDependencyBinding>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<WorkspaceAppAutomationState>()).isEmpty)

        let app = WorkspaceApp(
            workspaceID: oldWorkspaceID,
            logicalID: "legacy-v7-app",
            name: "Migrated App",
            manifestRelativePath: "apps/legacy-v7-app/manifest.json",
            appDirectoryRelativePath: "apps/legacy-v7-app",
            manifestDigest: "deadbeef"
        )
        context.insert(app)
        try context.save()
        let apps = try context.fetch(FetchDescriptor<WorkspaceApp>())
        #expect(apps.count == 1)
        #expect(apps.first?.name == "Migrated App")
    }

    @MainActor
    @Test("SchemaV7 store with a real non-host execution-environment payload survives migration to current byte-identical")
    func v7StoreCarriesNonHostExecutionEnvironmentPayloadThroughMigration() throws {
        // This exercises what the nil-only assertions elsewhere in this file don't: an actual
        // populated WorkspaceExecutionEnvironment (with credential projections) written as JSON
        // before the schema-version boundary, reopened under the current schema, decoded back,
        // and checked for exact equality/round-trip fidelity — not just "field is nil".
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("astra-schema-v7-env-payload-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let gcpADCHostPath = (root.path as NSString).appendingPathComponent(".config/gcloud")
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: gcpADCHostPath),
            withIntermediateDirectories: true
        )

        let nonHostEnvironment = WorkspaceExecutionEnvironment(
            id: "image:legacy-v7-env",
            kind: .dockerImage,
            displayName: "Legacy V7 Environment",
            image: "astra/legacy:v7",
            credentialProjections: [
                ExecutionEnvironmentCredentialProjection.gcpADC(hostPath: gcpADCHostPath)
            ]
        )
        let encodedEnvironmentJSON = try #require(ExecutionEnvironmentStore.encode(nonHostEnvironment))

        let storeURL = root.appendingPathComponent("store.store")
        var oldContainer: ModelContainer? = try ModelContainer(
            for: Schema(versionedSchema: ASTRASchemaV7.self),
            configurations: [ModelConfiguration(url: storeURL)]
        )
        let oldContext = try #require(oldContainer?.mainContext)

        let oldWorkspace = ASTRASchemaV7.Workspace()
        oldWorkspace.name = "Legacy V7 With Environment"
        oldWorkspace.primaryPath = "/tmp/legacy-v7-env"
        oldWorkspace.activeExecutionEnvironmentJSON = encodedEnvironmentJSON
        oldContext.insert(oldWorkspace)

        let oldTask = ASTRASchemaV7.AgentTask()
        oldTask.title = "Legacy V7 Task With Environment"
        oldTask.goal = "Do work in a container"
        oldTask.workspace = oldWorkspace
        oldTask.executionEnvironmentSnapshotJSON = encodedEnvironmentJSON
        oldContext.insert(oldTask)

        let oldRun = ASTRASchemaV7.TaskRun()
        oldRun.task = oldTask
        oldRun.executionEnvironmentSnapshotJSON = encodedEnvironmentJSON
        oldContext.insert(oldRun)

        try oldContext.save()
        oldContainer = nil

        let migratedContainer = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(url: storeURL)]
        )
        let context = migratedContainer.mainContext

        let migratedWorkspace = try #require(try context.fetch(FetchDescriptor<Workspace>()).first)
        let migratedTask = try #require(try context.fetch(FetchDescriptor<AgentTask>()).first)
        let migratedRun = try #require(try context.fetch(FetchDescriptor<TaskRun>()).first)

        // The raw JSON string is byte-identical post-migration (lightweight migration must not
        // touch a field it doesn't declare a transform for).
        #expect(migratedWorkspace.activeExecutionEnvironmentJSON == encodedEnvironmentJSON)
        #expect(migratedTask.executionEnvironmentSnapshotJSON == encodedEnvironmentJSON)
        #expect(migratedRun.executionEnvironmentSnapshotJSON == encodedEnvironmentJSON)

        // And it decodes back to the exact same non-host environment, not `.host`.
        let decodedWorkspaceEnvironment = ExecutionEnvironmentStore.decode(migratedWorkspace.activeExecutionEnvironmentJSON)
        let decodedTaskEnvironment = ExecutionEnvironmentStore.decode(migratedTask.executionEnvironmentSnapshotJSON)
        let decodedRunEnvironment = ExecutionEnvironmentStore.decode(migratedRun.executionEnvironmentSnapshotJSON)

        #expect(!decodedWorkspaceEnvironment.isHost)
        #expect(decodedWorkspaceEnvironment == nonHostEnvironment)
        #expect(!decodedTaskEnvironment.isHost)
        #expect(decodedTaskEnvironment == nonHostEnvironment)
        #expect(!decodedRunEnvironment.isHost)
        #expect(decodedRunEnvironment == nonHostEnvironment)
        #expect(decodedTaskEnvironment.credentialProjections?.first?.kind == .gcpADC)
    }
}

import Foundation
import SwiftData
import Testing
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

    @Test("Migration plan lists SchemaV1 through SchemaV7")
    func migrationPlanHasVersions() {
        #expect(ASTRAMigrationPlan.schemas.count == 7)
    }

    @Test("Migration plan has V1 to V7 lightweight stages")
    func migrationPlanHasStage() {
        #expect(ASTRAMigrationPlan.stages.count == 6)
    }

    @Test("ModelContainer can be created with versioned schema")
    func containerCreation() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [config]
        )
        #expect(container.schema.entities.count == 10)
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

        let runs = try context.fetch(FetchDescriptor<TaskRun>())
        let migratedRun = try #require(runs.first)
        #expect(migratedRun.runtimeID == nil)
        #expect(migratedRun.providerSessionId == nil)
        #expect(migratedRun.providerVersion == nil)

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
}

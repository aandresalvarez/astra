import Foundation
import SwiftData
import Testing
@testable import ASTRA

@Suite("Schema Versioning")
struct SchemaVersionTests {

    @Test("SchemaV1 declares all 10 model types")
    func v1ModelCount() {
        #expect(ASTRASchemaV1.models.count == 10)
    }

    @Test("SchemaV1 version identifier is 1.0.0")
    func v1VersionIdentifier() {
        #expect(ASTRASchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
    }

    @Test("Migration plan lists SchemaV1")
    func migrationPlanHasV1() {
        #expect(ASTRAMigrationPlan.schemas.count == 1)
    }

    @Test("Migration plan has no stages for single version")
    func migrationPlanNoStages() {
        #expect(ASTRAMigrationPlan.stages.isEmpty)
    }

    @Test("ModelContainer can be created with versioned schema")
    func containerCreation() throws {
        let schema = Schema(ASTRASchemaV1.models)
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [config]
        )
        #expect(container.schema.entities.count == 10)
    }

    @MainActor
    @Test("Versioned container supports full CRUD cycle")
    func crudCycle() throws {
        let schema = Schema(ASTRASchemaV1.models)
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [config]
        )
        let context = container.mainContext

        let workspace = Workspace(name: "Test", primaryPath: "/tmp/schema-test")
        context.insert(workspace)

        let skill = Skill(name: "Reader", allowedTools: ["Read"])
        skill.workspace = workspace
        context.insert(skill)

        let connector = Connector(name: "API", serviceType: "rest_api")
        connector.workspace = workspace
        context.insert(connector)

        let tool = LocalTool(name: "Build", command: "swift build")
        tool.workspace = workspace
        context.insert(tool)

        let task = AgentTask(title: "Test Task", goal: "Do something", workspace: workspace)
        task.skills = [skill]
        context.insert(task)

        let run = TaskRun(task: task)
        context.insert(run)

        let event = TaskEvent(task: task, type: "test", run: run)
        context.insert(event)

        let artifact = Artifact(task: task, type: "file", path: "/tmp/out.txt")
        context.insert(artifact)

        let template = TaskTemplate(name: "Build", mainGoal: "Build it", workspace: workspace)
        context.insert(template)

        let schedule = TaskSchedule(name: "Hourly", workspace: workspace)
        context.insert(schedule)

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
}

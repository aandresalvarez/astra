import Foundation
import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("SwiftData reversible deletion")
@MainActor
struct SwiftDataDeletionPreparationTests {
    @Test("Repeated rollback preserves empty and populated relationship graphs", arguments: [false, true], [false, true])
    func rollbackPreservesGraph(onDisk: Bool, populated: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-deletion-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try ModelContainer(
            for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: onDisk ? ModelConfiguration(url: root.appendingPathComponent("test.store"))
                : ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let seed = ModelContext(container)
        let original = Workspace(name: "Rollback", primaryPath: root.path)
        seed.insert(original)
        if populated {
            let task = AgentTask(title: "Keep me", goal: "goal", workspace: original)
            let skill = Skill(name: "Keep skill")
            original.skills = [skill]
            task.skills = [skill]
            let connector = Connector(name: "Keep connector", serviceType: "jira")
            let tool = LocalTool(name: "Keep tool")
            original.connectors = [connector]
            original.localTools = [tool]
            skill.connectors = [connector]
            skill.localTools = [tool]
            original.templates = [TaskTemplate(name: "Keep template", mainGoal: "goal", workspace: original)]
            original.schedules = [TaskSchedule(name: "Keep schedule", workspace: original)]
            seed.insert(task)
            seed.insert(TaskRun(task: task))
            seed.insert(TaskEvent(task: task, type: "test", payload: "{}"))
            seed.insert(Artifact(task: task, type: "file", path: root.appendingPathComponent("keep.txt").path))
        }
        try seed.save()

        // A fresh context leaves relationships faulted, as after opening a
        // workspace. In particular, empty arrays must also resolve before delete.
        let context = ModelContext(container)
        let workspace = try #require(try context.fetch(FetchDescriptor<Workspace>()).first)
        for _ in 0..<3 {
            SwiftDataDeletionPreparation.prepare(workspace)
            context.delete(workspace)
            context.rollback()
            workspace.name = "Still usable"
            try context.save()
            let expected = populated ? 1 : 0
            #expect(workspace.tasks.count == expected)
            #expect(workspace.skills.count == expected)
            #expect(workspace.connectors.count == expected)
            #expect(workspace.localTools.count == expected)
            #expect(workspace.templates.count == expected)
            #expect(workspace.schedules.count == expected)
            if populated {
                #expect(workspace.skills.first?.workspace === workspace)
                #expect(workspace.connectors.first?.workspace === workspace)
                #expect(workspace.localTools.first?.workspace === workspace)
                #expect(workspace.templates.first?.workspace === workspace)
                #expect(workspace.schedules.first?.workspace === workspace)
            }
            if let task = workspace.tasks.first {
                #expect(task.workspace === workspace)
                #expect(task.runs.count == 1)
                #expect(task.events.count == 1)
                #expect(task.artifacts.count == 1)
                #expect(task.skills.count == 1)
                #expect(workspace.skills.first?.tasks.first === task)
            }
        }
        // A subsequent successful deletion still performs the whole cascade.
        SwiftDataDeletionPreparation.prepare(workspace)
        context.delete(workspace)
        try context.save()
        let durable = ModelContext(container)
        #expect(try durable.fetchCount(FetchDescriptor<Workspace>()) == 0)
        #expect(try durable.fetchCount(FetchDescriptor<AgentTask>()) == 0)
        #expect(try durable.fetchCount(FetchDescriptor<TaskTemplate>()) == 0)
        #expect(try durable.fetchCount(FetchDescriptor<TaskSchedule>()) == 0)
    }

    @Test("Task-only rollback preserves its workspace and shared skill")
    func taskOnlyRollback() throws {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let seed = ModelContext(container)
        let workspace = Workspace(name: "Keep workspace", primaryPath: NSTemporaryDirectory())
        let task = AgentTask(title: "Keep task", goal: "goal", workspace: workspace)
        let skill = Skill(name: "Shared")
        skill.isGlobal = true
        task.skills = [skill]
        seed.insert(task)
        seed.insert(TaskTemplate(name: "Keep template", mainGoal: "goal", workspace: workspace))
        try seed.save()
        let context = ModelContext(container)
        let stored = try #require(try context.fetch(FetchDescriptor<AgentTask>()).first)
        for _ in 0..<3 {
            SwiftDataDeletionPreparation.prepare(stored)
            context.delete(stored)
            context.rollback()
            try context.save()
            #expect(stored.workspace?.tasks.first === stored)
            #expect(stored.workspace?.templates.count == 1)
            #expect(stored.skills.first?.tasks.first === stored)
        }
    }

}

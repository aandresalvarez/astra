import SwiftData
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Rail environment context")
@MainActor
struct WorkspaceRailEnvironmentContextTests {
    @Test("The rail follows a persisted composer worktree draft without a selected task")
    func composerDraft() throws {
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let draft = AgentTask(title: "Draft", goal: "Draft")
        draft.executionRootPath = "/tmp/prepared-draft"
        container.mainContext.insert(draft)
        try container.mainContext.save()
        #expect(WorkspaceRailEnvironmentLifecycle.repositoryTask(selectedTask: nil, preparedDraft: draft) === draft)
        let selected = AgentTask(title: "Selected", goal: "Selected")
        #expect(WorkspaceRailEnvironmentLifecycle.repositoryTask(selectedTask: selected, preparedDraft: draft) === selected)
        container.mainContext.delete(draft)
        #expect(WorkspaceRailEnvironmentLifecycle.repositoryTask(selectedTask: nil, preparedDraft: draft) == nil)
    }

    @Test("Environment signatures distinguish imported owners and workspace folder edits")
    func contextIdentity() throws {
        let container = try ModelContainer(for: ASTRASchema.current, migrationPlan: ASTRAMigrationPlan.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let workspace = Workspace(name: "Context", primaryPath: "/tmp/root")
        let original = AgentTask(title: "A", goal: "A", workspace: workspace)
        let copy = AgentTask(title: "B", goal: "B", workspace: workspace)
        copy.id = original.id
        container.mainContext.insert(workspace); container.mainContext.insert(original); container.mainContext.insert(copy)
        try container.mainContext.save()
        let before = WorkspaceRailEnvironmentLifecycle.RepositoryContext(workspace: workspace, task: original, enabled: true)
        #expect(before != .init(workspace: workspace, task: copy, enabled: true))
        workspace.additionalPaths = ["/tmp/new"]
        #expect(before != .init(workspace: workspace, task: original, enabled: true))
    }
}

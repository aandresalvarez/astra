import Foundation
import SwiftData
import Testing
@testable import ASTRA

@Suite("Workspace Command Service")
struct WorkspaceCommandServiceTests {
    @MainActor
    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let workspace: Workspace
        let root: URL
    }

    @MainActor
    private static func makeFixture() throws -> Fixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-command-service-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Slash Commands", primaryPath: root.path)
        context.insert(workspace)
        return Fixture(container: container, context: context, workspace: workspace, root: root)
    }

    @MainActor
    @Test("createSkill persists workspace skill with safe default tools")
    func createSkillPersistsWorkspaceSkillWithSafeDefaultTools() throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let skill = WorkspaceCommandService.createSkill(
            name: "Review Helper",
            behaviorInstructions: "Summarize PR risk.",
            allowedTools: [],
            disallowedTools: ["Bash"],
            workspace: fixture.workspace,
            modelContext: fixture.context,
            source: "slash-command-test"
        )

        #expect(skill.workspace?.id == fixture.workspace.id)
        #expect(skill.allowedTools == Skill.defaultAllowed)
        #expect(skill.disallowedTools == ["Bash"])
        #expect(skill.behaviorInstructions == "Summarize PR risk.")

        let fetched = try fixture.context.fetch(FetchDescriptor<Skill>())
        #expect(fetched.contains { $0.id == skill.id })
    }

    @MainActor
    @Test("createTool persists typed local tool metadata")
    func createToolPersistsTypedLocalToolMetadata() throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let tool = WorkspaceCommandService.createTool(
            name: "linear-search",
            toolType: "mcp",
            command: "mcp__linear__search_issues",
            description: "Search Linear issues.",
            workspace: fixture.workspace,
            modelContext: fixture.context,
            source: "slash-command-test"
        )

        #expect(tool.workspace?.id == fixture.workspace.id)
        #expect(tool.toolType == "mcp")
        #expect(tool.command == "mcp__linear__search_issues")
        #expect(tool.toolDescription == "Search Linear issues.")
        #expect(tool.icon == LocalTool.iconForType("mcp"))

        let fetched = try fixture.context.fetch(FetchDescriptor<LocalTool>())
        #expect(fetched.contains { $0.id == tool.id })
    }

    @MainActor
    @Test("createConnector persists non-secret connector metadata")
    func createConnectorPersistsNonSecretConnectorMetadata() throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let connector = WorkspaceCommandService.createConnector(
            name: "Jira",
            serviceType: "jira",
            baseURL: "https://jira.example.test",
            authMethod: "bearer",
            credentials: [:],
            workspace: fixture.workspace,
            modelContext: fixture.context,
            source: "slash-command-test"
        )

        #expect(connector.workspace?.id == fixture.workspace.id)
        #expect(connector.serviceType == "jira")
        #expect(connector.icon == WorkspaceCommandService.connectorIcon(for: "jira"))
        #expect(connector.baseURL == "https://jira.example.test")
        #expect(connector.authMethod == "bearer")
        #expect(connector.credentialKeys.isEmpty)

        let fetched = try fixture.context.fetch(FetchDescriptor<Connector>())
        #expect(fetched.contains { $0.id == connector.id })
    }
}

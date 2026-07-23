import Foundation
import SwiftData
import Testing
import ASTRAModels
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

        let (connector, failedCredentialKeys) = WorkspaceCommandService.createConnector(
            name: "Jira",
            serviceType: "jira",
            baseURL: "https://jira.example.test",
            authMethod: "bearer",
            credentials: [:],
            workspace: fixture.workspace,
            modelContext: fixture.context,
            source: "slash-command-test"
        )

        #expect(failedCredentialKeys.isEmpty)

        #expect(connector.workspace?.id == fixture.workspace.id)
        #expect(connector.serviceType == "jira")
        #expect(connector.icon == WorkspaceCommandService.connectorIcon(for: "jira"))
        #expect(connector.baseURL == "https://jira.example.test")
        #expect(connector.authMethod == "bearer")
        #expect(connector.credentialKeys.isEmpty)

        let fetched = try fixture.context.fetch(FetchDescriptor<Connector>())
        #expect(fetched.contains { $0.id == connector.id })
    }

    @MainActor
    @Test("Template main task persists one initial execution request")
    func templateMainPersistsInitialExecutionRequest() throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let template = TaskTemplate(name: "Review", mainGoal: "Review the change", workspace: fixture.workspace)
        fixture.context.insert(template)

        let creation = WorkspaceCommandService.createTemplateTasks(
            template: template,
            taskTitle: "Review",
            variables: [:],
            selectedSkills: [],
            defaultModel: "",
            defaultRuntimeID: "claude_code",
            workspace: fixture.workspace,
            modelContext: fixture.context,
            source: "test"
        )

        let requests = try TaskTurnRequestRepository.requests(for: creation.mainTask, in: fixture.context)
        let request = try #require(requests.first)
        #expect(requests.count == 1)
        #expect(request.kind == .initial)
        #expect(creation.mainTask.events.contains {
            $0.id == request.sourceEventID && $0.type == TaskEventTypes.ExecutionRequest.initial.rawValue
        })
    }

    @MainActor
    @Test("Template before phase is the only initially runnable request")
    func templateBeforePhaseOwnsInitialExecutionRequest() throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let template = TaskTemplate(name: "Review", mainGoal: "Review the change", workspace: fixture.workspace)
        template.beforeGoal = "Prepare the checkout"
        fixture.context.insert(template)

        let creation = WorkspaceCommandService.createTemplateTasks(
            template: template,
            taskTitle: "Review",
            variables: [:],
            selectedSkills: [],
            defaultModel: "",
            defaultRuntimeID: "claude_code",
            workspace: fixture.workspace,
            modelContext: fixture.context,
            source: "test"
        )

        let before = try #require(creation.beforeTask)
        #expect(try TaskTurnRequestRepository.requests(for: before, in: fixture.context).count == 1)
        #expect(try TaskTurnRequestRepository.requests(for: creation.mainTask, in: fixture.context).isEmpty)
        #expect(before.status == .queued)
        #expect(creation.mainTask.status == .draft)
    }

    @MainActor
    @Test("Failed template submission leaves no queued task without a durable request", arguments: [false, true])
    func failedTemplateSubmissionRestoresDraftState(hasBeforePhase: Bool) throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let template = TaskTemplate(name: "Review", mainGoal: "Review the change", workspace: fixture.workspace)
        if hasBeforePhase {
            template.beforeGoal = "Prepare the checkout"
        }
        fixture.context.insert(template)

        let creation = WorkspaceCommandService.createTemplateTasks(
            template: template,
            taskTitle: "Review",
            variables: [:],
            selectedSkills: [],
            defaultModel: "",
            defaultRuntimeID: "claude_code",
            workspace: fixture.workspace,
            modelContext: fixture.context,
            source: "test",
            submitInitial: { _, _ in .failure(.persistenceFailed("forced_test_failure")) }
        )

        let tasks = try fixture.context.fetch(FetchDescriptor<AgentTask>())
        let requests = try fixture.context.fetch(FetchDescriptor<TaskTurnRequest>())
        #expect(tasks.count == (hasBeforePhase ? 2 : 1))
        #expect(tasks.allSatisfy { $0.status == .draft })
        #expect(requests.isEmpty)
        #expect(creation.mainTask.status == .draft)
        #expect(creation.beforeTask?.status != .queued)
    }
}

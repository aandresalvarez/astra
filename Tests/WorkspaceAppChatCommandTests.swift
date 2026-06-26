import Foundation
import SwiftData
import Testing
@testable import ASTRA

/// `/app` in chat is only a launch affordance for the real Workspace App Studio flow.
/// It must not own deterministic app generation or publish persistence.
@Suite("Workspace App Chat Routing")
struct WorkspaceAppChatCommandTests {
    @MainActor
    private struct Fixture {
        var container: ModelContainer
        var workspace: Workspace
        var context: ModelContext
        var root: URL
    }

    @MainActor
    private static func makeFixture() throws -> Fixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wsapp-chat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspace = Workspace(name: "Apps", primaryPath: root.path)
        context.insert(workspace)
        return Fixture(container: container, workspace: workspace, context: context, root: root)
    }

    @Test("'/app' opens a blank App Studio composer")
    func emptyCommandRoutesToBlankStudio() throws {
        let request = try #require(WorkspaceAppChatCommand.launchRequest(input: "  /app  "))
        #expect(request.initialPrompt == nil)
    }

    @Test("'/app <description>' carries the description into App Studio")
    func describedCommandRoutesWithInitialPrompt() throws {
        let request = try #require(WorkspaceAppChatCommand.launchRequest(input: "/app Build me a PR tracker."))
        #expect(request.initialPrompt == "Build me a PR tracker.")
    }

    @Test("'/app' parser treats the command as a token")
    func appCommandParserTreatsCommandAsToken() throws {
        let request = try #require(WorkspaceAppChatCommand.launchRequest(input: "  /APP\tBuild me a PR tracker.  "))
        #expect(request.initialPrompt == "Build me a PR tracker.")
    }

    @Test("similar slash commands do not route to App Studio")
    func nonAppCommandsDoNotMatch() {
        #expect(WorkspaceAppChatCommand.launchRequest(input: "/application build") == nil)
        #expect(WorkspaceAppChatCommand.launchRequest(input: "/appstore build") == nil)
        #expect(WorkspaceAppChatCommand.launchRequest(input: "/recap /app build") == nil)
    }

    @MainActor
    @Test("routing /app has no direct publish side effects")
    func routeDoesNotPublishDirectly() throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let request = try #require(WorkspaceAppChatCommand.launchRequest(input: "/app Build me a grocery database app."))

        #expect(request.initialPrompt == "Build me a grocery database app.")
        let apps = try fixture.context.fetch(FetchDescriptor<WorkspaceApp>())
            .filter { $0.workspaceID == fixture.workspace.id }
        #expect(apps.isEmpty)
    }
}

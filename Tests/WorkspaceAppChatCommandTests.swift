import Foundation
import SwiftData
import Testing
@testable import ASTRA

/// Slice 1b: the `/app` chat command generates + publishes a Workspace App from a one-line
/// description (the working path; the chat view's SlashWizard subsystem is vestigial).
@Suite("Workspace App Chat Command (Slice 1b)")
struct WorkspaceAppChatCommandTests {
    @MainActor
    private struct Fixture {
        var container: ModelContainer  // retained so context + models stay valid
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

    @MainActor
    @Test("'/app' with no description prompts for one")
    func emptyIntentPrompts() throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let reply = WorkspaceAppChatCommand.reply(input: "/app", workspace: fixture.workspace, modelContext: fixture.context)
        #expect(reply.contains("Describe the app"))
    }

    @MainActor
    @Test("'/app' with no workspace asks to select one")
    func noWorkspaceSelected() throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let reply = WorkspaceAppChatCommand.reply(input: "/app a grocery app", workspace: nil, modelContext: fixture.context)
        #expect(reply.contains("Select a workspace"))
    }

    @MainActor
    @Test("'/app <description>' generates and publishes a Workspace App")
    func generatesApp() throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let reply = WorkspaceAppChatCommand.reply(
            input: "/app Build me a grocery database app.",
            workspace: fixture.workspace, modelContext: fixture.context
        )
        #expect(reply.contains("created"))
        let apps = try fixture.context.fetch(FetchDescriptor<WorkspaceApp>())
            .filter { $0.workspaceID == fixture.workspace.id }
        #expect(apps.count == 1)
        #expect(apps.first?.lifecycleStatus == .published)
    }
}

import Foundation
import Testing
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Workspace App Studio Draft Open Resolver")
struct WorkspaceAppStudioDraftOpenResolverTests {
    @MainActor
    @Test("draft apps route to Studio with their persisted manifest")
    func draftAppRoutesToStudioWithManifest() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-app-draft-open-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = Workspace(name: "Drafts", primaryPath: root.path)
        let manifest = WorkspaceAppStudioBuilder.localDatabaseManifest(intent: "notes")
        let manifestURL = URL(fileURLWithPath: WorkspaceFileLayout.appManifestFile(
            workspacePath: workspace.primaryPath,
            appID: manifest.app.id
        ))
        try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try WorkspaceAppService.encodeManifest(manifest).write(to: manifestURL)
        let app = makeApp(workspace: workspace, manifest: manifest, lifecycleStatus: .draft)

        let route = try #require(WorkspaceAppStudioDraftOpenResolver.route(
            app: app,
            workspaces: [workspace],
            fallbackWorkspace: nil
        ))

        #expect(route.workspace.id == workspace.id)
        #expect(route.manifest.app.id == manifest.app.id)
    }

    @MainActor
    @Test("draft app open failures are explicit instead of falling through to app detail")
    func draftAppOpenFailureIsExplicit() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-app-draft-open-missing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = Workspace(name: "Drafts", primaryPath: root.path)
        let manifest = WorkspaceAppStudioBuilder.localDatabaseManifest(intent: "notes")
        let app = makeApp(workspace: workspace, manifest: manifest, lifecycleStatus: .draft)

        let resolution = WorkspaceAppStudioDraftOpenResolver.resolve(
            app: app,
            workspaces: [workspace],
            fallbackWorkspace: nil
        )

        if case .failed(let failure) = resolution {
            #expect(failure.workspace?.id == workspace.id)
            #expect(failure.detail.contains("manifest.json"))
        } else {
            Issue.record("Expected a failed draft-open resolution, got \(resolution)")
        }
        #expect(WorkspaceAppStudioDraftOpenResolver.route(
            app: app,
            workspaces: [workspace],
            fallbackWorkspace: nil
        ) == nil)
    }

    @MainActor
    @Test("published apps do not route through the draft Studio path")
    func publishedAppDoesNotRouteThroughDraftStudioPath() {
        let workspace = Workspace(name: "Published", primaryPath: "/tmp/published")
        let manifest = WorkspaceAppStudioBuilder.localDatabaseManifest(intent: "published notes")
        let app = makeApp(workspace: workspace, manifest: manifest, lifecycleStatus: .published)

        let route = WorkspaceAppStudioDraftOpenResolver.route(
            app: app,
            workspaces: [workspace],
            fallbackWorkspace: nil
        )

        #expect(route?.manifest.app.id == nil)
    }

    @MainActor
    private func makeApp(
        workspace: Workspace,
        manifest: WorkspaceAppManifest,
        lifecycleStatus: WorkspaceAppLifecycleStatus
    ) -> WorkspaceApp {
        WorkspaceApp(
            workspaceID: workspace.id,
            logicalID: manifest.app.id,
            name: manifest.app.name,
            lifecycleStatus: lifecycleStatus,
            manifestRelativePath: WorkspaceFileLayout.relativeAppManifestFile(appID: manifest.app.id),
            appDirectoryRelativePath: WorkspaceFileLayout.relativeAppDirectory(appID: manifest.app.id),
            manifestDigest: "digest"
        )
    }
}

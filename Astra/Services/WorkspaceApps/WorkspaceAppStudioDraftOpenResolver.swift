import Foundation

struct WorkspaceAppStudioDraftOpenRoute {
    var workspace: Workspace
    var manifest: WorkspaceAppManifest
}

enum WorkspaceAppStudioDraftOpenResolver {
    static func route(
        app: WorkspaceApp?,
        workspaces: [Workspace],
        fallbackWorkspace: Workspace?,
        manifestStore: WorkspaceAppManifestStore = WorkspaceAppManifestStore()
    ) -> WorkspaceAppStudioDraftOpenRoute? {
        guard let app, app.lifecycleStatus == .draft else { return nil }
        guard let workspace = workspaces.first(where: { $0.id == app.workspaceID }) ?? fallbackWorkspace else { return nil }
        do {
            let manifest = try manifestStore.loadManifest(app: app, workspace: workspace).manifest
            return WorkspaceAppStudioDraftOpenRoute(workspace: workspace, manifest: manifest)
        } catch {
            AppLogger.error("Draft app resume failed for \(app.logicalID): \(error)", category: "WorkspaceApps")
            return nil
        }
    }
}

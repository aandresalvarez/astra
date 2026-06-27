import Foundation

struct WorkspaceAppStudioDraftOpenRoute {
    var workspace: Workspace
    var manifest: WorkspaceAppManifest
}

struct WorkspaceAppStudioDraftOpenFailure {
    var workspace: Workspace?
    var detail: String
}

enum WorkspaceAppStudioDraftOpenResolution {
    case unavailable
    case routed(WorkspaceAppStudioDraftOpenRoute)
    case failed(WorkspaceAppStudioDraftOpenFailure)
}

enum WorkspaceAppStudioDraftOpenResolver {
    static func resolve(
        app: WorkspaceApp?,
        workspaces: [Workspace],
        fallbackWorkspace: Workspace?,
        manifestStore: WorkspaceAppManifestStore = WorkspaceAppManifestStore()
    ) -> WorkspaceAppStudioDraftOpenResolution {
        guard let app else { return .unavailable }
        guard app.lifecycleStatus == .draft else { return .unavailable }
        guard let workspace = workspaces.first(where: { $0.id == app.workspaceID }) ?? fallbackWorkspace else {
            return .failed(WorkspaceAppStudioDraftOpenFailure(
                workspace: nil,
                detail: "The workspace for this draft app could not be found."
            ))
        }
        do {
            let manifest = try manifestStore.loadManifest(app: app, workspace: workspace).manifest
            return .routed(WorkspaceAppStudioDraftOpenRoute(workspace: workspace, manifest: manifest))
        } catch {
            AppLogger.error("Draft app resume failed for \(app.logicalID): \(error)", category: "WorkspaceApps")
            return .failed(WorkspaceAppStudioDraftOpenFailure(
                workspace: workspace,
                detail: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            ))
        }
    }

    static func route(
        app: WorkspaceApp?,
        workspaces: [Workspace],
        fallbackWorkspace: Workspace?,
        manifestStore: WorkspaceAppManifestStore = WorkspaceAppManifestStore()
    ) -> WorkspaceAppStudioDraftOpenRoute? {
        if case .routed(let route) = resolve(
            app: app,
            workspaces: workspaces,
            fallbackWorkspace: fallbackWorkspace,
            manifestStore: manifestStore
        ) {
            return route
        }
        return nil
    }
}

import Foundation
import SwiftData

struct WorkspaceAppStudioDraftAutosaveScope: Equatable {
    enum AppQuery: Equatable {
        case preferredWorkspace(UUID)
        case editingLogicalID(String)
    }

    let appQuery: AppQuery

    init(preferredWorkspaceID: UUID, editingLogicalID: String?) {
        let trimmedLogicalID = editingLogicalID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedLogicalID.isEmpty {
            appQuery = .preferredWorkspace(preferredWorkspaceID)
        } else {
            appQuery = .editingLogicalID(trimmedLogicalID)
        }
    }
}

/// App-facing autosave coordinator for Studio drafts.
///
/// Fetching SwiftData context belongs at the app boundary, while create/update rules belong to
/// `WorkspaceAppStudioDraftPersistenceService`. This coordinator keeps that wiring out of
/// `ContentView` without giving the service hidden access to app state.
enum WorkspaceAppStudioDraftAutosaveCoordinator {
    @MainActor
    static func autosave(
        session: WorkspaceAppStudioSession,
        preferredWorkspace: Workspace?,
        modelContext: ModelContext,
        persistenceService: WorkspaceAppStudioDraftPersistenceService = WorkspaceAppStudioDraftPersistenceService()
    ) {
        guard let workspace = preferredWorkspace, let draft = session.draft else { return }
        do {
            let scope = WorkspaceAppStudioDraftAutosaveScope(
                preferredWorkspaceID: workspace.id,
                editingLogicalID: session.editingAppLogicalID
            )
            let apps = try fetchApps(scope: scope, modelContext: modelContext)
            let workspaces = try fetchWorkspaces(
                preferredWorkspace: workspace,
                appWorkspaceIDs: apps.map(\.workspaceID),
                modelContext: modelContext
            )
            guard let result = try persistenceService.saveDraft(
                draft,
                journal: session.journal,
                existingLogicalID: session.editingAppLogicalID,
                sessionWorkspaceID: session.workspaceID,
                preferredWorkspace: workspace,
                workspaces: workspaces,
                apps: apps,
                modelContext: modelContext
            ) else {
                return
            }
            let targetWorkspace = workspaces.first { $0.id == result.app.workspaceID } ?? workspace
            session.bindPersistedDraft(appID: result.app.logicalID, workspacePath: targetWorkspace.primaryPath)
        } catch {
            AppLogger.error("App Studio draft autosave failed: \(error)", category: "WorkspaceApps")
            session.noteDraftSaveFailure((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    @MainActor
    private static func fetchApps(
        scope: WorkspaceAppStudioDraftAutosaveScope,
        modelContext: ModelContext
    ) throws -> [WorkspaceApp] {
        switch scope.appQuery {
        case .preferredWorkspace(let workspaceID):
            return try modelContext.fetch(FetchDescriptor<WorkspaceApp>(
                predicate: #Predicate<WorkspaceApp> { app in
                    app.workspaceID == workspaceID
                }
            ))
        case .editingLogicalID(let logicalID):
            return try modelContext.fetch(FetchDescriptor<WorkspaceApp>(
                predicate: #Predicate<WorkspaceApp> { app in
                    app.logicalID == logicalID
                }
            ))
        }
    }

    @MainActor
    private static func fetchWorkspaces(
        preferredWorkspace: Workspace,
        appWorkspaceIDs: [UUID],
        modelContext: ModelContext
    ) throws -> [Workspace] {
        var workspaces = [preferredWorkspace]
        var seen = Set([preferredWorkspace.id])
        for workspaceID in appWorkspaceIDs where !seen.contains(workspaceID) {
            let descriptor = FetchDescriptor<Workspace>(
                predicate: #Predicate<Workspace> { workspace in
                    workspace.id == workspaceID
                }
            )
            if let workspace = try modelContext.fetch(descriptor).first {
                workspaces.append(workspace)
            }
            seen.insert(workspaceID)
        }
        return workspaces
    }
}

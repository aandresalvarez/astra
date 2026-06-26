import Foundation
import SwiftData

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
        let apps = (try? modelContext.fetch(FetchDescriptor<WorkspaceApp>())) ?? []
        let workspaces = (try? modelContext.fetch(FetchDescriptor<Workspace>())) ?? []
        do {
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
}

import Foundation
import SwiftData

/// Autosaves App Studio creations as durable draft apps.
///
/// The service is deliberately small: it turns a verified Studio draft into either a new
/// `WorkspaceApp` with lifecycle `.draft`, or an in-place update to an existing draft app. It refuses
/// to mutate published apps, because editing a live app remains an explicit Publish action.
struct WorkspaceAppStudioDraftPersistenceService {
    var appService = WorkspaceAppService()
    var journalStore: WorkspaceAppStudioJournalStoring = WorkspaceAppStudioJournalService()

    @MainActor
    func saveDraft(
        _ draft: WorkspaceAppStudioDraft,
        journal: WorkspaceAppStudioJournal,
        existingLogicalID: String?,
        sessionWorkspaceID: UUID?,
        preferredWorkspace: Workspace,
        workspaces: [Workspace],
        apps: [WorkspaceApp],
        modelContext: ModelContext
    ) throws -> WorkspaceAppCreationResult? {
        guard shouldPersist(draft: draft, journal: journal) else { return nil }

        if let existing = existingDraftTarget(
            logicalID: existingLogicalID,
            sessionWorkspaceID: sessionWorkspaceID,
            apps: apps
        ) {
            guard existing.lifecycleStatus == .draft else { return nil }
            guard let workspace = workspace(for: existing, preferredWorkspace: preferredWorkspace, workspaces: workspaces) else {
                return nil
            }
            let result = try appService.updateApp(
                existing,
                manifest: draft.manifest,
                in: workspace,
                modelContext: modelContext,
                status: .draft
            )
            journalStore.save(journal, appID: result.app.logicalID, workspacePath: workspace.primaryPath)
            return result
        }

        guard existingLogicalID == nil else { return nil }
        let manifest = WorkspaceAppStudioBuilder.manifestForPublishing(
            draft.manifest,
            existingLogicalIDs: Set(apps.filter { $0.workspaceID == preferredWorkspace.id }.map(\.logicalID))
        )
        let result = try appService.createApp(
            manifest: manifest,
            in: preferredWorkspace,
            modelContext: modelContext,
            status: .draft
        )
        journalStore.save(journal, appID: result.app.logicalID, workspacePath: preferredWorkspace.primaryPath)
        return result
    }

    private func shouldPersist(
        draft: WorkspaceAppStudioDraft,
        journal: WorkspaceAppStudioJournal
    ) -> Bool {
        guard draft.canPublish,
              let event = journal.events.last,
              event.accepted,
              let data = try? WorkspaceAppService.encodeManifest(draft.manifest)
        else {
            return false
        }
        return event.manifestDigest == WorkspaceAppService.digest(for: data)
    }

    private func existingDraftTarget(
        logicalID: String?,
        sessionWorkspaceID: UUID?,
        apps: [WorkspaceApp]
    ) -> WorkspaceApp? {
        guard let logicalID else { return nil }
        if let sessionWorkspaceID,
           let exact = apps.first(where: { $0.logicalID == logicalID && $0.workspaceID == sessionWorkspaceID }) {
            return exact
        }
        return apps.first { $0.logicalID == logicalID }
    }

    private func workspace(
        for app: WorkspaceApp,
        preferredWorkspace: Workspace,
        workspaces: [Workspace]
    ) -> Workspace? {
        if app.workspaceID == preferredWorkspace.id { return preferredWorkspace }
        return workspaces.first { $0.id == app.workspaceID }
    }
}

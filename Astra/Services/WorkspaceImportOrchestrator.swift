import Foundation
import SwiftData

struct WorkspaceImportResult {
    let imported: [Workspace]

    var selectedWorkspace: Workspace? {
        imported.last
    }
}

@MainActor
struct WorkspaceImportOrchestrator {
    let modelContext: ModelContext
    let taskQueue: TaskQueue

    func importWorkspaces(
        from urls: [URL],
        existingWorkspaces: [Workspace],
        askDuplicateAction: (String, Int) -> TaskLifecycleCoordinator.DuplicateAction
    ) -> WorkspaceImportResult {
        let coordinator = TaskLifecycleCoordinator(modelContext: modelContext, taskQueue: taskQueue)
        var imported: [Workspace] = []
        var knownWorkspaces = existingWorkspaces

        for candidate in WorkspaceImportDiscovery.candidates(for: urls) {
            let workspace: Workspace?
            if let configURL = candidate.configURL {
                workspace = coordinator.importFromConfig(
                    at: configURL,
                    existingWorkspaces: knownWorkspaces,
                    askDuplicateAction: askDuplicateAction
                )
            } else {
                workspace = coordinator.createWorkspaceFromFolder(
                    candidate.folderURL,
                    existingWorkspaces: knownWorkspaces,
                    askDuplicateAction: askDuplicateAction
                )
            }

            if let workspace {
                imported.append(workspace)
                knownWorkspaces.append(workspace)
            }
        }

        for workspace in imported {
            coordinator.importSessionsIfNeeded(for: workspace)
        }

        do {
            try modelContext.save()
        } catch {
            AppLogger.audit(.workspaceExported, category: "UI", fields: [
                "operation": "save_imported_workspaces",
                "error_type": String(describing: type(of: error))
            ], level: .error)
        }

        for workspace in imported {
            WorkspaceConfigManager.autoExport(workspace: workspace, modelContext: modelContext)
        }

        if !imported.isEmpty {
            AppLogger.audit(.workspaceImported, category: "App", fields: [
                "workspace_count": String(imported.count)
            ])
        }

        return WorkspaceImportResult(imported: imported)
    }
}

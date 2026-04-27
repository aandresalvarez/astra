import Foundation
import SwiftData

@MainActor
enum WorkspacePersistenceCoordinator {
    private static var pendingExports: [UUID: Task<Void, Never>] = [:]

    static func saveAndAutoExport(workspace: Workspace?, modelContext: ModelContext) {
        do {
            try modelContext.save()
        } catch {
            AppLogger.audit(.workspaceExported, category: "Persistence", fields: [
                "result": "swiftdata_save_failed",
                "error_type": String(describing: type(of: error))
            ], level: .error)
        }

        guard let workspace else { return }
        WorkspaceConfigManager.autoExport(workspace: workspace, modelContext: modelContext)
    }

    static func scheduleAutoExport(
        workspace: Workspace?,
        modelContext: ModelContext,
        delayNanoseconds: UInt64 = 600_000_000
    ) {
        guard let workspace else {
            saveAndAutoExport(workspace: nil, modelContext: modelContext)
            return
        }

        let workspaceID = workspace.id
        pendingExports[workspaceID]?.cancel()
        pendingExports[workspaceID] = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            pendingExports[workspaceID] = nil
            saveAndAutoExport(workspace: workspace, modelContext: modelContext)
        }
    }

    static func flushPendingExport(workspace: Workspace?, modelContext: ModelContext) {
        if let id = workspace?.id {
            pendingExports[id]?.cancel()
            pendingExports[id] = nil
        }
        saveAndAutoExport(workspace: workspace, modelContext: modelContext)
    }
}

import Foundation
import SwiftData

@MainActor
enum WorkspacePersistenceCoordinator {
    private static var pendingExports: [UUID: Task<Void, Never>] = [:]

    @discardableResult
    static func saveAndAutoExport(
        workspace: Workspace?,
        modelContext: ModelContext,
        taskID: UUID? = nil,
        auditFields: [String: String] = [:]
    ) -> Bool {
        var didSave = false
        do {
            try modelContext.save()
            didSave = true
            if taskID != nil || !auditFields.isEmpty {
                var fields = auditFields
                fields["result"] = "swiftdata_save_succeeded"
                fields["workspace_id"] = workspace?.id.uuidString ?? "none"
                AppLogger.audit(.runtimePersistenceSummary, category: "Persistence", taskID: taskID, fields: fields, level: .debug)
            }
        } catch {
            var fields = auditFields
            fields["result"] = "swiftdata_save_failed"
            fields["workspace_id"] = workspace?.id.uuidString ?? "none"
            fields["error_type"] = String(describing: type(of: error))
            AppLogger.audit(.runtimePersistenceSummary, category: "Persistence", taskID: taskID, fields: fields, level: .error)
            AppLogger.audit(.workspaceExported, category: "Persistence", fields: [
                "result": "swiftdata_save_failed",
                "error_type": String(describing: type(of: error))
            ], level: .error)
        }

        guard let workspace else { return didSave }
        guard !shouldSkipAutoExport() else {
            AppLogger.audit(.workspaceExported, category: "Persistence", fields: [
                "result": "skipped",
                "reason": "launch_flag"
            ], level: .debug)
            return didSave
        }
        WorkspaceConfigManager.autoExport(workspace: workspace, modelContext: modelContext)
        return didSave
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

    nonisolated static func shouldSkipAutoExport(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if arguments.contains("--skip-workspace-auto-export") ||
            arguments.contains("--skip-workspace-recovery") {
            return true
        }
        return ["1", "true", "yes"].contains(
            environment["ASTRA_SKIP_WORKSPACE_AUTO_EXPORT"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        )
    }
}

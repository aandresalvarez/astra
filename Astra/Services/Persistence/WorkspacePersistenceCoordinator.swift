import Foundation
import SwiftData
import ASTRAModels
import ASTRACore

@MainActor
public enum WorkspacePersistenceCoordinator {
    /// The workspace is retained alongside its timer so a termination flush can
    /// write the pending mirror without re-fetching it from the store.
    private struct PendingExport {
        let workspace: Workspace
        let task: Task<Void, Never>
    }

    private static var pendingExports: [UUID: PendingExport] = [:]

    @discardableResult
    public static func saveAndAutoExport(
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
                AuditLoggingSeam.required.audit(.runtimePersistenceSummary, category: "Persistence", taskID: taskID, fields: fields, level: .debug)
            }
        } catch {
            var fields = auditFields
            fields["result"] = "swiftdata_save_failed"
            fields["workspace_id"] = workspace?.id.uuidString ?? "none"
            fields["error_type"] = String(describing: type(of: error))
            AuditLoggingSeam.required.audit(.runtimePersistenceSummary, category: "Persistence", taskID: taskID, fields: fields, level: .error)
            AuditLoggingSeam.required.audit(.workspaceExported, category: "Persistence", fields: [
                "result": "swiftdata_save_failed",
                "error_type": String(describing: type(of: error))
            ], level: .error)
        }

        guard didSave else { return didSave }
        guard let workspace else { return didSave }
        guard !shouldSkipAutoExport() else {
            AuditLoggingSeam.required.audit(.workspaceExported, category: "Persistence", fields: [
                "result": "skipped",
                "reason": "launch_flag"
            ], level: .debug)
            return didSave
        }
        WorkspaceConfigManager.autoExport(workspace: workspace, modelContext: modelContext)
        return didSave
    }

    /// Persists the SwiftData context without exporting the workspace JSON
    /// mirror, returning whether the save succeeded (mirrors `saveAndAutoExport`'s
    /// non-throwing style, not `saveWithoutAutoExportOrThrow` — this has no
    /// `workspace` parameter since it never exports, and records `auto_export`
    /// as "skipped" rather than "deferred"). For bookkeeping saves whose state
    /// is guaranteed to be superseded by a later, more authoritative
    /// save-and-export call (e.g. pre-admission lock events), so the mirror
    /// is never snapshotted mid-transition.
    ///
    /// `auditsSuccess: false` keeps `taskID`/`auditFields` attributing the
    /// *failure* while paying nothing on the success path. Every other caller
    /// here is a once-per-lifecycle event, but the transcript's pre-read flush
    /// runs once per invalidation while a task streams: `AppLogger.emit` is not
    /// level-gated, so even a `.debug` audit sanitizes fields, writes os_log,
    /// posts a notification and queues two file appends on the calling thread.
    @discardableResult
    public static func saveWithoutAutoExport(
        modelContext: ModelContext,
        taskID: UUID? = nil,
        auditFields: [String: String] = [:],
        auditsSuccess: Bool = true
    ) -> Bool {
        do {
            try modelContext.save()
            if auditsSuccess, taskID != nil || !auditFields.isEmpty {
                var fields = auditFields
                fields["result"] = "swiftdata_save_succeeded"
                fields["auto_export"] = "skipped"
                AuditLoggingSeam.required.audit(.runtimePersistenceSummary, category: "Persistence", taskID: taskID, fields: fields, level: .debug)
            }
            return true
        } catch {
            var fields = auditFields
            fields["result"] = "swiftdata_save_failed"
            fields["auto_export"] = "skipped"
            fields["error_type"] = String(describing: type(of: error))
            AuditLoggingSeam.required.audit(.runtimePersistenceSummary, category: "Persistence", taskID: taskID, fields: fields, level: .error)
            return false
        }
    }

    public static func saveAndAutoExportOrThrow(
        workspace: Workspace?,
        modelContext: ModelContext,
        taskID: UUID? = nil,
        auditFields: [String: String] = [:]
    ) throws {
        do {
            try modelContext.save()
            if taskID != nil || !auditFields.isEmpty {
                var fields = auditFields
                fields["result"] = "swiftdata_save_succeeded"
                fields["workspace_id"] = workspace?.id.uuidString ?? "none"
                AuditLoggingSeam.required.audit(.runtimePersistenceSummary, category: "Persistence", taskID: taskID, fields: fields, level: .debug)
            }
        } catch {
            var fields = auditFields
            fields["result"] = "swiftdata_save_failed"
            fields["workspace_id"] = workspace?.id.uuidString ?? "none"
            fields["error_type"] = String(describing: type(of: error))
            AuditLoggingSeam.required.audit(.runtimePersistenceSummary, category: "Persistence", taskID: taskID, fields: fields, level: .error)
            AuditLoggingSeam.required.audit(.workspaceExported, category: "Persistence", fields: [
                "result": "swiftdata_save_failed",
                "error_type": String(describing: type(of: error))
            ], level: .error)
            throw error
        }

        guard let workspace else { return }
        guard !shouldSkipAutoExport() else {
            AuditLoggingSeam.required.audit(.workspaceExported, category: "Persistence", fields: [
                "result": "skipped",
                "reason": "launch_flag"
            ], level: .debug)
            return
        }
        WorkspaceConfigManager.autoExport(workspace: workspace, modelContext: modelContext)
    }

    public static func saveWithoutAutoExportOrThrow(
        workspace: Workspace?,
        modelContext: ModelContext,
        taskID: UUID? = nil,
        auditFields: [String: String] = [:]
    ) throws {
        do {
            try modelContext.save()
            if taskID != nil || !auditFields.isEmpty {
                var fields = auditFields
                fields["result"] = "swiftdata_save_succeeded"
                fields["workspace_id"] = workspace?.id.uuidString ?? "none"
                fields["auto_export"] = "deferred"
                AuditLoggingSeam.required.audit(.runtimePersistenceSummary, category: "Persistence", taskID: taskID, fields: fields, level: .debug)
            }
        } catch {
            var fields = auditFields
            fields["result"] = "swiftdata_save_failed"
            fields["workspace_id"] = workspace?.id.uuidString ?? "none"
            fields["auto_export"] = "deferred"
            fields["error_type"] = String(describing: type(of: error))
            AuditLoggingSeam.required.audit(.runtimePersistenceSummary, category: "Persistence", taskID: taskID, fields: fields, level: .error)
            AuditLoggingSeam.required.audit(.workspaceExported, category: "Persistence", fields: [
                "result": "swiftdata_save_failed",
                "error_type": String(describing: type(of: error))
            ], level: .error)
            throw error
        }
    }

    public static func scheduleAutoExport(
        workspace: Workspace?,
        modelContext: ModelContext,
        delayNanoseconds: UInt64 = 600_000_000
    ) {
        guard let workspace else {
            saveAndAutoExport(workspace: nil, modelContext: modelContext)
            return
        }

        let workspaceID = workspace.id
        pendingExports[workspaceID]?.task.cancel()
        pendingExports[workspaceID] = PendingExport(
            workspace: workspace,
            task: Task { @MainActor in
                do {
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                pendingExports[workspaceID] = nil
                saveAndAutoExport(workspace: workspace, modelContext: modelContext)
            }
        )
    }

    public static func flushPendingExport(workspace: Workspace?, modelContext: ModelContext) {
        if let id = workspace?.id {
            pendingExports[id]?.task.cancel()
            pendingExports[id] = nil
        }
        saveAndAutoExport(workspace: workspace, modelContext: modelContext)
    }

    /// Workspaces whose debounced mirror export has not fired yet.
    public static var pendingExportWorkspaceCount: Int { pendingExports.count }

    /// Writes every debounced mirror export that has not fired yet.
    ///
    /// `scheduleAutoExport` puts the `.astra-workspace.json` mirror 600 ms
    /// behind its SwiftData save, so quitting inside that window drops the
    /// pending write and leaves the mirror stale (a task the user just read
    /// keeps its `unreadAt`, and a later import or recovery resurrects it as
    /// unread). Termination drains the queue through here.
    ///
    /// Bounded on purpose: only workspaces with a still-pending export are
    /// written, and the debounce coalesces to at most one entry per workspace,
    /// so this cannot fan out across the whole workspace list on quit.
    /// Returns how many mirrors were written.
    ///
    /// The write is synchronous rather than going through `saveAndAutoExport`.
    /// That path hands the encode and file write to a detached task, which is
    /// not guaranteed to be scheduled before the process exits, so at quit time
    /// it would drop exactly the write this call exists to make.
    /// `WorkspaceRecoveryService` uses the same synchronous
    /// `autoExportTarget` + `exportToFileResult` shape for the same reason.
    @discardableResult
    public static func flushAllPendingExports(modelContext: ModelContext) -> Int {
        let pending = pendingExports
        pendingExports.removeAll()
        for entry in pending.values {
            entry.task.cancel()
        }
        guard !pending.isEmpty else { return 0 }
        guard !shouldSkipAutoExport() else {
            AuditLoggingSeam.required.audit(.workspaceExported, category: "Persistence", fields: [
                "result": "skipped",
                "reason": "launch_flag"
            ], level: .debug)
            return 0
        }

        // One save covers the whole drain; the debounced saves already ran.
        saveWithoutAutoExport(
            modelContext: modelContext,
            auditFields: ["operation": "pending_export_drain"]
        )

        var exported = 0
        for entry in pending.values {
            let target = WorkspaceConfigManager.autoExportTarget(for: entry.workspace.primaryPath)
            guard let url = target.url else { continue }
            let result = WorkspaceConfigManager.exportToFileResult(
                workspace: entry.workspace,
                modelContext: modelContext,
                url: url
            )
            if result.didExport { exported += 1 }
        }
        return exported
    }

    public nonisolated static func shouldSkipAutoExport(
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

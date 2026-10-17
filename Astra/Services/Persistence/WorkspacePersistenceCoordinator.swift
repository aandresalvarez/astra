import Foundation
import SwiftData
import ASTRAModels
import ASTRACore

@MainActor
public enum WorkspacePersistenceCoordinator {
    /// The workspace is retained through debounce, projection and write so a
    /// termination flush can drain the current mirror synchronously.
    private struct PendingExport {
        let id: UUID
        let workspace: Workspace
        // The caller owns persistence. A deferred mirror must not keep a closed
        // context (and its autosave timer) alive. Active reads retain their
        // container only while actually reading; termination drains live owners.
        weak var context: ModelContext?
        weak var container: ModelContainer?
        let ticket: WorkspaceAutoExportGate.Ticket?
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
            try WorkspacePersistenceWork.measure("swiftdata_save", workspaceID: workspace?.id.uuidString ?? "none") {
                try modelContext.save()
            }
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
        enqueueSavedAutoExport(workspace: workspace, modelContext: modelContext)
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
            // The transcript's frequent pre-read flush deliberately emits no
            // success audit when auditsSuccess is false. Keep it free of
            // timing audits too; save-and-export boundaries are measured above.
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
            try WorkspacePersistenceWork.measure("swiftdata_save", workspaceID: workspace?.id.uuidString ?? "none") {
                try modelContext.save()
            }
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
        enqueueSavedAutoExport(workspace: workspace, modelContext: modelContext)
    }

    public static func saveWithoutAutoExportOrThrow(
        workspace: Workspace?,
        modelContext: ModelContext,
        taskID: UUID? = nil,
        auditFields: [String: String] = [:]
    ) throws {
        do {
            try WorkspacePersistenceWork.measure("swiftdata_save", workspaceID: workspace?.id.uuidString ?? "none") {
                try modelContext.save()
            }
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

    /// Called only after a successful save. The mirror reads that durable
    /// authority on its own actor rather than faulting every task's history on
    /// the main actor at each settlement checkpoint. Keep the request pending
    /// through the write so termination can synchronously drain it.
    private static func enqueueSavedAutoExport(workspace: Workspace, modelContext: ModelContext) {
        let target = WorkspaceConfigManager.autoExportTarget(for: workspace.primaryPath)
        guard let url = target.url else {
            logSkippedExport(workspace: workspace, reason: target.reason)
            return
        }
        // Register before dispatch, ordered with deletion on the saving actor.
        guard WorkspaceMirrorRegistry(for: modelContext)?.register([workspace.primaryPath]) ?? true else {
            logSkippedExport(workspace: workspace, reason: "mirror_registry_unwritable")
            return
        }
        let workspaceID = workspace.id
        let ticket = WorkspaceAutoExportGate.shared.beginExport(for: workspaceID.uuidString)
        let lease = WorkspaceSavedExportLease(context: modelContext, ticket: ticket)
        let container = modelContext.container
        let source = WorkspaceSavedExportSource(container)
        let requestID = UUID()
        pendingExports[workspaceID]?.task.cancel()
        pendingExports[workspaceID] = PendingExport(
            id: requestID, workspace: workspace, context: modelContext, container: container, ticket: ticket,
            task: Task { @MainActor in
                defer { withExtendedLifetime(lease) {} }
                guard !Task.isCancelled else { return }
                let written = await WorkspaceSavedAutoExport.shared.export(source: source, workspaceID: workspaceID,
                    url: url, ticket: ticket)
                // An old completion must never erase a newer pending request.
                if pendingExports[workspaceID]?.id == requestID,
                   written || pendingExports[workspaceID]?.context == nil || pendingExports[workspaceID]?.container == nil ||
                    workspace.isDeleted || workspace.modelContext == nil {
                    pendingExports[workspaceID] = nil
                }
            }
        )
    }

    private static func logSkippedExport(workspace: Workspace, reason: String) {
        AuditLoggingSeam.required.audit(.workspaceExported, category: "Persistence", fields: [
            "result": "auto_export_skipped", "reason": reason, "workspace_id": workspace.id.uuidString
        ], level: .debug)
    }

    /// A successful explicit snapshot can finish the work owed by an older
    /// coordinator request. Failed writes and later/debounced saves stay owed.
    static func autoExportDidWrite(_ ticket: WorkspaceAutoExportGate.Ticket) {
        guard let id = UUID(uuidString: ticket.workspaceID),
              let pending = pendingExports[id], let previous = pending.ticket,
              previous.generation <= ticket.generation,
              WorkspaceAutoExportGate.shared.isCurrent(ticket) else { return }
        if previous.generation < ticket.generation { pending.task.cancel() }
        pendingExports[id] = nil
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
        let container = modelContext.container
        pendingExports[workspaceID]?.task.cancel()
        pendingExports[workspaceID] = PendingExport(
            id: UUID(),
            workspace: workspace,
            context: modelContext,
            container: container,
            ticket: nil,
            task: Task { @MainActor in
                defer { withExtendedLifetime(container) {} }
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

    /// Workspaces whose debounced or in-flight mirror export has not finished.
    public static var pendingExportWorkspaceCount: Int { pendingExports.count }

    /// Waits for the currently scheduled attempt without saving, retrying, or
    /// promoting a deferred bookkeeping mirror. Callers must still check its
    /// output: invalidation or a write failure can leave a mirror owed.
    static func waitForPendingExport(workspaceID: UUID) async {
        await pendingExports[workspaceID]?.task.value
    }

    /// Writes every pending mirror, including projections already off-main.
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
        for (workspaceID, entry) in pending {
            entry.task.cancel()
            // A read/encode already executing off-main cannot be cancelled by
            // cancelling its waiter. Invalidate it before the synchronous drain
            // so it cannot overwrite the termination snapshot later.
            WorkspaceAutoExportGate.shared.retire(workspaceID: workspaceID.uuidString)
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
            guard let context = entry.context, let container = entry.container else { continue }
            defer { withExtendedLifetime(container) {} }
            guard !entry.workspace.isDeleted, entry.workspace.modelContext != nil else { continue }
            let target = WorkspaceConfigManager.autoExportTarget(for: entry.workspace.primaryPath)
            guard let url = target.url else { continue }
            let result = WorkspaceConfigManager.exportToFileResult(
                workspace: entry.workspace,
                modelContext: context,
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

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
        let source: WorkspaceSavedExportSource
        let lease: WorkspaceSavedExportLease?
        // A committed save is still owed when setup cannot launch a job.
        var task: Task<Void, Never>?
    }

    // Committed projections and unsaved debounce work are distinct obligations.
    // A debounce can replace another debounce; only a successful replacement
    // save/export can supersede a committed projection.
    private static var savedExports: [UUID: PendingExport] = [:]
    private static var debouncedExports: [UUID: PendingExport] = [:]

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
                try WorkspaceSavedExportLease.preservingPriorProjection(
                    for: shouldSkipAutoExport() ? nil : workspace?.id, context: modelContext) {
                    try modelContext.save()
                }
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
        debouncedExports.removeValue(forKey: workspace.id)?.task?.cancel()
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
                try WorkspaceSavedExportLease.preservingPriorProjection(
                    for: shouldSkipAutoExport() ? nil : workspace?.id, context: modelContext) {
                    try modelContext.save()
                }
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
        debouncedExports.removeValue(forKey: workspace.id)?.task?.cancel()
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
    @discardableResult
    static func enqueueSavedAutoExport(workspace: Workspace, modelContext: ModelContext,
                                      writer: WorkspaceAutoExportWriter = .shared,
                                      reader: WorkspaceSavedAutoExport = .shared,
                                      completion: (@MainActor (Bool) -> Void)? = nil) -> Task<Void, Never>? {
        let workspaceID = workspace.id
        let ticket = WorkspaceAutoExportGate.shared.beginRead(for: workspaceID.uuidString)
        let lease = WorkspaceSavedExportLease(context: modelContext, workspace: workspace, ticket: ticket)
        let container = modelContext.container
        let source = WorkspaceSavedExportSource(container)
        let requestID = UUID()
        // Unprepared reads may coalesce. A prepared value remains publishable
        // until its replacement has actually prepared and promoted a ticket.
        if savedExports[workspaceID]?.lease?.isSealed != true { savedExports[workspaceID]?.task?.cancel() }
        // Record the newer obligation before destination or registry setup.
        // Even a successful older fallback cannot complete this newer save.
        savedExports[workspaceID] = PendingExport(
            id: requestID, workspace: workspace, context: modelContext, source: source, lease: lease,
            task: nil
        )
        let target = WorkspaceConfigManager.autoExportTarget(for: workspace.primaryPath)
        guard let url = target.url else {
            logSkippedExport(workspace: workspace, reason: target.reason)
            completion?(false)
            return nil
        }
        // Register before dispatch, ordered with deletion on the saving actor.
        guard registerMirror(path: workspace.primaryPath, workspaceID: workspaceID, modelContext: modelContext) else {
            completion?(false)
            return nil
        }
        savedExports[workspaceID]?.task = Task { @MainActor in
            var written = false
            defer {
                completion?(written)
                withExtendedLifetime(lease) {}
            }
            guard !Task.isCancelled else { return }
            if let prepared = await reader.prepareForExport(source: source,
                workspaceID: workspaceID, url: url, lease: lease),
               !Task.isCancelled, let publication = lease.promote() {
                written = await writer.write(prepared.config, to: url,
                    workspaceID: workspaceID.uuidString, ticket: publication)
            }
            // An old completion must never erase a newer pending request.
            if savedExports[workspaceID]?.id == requestID,
               written || savedExports[workspaceID]?.context == nil || source.resolve() == nil ||
                workspace.isDeleted || workspace.modelContext == nil {
                savedExports[workspaceID] = nil
            }
        }
        return savedExports[workspaceID]?.task
    }

    /// Writes only durable state using the background projection reader. The
    /// acknowledgement belongs to this actual write, never to an empty queue
    /// or a completed task (both can also mean cancellation or failed setup).
    public static func exportSavedMirrorNow(workspace: Workspace, modelContext: ModelContext) async -> Bool {
        guard !Task.isCancelled, !modelContext.hasChanges else { return false }
        if shouldSkipAutoExport() { return true }
        if workspace.primaryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        let written = await withCheckedContinuation { continuation in
            enqueueSavedAutoExport(workspace: workspace, modelContext: modelContext,
                completion: { continuation.resume(returning: $0) })
        }
        return written && !Task.isCancelled
    }

    private static func registerMirror(path: String, workspaceID: UUID, modelContext: ModelContext) -> Bool {
        guard WorkspaceMirrorRegistry(for: modelContext)?.register([path]) ?? true else {
            AuditLoggingSeam.required.audit(.workspaceExported, category: "Persistence", fields: [
                "result": "auto_export_skipped", "reason": "mirror_registry_unwritable",
                "workspace_id": workspaceID.uuidString
            ], level: .debug)
            return false
        }
        return true
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
              let pending = savedExports[id], let lease = pending.lease,
              WorkspaceAutoExportGate.shared.isCurrent(ticket) else { return }
        guard ticket.coveredReadRevision >= lease.readTicket.revision else { return }
        pending.task?.cancel()
        savedExports[id] = nil
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
        let source = WorkspaceSavedExportSource(container)
        let requestID = UUID()
        debouncedExports[workspaceID]?.task?.cancel()
        debouncedExports[workspaceID] = PendingExport(
            id: requestID, workspace: workspace, context: modelContext,
            source: source, lease: nil,
            task: Task { @MainActor in
                defer { withExtendedLifetime(container) {} }
                do { try await Task.sleep(nanoseconds: delayNanoseconds) }
                catch { return }
                guard !Task.isCancelled, debouncedExports[workspaceID]?.id == requestID else { return }
                // A delayed save still belongs to its original store, even
                // if another store now exists at that URL. Check before
                // touching the old context or faulting its workspace models.
                guard source.resolve(workspaceID: workspaceID.uuidString) != nil else {
                    debouncedExports[workspaceID] = nil
                    return
                }
                // Success retires this debounce and enqueues its committed
                // replacement. Failure keeps both obligations drainable.
                saveAndAutoExport(workspace: workspace, modelContext: modelContext)
            }
        )
    }

    public static func flushPendingExport(workspace: Workspace?, modelContext: ModelContext) {
        // Do not cancel the committed projection (or its debounce) before the
        // replacement actually saves. A read-only/failed save owes the old one.
        saveAndAutoExport(workspace: workspace, modelContext: modelContext)
    }

    /// Count workspaces, even if both committed and unsaved work is pending.
    public static var pendingExportWorkspaceCount: Int {
        Set(savedExports.keys).union(debouncedExports.keys).count
    }

    /// Wait for the committed projection first, without saving pending edits.
    /// With only a debounce queued, wait for that scheduled attempt instead.
    /// A failure or invalidation may still leave an obligation to drain.
    static func waitForPendingExport(workspaceID: UUID) async {
        if let saved = savedExports[workspaceID] { await saved.task?.value }
        else { await debouncedExports[workspaceID]?.task?.value }
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
        var pending = savedExports
        for (id, entry) in debouncedExports {
            if entry.context != nil, entry.source.resolve() != nil { pending[id] = entry }
            else if pending[id] == nil { pending[id] = entry }
        }
        for entry in savedExports.values { entry.task?.cancel() }
        for entry in debouncedExports.values { entry.task?.cancel() }
        savedExports.removeAll()
        debouncedExports.removeAll()
        for workspaceID in pending.keys {
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

        // Validate each original owner before saving. A store recreated at the
        // same path is a different authority, even if the old context survives.
        var savedContexts = Set<ObjectIdentifier>()
        var exported = 0
        for (workspaceID, entry) in pending {
            guard let context = entry.context,
                  let container = entry.source.resolve(workspaceID: workspaceID.uuidString) else { continue }
            defer { withExtendedLifetime(container) {} }
            let owner = ObjectIdentifier(context)
            if savedContexts.insert(owner).inserted {
                saveWithoutAutoExport(modelContext: context,
                    auditFields: ["operation": "pending_export_drain"])
            }
            do {
                // Use only stable IDs and freshly read committed rows, even
                // after successful saves: an old context may have invalidated
                // lazy relationship snapshots after rollback or replacement.
                guard let prepared = try WorkspaceSavedAutoExport.prepareForTermination(
                    container: container, workspaceID: workspaceID),
                      entry.source.resolve(workspaceID: workspaceID.uuidString) != nil,
                      let url = WorkspaceConfigManager.autoExportTarget(for: prepared.config.primaryPath).url else { continue }
                guard registerMirror(path: prepared.config.primaryPath, workspaceID: workspaceID,
                    modelContext: context) else { continue }
                let result = WorkspaceConfigManager.writeResult(prepared.config,
                    workspaceID: workspaceID.uuidString, to: url)
                if result.didExport { exported += 1 }
            } catch {
                AuditLoggingSeam.required.audit(.workspaceExported, category: "Persistence", fields: [
                    "result": "auto_export_failed", "operation": "pending_export_drain_saved_rows",
                    "workspace_id": workspaceID.uuidString, "error_type": String(describing: type(of: error))
                ], level: .error)
            }
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

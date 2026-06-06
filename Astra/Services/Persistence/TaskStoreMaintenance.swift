import Foundation
import SwiftData

/// One-time-per-launch housekeeping that keeps the task store aligned with the
/// board invariant ("only meaningful supervisable work"). It does two things,
/// both conservative and audited rather than silent:
///
///  1. Prune *abandoned* low-signal drafts — never-run greeting/probe chats that
///     have gone stale. This is what clears the long tail of "open chat, type
///     hi, wander off" drafts.
///  2. Remove *exact* duplicate Claude Code session imports — tasks that share a
///     workspace + provider `sessionId` because an import ran more than once.
///     Keeps the earliest copy.
///
/// It never deletes work the user ran, pinned, planned, or recently touched.
enum TaskStoreMaintenance {
    @discardableResult
    @MainActor
    static func runStartupMaintenance(modelContext: ModelContext, now: Date = Date()) -> (prunedDrafts: Int, dedupedImports: Int) {
        let allTasks = (try? modelContext.fetch(FetchDescriptor<AgentTask>())) ?? []
        let pruned = pruneAbandonedDrafts(allTasks, modelContext: modelContext, now: now)
        let deduped = deduplicateImportedSessions(allTasks, modelContext: modelContext)

        if pruned > 0 || deduped > 0 {
            try? modelContext.save()
        }
        // Always emit one line so the pass is observable in logs even on a
        // no-op launch (positive confirmation that maintenance ran). The
        // `hidden_drafts` count is how many drafts the board now suppresses but
        // that aren't yet stale enough to delete.
        let hidden = allTasks.filter(TaskHygiene.isHiddenFromBoard).count
        AppLogger.audit(.taskStats, category: "App", fields: [
            "operation": "task_store_maintenance",
            "scanned_tasks": String(allTasks.count),
            "pruned_abandoned_drafts": String(pruned),
            "deduped_session_imports": String(deduped),
            "hidden_drafts": String(hidden)
        ], level: .info)
        return (pruned, deduped)
    }

    /// Delete low-signal drafts that have gone stale. Returns the count removed.
    @MainActor
    static func pruneAbandonedDrafts(
        _ tasks: [AgentTask],
        modelContext: ModelContext,
        olderThan staleInterval: TimeInterval = 24 * 3600,
        now: Date = Date()
    ) -> Int {
        var removed = 0
        for task in tasks where TaskHygiene.isPrunableAbandonedDraft(task, olderThan: staleInterval, now: now) {
            modelContext.delete(task)
            removed += 1
        }
        return removed
    }

    /// Collapse duplicate Claude Code session imports that share a workspace and
    /// `sessionId`, keeping the earliest-created copy. Returns the count removed.
    @MainActor
    static func deduplicateImportedSessions(_ tasks: [AgentTask], modelContext: ModelContext) -> Int {
        // Group imported-session tasks by their (workspace, sessionId) identity.
        var groups: [String: [AgentTask]] = [:]
        for task in tasks where isImportedSessionTask(task) {
            guard let sessionId = task.sessionId, !sessionId.isEmpty else { continue }
            let workspaceKey = task.workspace?.id.uuidString ?? "no-workspace"
            groups[workspaceKey + "|" + sessionId, default: []].append(task)
        }

        var removed = 0
        for (_, duplicates) in groups where duplicates.count > 1 {
            // Keep the earliest import; delete the rest.
            let sorted = duplicates.sorted { $0.createdAt < $1.createdAt }
            for task in sorted.dropFirst() {
                modelContext.delete(task)
                removed += 1
            }
        }
        return removed
    }

    /// A task created by `SessionScanner.importSessions`: a completed, archived
    /// run carrying a provider session id and the import marker event.
    private static func isImportedSessionTask(_ task: AgentTask) -> Bool {
        guard task.status == .completed, task.isDone else { return false }
        guard let sessionId = task.sessionId, !sessionId.isEmpty else { return false }
        return task.events.contains { event in
            event.payload.hasPrefix(SessionScanner.importedSessionMarker)
        }
    }
}

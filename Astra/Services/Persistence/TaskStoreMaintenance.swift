import Foundation
import SwiftData
import ASTRAModels
import ASTRACore

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
public enum TaskStoreMaintenance {
    @discardableResult
    @MainActor
    public static func runStartupMaintenance(modelContext: ModelContext, now: Date = Date()) -> (prunedDrafts: Int, dedupedImports: Int) {
        let allTasks = (try? modelContext.fetch(FetchDescriptor<AgentTask>())) ?? []
        let pruned = pruneAbandonedDrafts(allTasks, modelContext: modelContext, now: now)
        let deduped = deduplicateImportedSessions(allTasks, modelContext: modelContext)

        if pruned > 0 || deduped > 0 {
            try? modelContext.save()
        }
        // Always emit one line so the pass is observable in logs even on a
        // no-op launch (positive confirmation that maintenance ran). The
        // `hidden_drafts` is how many drafts the board still suppresses *after*
        // this pass — i.e. survivors that weren't stale enough to delete. The
        // pruned drafts are a subset of the hidden set (`allTasks` is the
        // pre-prune snapshot), so subtract them to keep the count accurate.
        let hidden = max(0, allTasks.filter(TaskHygiene.isHiddenFromBoard).count - pruned)
        AuditLoggingSeam.required.audit(.taskStats, category: "App", fields: [
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
    public static func pruneAbandonedDrafts(
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
    public static func deduplicateImportedSessions(_ tasks: [AgentTask], modelContext: ModelContext) -> Int {
        // Group imported-session tasks by their (workspace, sessionId) identity.
        var groups: [String: [AgentTask]] = [:]
        for task in tasks where isImportedSessionTask(task) {
            guard let sessionId = task.sessionId, !sessionId.isEmpty else { continue }
            let workspaceKey = task.workspace?.id.uuidString ?? "no-workspace"
            groups[workspaceKey + "|" + sessionId, default: []].append(task)
        }

        var removed = 0
        for (_, duplicates) in groups where duplicates.count > 1 {
            // Keep one copy, delete the rest. Prefer a task with an active
            // durable turn request (its queued user message must survive —
            // startup dedup runs BEFORE turn recovery, and the scalar
            // `taskID` reference doesn't cascade, so deleting that task would
            // strand the request and lose the message), then a pinned task
            // (user-curated) so dedup never drops a pin in favour of an
            // unpinned twin, then the earliest import, then a stable id
            // tiebreaker — imported sessions overwrite createdAt with the
            // session start time, so ties are common and the survivor must
            // be deterministic.
            let sorted = duplicates.sorted { lhs, rhs in
                let lhsActive = hasActiveTurnRequests(lhs, modelContext: modelContext)
                let rhsActive = hasActiveTurnRequests(rhs, modelContext: modelContext)
                if lhsActive != rhsActive { return lhsActive }
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            for task in sorted.dropFirst() {
                // Both copies carrying active requests is possible (a follow-up
                // was submitted from each before a restart); never delete a
                // task whose queued message would be lost with it.
                guard !hasActiveTurnRequests(task, modelContext: modelContext) else { continue }
                removeTurnRequests(for: task, modelContext: modelContext)
                modelContext.delete(task)
                removed += 1
            }
        }
        return removed
    }

    /// Whether the task has a durable turn request that is not yet terminal.
    /// Mirrors `TaskTurnRequestRepository.activeRequests` (app target, not
    /// importable here).
    @MainActor
    private static func hasActiveTurnRequests(_ task: AgentTask, modelContext: ModelContext) -> Bool {
        let taskID = task.id
        let completed = TaskTurnRequestState.completed.rawValue
        let failed = TaskTurnRequestState.failed.rawValue
        let cancelled = TaskTurnRequestState.cancelled.rawValue
        var descriptor = FetchDescriptor<TaskTurnRequest>(
            predicate: #Predicate {
                $0.taskID == taskID
                    && $0.stateRawValue != completed
                    && $0.stateRawValue != failed
                    && $0.stateRawValue != cancelled
            }
        )
        descriptor.fetchLimit = 1
        return ((try? modelContext.fetch(descriptor)) ?? []).isEmpty == false
    }

    /// Turn requests reference their task by scalar id, so task deletion never
    /// cascades to them; remove the (terminal) rows with their task or they
    /// accumulate as permanent orphans.
    @MainActor
    private static func removeTurnRequests(for task: AgentTask, modelContext: ModelContext) {
        let taskID = task.id
        let descriptor = FetchDescriptor<TaskTurnRequest>(
            predicate: #Predicate { $0.taskID == taskID }
        )
        for request in (try? modelContext.fetch(descriptor)) ?? [] {
            modelContext.delete(request)
        }
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

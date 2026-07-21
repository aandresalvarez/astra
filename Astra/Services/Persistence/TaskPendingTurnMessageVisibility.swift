import Foundation
import SwiftData
import ASTRAModels

/// Identifies `user.message` events that belong to durable turns which are
/// persisted but not yet admitted.
///
/// Durable submission writes every follow-up to `task.events` immediately, so
/// while turn N is being prompted, turns N+1… already exist as ordinary
/// user-message events. Context and prompt scanners that walk `task.events`
/// must treat those messages as invisible until their own admission —
/// otherwise turn N absorbs turn N+1's instructions (or has its objective
/// superseded by it) despite FIFO admission ordering.
///
/// Deliberately nonisolated: callers (context refresh, objective resolution)
/// already assume caller-side isolation for `task.events` access, and the
/// fetch uses the task's own `modelContext` under that same assumption.
public enum TaskPendingTurnMessageVisibility {
    /// Event ids of user messages that must stay invisible to prompt
    /// scanners: turns still waiting for a worker or resource, plus turns
    /// that terminalized without ever starting provider work (`startedAt`
    /// nil — a cancelled or admission-failed request). A retracted
    /// instruction (e.g. an objective override the user cancelled while it
    /// waited) must never leak into a later turn's prompt just because its
    /// append-only message event outlives the request state.
    /// Admitted/running requests are deliberately visible: the turn
    /// currently being prompted owns one of those states, and FIFO admission
    /// guarantees no later turn can reach them first. Retry-from-terminal
    /// clears `startedAt`, so a retried turn re-hides until re-admission.
    public static func pendingMessageEventIDs(for task: AgentTask) -> Set<UUID> {
        guard let modelContext = task.modelContext else { return [] }
        let taskID = task.id
        let waitingForWorker = TaskTurnRequestState.waitingForWorker.rawValue
        let waitingForResource = TaskTurnRequestState.waitingForResource.rawValue
        let cancelled = TaskTurnRequestState.cancelled.rawValue
        let failed = TaskTurnRequestState.failed.rawValue
        let descriptor = FetchDescriptor<TaskTurnRequest>(
            predicate: #Predicate {
                $0.taskID == taskID && (
                    $0.stateRawValue == waitingForWorker
                        || $0.stateRawValue == waitingForResource
                        || (
                            ($0.stateRawValue == cancelled || $0.stateRawValue == failed)
                                && $0.startedAt == nil
                        )
                )
            }
        )
        guard let requests = try? modelContext.fetch(descriptor) else { return [] }
        return Set(requests.map(\.messageEventID))
    }
}

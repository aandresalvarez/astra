import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import WorkspaceToolSupport

@MainActor
enum RemoteWorkspaceJobEventReconciler {
    static func reconcile(_ job: RemoteWorkspaceJobRecord, task: AgentTask, context: ModelContext,
                          store: RemoteWorkspaceJobStore) throws {
        guard task.isLive, task.modelContext === context else { return }
        let pending = job.pendingTransitions ?? []
        guard !pending.isEmpty else { return }
        let existing = Set(task.events.map(\.id))
        var inserted: [TaskEvent] = []
        for transition in pending where !existing.contains(transition.id) {
            let event = TaskEvent(task: task,
                eventType: transition.cancellation ? TaskEventTypes.System.remoteJobCancellation : TaskEventTypes.System.remoteJobObserved,
                payload: String(decoding: try JSONEncoder().encode(transition), as: UTF8.self))
            event.id = transition.id
            context.insert(event); inserted.append(event)
        }
        do { try context.save() }
        catch { for event in inserted { context.delete(event) }; throw error }
        let delivered = Set(pending.map(\.id))
        try store.update(jobID: job.jobID) { record in
            record.pendingTransitions?.removeAll { delivered.contains($0.id) }
        }
    }
}

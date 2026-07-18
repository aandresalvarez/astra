import Foundation
import SwiftData
import ASTRAModels

/// Links a send-boundary event to its admitted run without creating a second
/// user message. Kept outside the runtime worker so the ownership rule stays
/// explicit and independently testable.
@MainActor
enum PersistedTurnRuntimeEventLinker {
    @discardableResult
    static func link(
        eventID: UUID?,
        to run: TaskRun,
        for task: AgentTask,
        fallbackType: String,
        fallbackPayload: String,
        in modelContext: ModelContext
    ) -> Bool {
        if let eventID,
           let event = task.events.first(where: { $0.id == eventID }) {
            event.run = run
            TaskThreadChangeNotifier.post(taskID: task.id, source: "turn_request_admitted")
            return true
        }
        let event = TaskEvent(task: task, type: fallbackType, payload: fallbackPayload, run: run)
        TaskEventInsertionService.insert(event, into: modelContext)
        return false
    }
}

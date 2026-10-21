import Foundation
import SwiftData
import ASTRAModels
import ASTRAPersistence

/// Durable progress prevents a failed verdict save from repeating validation
/// commands or plan transitions. An interrupted, unprepared attempt is uncertain.
@MainActor
enum RuntimeSettlementProgress {
    struct Prepared: Codable {
        let taskStatus: TaskStatus
        let taskCompletedAt: Date?
        // Legacy prepared records were written after finalization.
        var finalizationComplete: Bool? = nil
    }

    static func event(_ type: TaskEventType, task: AgentTask, run: TaskRun) -> TaskEvent? {
        TaskEventTypeLookup.first(ofType: type.rawValue, task: task, run: run)
    }

    static func prepared(task: AgentTask, run: TaskRun) throws -> Prepared? {
        guard let event = event(TaskEventTypes.System.runtimeOutcomePrepared, task: task, run: run) else { return nil }
        return try JSONDecoder().decode(Prepared.self, from: Data(event.payload.utf8))
    }

    static func stagePrepared(task: AgentTask, run: TaskRun, modelContext: ModelContext,
                              finalizationComplete: Bool = true) {
        let prepared = Prepared(taskStatus: task.status, taskCompletedAt: task.completedAt,
                                finalizationComplete: finalizationComplete)
        if let existing = event(TaskEventTypes.System.runtimeOutcomePrepared, task: task, run: run) {
            if let payload = try? JSONEncoder().encode(prepared), let json = String(data: payload, encoding: .utf8) {
                existing.payload = json
            }
        } else {
            modelContext.insert(TaskEvent.structuredPayloadEvent(task: task,
                type: TaskEventTypes.System.runtimeOutcomePrepared.rawValue, payload: prepared, run: run))
        }
    }

    static func restore(_ prepared: Prepared, task: AgentTask, modelContext: ModelContext) {
        guard task.status != .cancelled, !task.isDone else { return }
        TaskStateMachine.restoreExecutionSubmissionFailure(task,
            snapshot: .init(status: prepared.taskStatus, completedAt: prepared.taskCompletedAt), modelContext: modelContext)
    }

    @discardableResult
    static func pruneSettledCaptures(task: AgentTask, modelContext: ModelContext) -> Bool {
        // The staged captures first: once pruned there are none, so the common
        // call reads three empty result sets and decodes no verdict at all.
        let captures = [TaskEventTypes.System.runtimeResultCaptured, TaskEventTypes.System.runtimeSettlementStarted,
                        TaskEventTypes.System.runtimeOutcomePrepared]
            .flatMap { TaskEventTypeLookup.events(ofType: $0.rawValue, task: task) }
        let capturedRunIDs = Set(captures.compactMap { $0.run?.id })
        guard !capturedRunIDs.isEmpty else { return false }
        let settled = Set(TaskEventTypeLookup.events(ofType: TaskEventTypes.System.runtimeTurnSettled.rawValue, task: task)
            .filter {
                guard let runID = $0.run?.id, capturedRunIDs.contains(runID),
                      let verdict = try? JSONDecoder().decode(RuntimeTurnSettlementService.Verdict.self, from: Data($0.payload.utf8))
                else { return false }
                return verdict.version == 1
            }
            .compactMap { $0.run?.id })
        var changed = false
        for event in captures where event.run.map({ settled.contains($0.id) }) == true {
            TaskEventIndex.delete(event, from: modelContext)
            changed = true
        }
        return changed
    }
}

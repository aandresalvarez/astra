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
        task.events.first { !$0.isDeleted && $0.run?.id == run.id && $0.type == type.rawValue }
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
        var changed = false
        let settled = Set(task.events.filter {
            guard !$0.isDeleted, $0.type == TaskEventTypes.System.runtimeTurnSettled.rawValue,
                  let verdict = try? JSONDecoder().decode(RuntimeTurnSettlementService.Verdict.self, from: Data($0.payload.utf8)) else { return false }
            return verdict.version == 1
        }.compactMap { $0.run?.id })
        for event in task.events where !event.isDeleted && event.run.map({ settled.contains($0.id) }) == true {
            if [TaskEventTypes.System.runtimeResultCaptured, TaskEventTypes.System.runtimeSettlementStarted,
                TaskEventTypes.System.runtimeOutcomePrepared].contains(where: { $0.rawValue == event.type }) {
                modelContext.delete(event)
                changed = true
            }
        }
        return changed
    }
}

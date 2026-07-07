import Foundation

/// Pure read-side query slice of
/// `Astra/Services/Validation/TaskCorrectiveWorkService.swift`, extracted
/// for Track A4 (`ASTRAPersistence`) so `TaskContextStateManager.swift` can
/// read a task's corrective-work state without depending on the write side
/// of that app-side service (which inserts `TaskEvent`s, calls `AppLogger`,
/// and refreshes UI-facing derived state). `TaskCorrectiveWorkService`'s own
/// write-side methods call through to these same functions, so behavior is
/// unchanged - only the pure query logic physically moved.
public struct TaskCorrectiveWorkRecord {
    public var event: TaskEvent
    public var payload: TaskCorrectiveStepPayload

    public init(event: TaskEvent, payload: TaskCorrectiveStepPayload) {
        self.event = event
        self.payload = payload
    }
}

public enum TaskCorrectiveWorkQueries {
    @MainActor
    public static func latestCorrectiveSteps(for task: AgentTask) -> [TaskCorrectiveWorkRecord] {
        var latestByID: [String: TaskCorrectiveWorkRecord] = [:]
        for event in task.events
            .filter({ isCorrectiveStepEvent($0.type) })
            .sorted(by: { $0.timestamp > $1.timestamp }) {
            guard let payload = decode(event.payload) else { continue }
            let stepID = normalizedCorrectiveStepID(payload)
            guard latestByID[stepID] == nil else { continue }
            latestByID[stepID] = TaskCorrectiveWorkRecord(event: event, payload: payload)
        }
        return latestByID.values.sorted { $0.event.timestamp > $1.event.timestamp }
    }

    @MainActor
    public static func openCorrectiveSteps(for task: AgentTask) -> [TaskCorrectiveWorkRecord] {
        latestCorrectiveSteps(for: task).filter { record in
            ["proposed", "approved", "task_created"].contains(record.payload.status)
        }
    }

    public static func correctiveStepID(planID: UUID, failedAssertionID: String) -> String {
        "corrective-\(planID.uuidString.prefix(8))-\(failedAssertionID)"
    }

    public static func normalizedCorrectiveStepID(_ payload: TaskCorrectiveStepPayload) -> String {
        payload.correctiveStepID ?? correctiveStepID(planID: payload.planID, failedAssertionID: payload.failedAssertionID)
    }

    public static func decode(_ payload: String) -> TaskCorrectiveStepPayload? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TaskCorrectiveStepPayload.self, from: data)
    }

    private static func isCorrectiveStepEvent(_ type: String) -> Bool {
        type == TaskCorrectiveEventTypes.stepCreated ||
            type == TaskCorrectiveEventTypes.stepApproved ||
            type == TaskCorrectiveEventTypes.stepDismissed ||
            type == TaskCorrectiveEventTypes.taskCreated
    }
}

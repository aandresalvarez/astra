import Foundation
import SwiftData

enum TaskCorrectiveWorkService {
    struct CorrectiveStepRecord {
        var event: TaskEvent
        var payload: TaskCorrectiveStepPayload
    }

    @MainActor
    static func latestCorrectiveSteps(for task: AgentTask) -> [CorrectiveStepRecord] {
        var latestByID: [String: CorrectiveStepRecord] = [:]
        for event in task.events
            .filter({ TaskCorrectiveWorkService.isCorrectiveStepEvent($0.type) })
            .sorted(by: { $0.timestamp > $1.timestamp }) {
            guard let payload = decode(event.payload) else { continue }
            let stepID = normalizedCorrectiveStepID(payload)
            guard latestByID[stepID] == nil else { continue }
            latestByID[stepID] = CorrectiveStepRecord(event: event, payload: payload)
        }
        return latestByID.values.sorted { $0.event.timestamp > $1.event.timestamp }
    }

    @MainActor
    static func openCorrectiveSteps(for task: AgentTask) -> [CorrectiveStepRecord] {
        latestCorrectiveSteps(for: task).filter { record in
            ["proposed", "approved", "task_created"].contains(record.payload.status)
        }
    }

    @MainActor
    static func recordProposedStep(
        planID: UUID,
        sourceRunID: UUID?,
        failedAssertionID: String,
        failureSummary: String,
        suggestedRepair: String,
        task: AgentTask,
        run: TaskRun?,
        modelContext: ModelContext
    ) {
        let stepID = correctiveStepID(planID: planID, failedAssertionID: failedAssertionID)
        guard latestCorrectiveSteps(for: task).contains(where: {
            normalizedCorrectiveStepID($0.payload) == stepID &&
                $0.payload.status != "dismissed"
        }) == false else {
            return
        }

        let payload = TaskCorrectiveStepPayload(
            version: 1,
            planID: planID,
            sourceRunID: sourceRunID,
            correctiveStepID: stepID,
            failedAssertionID: failedAssertionID,
            failureSummary: failureSummary,
            suggestedRepair: suggestedRepair,
            status: "proposed",
            correctiveTaskID: nil,
            dismissedReason: nil,
            createdAt: isoTimestamp(Date()),
            updatedAt: nil
        )
        modelContext.insert(TaskEvent(
            task: task,
            type: TaskCorrectiveEventTypes.stepCreated,
            payload: encode(payload),
            run: run
        ))
        AppLogger.audit(.correctiveStepCreated, category: "Validation", taskID: task.id, fields: [
            "plan_id": planID.uuidString,
            "source_run_id": sourceRunID?.uuidString ?? "none",
            "failed_assertion_id": failedAssertionID,
            "corrective_step_id": stepID,
            "repair": suggestedRepair
        ], level: .warning)
        TaskContextStateManager.refresh(task: task)
    }

    @MainActor
    @discardableResult
    static func approveStep(
        task: AgentTask,
        correctiveStepID: String,
        modelContext: ModelContext
    ) -> TaskCorrectiveStepPayload? {
        guard var payload = latestCorrectiveSteps(for: task)
            .first(where: { normalizedCorrectiveStepID($0.payload) == correctiveStepID })?
            .payload else {
            return nil
        }
        payload.correctiveStepID = normalizedCorrectiveStepID(payload)
        payload.status = "approved"
        payload.updatedAt = isoTimestamp(Date())
        let event = TaskEvent(task: task, type: TaskCorrectiveEventTypes.stepApproved, payload: encode(payload))
        modelContext.insert(event)
        AppLogger.audit(.correctiveStepApproved, category: "Validation", taskID: task.id, fields: [
            "plan_id": payload.planID.uuidString,
            "source_run_id": payload.sourceRunID?.uuidString ?? "none",
            "failed_assertion_id": payload.failedAssertionID,
            "corrective_step_id": payload.correctiveStepID ?? correctiveStepID
        ])
        TaskContextStateManager.refresh(task: task)
        return payload
    }

    @MainActor
    @discardableResult
    static func dismissStep(
        task: AgentTask,
        correctiveStepID: String,
        reason: String,
        modelContext: ModelContext
    ) -> TaskCorrectiveStepPayload? {
        guard var payload = latestCorrectiveSteps(for: task)
            .first(where: { normalizedCorrectiveStepID($0.payload) == correctiveStepID })?
            .payload else {
            return nil
        }
        payload.correctiveStepID = normalizedCorrectiveStepID(payload)
        payload.status = "dismissed"
        payload.dismissedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        payload.updatedAt = isoTimestamp(Date())
        modelContext.insert(TaskEvent(task: task, type: TaskCorrectiveEventTypes.stepDismissed, payload: encode(payload)))
        AppLogger.audit(.correctiveStepDismissed, category: "Validation", taskID: task.id, fields: [
            "plan_id": payload.planID.uuidString,
            "source_run_id": payload.sourceRunID?.uuidString ?? "none",
            "failed_assertion_id": payload.failedAssertionID,
            "corrective_step_id": payload.correctiveStepID ?? correctiveStepID,
            "reason": payload.dismissedReason ?? ""
        ])
        TaskContextStateManager.refresh(task: task)
        return payload
    }

    @MainActor
    @discardableResult
    static func createCorrectiveTask(
        from sourceTask: AgentTask,
        correctiveStepID: String,
        modelContext: ModelContext
    ) -> AgentTask? {
        guard var payload = latestCorrectiveSteps(for: sourceTask)
            .first(where: { normalizedCorrectiveStepID($0.payload) == correctiveStepID })?
            .payload else {
            return nil
        }
        if payload.status == "task_created",
           let correctiveTaskID = payload.correctiveTaskID {
            return sourceTask.workspace?.tasks.first { $0.id == correctiveTaskID }
        }
        let child = AgentTask(
            title: "Correct validation: \(payload.failedAssertionID)",
            goal: """
            Fix the failed validation assertion `\(payload.failedAssertionID)`.

            Failure:
            \(payload.failureSummary)

            Suggested repair:
            \(payload.suggestedRepair)
            """,
            workspace: sourceTask.workspace,
            tokenBudget: sourceTask.tokenBudget,
            model: sourceTask.model,
            runtime: sourceTask.resolvedRuntimeID,
            isolationStrategy: sourceTask.isolationStrategy,
            validationStrategy: sourceTask.validationStrategy
        )
        child.constraints = sourceTask.constraints + [
            "Corrective work for source task \(sourceTask.id.uuidString)",
            "Failed assertion ID: \(payload.failedAssertionID)"
        ]
        child.acceptanceCriteria = sourceTask.acceptanceCriteria + [
            "Validation assertion \(payload.failedAssertionID) passes when rerun."
        ]
        child.executionRootPath = sourceTask.executionRootPath
        child.executionEnvironmentSnapshotJSON = sourceTask.executionEnvironmentSnapshotJSON
        child.queuePosition = (sourceTask.workspace?.tasks.map(\.queuePosition).max() ?? sourceTask.queuePosition) + 1
        modelContext.insert(child)

        payload.correctiveStepID = normalizedCorrectiveStepID(payload)
        payload.status = "task_created"
        payload.correctiveTaskID = child.id
        payload.updatedAt = isoTimestamp(Date())
        modelContext.insert(TaskEvent(task: sourceTask, type: TaskCorrectiveEventTypes.taskCreated, payload: encode(payload)))
        AppLogger.audit(.correctiveTaskCreated, category: "Validation", taskID: sourceTask.id, fields: [
            "plan_id": payload.planID.uuidString,
            "source_run_id": payload.sourceRunID?.uuidString ?? "none",
            "failed_assertion_id": payload.failedAssertionID,
            "corrective_step_id": payload.correctiveStepID ?? correctiveStepID,
            "corrective_task_id": child.id.uuidString
        ])
        TaskContextStateManager.refresh(task: sourceTask)
        return child
    }

    static func decode(_ payload: String) -> TaskCorrectiveStepPayload? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TaskCorrectiveStepPayload.self, from: data)
    }

    static func correctiveStepID(planID: UUID, failedAssertionID: String) -> String {
        "corrective-\(planID.uuidString.prefix(8))-\(failedAssertionID)"
    }

    static func normalizedCorrectiveStepID(_ payload: TaskCorrectiveStepPayload) -> String {
        payload.correctiveStepID ?? correctiveStepID(planID: payload.planID, failedAssertionID: payload.failedAssertionID)
    }

    private static func isCorrectiveStepEvent(_ type: String) -> Bool {
        type == TaskCorrectiveEventTypes.stepCreated ||
            type == TaskCorrectiveEventTypes.stepApproved ||
            type == TaskCorrectiveEventTypes.stepDismissed ||
            type == TaskCorrectiveEventTypes.taskCreated
    }

    private static func isoTimestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func encode<T: Encodable>(_ payload: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}
